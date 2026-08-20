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
import '../../../core/providers/pending_captions_provider.dart';
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

  /// The blob sha the current page WANTS open, and the one that actually IS.
  /// They differ while a controller is opening or closing; the reconciler's
  /// only job is to close the gap.
  String? _videoWanted;
  String? _videoKey;

  bool _videoFailed = false;

  /// Play was tapped before the clip was ready. Honoured the moment it is,
  /// rather than dropped - a play button that swallows the tap is exactly the
  /// bug this screen had.
  bool _playWhenReady = false;

  /// Every open and close is queued here. Opening a controller takes several
  /// frames, and a swipe during one used to dispose a controller that another
  /// call was still initialising - which left the page holding a controller
  /// that never became ready, showing a play badge that did nothing.
  Future<void> _videoWork = Future<void>.value();
  bool _videoBusy = false;

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
    // Queued rather than disposed outright: a controller may still be opening,
    // and the one that ends up in _video is the one that has to be torn down.
    _videoWanted = null;
    _queueVideoWork(_closeVideo);
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
      if (_videoKey == item.blobSha) {
        // Forget the controller too. Without this the reconciler would decide
        // the page already has what it asked for and never try again, so
        // "Try again" on a video would do nothing.
        _videoFailed = false;
        _videoKey = null;
      }
    });
  }

  // ------------------------------------------------------------------ video

  /// Record which video [current] needs open and get the work moving.
  ///
  /// Called from build because three unrelated things decide which video
  /// should be open - a page change, a download finishing, and a delete
  /// shifting the list - and funnelling them here means there is one place
  /// where a controller can leak. It only records intent: creating a
  /// controller inline would mutate, during a build, the very state that build
  /// has already read.
  void _syncVideo(MediaItem current) {
    final wanted = current.isVideo ? current.blobSha : null;
    if (wanted != _videoWanted) {
      _videoWanted = wanted;
      _videoFailed = false;
      _playWhenReady = false;
    }
    // Already showing what it wants, or a reconcile is running that will get
    // there. _videoBusy is the guard that stops every rebuild queueing another.
    if (_videoWanted == _videoKey || _videoBusy) return;
    _videoBusy = true;
    _queueVideoWork(_reconcileVideo);
  }

  /// Run [work] after whatever controller work is already in flight.
  ///
  /// Errors are swallowed deliberately: a platform teardown that throws must
  /// not leave a failed future at the head of the queue, or no video would
  /// open again for the rest of the session.
  void _queueVideoWork(Future<void> Function() work) {
    _videoWork = _videoWork.then((_) => work()).catchError((Object _) {});
  }

  /// Close whatever is open and open what the current page asked for.
  ///
  /// Loops rather than running once: the page can turn again while a
  /// controller is still initialising, and the last intent has to win.
  Future<void> _reconcileVideo() async {
    try {
      while (mounted && _videoWanted != _videoKey) {
        final wanted = _videoWanted;
        await _closeVideo();
        if (!mounted || wanted != _videoWanted) continue;
        if (wanted == null) continue; // _closeVideo already settled it

        final file = _resolved[wanted];
        // Not downloaded yet. Stop here rather than spinning - resolving it
        // rebuilds the screen, and that build queues this again.
        if (file == null) break;
        await _openVideo(wanted, file);
      }
    } finally {
      // In a finally so a throw still releases the guard; otherwise one bad
      // teardown would stop every later page from opening its video.
      _videoBusy = false;
    }
  }

  Future<void> _openVideo(String key, File file) async {
    final controller = VideoPlayerController.file(file);
    // Claimed synchronously so nothing can start a second controller for the
    // same page while this one initialises.
    _video = controller;
    // Set BEFORE the await, and left set even when initialisation fails, so
    // this key counts as settled either way and the loop above terminates.
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

    if (_video != controller) return; // superseded; _closeVideo owns it now
    if (!mounted) return; // the screen went away; dispose() owns it now

    if (_playWhenReady) {
      _playWhenReady = false;
      await controller.play();
    }
    if (mounted) setState(() {});
  }

  /// Tear down the open controller, awaiting it fully.
  ///
  /// Nulling [_video] first is what hands ownership over: an [_openVideo] call
  /// still sitting in `initialize()` sees the field has moved on and leaves
  /// the disposing to this, so nothing is ever disposed twice.
  Future<void> _closeVideo() async {
    final controller = _video;
    _video = null;
    _videoKey = null;
    if (controller == null) return;
    // dispose() waits on the platform-side create, so this is safe to call
    // while initialisation is still in flight.
    await controller.dispose();
  }

  Future<void> _togglePlay() async {
    final controller = _video;
    if (controller == null || !controller.value.isInitialized) {
      // Still downloading, or still opening. Remember the tap and start the
      // moment it is ready - and let a second tap take it back, so this can't
      // strand the user with a clip that starts by itself later.
      setState(() => _playWhenReady = !_playWhenReady);
      return;
    }
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
    // Silenced the moment the page turns, rather than waiting for the teardown
    // queued behind whatever else is running: a clip that keeps playing after
    // you have swiped away from it is worse than one that never started.
    // Here rather than in _syncVideo because pausing notifies the controller's
    // listeners, and _syncVideo runs during build.
    unawaited(_video?.pause());
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
    // Staged captions follow the two filenames the commit swaps - done inside
    // the action, not here, so no screen can be the one that forgets.
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
    if (album.isCover(item)) {
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

    // A staged caption for the deleted file is dropped inside the action: it
    // could never be saved onto anything, and would count as unsaved forever.
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

  /// The caption to SHOW for [item]: the staged edit when there is one, and
  /// the committed value otherwise.
  ///
  /// Read rather than watched because [build] watches the staged map already,
  /// so every helper it calls re-runs whenever anything is staged.
  String _captionFor(Album album, MediaItem item) => ref
      .read(pendingCaptionsNotifierProvider.notifier)
      .captionFor(album, item.name);

  Future<void> _editCaption(Album album, MediaItem item) async {
    _setChrome(true);
    // What is on screen, not what is committed - otherwise reopening the sheet
    // on a caption typed a moment ago offers the old text back.
    final current = _captionFor(album, item);

    final text = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CaptionSheet(fileName: item.name, initial: current),
    );
    if (text == null || !mounted) return;
    if (text.trim() == current.trim()) return;

    // STAGED, not committed. Every commit to the album repo triggers the
    // site's build, so captioning twenty photos here has to cost one build,
    // not twenty - the pill in the top bar is what sends them.
    await ref
        .read(pendingCaptionsNotifierProvider.notifier)
        .stage(album, item.name, text);
  }

  /// Commit every caption staged for this album, in one commit.
  ///
  /// On failure the edits stay staged: the notifier only clears them once the
  /// commit lands, so a network blip costs a retry rather than the typing.
  Future<void> _saveCaptions(Album album) async {
    // Counted here rather than taken from the pill: the two are the same
    // number, but only one of them cannot go stale between paint and tap.
    final count = ref
        .read(pendingCaptionsNotifierProvider.notifier)
        .countFor(album.folder);

    final ok = await _run(
      () => ref.read(pendingCaptionsNotifierProvider.notifier).flush(album),
    );
    if (!ok || !mounted) return;
    _snack(count == 1 ? 'Caption saved.' : '$count captions saved.');
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

    // How many captions are typed but not sent, for the save pill - and the
    // subscription that lets every caption below be READ from the notifier
    // instead of watched: staging anything replaces this map, which rebuilds
    // the screen, which re-runs those reads.
    final unsaved =
        ref.watch(pendingCaptionsNotifierProvider)[album.folder]?.length ?? 0;

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
                  child: _chrome(album, items, index, unsaved),
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

    final requested = _resolved.containsKey(key);
    if (!requested) unawaited(_fileFor(item));
    final file = requested ? _resolved[key] : null;

    if (item.isVideo) {
      final isCurrent = index == _index.clamp(0, items.length - 1);
      return _customPage(
        hero: hero,
        child: _VideoStage(
          // The poster frame, so a video page shows the clip's own first
          // second while it opens instead of a black rectangle - and so the
          // hero arrives holding the same image the grid tile was showing.
          poster: _onBlack(
            RemoteMedia(album: album, item: item, fit: BoxFit.contain),
          ),
          // Only the current page gets the controller; the neighbours the
          // PageView has already built show the poster and the play badge.
          controller: isCurrent ? _video : null,
          failed: isCurrent && _videoFailed,
          unavailable: requested && file == null,
          armed: isCurrent && _playWhenReady,
          onTap: _toggleChrome,
          onPlayPause: () => unawaited(_togglePlay()),
          onRetry: () => unawaited(_retry(item)),
        ),
      );
    }

    if (!requested) {
      // RemoteMedia rather than a bare spinner, because this is what the hero
      // flies: the flight builds the destination's child, and a live
      // RemoteMedia resolves the same cached bytes mid-flight instead of
      // sailing a spinner across the screen. Both share one download - the
      // cache manager de-duplicates concurrent requests for a key.
      return _customPage(
        hero: hero,
        child: _onBlack(
          RemoteMedia(album: album, item: item, fit: BoxFit.contain),
        ),
      );
    }

    if (file == null) {
      return _customPage(
        hero: hero,
        child: _ViewerError(
          message: "Couldn't load this photo",
          onRetry: () => unawaited(_retry(item)),
        ),
      );
    }

    final caption = _captionFor(album, item);

    return PhotoViewGalleryPageOptions(
      imageProvider: FileImage(file),
      heroAttributes: hero,
      // A caption IS the alt text, staged or not - a screen-reader user has no
      // other way to tell that the caption they just dictated took.
      semanticLabel: caption.trim().isNotEmpty ? caption : item.name,
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

  /// RemoteMedia's own placeholder is a surfaceContainer block, which in the
  /// light theme is a pale rectangle - fine in the grid, a full-screen flash
  /// here. The room is black, so the placeholder should be too.
  Widget _onBlack(Widget child) {
    return Theme(
      data: Theme.of(context).copyWith(
        colorScheme: context.colorScheme.copyWith(
          surfaceContainer: Colors.black,
        ),
      ),
      child: child,
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

  Widget _chrome(Album album, List<MediaItem> items, int index, int unsaved) {
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
              child: _topBar(album, items, index, unsaved),
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

  Widget _topBar(Album album, List<MediaItem> items, int index, int unsaved) {
    final item = items[index];
    final canSetCover = item.isImage && !album.isCover(item);
    final coverBlocked =
        item.isVideo
            ? 'Only a photo can be the album cover.'
            : (album.isCover(item) ? "This one already is the cover." : null);

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
          // Without this the Column takes the full height the Align above it
          // offers, the gradient Container sizes to it, and the whole screen
          // becomes one RenderDecoratedBox - whose hitTestSelf is true anywhere
          // inside a rectangular decoration, and which absorbs the pointer
          // AFTER its children decline it. That swallowed every gesture aimed
          // at the photo before the pager was ever hit-tested, so swiping
          // between photos did nothing and drag-down-to-dismiss never fired,
          // while the buttons drawn on top kept working - which is exactly why
          // it read as "the viewer is fine, it just won't swipe".
          mainAxisSize: MainAxisSize.min,
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
                if (unsaved > 0) _unsavedPill(album, unsaved),
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

  /// The "captions waiting" pill in the top bar.
  ///
  /// A user can caption twenty photos here without ever going back to the
  /// album screen, where the save banner lives, and unsaved work that looks
  /// exactly like saved work is the whole reason this feature had a bug. It is
  /// a pill rather than a bar because it sits over a full-bleed photograph:
  /// absent entirely with nothing staged, and one tap from being sent.
  Widget _unsavedPill(Album album, int count) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Tooltip(
        message:
            'Saved together in one commit, so your site rebuilds once instead '
            'of once per caption.',
        triggerMode: TooltipTriggerMode.longPress,
        child: Material(
          // The same black-45 lozenge the cover chip uses, so over-photo
          // chrome reads as one family.
          color: Colors.black.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(20),
          child: InkWell(
            onTap: _busy ? null : () => unawaited(_saveCaptions(album)),
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 7, 12, 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.edit_note_rounded,
                    size: 17,
                    // The amber from the DARK palette in both themes: this
                    // pill is always a dark context, and the light palette's
                    // burnt orange computes to under 3:1 on it.
                    color: AppColors.dark.warning,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    // Reads as a count of work, not as an error - the state is
                    // ordinary, it just has to be visible.
                    '$count unsaved',
                    // "3 unsaved" is only meaningful next to the photo it is
                    // drawn on; spoken aloud it needs its noun.
                    semanticsLabel: count == 1
                        ? '1 caption not saved'
                        : '$count captions not saved',
                    style: AppTheme.mono(
                      context,
                      size: 12,
                      weight: FontWeight.w600,
                      color: AppColors.dark.warning,
                    ),
                  ),
                ],
              ),
            ),
          ),
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
        // Present from the moment the clip is ready, not only once it has
        // started: the scrubber is also how you tell a video that CAN play
        // from one that is still opening.
        if (!value.isInitialized) return const SizedBox.shrink();

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
    // The staged text when there is one: typing a caption and watching the old
    // one stay put reads as the app having thrown the typing away.
    final caption = _captionFor(album, item);
    final hasCaption = caption.trim().isNotEmpty;
    // Deliberately NOT gated on _busy, unlike the pill and the menu. A commit
    // takes seconds and captioning is what this screen is for; freezing it for
    // the length of a network round trip would be its own bug. An edit made
    // mid-save is kept - `flush` drops only the entries its commit carried.
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
                      caption,
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

class _ViewerError extends StatelessWidget {
  final String message;
  final String detail;
  final VoidCallback onRetry;

  const _ViewerError({
    required this.message,
    required this.onRetry,
    this.detail = "You might be offline, or it hasn't finished downloading.",
  });

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
            detail,
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

/// The video page: the poster or the clip itself, plus the play control.
///
/// Stateless on purpose - the controller's whole lifecycle lives in the screen
/// state, so there is exactly one of them and one place that disposes it.
class _VideoStage extends StatelessWidget {
  /// Drawn until the clip itself can be. A video page used to sit on black
  /// while it opened, which read as a file that had failed.
  final Widget poster;

  final VideoPlayerController? controller;

  /// The clip's bytes could not be fetched.
  final bool unavailable;

  /// The bytes are here, but the device could not open them.
  final bool failed;

  /// Play was tapped before the clip was ready.
  final bool armed;

  final VoidCallback onTap;
  final VoidCallback onPlayPause;
  final VoidCallback onRetry;

  const _VideoStage({
    required this.poster,
    required this.controller,
    required this.unavailable,
    required this.failed,
    required this.armed,
    required this.onTap,
    required this.onPlayPause,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    if (unavailable) {
      return _ViewerError(
        message: "Couldn't load this video",
        onRetry: onRetry,
      );
    }
    if (failed) {
      return _ViewerError(
        message: "Couldn't play this video",
        detail:
            "Your phone might not be able to decode it - it's still safe on "
            'GitHub.',
        onRetry: onRetry,
      );
    }

    final controller = this.controller;
    if (controller == null) {
      // A neighbouring page, or the current one before its controller exists.
      return _frame(background: poster, ready: false, playing: false);
    }

    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, player) {
        if (!value.isInitialized) {
          return _frame(background: poster, ready: false, playing: false);
        }
        return _frame(
          background: Center(
            child: AspectRatio(aspectRatio: value.aspectRatio, child: player),
          ),
          ready: true,
          playing: value.isPlaying,
        );
      },
      // Passed as the unchanging child: the texture must not be rebuilt on
      // every position tick.
      child: VideoPlayer(controller),
    );
  }

  Widget _frame({
    required Widget background,
    required bool ready,
    required bool playing,
  }) {
    return GestureDetector(
      // The tap that shows and hides the chrome. The play button below sits
      // deeper in the tree, so it takes the taps that land on it and this one
      // gets the rest.
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          background,
          // Never autoplays. These are the user's own files, but they still
          // cost battery and data, and a video that starts itself on a
          // swipe-through is hostile.
          if (!playing)
            Center(
              child: Semantics(
                button: true,
                label: armed ? 'Cancel play' : 'Play',
                child: GestureDetector(
                  // Opaque, so the whole 64px target answers rather than just
                  // the glyph drawn inside it.
                  behavior: HitTestBehavior.opaque,
                  onTap: onPlayPause,
                  child: SizedBox(
                    width: 64,
                    height: 64,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // Armed means the tap landed before the clip was
                        // ready. Showing that is the difference between
                        // "loading" and "that button is broken".
                        if (armed && !ready)
                          const SizedBox.expand(
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          ),
                        VideoBadge(size: armed && !ready ? 46 : 64),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// -------------------------------------------------------------------- sheets

class _CaptionSheet extends StatefulWidget {
  final String fileName;

  /// The caption as currently DISPLAYED, which may be a staged edit rather
  /// than the committed one - the sheet is seeded with it so reopening an
  /// unsaved caption shows what the user typed, not what the repo still says.
  final String initial;

  const _CaptionSheet({required this.fileName, required this.initial});

  @override
  State<_CaptionSheet> createState() => _CaptionSheetState();
}

class _CaptionSheetState extends State<_CaptionSheet> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
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
              Text(widget.fileName, style: AppTheme.mono(context, size: 12)),
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
                      'Kept on this device until you save the album, then '
                      'written to album.json together in one commit. Your '
                      'site needs a small plugin change to show them.',
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
                    // "Done", not "Save": this closes the sheet and keeps the
                    // text on the device. Calling it Save and then showing an
                    // "unsaved" pill a frame later would be a straight lie.
                    child: const Text('Done'),
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
            if (album.isCover(item)) ...[
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
