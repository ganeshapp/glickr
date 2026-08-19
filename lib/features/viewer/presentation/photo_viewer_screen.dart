import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../../../core/models/album.dart';
import '../../../core/models/media_item.dart';
import '../../../core/providers/album_actions_provider.dart';
import '../../../core/providers/config_provider.dart';
import '../../../core/providers/services_provider.dart';
import '../../../core/services/media_pipeline_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/remote_media.dart';

/// Drag distance past which releasing dismisses the viewer.
const double _dismissDistance = 120;

/// ...or this much downward velocity, so a quick flick works without the
/// finger ever travelling 120px.
const double _dismissVelocity = 700;

/// Distance over which the drag fades the backdrop out completely.
const double _dismissFade = 300;

enum _ViewerAction { details, share, setCover, delete }

/// Full-screen viewer for one album, opened from the album grid.
///
/// Pages over [Album.allInDisplayOrder] - the cover included - so the index the
/// grid passes in lines up with what it shows. Anything that reorders the album
/// (setting a new cover renames files) reorders both the same way.
class PhotoViewerScreen extends ConsumerStatefulWidget {
  final Album album;
  final int initialIndex;

  const PhotoViewerScreen({
    super.key,
    required this.album,
    this.initialIndex = 0,
  });

  /// A route that leaves the page underneath painted.
  ///
  /// Drag-to-dismiss fades the black backdrop out to reveal the grid behind it.
  /// On an ordinary opaque route there is nothing behind to reveal, so the
  /// gesture just fades into a black hole.
  static Route<void> route(
    BuildContext context, {
    required Album album,
    required int initialIndex,
  }) {
    // Hero flights are driven by the route's animation, so collapsing this to
    // zero is also what stops the photo flying under "Remove animations".
    final duration = context.motion(const Duration(milliseconds: 300));
    return PageRouteBuilder<void>(
      opaque: false,
      transitionDuration: duration,
      reverseTransitionDuration: duration,
      pageBuilder:
          (_, _, _) =>
              PhotoViewerScreen(album: album, initialIndex: initialIndex),
      transitionsBuilder:
          (_, animation, _, child) =>
              FadeTransition(opacity: animation, child: child),
    );
  }

