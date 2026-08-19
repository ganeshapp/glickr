import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import '../../../core/models/album.dart';
import '../../../core/models/app_config.dart';
import '../../../core/providers/albums_provider.dart';
import '../../../core/providers/config_provider.dart';
import '../../../core/providers/services_provider.dart';
import '../../../core/providers/upload_provider.dart';
import '../../../core/services/media_pipeline_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/album_conventions.dart';
import '../../../core/widgets/empty_state.dart';

/// Projected upload size for [assets] at [preset].
///
/// Top-level and shared with the picker on purpose: the grid's "about 17 MB at
/// Medium" caption and this sheet's numbers describe the same batch one tap
/// apart, and two estimates that disagree by a megabyte read as a bug in both.
int projectedBatchBytes(
  MediaPipelineService media,
  List<AssetEntity> assets,
  QualityPreset preset,
) {
  var total = 0;
  for (final asset in assets) {
    total += projectedAssetBytes(media, asset, preset);
  }
  return total;
}

/// Projected output size of one asset, used for the per-file ceiling check.
int projectedAssetBytes(
  MediaPipelineService media,
  AssetEntity asset,
  QualityPreset preset,
) {
  if (asset.type == AssetType.video) {
    return media.projectedVideoBytes(asset.videoDuration, preset);
  }
  return media.projectedPhotoBytes(
    width: asset.orientatedWidth,
    height: asset.orientatedHeight,
    preset: preset,
  );
}

/// Show the last step before an upload is queued.
///
/// Resolves to true once the batch is on the queue, so the picker knows to
/// close itself. Null or false means the user backed out.
Future<bool?> showUploadReviewSheet(
  BuildContext context, {
  required List<AssetEntity> assets,
  Album? album,
  String? newAlbumTitle,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    // The inner DraggableScrollableSheet owns every drag. The route's own
    // drag-to-dismiss pops with a bare Navigator.pop(), which PopScope cannot
    // see - so leaving it on would give the sheet one exit that silently
    // throws away typed captions.
    enableDrag: false,
    builder:
        (context) => Padding(
          // DraggableScrollableSheet measures its fractions against the parent's
          // constraints, so shrinking the parent by the keyboard inset keeps the
          // whole sheet - the pinned Upload button included - above the keyboard
          // instead of behind it.
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: UploadReviewSheet(
            assets: assets,
            album: album,
            initialTitle: newAlbumTitle,
          ),
        ),
  );
}

class UploadReviewSheet extends ConsumerStatefulWidget {
  /// In pick order: index 0 becomes the lowest filename, and therefore the
  /// first item on the website.
  final List<AssetEntity> assets;

  /// Null means this batch creates a new album.
  final Album? album;

  /// Prefill for the album name, when the caller already knows it.
  final String? initialTitle;

  const UploadReviewSheet({
    super.key,
    required this.assets,
    this.album,
    this.initialTitle,
  });

  @override
  ConsumerState<UploadReviewSheet> createState() => _UploadReviewSheetState();
}

class _UploadReviewSheetState extends ConsumerState<UploadReviewSheet> {
  static const double _initialExtent = 0.72;
  static const double _minExtent = 0.5;

  /// Below this the repo is nowhere near its size limit and the projection
  /// is just noise on the screen.
  static const int _budgetNoticeBytes = 30 * 1024 * 1024;

  final DraggableScrollableController _sheetController =
      DraggableScrollableController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();

  /// Keyed by asset id, created lazily so an untouched batch allocates none.
  final Map<String, TextEditingController> _captions = {};

  Album? _album;
  String? _expandedAssetId;
  String? _coverAssetId;
  late QualityPreset _preset;
  bool _submitting = false;
  bool _confirmingDiscard = false;
  String? _submitError;

  @override
  void initState() {
    super.initState();
    _album = widget.album;
    _nameController.text = widget.initialTitle ?? '';
    // Seeded from the saved default and NEVER written back. A quality choice
    // that quietly becomes the new default is the classic surprise bug: you
    // pick Low once on a train and three months later every album is Low.
    _preset = ref.read(configNotifierProvider)?.quality ?? QualityPreset.medium;
    _coverAssetId = _firstImage()?.id;
  }

