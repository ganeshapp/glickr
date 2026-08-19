import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import '../../../core/models/album.dart';
import '../../../core/models/app_config.dart';
import '../../../core/providers/albums_provider.dart';
import '../../../core/providers/config_provider.dart';
import '../../../core/providers/gallery_provider.dart';
import '../../../core/providers/services_provider.dart';
import '../../../core/services/media_pipeline_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/empty_state.dart';
import '../../../core/widgets/glickr_shimmer.dart';
import '../../../core/widgets/remote_media.dart';
import 'upload_review_sheet.dart';

/// The device gallery grid.
///
/// The whole screen exists to capture one thing the system picker cannot give
/// us: the ORDER the user tapped. glickr names uploads 0001, 0002, ... in that
/// order and the website sorts by filename, so the tap order is the running
/// order on the site.
class MediaPickerScreen extends ConsumerStatefulWidget {
  /// Null means the user picks or creates the album after choosing photos.
  final Album? targetAlbum;

  const MediaPickerScreen({super.key, this.targetAlbum});

  @override
  ConsumerState<MediaPickerScreen> createState() => _MediaPickerScreenState();
}

class _MediaPickerScreenState extends ConsumerState<MediaPickerScreen> {
  static const int _columns = 4;
  static const double _gutter = 2;

  /// How close to the end of the grid triggers the next page. Roughly two rows
  /// of headroom on a phone, so the grid never actually reaches its end.
  static const double _prefetchWindow = 800;

  final ScrollController _scroll = ScrollController();

  /// Selection in tap order. This list IS the upload order.
  final List<AssetEntity> _selected = [];

  /// Asset id -> 1-based place in [_selected], rebuilt on every change so a
  /// tile can render its badge without scanning the list.
  final Map<String, int> _order = {};

  /// True until the OS has told us what is already granted. Without it the
  /// grid renders one frame of "Nothing to show here" - an empty gallery
  /// state - while the permission check is still in flight.
  bool _resolvingAccess = true;