  @override
  ConsumerState<PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends ConsumerState<PhotoViewerScreen>
    with SingleTickerProviderStateMixin {
  late final PageController _pager;

  /// Spring-back for a drag that didn't travel far enough to dismiss.
  late final AnimationController _settle;
  double _settleFrom = 0;

  /// Live drag offset in logical pixels. A [ValueNotifier] rather than
  /// setState: a drag updates at 120Hz and this must not rebuild the gallery,
  /// which would tear down and rebuild the decoded image on every frame.
  final ValueNotifier<double> _dragY = ValueNotifier<double>(0);

  /// blobSha -> resolved bytes on disk. A key present with a null value means
  /// the fetch failed; an absent key means it hasn't been asked for yet.
  final Map<String, File?> _resolved = <String, File?>{};
  final Map<String, Future<File?>> _requests = <String, Future<File?>>{};

  /// Exactly one video controller exists at a time, and it belongs to the
  /// current page. Holding one per page would keep a hardware decoder open for
  /// every neighbour the PageView has built.
  VideoPlayerController? _video;
  String? _videoKey;
  bool _videoFailed = false;

  int _index = 0;
  bool _chromeVisible = true;
  bool _zoomed = false;
  bool _busy = false;
  bool _exiting = false;

  @override
  void initState() {
    super.initState();
    final count = widget.album.allInDisplayOrder.length;
    _index = count == 0 ? 0 : widget.initialIndex.clamp(0, count - 1);
    _pager = PageController(initialPage: _index);
    _settle = AnimationController(vsync: this)..addListener(() {
      _dragY.value =
          _settleFrom * (1 - Curves.easeOut.transform(_settle.value));
    });
  }

  @override
  void dispose() {
    _video?.dispose();
    _pager.dispose();
    _settle.dispose();
    _dragY.dispose();
    // The viewer is the only screen that hides the system bars, so it is also
    // the only one that has to put them back.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  // ------------------------------------------------------------------ bytes

  /// Resolve [item] to a file on disk, from cache when possible.
  ///
  /// Memoised on the blob sha, which is also the cache key, so the page, the
  /// share sheet and a second build all wait on one download.
  Future<File?> _fileFor(MediaItem item) {
    final key = item.blobSha;
    return _requests.putIfAbsent(key, () async {
      final file = await _download(item);
      _resolved[key] = file;
      if (mounted) setState(() {});
      return file;
    });
  }

  Future<File?> _download(MediaItem item) async {
    final cache = ref.read(mediaCacheServiceProvider);
    try {
      final hit = await cache.cachedFile(item);
      if (hit != null) return hit;

      final config = ref.read(configNotifierProvider);
      final commitSha = ref.read(syncStateNotifierProvider).commitSha;
      if (config == null || commitSha == null) return null;
      return await cache.fetch(
        config: config,
        album: widget.album,
        item: item,
        commitSha: commitSha,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _retry(MediaItem item) async {
    // Evict before re-requesting: a truncated download stays truncated no
    // matter how many times it is read back out of the cache.
    await ref.read(mediaCacheServiceProvider).evict(item.blobSha);
    if (!mounted) return;
    setState(() {
      _resolved.remove(item.blobSha);
      _requests.remove(item.blobSha);
    });
  }

  // ------------------------------------------------------------------ video

  /// Make the open controller match [current], creating and tearing down as
  /// the user swipes.
  ///
  /// Driven from build because three unrelated things decide which video
  /// should be open - a page change, a download finishing, and a delete
  /// shifting the list - and funnelling them here means there is one place
  /// where a controller can leak. It only touches fields; the async
  /// initialisation calls setState later.
  void _syncVideo(MediaItem current) {
    final wanted = current.isVideo ? current.blobSha : null;
    if (wanted == _videoKey) return;

    _closeVideo();
    _videoFailed = false;
    if (wanted == null) return;

    final file = _resolved[wanted];
    if (file == null) return; // still downloading - the next build tries again
    unawaited(_openVideo(wanted, file));
  }

  Future<void> _openVideo(String key, File file) async {
    final controller = VideoPlayerController.file(file);
    // Claimed synchronously so a rebuild during initialisation can't start a
    // second controller for the same page.
    _video = controller;
    _videoKey = key;

    try {
      await controller.initialize();
    } catch (_) {
      if (_video != controller) return; // superseded; _closeVideo owns it now
      _video = null;
      _videoFailed = true;
      await controller.dispose();
      if (mounted) setState(() {});
      return;
    }

    if (!mounted || _video != controller) return;
    setState(() {});
  }

  void _closeVideo() {
    final controller = _video;
    _video = null;
    _videoKey = null;
    if (controller == null) return;
    // Deferred one frame: this runs during build, and the VideoPlayer widget
    // still holding this controller is only unmounted once that build lands.
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
  }

  Future<void> _togglePlay() async {
    final controller = _video;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isPlaying) {
      await controller.pause();
      return;
    }
    // Start over rather than sitting on the last frame when the clip has run
    // to the end.
    if (controller.value.position >= controller.value.duration) {
      await controller.seekTo(Duration.zero);
    }
    await controller.play();
  }

  // ----------------------------------------------------------------- chrome

  void _toggleChrome() => _setChrome(!_chromeVisible);

  void _setChrome(bool visible) {
    if (_chromeVisible == visible) return;
    setState(() => _chromeVisible = visible);
    SystemChrome.setEnabledSystemUIMode(
      visible ? SystemUiMode.edgeToEdge : SystemUiMode.immersive,
    );
  }

  void _onPageChanged(int page) {
    setState(() {
      _index = page;
      // Each page carries its own scale controller, and photo_view doesn't
      // report the reset when the new one comes into view.
      _zoomed = false;
    });
  }

  void _onScaleState(PhotoViewScaleState state) {
    final zoomed =
        state != PhotoViewScaleState.initial &&
        state != PhotoViewScaleState.zoomedOut;
    if (zoomed == _zoomed) return;
    setState(() => _zoomed = zoomed);
  }

  // ------------------------------------------------------------------- drag

  void _onDragUpdate(DragUpdateDetails details) {
    _dragY.value += details.delta.dy;
  }

  void _onDragEnd(DragEndDetails details) {
    final travelled = _dragY.value.abs();
    final velocity = details.velocity.pixelsPerSecond.dy.abs();
    if (travelled >= _dismissDistance || velocity >= _dismissVelocity) {
      // Leave the offset where it is: the hero flies back to its grid tile
      // from wherever the finger let go.
      Navigator.of(context).maybePop();
      return;
    }

    final duration = context.motion(const Duration(milliseconds: 220));
    if (duration == Duration.zero) {
      _dragY.value = 0;
      return;
    }
    _settleFrom = _dragY.value;
    _settle
      ..duration = duration
      ..value = 0
      ..forward();
  }

  // ---------------------------------------------------------------- actions

  Future<bool> _run(Future<ActionResult> Function() action) async {
    if (_busy) return false;
    setState(() => _busy = true);
    final result = await action();
    if (!mounted) return result.ok;
    setState(() => _busy = false);
    if (!result.ok) _snack(result.error ?? "That didn't go through.");
    return result.ok;
  }

  void _snack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _onAction(
    _ViewerAction action,
    Album album,
    List<MediaItem> items,
    int index,
  ) {
    final item = items[index];
    switch (action) {
      case _ViewerAction.details:
        _showDetails(album, item);
      case _ViewerAction.share:
        unawaited(_share(item));
      case _ViewerAction.setCover:
        unawaited(_setCover(album, item));
      case _ViewerAction.delete:
        unawaited(_confirmDelete(album, items, index));
    }
  }

  Future<void> _share(MediaItem item) async {
    final file = _resolved[item.blobSha] ?? await _fileFor(item);
    if (!mounted) return;
    if (file == null) {
      _snack(
        "That file hasn't downloaded yet - open it with a connection "
        'first.',
      );
      return;
    }
    try {
      // The file, not the CDN URL. A link pasted into a chat app stays a link;
      // the file arrives as a photo, and it works with no connection at all.
      // The cached copy is named after its blob sha on disk, so the real
      // filename has to be supplied separately.
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: _mimeTypeFor(item))],
          fileNameOverrides: [item.name],
        ),
      );
    } catch (_) {
      if (mounted) _snack("Couldn't open the share sheet.");
    }
  }