  @override
  void dispose() {
    _sheetController.dispose();
    _nameController.dispose();
    _descriptionController.dispose();
    for (final controller in _captions.values) {
      controller.dispose();
    }
    super.dispose();
  }

  bool get _isNewAlbum => _album == null;

  AssetEntity? _firstImage() {
    for (final asset in widget.assets) {
      if (asset.type == AssetType.image) return asset;
    }
    return null;
  }

  TextEditingController _captionController(String assetId) {
    return _captions.putIfAbsent(assetId, TextEditingController.new);
  }

  String get _folder => _album?.folder ?? folderNameFor(_nameController.text);

  /// The album this name would land in, in new-album mode.
  ///
  /// Takes the list instead of reading the provider itself: albums_provider is
  /// autoDispose, so a `ref.read` per keystroke would build and tear the
  /// notifier down again on every letter - and each build kicks off a repo
  /// refresh.
  Album? _collisionIn(List<Album> albums) {
    if (!_isNewAlbum) return null;
    final folder = _folder;
    if (folder.isEmpty) return null;
    for (final album in albums) {
      if (album.folder == folder) return album;
    }
    return null;
  }

  // ------------------------------------------------------------- dismissal

  /// The sheet reached the bottom of its drag range.
  ///
  /// [DraggableScrollableSheet.shouldCloseOnMinExtent] is off so this asks
  /// first: dragging past the bottom edge is easy to do by accident, and the
  /// captions in this sheet exist nowhere else.
  bool _onExtentChanged(DraggableScrollableNotification notification) {
    if (_confirmingDiscard || _submitting) return false;
    if (notification.extent <= notification.minExtent + 0.001) {
      _confirmDiscard();
    }
    return false;
  }