  /// True while the pre-permission panel is up, before the OS dialog.
  bool _explainPermission = false;
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    // Providers are not readable until the first frame is being built.
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolveAccess());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Decide between "explain, then ask" and "just load".
  ///
  /// [PhotoManager.getPermissionState] reads the current grant WITHOUT
  /// prompting, which is what makes the explainer a one-time thing: the
  /// gallery provider is autoDispose, so its access is `unknown` on every fresh
  /// open, and keying off that alone would re-explain the permission to
  /// somebody who granted it months ago.
  Future<void> _resolveAccess() async {
    var granted = false;
    try {
      final state = await PhotoManager.getPermissionState(
        requestOption: const PermissionRequestOption(),
      );
      granted =
          state == PermissionState.authorized ||
          state == PermissionState.limited;
    } catch (_) {
      // Treat an unreadable permission state as "ask", never as "granted".
    }
    if (!mounted) return;
    if (granted) {
      _load();
    } else {
      setState(() {
        _resolvingAccess = false;
        _explainPermission = true;
      });
    }
  }

  void _load() {
    setState(() {
      _resolvingAccess = false;
      _explainPermission = false;
    });
    ref.read(galleryNotifierProvider.notifier).requestAndLoad();
  }

  void _onScroll() {
    if (!_scroll.hasClients || _loadingMore) return;
    final position = _scroll.position;
    if (position.pixels < position.maxScrollExtent - _prefetchWindow) return;

    final state = ref.read(galleryNotifierProvider);
    if (!state.hasMore || state.activeBucket == null) return;

    // GalleryNotifier.loadMore has no in-flight guard of its own, and two
    // overlapping calls would fetch the same page twice and append every asset
    // in it a second time - which would also duplicate selection badges.
    _loadingMore = true;
    ref
        .read(galleryNotifierProvider.notifier)
        .loadMore()
        .whenComplete(() => _loadingMore = false);
  }

  void _toggle(AssetEntity asset) {
    setState(() {
      final index = _selected.indexWhere((a) => a.id == asset.id);
      if (index == -1) {
        _selected.add(asset);
      } else {
        _selected.removeAt(index);
      }
      _order
        ..clear()
        ..addEntries([
          for (var i = 0; i < _selected.length; i++)
            MapEntry(_selected[i].id, i + 1),
        ]);
    });
  }

  Future<void> _next() async {
    var album = widget.targetAlbum;

    if (album == null) {
      final choice = await _chooseAlbum();
      if (choice == null || !mounted) return;
      album = choice.album;
    }

    final queued = await showUploadReviewSheet(
      context,
      // A copy: the picker stays alive under the sheet and its selection can
      // still change if the sheet is dismissed.
      assets: List<AssetEntity>.from(_selected),
      album: album,
    );
    if (queued == true && mounted) {
      Navigator.of(context).pop(true);
    }
  }

  /// "Add to..." - one tap, no confirm step.
  Future<_AlbumChoice?> _chooseAlbum() {
    final albums = [...ref.read(albumsNotifierProvider).albums]
      ..sort((a, b) => a.folder.compareTo(b.folder));

    return showModalBottomSheet<_AlbumChoice>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder:
          (context) => SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Add to', style: context.textTheme.titleLarge),
                  ),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(bottom: 12),
                    children: [
                      ListTile(
                        leading: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: context.colorScheme.primary.withValues(
                              alpha: 0.12,
                            ),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            Icons.add_rounded,
                            color: context.colorScheme.primary,
                          ),
                        ),
                        title: const Text('New album'),
                        subtitle: const Text('Creates a folder in your repo'),
                        onTap:
                            () => Navigator.of(
                              context,
                            ).pop(const _AlbumChoice(null)),
                      ),
                      if (albums.isNotEmpty)
                        const Divider(indent: 20, endIndent: 20),
                      for (final album in albums)
                        _AlbumRow(
                          album: album,
                          onTap:
                              () => Navigator.of(
                                context,
                              ).pop(_AlbumChoice(album)),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(galleryNotifierProvider);

    return Scaffold(
      appBar: AppBar(
        title: _title(state),
        actions: [
          if (_selected.isNotEmpty)
            TextButton(
              onPressed:
                  () => setState(() {
                    _selected.clear();
                    _order.clear();
                  }),
              child: const Text('Clear'),
            ),
        ],
      ),
      body: _body(state),
      bottomNavigationBar: _selected.isEmpty ? null : _bottomBar(context),
    );
  }

  Widget _title(GalleryState state) {
    final bucket = state.activeBucket;
    if (bucket == null || state.buckets.isEmpty) {
      return const Text('Add photos');
    }

    return PopupMenuButton<AssetPathEntity>(
      tooltip: 'Choose an album on this device',
      position: PopupMenuPosition.under,
      onSelected:
          (selected) =>
              ref.read(galleryNotifierProvider.notifier).selectBucket(selected),
      itemBuilder:
          (context) => [
            for (final option in state.buckets)
              PopupMenuItem(
                value: option,
                child: Row(
                  children: [
                    Expanded(child: Text(option.name)),
                    if (option.id == bucket.id)
                      Icon(
                        Icons.check_rounded,
                        size: 18,
                        color: context.colorScheme.primary,
                      ),
                  ],
                ),
              ),
          ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: Text(bucket.name, overflow: TextOverflow.ellipsis)),
          const Icon(Icons.arrow_drop_down_rounded),
        ],
      ),
    );
  }

  Widget _body(GalleryState state) {
    if (_resolvingAccess) return _skeletonGrid();
    if (_explainPermission) return _permissionPanel(context);

    if (state.access == GalleryAccess.denied) {
      return EmptyState(
        icon: Icons.no_photography_outlined,
        title: "glickr can't see your photos",
        body: 'Allow access to photos and videos to pick from your gallery.',
        action: ElevatedButton(
          onPressed:
              () => ref.read(galleryNotifierProvider.notifier).openSettings(),
          child: const Text('Open settings'),
        ),
      );
    }

    if (state.assets.isEmpty && state.isLoading) return _skeletonGrid();

    return Column(
      children: [
        if (state.access == GalleryAccess.limited)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            // Never conditional on "have they seen this": Android does not
            // revoke an asset it has already shared, so a limited grant is a
            // permanent state the user may want to widen at any point.
            child: StatusBanner(
              icon: Icons.photo_library_outlined,
              tint: context.appColors.info,
              message: "You've shared some photos",
              actionLabel: 'Manage',
              onAction:
                  () =>
                      ref
                          .read(galleryNotifierProvider.notifier)
                          .presentLimitedPicker(),
            ),
          ),
        if (state.error != null)
          StatusBanner(
            icon: Icons.error_outline_rounded,
            tint: context.colorScheme.error,
            message: "Couldn't read your gallery - ${state.error}",
            actionLabel: 'Retry',
            onAction: _load,
          ),
        if (state.assets.isEmpty)
          Expanded(
            // A limited grant with nothing in it is a different problem from
            // an empty device, and the fix for it is the Manage chip above.
            child:
                state.access == GalleryAccess.limited
                    ? const EmptyState(
                      icon: Icons.photo_outlined,
                      title: 'Nothing shared yet',
                      body:
                          "You haven't shared any photos with glickr. Tap Manage "
                          'to choose some.',
                    )
                    : const EmptyState(
                      icon: Icons.photo_outlined,
                      title: 'Nothing to show here',
                      body: 'This device has no photos or videos yet.',
                    ),
          )
        else ...[
          _orderHint(context),
          Expanded(child: _grid(state)),
        ],
      ],
    );
  }

  /// The explanation that earns the OS dialog.
  ///
  /// Shown BEFORE anything is requested: a permission prompt the user does not
  /// expect gets denied, and on Android a second denial is permanent.
  Widget _permissionPanel(BuildContext context) {
    return EmptyState(
      icon: Icons.photo_library_outlined,
      title: 'glickr needs to see your photos',
      body:
          'So you can pick what to upload. Nothing leaves your device until '
          'you tap Upload.',
      action: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TextButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('Not now'),
          ),
          const SizedBox(width: 12),
          ElevatedButton(onPressed: _load, child: const Text('Continue')),
        ],
      ),
    );
  }

  /// The one line that lets this app skip a reorder feature entirely.
  Widget _orderHint(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.format_list_numbered_rounded,
            size: 15,
            color: context.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              "Photos upload in the order you pick them - that's the order "
              "they'll appear.",
              style: context.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _grid(GalleryState state) {
    // Four trailing skeletons while the next page is on its way, so the grid
    // says "there is more" instead of stopping dead at a page boundary.
    final tail = state.hasMore ? _columns : 0;

    return GridView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(_gutter, 0, _gutter, _gutter),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: _columns,
        crossAxisSpacing: _gutter,
        mainAxisSpacing: _gutter,
      ),
      itemCount: state.assets.length + tail,
      itemBuilder: (context, index) {
        if (index >= state.assets.length) {
          return const ShimmerBlock(radius: 4);
        }
        final asset = state.assets[index];
        final supported = isSupportedAsset(asset);
        return _AssetTile(
          asset: asset,
          order: _order[asset.id],
          supported: supported,
          onTap: supported ? () => _toggle(asset) : null,
        );
      },
    );
  }

  Widget _skeletonGrid() {
    return GlickrShimmer(
      child: GridView.builder(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.all(_gutter),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: _columns,
          crossAxisSpacing: _gutter,
          mainAxisSpacing: _gutter,
        ),
        itemCount: _columns * 6,
        itemBuilder: (_, _) => const ShimmerBlock(radius: 4),
      ),
    );
  }

  Widget _bottomBar(BuildContext context) {
    final preset =
        ref.watch(configNotifierProvider)?.quality ?? QualityPreset.medium;
    final projected = projectedBatchBytes(
      ref.watch(mediaPipelineServiceProvider),
      _selected,
      preset,
    );

    return Container(
      decoration: BoxDecoration(
        color: context.colorScheme.surfaceContainerHigh,
        border: Border(
          top: BorderSide(
            color: context.colorScheme.outline.withValues(alpha: 0.3),
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _next,
                  child: Text('Next - ${_selected.length} selected'),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'about ${formatBytes(projected)} at ${preset.label}',
                style: context.textTheme.bodySmall?.copyWith(fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the "Add to" sheet resolves to. A null [album] means "create one".
class _AlbumChoice {
  final Album? album;
  const _AlbumChoice(this.album);
}

class _AlbumRow extends StatelessWidget {
  final Album album;
  final VoidCallback onTap;

  const _AlbumRow({required this.album, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final items = album.gallery;
    final count = items.length;

    // Falls back to the first IMAGE rather than the first item: RemoteMedia
    // decodes bytes as an image, so an album whose first file is a video would
    // show a broken-image glyph here.
    var cover = album.cover;
    if (cover == null) {
      for (final item in items) {
        if (item.isImage) {
          cover = item;
          break;
        }
      }
    }

    return ListTile(
      onTap: onTap,
      leading: SizedBox(
        width: 44,
        height: 44,
        child:
            cover == null
                ? Container(
                  decoration: BoxDecoration(
                    color: context.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.photo_outlined,
                    size: 20,
                    color: context.colorScheme.onSurfaceVariant,
                  ),
                )
                : RemoteMedia(
                  album: album,
                  item: cover,
                  decodeWidth: 132,
                  borderRadius: BorderRadius.circular(10),
                ),
      ),
      title: Text(album.title),
      subtitle: Text(
        '${album.folder}  ·  $count ${count == 1 ? 'item' : 'items'}',
        overflow: TextOverflow.ellipsis,
        style: AppTheme.mono(context, size: 12),
      ),
    );
  }
}

/// One gallery tile.
class _AssetTile extends StatelessWidget {
  final AssetEntity asset;

  /// 1-based place in the selection, or null when unselected.
  final int? order;

  final bool supported;
  final VoidCallback? onTap;

  const _AssetTile({
    required this.asset,
    required this.order,
    required this.supported,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final selected = order != null;
    final isVideo = asset.type == AssetType.video;

    return Semantics(
      button: supported,
      selected: selected,
      label: isVideo ? 'Video' : 'Photo',
      hint: selected ? 'Number $order in this upload' : null,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: scheme.surfaceContainer),
          // isOriginal:false with an explicit thumbnailSize is mandatory here:
          // decoding full-resolution frames four-across would exhaust the heap
          // within a screen or two of scrolling.
          Image(
            image: AssetEntityImageProvider(
              asset,
              isOriginal: false,
              thumbnailSize: const ThumbnailSize.square(240),
            ),
            fit: BoxFit.cover,
            gaplessPlayback: true,
            frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
              if (wasSynchronouslyLoaded) return child;
              // Opacity rather than a staggered entrance: grid children are
              // rebuilt constantly while scrolling, and an index-based stagger
              // would re-run on every recycled tile.
              return AnimatedOpacity(
                opacity: frame == null ? 0 : 1,
                duration: context.motion(const Duration(milliseconds: 180)),
                child: child,
              );
            },
            errorBuilder:
                (_, _, _) => Icon(
                  Icons.broken_image_outlined,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
          ),

          if (!supported)
            Container(
              color: scheme.surface.withValues(alpha: 0.72),
              alignment: Alignment.bottomLeft,
              padding: const EdgeInsets.all(4),
              child: Text(
                'Not supported',
                style: context.textTheme.labelSmall?.copyWith(fontSize: 9),
              ),
            )
          else ...[
            if (selected)
              Container(
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.22),
                  border: Border.all(color: scheme.primary, width: 2),
                ),
              ),
            if (isVideo)
              Positioned(
                left: 4,
                bottom: 4,
                child: VideoBadge(
                  size: 20,
                  duration: formatDuration(asset.videoDuration),
                ),
              ),
            Positioned(top: 4, right: 4, child: _OrderBadge(order: order)),
            Material(
              type: MaterialType.transparency,
              child: InkWell(onTap: onTap),
            ),
          ],
        ],
      ),
    );
  }
}

/// The selection badge.
///
/// A NUMBER, not a checkmark. That number is the position the item will have
/// on the website, because glickr names uploads in pick order and the site
/// sorts by filename - showing it is what makes a reorder screen unnecessary.
class _OrderBadge extends StatelessWidget {
  final int? order;
  const _OrderBadge({required this.order});

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final selected = order != null;

    return AnimatedContainer(
      duration: context.motion(const Duration(milliseconds: 140)),
      curve: Curves.easeOutBack,
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        // Unselected still draws a ring: an empty tile gives no hint that it
        // is tappable, over a photo that may be any colour at all.
        color: selected ? scheme.primary : Colors.black.withValues(alpha: 0.28),
        border: Border.all(
          color:
              selected ? scheme.primary : Colors.white.withValues(alpha: 0.85),
          width: 1.5,
        ),
      ),
      alignment: Alignment.center,
      child:
          selected
              ? Text(
                '$order',
                style: AppTheme.mono(
                  context,
                  size: 11,
                  weight: FontWeight.w600,
                  color: scheme.onPrimary,
                ),
              )
              : null,
    );
  }
}