  Future<void> _setCover(Album album, MediaItem item) async {
    final ok = await _run(
      () => ref.read(albumActionsProvider.notifier).setCover(album, item),
    );
    if (!ok || !mounted) return;
    // The commit renames the chosen file to 0.<ext>, which puts it first in
    // display order - follow it, so the user keeps looking at the photo they
    // just acted on instead of whatever slid into this slot.
    _jumpTo(0);
    _snack("That's the album cover now.");
  }

  Future<void> _confirmDelete(
    Album album,
    List<MediaItem> items,
    int index,
  ) async {
    final item = items[index];
    _setChrome(true);

    final kind = item.isVideo ? 'video' : 'photo';
    final buffer = StringBuffer(
      'This deletes ${item.name} from the album on GitHub, and from your '
      'website once it rebuilds. This cannot be undone from the app.',
    );
    if (item.isCover) {
      buffer.write(
        "\n\nIt's the album cover too, so the album won't have one until you "
        'set another.',
      );
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: Text('Delete this $kind?'),
            content: Text(buffer.toString()),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                style: TextButton.styleFrom(
                  foregroundColor: context.colorScheme.error,
                ),
                child: const Text('Delete'),
              ),
            ],
          ),
    );
    if (confirmed != true || !mounted) return;

    HapticFeedback.heavyImpact();
    final remaining = items.length - 1;
    final wasLast = index == items.length - 1;

    final ok = await _run(
      () => ref.read(albumActionsProvider.notifier).deleteItems(album, {
        item.name,
      }),
    );
    if (!ok || !mounted) return;

    if (remaining == 0) {
      Navigator.of(context).maybePop();
      return;
    }
    // Everything after the deleted item shifts back one, so staying put lands
    // on the next photo - except at the end, where there is no next.
    if (wasLast) _jumpTo(remaining - 1);
  }

  Future<void> _editCaption(Album album, MediaItem item) async {
    _setChrome(true);
    final text = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CaptionSheet(item: item),
    );
    if (text == null || !mounted) return;

    final trimmed = text.trim();
    if (trimmed == item.caption.trim()) return;
    await _run(
      () => ref
          .read(albumActionsProvider.notifier)
          // Empty clears the entry rather than writing "" into album.json.
          .setCaption(album, item.name, trimmed.isEmpty ? null : trimmed),
    );
  }

  void _showDetails(Album album, MediaItem item) {
    _setChrome(true);
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => _DetailsSheet(album: album, item: item),
    );
  }

  void _jumpTo(int page) {
    setState(() => _index = page);
    // The list only shrinks or reorders once the refreshed album has rebuilt
    // this screen, so the pager can't be moved until that frame is done.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pager.hasClients) return;
      _pager.jumpToPage(page);
    });
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    // The live album, not the snapshot the caller passed: a caption edit, a
    // new cover or a delete has to be visible here the moment it lands.
    final album =
        ref.watch(albumByFolderProvider(widget.album.folder)) ?? widget.album;
    final items = album.allInDisplayOrder;

    if (items.isEmpty) {
      // The album emptied under us - the last item was deleted, or a sync
      // dropped the folder. Leave, rather than render a viewer of nothing.
      if (!_exiting) {
        _exiting = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          // Only when this screen is still the top route: something modal
          // above it would be what popped instead.
          if (ModalRoute.of(context)?.isCurrent ?? false) {
            Navigator.of(context).pop();
          }
        });
      }
      // Shown for the frame before the pop lands - and it is also the way out
      // if the pop was blocked, so this can't become a screen with no exit.
      return Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Stack(
            children: [
              Align(
                alignment: Alignment.topLeft,
                child: IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  tooltip: 'Back',
                  icon: const Icon(
                    Icons.arrow_back_rounded,
                    color: Colors.white,
                  ),
                ),
              ),
              const Center(
                child: Text(
                  "There's nothing left in this album.",
                  style: TextStyle(color: Colors.white70, fontSize: 15),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final index = _index.clamp(0, items.length - 1);
    _syncVideo(items[index]);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      // Deeper in the tree than the app-wide style in main.dart, so this wins:
      // dark status bar icons over a black viewer are invisible in light mode.
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        // The backdrop below paints the black, so it can be faded out.
        backgroundColor: Colors.transparent,
        body: ValueListenableBuilder<double>(
          valueListenable: _dragY,
          builder: (context, dy, gallery) {
            final progress = (dy.abs() / _dismissFade).clamp(0.0, 1.0);
            return Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: Colors.black.withValues(alpha: 1 - progress)),
                Transform.translate(
                  offset: Offset(0, dy),
                  child: Transform.scale(
                    scale: 1 - 0.15 * progress,
                    child: gallery,
                  ),
                ),
                Opacity(
                  opacity: 1 - progress,
                  child: _chrome(album, items, index),
                ),
              ],
            );
          },
          child: _gallery(album, items),
        ),
      ),
    );
  }

  Widget _gallery(Album album, List<MediaItem> items) {
    // A screen-reader user can't produce a velocity drag, so the gesture is
    // suppressed for them entirely and the back button is the way out. It also
    // goes away while zoomed in, where a vertical drag means "pan the photo" -
    // the parent's drag recogniser reaches its slop first and would otherwise
    // steal every pan from photo_view.
    final canDrag = !context.accessibleNavigation && !_zoomed;

    return GestureDetector(
      onVerticalDragStart: canDrag ? (_) => _settle.stop() : null,
      onVerticalDragUpdate: canDrag ? _onDragUpdate : null,
      onVerticalDragEnd: canDrag ? _onDragEnd : null,
      child: PhotoViewGallery.builder(
        itemCount: items.length,
        pageController: _pager,
        onPageChanged: _onPageChanged,
        scaleStateChangedCallback: _onScaleState,
        // Transparent so the drag backdrop behind it is what the user sees
        // fading.
        backgroundDecoration: const BoxDecoration(color: Colors.transparent),
        builder: (context, index) => _pageFor(album, items, index),
      ),
    );
  }

  PhotoViewGalleryPageOptions _pageFor(
    Album album,
    List<MediaItem> items,
    int index,
  ) {
    final item = items[index];
    // Matches the tag the album grid puts on its tiles.
    final hero = PhotoViewHeroAttributes(
      tag: 'media-${album.folder}/${item.name}',
    );
    final key = item.blobSha;

    if (!_resolved.containsKey(key)) {
      unawaited(_fileFor(item));
      // RemoteMedia rather than a bare spinner, because this is what the hero
      // flies: the flight builds the destination's child, and a live
      // RemoteMedia resolves the same cached bytes mid-flight instead of
      // sailing a spinner across the screen. Both share one download - the
      // cache manager de-duplicates concurrent requests for a key.
      return _customPage(
        hero: hero,
        child:
            item.isVideo
                ? const _ViewerLoading()
                // RemoteMedia's own placeholder is a surfaceContainer block,
                // which in the light theme is a pale rectangle - fine in the
                // grid, a full-screen flash here. The room is black, so the
                // placeholder should be too.
                : Theme(
                  data: Theme.of(context).copyWith(
                    colorScheme: context.colorScheme.copyWith(
                      surfaceContainer: Colors.black,
                    ),
                  ),
                  child: RemoteMedia(
                    album: album,
                    item: item,
                    fit: BoxFit.contain,
                  ),
                ),
      );
    }

    final file = _resolved[key];
    if (file == null) {
      return _customPage(
        hero: hero,
        child: _ViewerError(
          message:
              item.isVideo
                  ? "Couldn't load this video"
                  : "Couldn't load this photo",
          onRetry: () => unawaited(_retry(item)),
        ),
      );
    }

    if (item.isVideo) {
      final isCurrent = index == _index.clamp(0, items.length - 1);
      return _customPage(
        hero: hero,
        child: _VideoStage(
          // Only the current page gets the controller; the neighbours the
          // PageView has already built show the play badge and nothing else.
          controller: isCurrent ? _video : null,
          failed: isCurrent && _videoFailed,
          onTap: _toggleChrome,
          onPlayPause: () => unawaited(_togglePlay()),
        ),
      );
    }

    return PhotoViewGalleryPageOptions(
      imageProvider: FileImage(file),
      heroAttributes: hero,
      semanticLabel: item.hasCaption ? item.caption : item.name,
      minScale: PhotoViewComputedScale.contained,
      maxScale: PhotoViewComputedScale.covered * 4,
      initialScale: PhotoViewComputedScale.contained,
      onTapUp: (_, _, _) => _toggleChrome(),
      errorBuilder:
          (_, _, _) => _ViewerError(
            message: "Couldn't load this photo",
            onRetry: () => unawaited(_retry(item)),
          ),
    );
  }

  PhotoViewGalleryPageOptions _customPage({
    required Widget child,
    required PhotoViewHeroAttributes hero,
  }) {
    return PhotoViewGalleryPageOptions.customChild(
      child: child,
      heroAttributes: hero,
      // Nothing here is zoomable, and leaving photo_view's recogniser in place
      // would swallow the taps meant for the play button and the scrubber.
      disableGestures: true,
    );
  }

  Widget _chrome(Album album, List<MediaItem> items, int index) {
    final item = items[index];
    // Never hide the controls from a screen reader: the tap that brings them
    // back is not a gesture it can reliably make.
    final visible = _chromeVisible || context.accessibleNavigation;

    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: context.motion(const Duration(milliseconds: 200)),
        curve: Curves.easeOut,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Align(
              alignment: Alignment.topCenter,
              child: _topBar(album, items, index),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_video != null) _videoControls(_video!),
                  _captionBar(album, item),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _topBar(Album album, List<MediaItem> items, int index) {
    final item = items[index];
    final canSetCover = item.isImage && !item.isCover;
    final coverBlocked =
        item.isVideo
            ? 'Only a photo can be the album cover.'
            : (item.isCover ? "This one already is the cover." : null);

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black.withValues(alpha: 0.55), Colors.transparent],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  tooltip: 'Back',
                  icon: const Icon(
                    Icons.arrow_back_rounded,
                    color: Colors.white,
                    shadows: AppTheme.photoTextShadow,
                  ),
                ),
                Expanded(
                  child: Semantics(
                    label: 'Item ${index + 1} of ${items.length}',
                    excludeSemantics: true,
                    child: Text(
                      '${index + 1} / ${items.length}',
                      textAlign: TextAlign.center,
                      // Tabular figures: the counter must not jitter as the
                      // digits change under a swipe.
                      style: AppTheme.mono(
                        context,
                        size: 14,
                        weight: FontWeight.w600,
                        color: Colors.white,
                      ).copyWith(shadows: AppTheme.photoTextShadow),
                    ),
                  ),
                ),
                PopupMenuButton<_ViewerAction>(
                  enabled: !_busy,
                  tooltip: 'More',
                  icon: const Icon(
                    Icons.more_vert_rounded,
                    color: Colors.white,
                    shadows: AppTheme.photoTextShadow,
                  ),
                  onSelected:
                      (action) => _onAction(action, album, items, index),
                  itemBuilder:
                      (context) => [
                        PopupMenuItem(
                          value: _ViewerAction.details,
                          child: _menuRow(
                            Icons.info_outline_rounded,
                            'Details',
                          ),
                        ),
                        PopupMenuItem(
                          value: _ViewerAction.share,
                          child: _menuRow(Icons.ios_share_rounded, 'Share'),
                        ),
                        PopupMenuItem(
                          value: _ViewerAction.setCover,
                          enabled: canSetCover,
                          child: _wrapTooltip(
                            coverBlocked,
                            _menuRow(
                              Icons.star_outline_rounded,
                              'Set as cover',
                              enabled: canSetCover,
                            ),
                          ),
                        ),
                        PopupMenuItem(
                          value: _ViewerAction.delete,
                          child: _menuRow(
                            Icons.delete_outline_rounded,
                            'Delete',
                            color: context.colorScheme.error,
                          ),
                        ),
                      ],
                ),
              ],
            ),
            // A commit takes a couple of seconds against GitHub, and silence
            // reads as a dead tap.
            SizedBox(
              height: 2,
              child:
                  _busy
                      ? const LinearProgressIndicator(minHeight: 2)
                      : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _menuRow(
    IconData icon,
    String label, {
    Color? color,
    bool enabled = true,
  }) {
    final tint =
        enabled
            ? (color ?? context.colorScheme.onSurface)
            : context.colorScheme.onSurfaceVariant.withValues(alpha: 0.5);
    return Row(
      children: [
        Icon(icon, size: 19, color: tint),
        const SizedBox(width: 14),
        Text(label, style: context.textTheme.labelLarge?.copyWith(color: tint)),
      ],
    );
  }

  Widget _wrapTooltip(String? message, Widget child) {
    if (message == null) return child;
    // The reason a disabled item is disabled, rather than an item that just
    // doesn't respond.
    return Tooltip(
      message: message,
      triggerMode: TooltipTriggerMode.tap,
      child: child,
    );
  }

  Widget _videoControls(VideoPlayerController controller) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        if (!value.isInitialized) return const SizedBox.shrink();
        // Nothing to scrub before the clip has started; the big play button is
        // the only control that matters until then.
        final started = value.isPlaying || value.position > Duration.zero;
        if (!started) return const SizedBox.shrink();

        return Container(
          width: double.infinity,
          color: Colors.black.withValues(alpha: 0.78),
          padding: const EdgeInsets.only(left: 4, right: 16),
          child: Row(
            children: [
              IconButton(
                onPressed: () => unawaited(_togglePlay()),
                tooltip: value.isPlaying ? 'Pause' : 'Play',
                icon: Icon(
                  value.isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  color: Colors.white,
                ),
              ),
              Expanded(
                child: VideoProgressIndicator(
                  controller,
                  allowScrubbing: true,
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  // White over a black bar: the themed rose would be the
                  // accent colour everywhere else, but here it sits on a scrim
                  // over arbitrary video and legibility wins.
                  colors: VideoProgressColors(
                    playedColor: Colors.white,
                    bufferedColor: Colors.white.withValues(alpha: 0.35),
                    backgroundColor: Colors.white.withValues(alpha: 0.15),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${formatDuration(value.position)} / '
                '${formatDuration(value.duration)}',
                style: AppTheme.mono(context, size: 12, color: Colors.white),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _captionBar(Album album, MediaItem item) {
    final hasCaption = item.hasCaption;
    return GestureDetector(
      onTap: () => unawaited(_editCaption(album, item)),
      child: Container(
        width: double.infinity,
        // Solid, not a gradient. A three-line caption over a gradient goes
        // illegible on its top line.
        color: Colors.black.withValues(alpha: 0.78),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
            child:
                hasCaption
                    ? Text(
                      item.caption,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        height: 1.4,
                      ),
                    )
                    : Row(
                      children: [
                        Icon(
                          Icons.edit_outlined,
                          size: 16,
                          color: Colors.white.withValues(alpha: 0.55),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'Add a caption',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.55),
                            fontSize: 15,
                          ),
                        ),
                      ],
                    ),
          ),
        ),
      ),
    );
  }
}

/// MIME type from the extension, so the receiving app in the share sheet knows
/// it is being handed a photo rather than an opaque blob.
String? _mimeTypeFor(MediaItem item) {
  switch (item.ext) {
    case '.jpg':
    case '.jpeg':
      return 'image/jpeg';
    case '.png':
      return 'image/png';
    case '.gif':
      return 'image/gif';
    case '.webp':
      return 'image/webp';
    case '.avif':
      return 'image/avif';
    case '.mp4':
      return 'video/mp4';
    case '.webm':
      return 'video/webm';
    case '.mov':
      return 'video/quicktime';
  }
  return null;
}

// --------------------------------------------------------------- page states

class _ViewerLoading extends StatelessWidget {
  const _ViewerLoading();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: 26,
        height: 26,
        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
      ),
    );
  }
}