  Future<void> _confirmDiscard() async {
    if (_confirmingDiscard) return;
    setState(() => _confirmingDiscard = true);

    final count = widget.assets.length;
    final noun = count == 1 ? 'item' : 'items';
    final discard = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Discard this upload?'),
            content: Text("The $count $noun you picked won't be uploaded."),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Keep editing'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                ),
                child: const Text('Discard'),
              ),
            ],
          ),
    );

    if (!mounted) return;
    setState(() => _confirmingDiscard = false);

    if (discard == true) {
      Navigator.of(context).pop(false);
      return;
    }
    // "Keep editing" after a drag leaves the sheet parked at its minimum
    // extent, so put it back where the user found it.
    if (_sheetController.isAttached && _sheetController.size < _initialExtent) {
      final duration = context.motion(const Duration(milliseconds: 220));
      if (duration == Duration.zero) {
        _sheetController.jumpTo(_initialExtent);
      } else {
        await _sheetController.animateTo(
          _initialExtent,
          duration: duration,
          curve: Curves.easeOutCubic,
        );
      }
    }
  }

  // ---------------------------------------------------------------- submit

  Future<void> _submit() async {
    if (_submitting) return;
    final config = ref.read(configNotifierProvider);
    if (config == null) {
      setState(() => _submitError = "glickr isn't connected to a repo yet.");
      return;
    }

    setState(() {
      _submitting = true;
      _submitError = null;
    });

    try {
      final captions = <String, String>{};
      for (final entry in _captions.entries) {
        final text = entry.value.text.trim();
        if (text.isNotEmpty) captions[entry.key] = text;
      }
      final description = _descriptionController.text.trim();

      final job = await ref
          .read(uploadServiceProvider)
          .enqueue(
            config: config,
            assets: widget.assets,
            albumFolder: _folder,
            preset: _preset,
            isNewAlbum: _isNewAlbum,
            blurb: _isNewAlbum && description.isNotEmpty ? description : null,
            existingAlbum: _album,
            captions: captions,
            // Only a new album gets a cover from this sheet; writing 0.jpg
            // into an existing album would replace the cover it already has.
            coverAssetId: _isNewAlbum ? _coverAssetId : null,
          );
      await ref.read(uploadQueueNotifierProvider.notifier).enqueueJob(job);

      if (!mounted) return;
      // The queue drains in the background from here. Waiting on it would
      // hold the user on a modal for the length of a video transcode.
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submitError = "Couldn't queue this upload - $e";
      });
    }
  }

  // ----------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final media = ref.watch(mediaPipelineServiceProvider);
    final projected = projectedBatchBytes(media, widget.assets, _preset);
    final repoBytes = ref.watch(syncStateNotifierProvider).repoBytes;
    final projectedRepo = repoBytes + projected;
    // Only meaningful once a sync has told us how big the repo actually is.
    final knowsRepoSize = repoBytes > 0;
    final blocked =
        knowsRepoSize && projectedRepo >= MediaPipelineService.repoBlockBytes;

    final oversized = _oversizedAt(media, _preset);
    final hasVideo = widget.assets.any((a) => a.type == AssetType.video);

    final collision = _collisionIn(ref.watch(albumsNotifierProvider).albums);
    final nameIsUsable =
        !_isNewAlbum || (_folder.isNotEmpty && collision == null);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmDiscard();
      },
      child: NotificationListener<DraggableScrollableNotification>(
        onNotification: _onExtentChanged,
        child: DraggableScrollableSheet(
          controller: _sheetController,
          initialChildSize: _initialExtent,
          minChildSize: _minExtent,
          maxChildSize: 0.95,
          expand: false,
          shouldCloseOnMinExtent: false,
          builder: (context, scrollController) {
            return FocusTraversalGroup(
              // Name -> description -> caption, in the order they appear.
              policy: ReadingOrderTraversalPolicy(),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _grabber(context),
                  _header(context),
                  Expanded(
                    child: ListView(
                      controller: scrollController,
                      padding: const EdgeInsets.only(bottom: 24),
                      children: [
                        if (_isNewAlbum) ..._newAlbumFields(context, collision),
                        _thumbStrip(context),
                        _captionEditor(context),
                        const SizedBox(height: 20),
                        _qualitySection(context, projected, hasVideo),
                        if (_isNewAlbum) ...[
                          const SizedBox(height: 20),
                          _coverSection(context),
                        ],
                        if (oversized != null) ...[
                          const SizedBox(height: 20),
                          oversized,
                        ],
                        ..._budgetSection(
                          context,
                          knowsRepoSize: knowsRepoSize,
                          projectedRepo: projectedRepo,
                          blocked: blocked,
                        ),
                      ],
                    ),
                  ),
                  _footer(
                    context,
                    blocked: blocked,
                    nameIsUsable: nameIsUsable,
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _grabber(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: context.colorScheme.outline,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final count = widget.assets.length;
    final album = _album;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  album == null ? 'New album' : 'Add to ${album.title}',
                  style: context.textTheme.titleLarge,
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Text(
                      '$count ${count == 1 ? 'item' : 'items'}',
                      style: context.textTheme.bodySmall,
                    ),
                    if (album != null) ...[
                      Text('  ·  ', style: context.textTheme.bodySmall),
                      Flexible(
                        child: Text(
                          album.folder,
                          overflow: TextOverflow.ellipsis,
                          style: AppTheme.mono(context, size: 12),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: _confirmDiscard,
            tooltip: 'Close',
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- new album

  List<Widget> _newAlbumFields(BuildContext context, Album? collision) {
    final folder = _folder;
    final typed = _nameController.text.trim();

    String? errorText;
    if (collision != null) {
      errorText = 'An album called ${collision.title} already exists.';
    } else if (typed.isNotEmpty && folder.isEmpty) {
      errorText =
          'That leaves nothing glickr can use as a folder name - try adding '
          'some letters or numbers.';
    }

    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: TextField(
          controller: _nameController,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: 'Album name',
            hintText: 'Cycling trip',
            errorText: errorText,
          ),
          onChanged: (_) => setState(() {}),
        ),
      ),
      if (collision != null)
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 8, top: 2),
            child: TextButton.icon(
              onPressed: () => _useExisting(collision),
              icon: const Icon(
                Icons.subdirectory_arrow_right_rounded,
                size: 18,
              ),
              label: const Text('Add to it instead'),
            ),
          ),
        )
      else
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 16, 0),
          child: _folderHelper(context, folder),
        ),
      const SizedBox(height: 16),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: TextField(
          controller: _descriptionController,
          maxLines: 2,
          // Explicitly not multiline: TextInputAction.next only traverses when
          // the keyboard is not offering a newline key.
          keyboardType: TextInputType.text,
          textCapitalization: TextCapitalization.sentences,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'Description',
            hintText: 'Optional',
            helperText: 'Saved as album.md, above the photos on your site.',
          ),
        ),
      ),
      const SizedBox(height: 20),
    ];
  }

  /// Both derived values, live: the folder that gets created and the title the
  /// website will render from it. Showing only the folder hides the lossy step
  /// - "BarCamp Days" comes back as "Barcamp Days" - and the user finds out
  /// after the upload, when renaming means editing the repo by hand.
  Widget _folderHelper(BuildContext context, String folder) {
    final style = context.textTheme.bodySmall;
    if (folder.isEmpty) {
      return Text(
        'Type a name and glickr will create the folder.',
        style: style,
      );
    }
    return Text.rich(
      TextSpan(
        children: [
          const TextSpan(text: 'Creates the folder '),
          TextSpan(
            text: folder,
            style: AppTheme.mono(
              context,
              size: 12,
              weight: FontWeight.w600,
              color: context.colorScheme.primary,
            ),
          ),
          TextSpan(text: ', shown as "${albumTitle(folder)}" on your site.'),
        ],
      ),
      style: style,
    );
  }

  /// Turn the duplicate-name error into the thing the user probably meant.
  void _useExisting(Album album) {
    FocusScope.of(context).unfocus();
    setState(() {
      _album = album;
      // The album already has a cover; this sheet no longer offers to set one.
      _coverAssetId = null;
    });
  }

  // ---------------------------------------------------------------- thumbs

  Widget _thumbStrip(BuildContext context) {
    return SizedBox(
      height: 76,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: widget.assets.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final asset = widget.assets[index];
          final expanded = _expandedAssetId == asset.id;
          final hasCaption =
              (_captions[asset.id]?.text.trim().isNotEmpty) ?? false;

          return _Thumb(
            asset: asset,
            size: 76,
            position: index + 1,
            selected: expanded,
            captioned: hasCaption,
            badge:
                asset.type == AssetType.video ? Icons.play_arrow_rounded : null,
            onTap:
                () => setState(
                  () => _expandedAssetId = expanded ? null : asset.id,
                ),
          );
        },
      ),
    );
  }

  Widget _captionEditor(BuildContext context) {
    final assetId = _expandedAssetId;
    final index =
        assetId == null ? -1 : widget.assets.indexWhere((a) => a.id == assetId);

    return AnimatedSize(
      duration: context.motion(const Duration(milliseconds: 180)),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child:
          assetId == null || index < 0
              ? const SizedBox(width: double.infinity)
              : Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: TextField(
                  key: ValueKey(assetId),
                  controller: _captionController(assetId),
                  autofocus: true,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: 'Caption for item ${index + 1}',
                    hintText: 'Optional',
                    suffixIcon: IconButton(
                      tooltip: 'Done',
                      icon: const Icon(Icons.keyboard_hide_rounded),
                      onPressed: () {
                        FocusScope.of(context).unfocus();
                        setState(() => _expandedAssetId = null);
                      },
                    ),
                  ),
                  // Keeps the quote badge on the thumb honest as you type.
                  onChanged: (_) => setState(() {}),
                ),
              ),
    );
  }

  // --------------------------------------------------------------- quality

  Widget _qualitySection(BuildContext context, int projected, bool hasVideo) {
    final defaultPreset =
        ref.watch(configNotifierProvider)?.quality ?? QualityPreset.medium;
    final spec = MediaPipelineService.specFor(_preset);

    final detail = StringBuffer('${_preset.label} - long edge ')
      ..write('${spec.imageMaxEdge}px');
    // The video line is dropped for an all-photo batch rather than shown as a
    // number that describes nothing in this upload.
    if (hasVideo) detail.write(', video ${spec.videoLabel}');
    detail.write(' - about ${formatBytes(projected)} total');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel(context, 'Quality'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<QualityPreset>(
              segments: [
                for (final preset in QualityPreset.values)
                  ButtonSegment(value: preset, label: Text(preset.label)),
              ],
              selected: {_preset},
              showSelectedIcon: false,
              onSelectionChanged:
                  (selection) => setState(() => _preset = selection.first),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              for (final preset in QualityPreset.values)
                Expanded(
                  child: Opacity(
                    // Opacity rather than a conditional child so the row never
                    // changes height as the marker moves.
                    opacity: preset == defaultPreset ? 1 : 0,
                    child: Text(
                      'Default',
                      textAlign: TextAlign.center,
                      style: context.textTheme.labelSmall?.copyWith(
                        fontSize: 10,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            detail.toString(),
            style: context.textTheme.bodySmall?.copyWith(fontSize: 12),
          ),
        ),
      ],
    );
  }

  /// Warn when one file is projected past the per-file ceiling.
  ///
  /// Not a block: the projection is a rate estimate, and the real check happens
  /// on the compressed bytes. But a 4-minute clip at High will be dropped from
  /// the batch, and finding that out afterwards - from a "skipped 1" line -
  /// is worse than seeing it here, where changing the preset fixes it.
  Widget? _oversizedAt(MediaPipelineService media, QualityPreset preset) {
    var count = 0;
    var largest = 0;
    for (final asset in widget.assets) {
      final bytes = projectedAssetBytes(media, asset, preset);
      if (bytes > MediaPipelineService.maxFileBytes) {
        count++;
        if (bytes > largest) largest = bytes;
      }
    }
    if (count == 0) return null;

    final limit = formatBytes(MediaPipelineService.maxFileBytes);
    return StatusBanner(
      icon: Icons.warning_amber_rounded,
      tint: context.appColors.warning,
      message:
          count == 1
              ? 'One clip lands at about ${formatBytes(largest)}, over the $limit '
                  'limit for a single file. glickr will skip it unless a lower '
                  'quality brings it under.'
              : '$count clips land over the $limit limit for a single file. '
                  'glickr will skip them unless a lower quality brings them '
                  'under.',
    );
  }

  // ----------------------------------------------------------------- cover

  Widget _coverSection(BuildContext context) {
    final images =
        widget.assets.where((a) => a.type == AssetType.image).toList();

    if (images.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionLabel(context, 'Cover'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              "Everything here is a video, so this album starts without a "
              'cover. You can set one from the album once a photo is in it.',
              style: context.textTheme.bodySmall,
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel(context, 'Cover'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Text(
            'This one is copied to 0.jpg - the image your site puts on the '
            'album card.',
            style: context.textTheme.bodySmall,
          ),
        ),
        SizedBox(
          height: 64,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: images.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final asset = images[index];
              final chosen = _coverAssetId == asset.id;
              return _Thumb(
                asset: asset,
                size: 64,
                selected: chosen,
                selectedTint: context.appColors.coverBadge,
                badge: chosen ? Icons.star_rounded : null,
                onTap: () => setState(() => _coverAssetId = asset.id),
              );
            },
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- budget

  List<Widget> _budgetSection(
    BuildContext context, {
    required bool knowsRepoSize,
    required int projectedRepo,
    required bool blocked,
  }) {
    if (!knowsRepoSize || projectedRepo < _budgetNoticeBytes) return const [];

    final after = _megabytes(projectedRepo);
    final ceiling = _megabytes(
      MediaPipelineService.repoCeilingBytes,
      decimals: 0,
    );

    if (blocked) {
      return [
        const SizedBox(height: 20),
        StatusBanner(
          icon: Icons.block_rounded,
          tint: context.colorScheme.error,
          message:
              'Your repo would be $after of $ceiling MB after this. The CDN '
              'stops serving a repo over $ceiling MB, so every photo on your '
              "site would stop loading - glickr won't add these. Try a lower "
              'quality, or delete some items first.',
        ),
      ];
    }

    final warning = projectedRepo >= MediaPipelineService.repoWarnBytes;
    if (warning) {
      return [
        const SizedBox(height: 20),
        StatusBanner(
          icon: Icons.warning_amber_rounded,
          tint: context.appColors.warning,
          message:
              'Your repo would be $after of $ceiling MB after this. Past '
              '$ceiling MB the CDN stops serving your site.',
        ),
      ];
    }

    return [
      const SizedBox(height: 20),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          'Your repo would be $after of $ceiling MB after this.',
          style: context.textTheme.bodySmall,
        ),
      ),
    ];
  }

  // ---------------------------------------------------------------- footer

  Widget _footer(
    BuildContext context, {
    required bool blocked,
    required bool nameIsUsable,
  }) {
    final count = widget.assets.length;
    final canUpload = !blocked && !_submitting && nameIsUsable;

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
              if (_submitError != null) ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    _submitError!,
                    textAlign: TextAlign.center,
                    style: context.textTheme.bodySmall?.copyWith(
                      color: context.colorScheme.error,
                    ),
                  ),
                ),
              ],
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: canUpload ? _submit : null,
                  child: Text('Upload $count ${count == 1 ? 'item' : 'items'}'),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Uploading keeps going while you use the rest of glickr.',
                textAlign: TextAlign.center,
                style: context.textTheme.bodySmall?.copyWith(fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Text(
        text,
        style: context.textTheme.labelMedium?.copyWith(letterSpacing: 0.6),
      ),
    );
  }

  String _megabytes(int bytes, {int decimals = 1}) =>
      (bytes / (1024 * 1024)).toStringAsFixed(decimals);
}