class _ViewerError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ViewerError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.cloud_off_rounded,
            size: 34,
            color: Colors.white.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 14),
          Text(
            message,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.8),
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            "You might be offline, or it hasn't finished downloading.",
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 10),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            child: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}

/// The video page: the frame itself plus the play badge that sits over it.
///
/// Stateless on purpose - the controller's whole lifecycle lives in the screen
/// state, so there is exactly one of them and one place that disposes it.
class _VideoStage extends StatelessWidget {
  final VideoPlayerController? controller;
  final bool failed;
  final VoidCallback onTap;
  final VoidCallback onPlayPause;

  const _VideoStage({
    required this.controller,
    required this.failed,
    required this.onTap,
    required this.onPlayPause,
  });

  @override
  Widget build(BuildContext context) {
    if (failed) {
      return const Center(
        child: Text(
          "Couldn't play this video",
          style: TextStyle(color: Colors.white70, fontSize: 15),
        ),
      );
    }

    final controller = this.controller;
    if (controller == null || !controller.value.isInitialized) {
      // Either a neighbouring page or one still opening. The badge doubles as
      // the "this is a video" signal while the user swipes past.
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: const Center(child: VideoBadge(size: 64)),
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ValueListenableBuilder<VideoPlayerValue>(
        valueListenable: controller,
        builder: (context, value, player) {
          return Stack(
            fit: StackFit.expand,
            children: [
              Center(
                child: AspectRatio(
                  aspectRatio: value.aspectRatio,
                  child: player,
                ),
              ),
              // Never autoplays. These are the user's own files, but they still
              // cost battery and data, and a video that starts itself on a
              // swipe-through is hostile.
              if (!value.isPlaying)
                Center(
                  child: Semantics(
                    button: true,
                    label: 'Play',
                    child: GestureDetector(
                      onTap: onPlayPause,
                      child: const VideoBadge(size: 64),
                    ),
                  ),
                ),
            ],
          );
        },
        // Passed as the unchanging child: the texture must not be rebuilt on
        // every position tick.
        child: VideoPlayer(controller),
      ),
    );
  }
}

// -------------------------------------------------------------------- sheets

class _CaptionSheet extends StatefulWidget {
  final MediaItem item;

  const _CaptionSheet({required this.item});

  @override
  State<_CaptionSheet> createState() => _CaptionSheetState();
}

class _CaptionSheetState extends State<_CaptionSheet> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.item.caption,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Lifts the sheet clear of the keyboard it just summoned.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SheetGrabber(),
              Text('Caption', style: context.textTheme.titleMedium),
              const SizedBox(height: 2),
              Text(widget.item.name, style: AppTheme.mono(context, size: 12)),
              const SizedBox(height: 16),
              TextField(
                controller: _controller,
                autofocus: true,
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(hintText: 'Say what this is'),
              ),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 16,
                    color: context.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Captions are saved in album.json. Your site needs a '
                      'small plugin change to show them.',
                      style: context.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed:
                        () => Navigator.of(context).pop(_controller.text),
                    child: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailsSheet extends StatelessWidget {
  final Album album;
  final MediaItem item;

  const _DetailsSheet({required this.album, required this.item});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SheetGrabber(),
            Text('Details', style: context.textTheme.titleMedium),
            const SizedBox(height: 16),
            _DetailRow(label: 'File', value: item.name, mono: true),
            const SizedBox(height: 12),
            _DetailRow(
              label: 'Size',
              // A zero here means the tree never reported one, which is not
              // the same as an empty file.
              value: item.size > 0 ? formatBytes(item.size) : 'Not recorded',
            ),
            const SizedBox(height: 12),
            _DetailRow(label: 'Album', value: album.folder, mono: true),
            if (item.isCover) ...[
              const SizedBox(height: 18),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.star_rounded,
                    size: 17,
                    color: context.appColors.coverBadge,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'This is the cover. Your website uses it as the album '
                      "thumbnail and leaves it out of the gallery grid - "
                      'glickr still shows it here.',
                      style: context.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  final bool mono;

  const _DetailRow({
    required this.label,
    required this.value,
    this.mono = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 74,
          child: Text(label, style: context.textTheme.bodySmall),
        ),
        Expanded(
          child:
              mono
                  ? Text(
                    value,
                    style: AppTheme.mono(
                      context,
                      size: 13,
                      color: context.colorScheme.onSurface,
                    ),
                  )
                  : Text(
                    value,
                    style: context.textTheme.bodyLarge?.copyWith(fontSize: 14),
                  ),
        ),
      ],
    );
  }
}

class _SheetGrabber extends StatelessWidget {
  const _SheetGrabber();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 36,
        height: 4,
        margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(
          color: context.colorScheme.outlineVariant,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}