/// One square thumbnail in the review strips.
class _Thumb extends StatelessWidget {
  final AssetEntity asset;
  final double size;
  final bool selected;

  /// 1-based place in the batch, shown so the strip agrees with the numbers
  /// the picker grid just showed.
  final int? position;

  /// Corner glyph for what the item IS - the play arrow on a video.
  final IconData? badge;

  /// Separate from [badge] so a captioned video keeps its play arrow: one is
  /// what the file is, the other is what the user has done to it.
  final bool captioned;

  final Color? selectedTint;
  final VoidCallback onTap;

  const _Thumb({
    required this.asset,
    required this.size,
    required this.selected,
    required this.onTap,
    this.position,
    this.badge,
    this.captioned = false,
    this.selectedTint,
  });

  @override
  Widget build(BuildContext context) {
    final tint = selectedTint ?? context.colorScheme.primary;
    final radius = BorderRadius.circular(10);

    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: context.motion(const Duration(milliseconds: 150)),
          width: size,
          height: size,
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(
              color: selected ? tint : Colors.transparent,
              width: 2.5,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: context.colorScheme.surfaceContainer),
                Image(
                  image: AssetEntityImageProvider(
                    asset,
                    isOriginal: false,
                    thumbnailSize: const ThumbnailSize.square(200),
                  ),
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder:
                      (_, _, _) => Icon(
                        Icons.broken_image_outlined,
                        size: 18,
                        color: context.colorScheme.onSurfaceVariant,
                      ),
                ),
                if (position != null)
                  Positioned(
                    left: 3,
                    top: 3,
                    child: _Pill(
                      child: Text(
                        '$position',
                        style: AppTheme.mono(
                          context,
                          size: 10,
                          weight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                if (badge != null)
                  Positioned(
                    right: 3,
                    bottom: 3,
                    child: _Pill(
                      child: Icon(badge, size: 12, color: Colors.white),
                    ),
                  ),
                if (captioned)
                  Positioned(
                    right: 3,
                    top: 3,
                    child: _Pill(
                      child: Icon(
                        Icons.format_quote_rounded,
                        size: 12,
                        color: Colors.white,
                      ),
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

/// A black scrim pill, so white glyphs stay legible over any photograph.
class _Pill extends StatelessWidget {
  final Widget child;
  const _Pill({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(6),
      ),
      child: child,
    );
  }
}
