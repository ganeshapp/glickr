import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/album.dart';
import '../../../core/models/media_item.dart';
import '../../../core/platform.dart';
import '../../../core/providers/album_actions_provider.dart';
import '../../../core/providers/config_provider.dart';
import '../../../core/providers/pending_captions_provider.dart';
import '../../../core/services/media_pipeline_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/album_conventions.dart';
import '../../../core/utils/external_url.dart';
import '../../../core/widgets/empty_state.dart';
import '../../../core/widgets/remote_media.dart';
import '../../picker/presentation/media_picker_screen.dart';
import '../../viewer/presentation/photo_viewer_screen.dart';
import '../widgets/description_dialog.dart';
import '../widgets/media_tile.dart';

enum _AlbumMenu { description, rename, web, discardCaptions, delete }

enum _SelectionMenu { selectAll, clear }

/// One album: a stretchy cover header, the description, and every file in the
/// folder as a 3-up grid.
///
/// Addressed by FOLDER rather than by an [Album] instance. Every mutation
/// re-reads the repo and hands back new objects, so a screen holding the
/// instance it was pushed with would keep rendering photos that are no longer
/// there.
///
/// There is deliberately no reorder affordance. The website sorts by filename,
/// so display order IS filename order, and a drag would mean renaming every
/// file after the drop point - N commits and N changed public URLs to move one
/// photo left.
class AlbumDetailScreen extends ConsumerStatefulWidget {
  final String folder;

  const AlbumDetailScreen({super.key, required this.folder});

  @override
  ConsumerState<AlbumDetailScreen> createState() => _AlbumDetailScreenState();
}

class _AlbumDetailScreenState extends ConsumerState<AlbumDetailScreen> {
  static const double _expandedHeight = 280;

  final ScrollController _scroll = ScrollController();

  /// 0 = header fully open, 1 = collapsed onto the toolbar.
  ///
  /// A ValueNotifier rather than setState because it changes every scroll
  /// frame: setState would rebuild the CustomScrollView, and with it the grid
  /// delegate, purely to fade a title from white to ink.
  final ValueNotifier<double> _collapse = ValueNotifier<double>(0);

  /// Selected FILENAMES, never indices - a sync landing mid-selection can add,
  /// remove and reorder the item list underneath.
  final Set<String> _selected = <String>{};

  /// Set from the moment a rename commit goes out until the replacement route
  /// is pushed, so the "album is gone" pop below doesn't fire in that gap: a
  /// rename makes the old folder key vanish, which is indistinguishable from a
  /// delete at the provider level.
  bool _renaming = false;

  /// True while the staged captions are being committed. Separate from
  /// [albumActionsProvider]'s flag because the flush goes through the pending
  /// captions notifier, which has no busy state of its own.
  bool _savingCaptions = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    _collapse.dispose();
    super.dispose();
  }

  void _onScroll() {
    // The header travels exactly (expanded - toolbar); the status bar inset is
    // added to both ends by SliverAppBar and cancels out.
    const travel = _expandedHeight - kToolbarHeight;
    final next = (_scroll.offset / travel).clamp(0.0, 1.0);
    if ((next - _collapse.value).abs() > 0.004) _collapse.value = next;
  }

  // ------------------------------------------------------------- selection

  void _beginSelection(MediaItem item) {
    HapticFeedback.selectionClick();
    setState(() => _selected.add(item.name));
  }

  void _toggle(MediaItem item) {
    HapticFeedback.selectionClick();
    setState(() {
      if (!_selected.remove(item.name)) _selected.add(item.name);
    });
  }

  void _clearSelection() => setState(_selected.clear);

  // --------------------------------------------------------------- actions

  void _openViewer(Album album, int index) {
    // PhotoViewerScreen.route, never a route built here: it is non-opaque on
    // purpose, so drag-to-dismiss fades the backdrop out over this grid. An
    // opaque route takes everything below it offstage and the gesture fades
    // into nothing instead.
    //
    // The index is into allInDisplayOrder - the same list the grid built - so
    // the viewer opens on the tile that was tapped and the hero tags line up.
    Navigator.of(
      context,
    ).push(PhotoViewerScreen.route(context, album: album, initialIndex: index));
  }

  void _addPhotos(Album album) {
    // The destination is already known, so the picker gets no "choose an
    // album" step.
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => MediaPickerScreen(targetAlbum: album),
      ),
    );
  }

  Future<void> _editDescription(Album album) async {
    final edit = await showDescriptionDialog(context, album);
    if (edit == null || !mounted) return;

    final result = await ref
        .read(albumActionsProvider.notifier)
        .setDescription(album, summary: edit.summary, note: edit.note);
    _report(
      result,
      edit.summary.isEmpty && edit.note.isEmpty
          ? 'Description removed'
          : 'Description saved',
    );
  }

  Future<void> _rename(Album album) async {
    final config = ref.read(configNotifierProvider);
    final title = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(
        initialTitle: album.title,
        albumsPath: config?.albumsPath ?? 'albums',
      ),
    );
    if (title == null || !mounted) return;

    final newFolder = folderNameFor(title);
    final moved = newFolder.isNotEmpty && newFolder != album.folder;

    // Staged captions are filed under the folder name, and the action re-files
    // them under the new one when the rename lands. They are NOT committed on
    // the way past: the user left them unsaved on purpose, and a rename is no
    // reason to publish typing they were still thinking about - or to spend a
    // second site build doing it.
    _renaming = moved;

    final result = await ref
        .read(albumActionsProvider.notifier)
        .renameAlbum(album, title);
    if (!mounted) return;

    if (!result.ok) {
      _renaming = false;
      _report(result, '');
      return;
    }
    if (!moved) return;

    // This screen is keyed on a folder that no longer exists. Replace the route
    // rather than letting the pop-on-missing path fire: the user renamed an
    // album, they did not ask to be sent back to the list.
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => AlbumDetailScreen(folder: newFolder),
      ),
    );
  }

  Future<void> _openOnWeb(Album album) async {
    final url = ref.read(configNotifierProvider)?.albumWebUrl(album.slug) ?? '';
    if (url.isEmpty) return;
    await openExternalUrl(context, url);
  }

  Future<void> _confirmDeleteAlbum(Album album) async {
    final count = album.allInDisplayOrder.length;
    final ok = await _confirm(
      title: 'Delete ${album.title}?',
      body:
          'This deletes the folder and all ${_plural(count, 'item')} from '
          'GitHub. This cannot be undone from the app.',
      confirmLabel: 'Delete album',
    );
    if (!ok || !mounted) return;

    // Staged captions for the folder go with it, inside the action: they could
    // never be saved once it is gone, and would keep the leave-warning armed
    // for an album that no longer exists.
    final result = await ref
        .read(albumActionsProvider.notifier)
        .deleteAlbum(album);
    // On success the album leaves the list, this screen's watch turns null and
    // the build below pops it - so there is nothing to do here but say so.
    _report(result, 'Album deleted');
  }

  Future<void> _setCover(Album album, MediaItem item) async {
    // The commit swaps two filenames and their committed captions with them;
    // staged edits are swapped to match inside the action.
    final result = await ref
        .read(albumActionsProvider.notifier)
        .setCover(album, item);
    if (result.ok && mounted) _clearSelection();
    _report(result, 'Cover updated');
  }

  Future<void> _confirmDeleteItems(
    Album album,
    List<MediaItem> selected,
  ) async {
    final count = selected.length;
    final single = count == 1 ? selected.first : null;

    final title = single == null
        ? 'Delete $count items?'
        : (single.isVideo ? 'Delete this video?' : 'Delete this photo?');
    final buffer = StringBuffer(
      single == null
          ? 'This removes them from the album on GitHub. '
          : 'This removes it from the album on GitHub. ',
    )..write('This cannot be undone from the app.');

    // Deleting the cover promotes the next photo to cover, since the cover is
    // simply whichever image sorts first. Worth saying: from a grid where the
    // cover looks like every other tile, that consequence is invisible.
    if (selected.any(album.isCover)) {
      buffer.write(
        single == null
            ? '\n\nOne of these is the cover, so the next photo becomes the '
                  'new one.'
            : '\n\nThis is the album cover, so the next photo becomes the '
                  'new one.',
      );
    }

    final ok = await _confirm(
      title: title,
      body: buffer.toString(),
      confirmLabel: 'Delete',
    );
    if (!ok || !mounted) return;

    final names = selected.map((i) => i.name).toSet();
    // Staged captions for the deleted files are dropped inside the action:
    // they can never be saved, and would keep the unsaved count - and the
    // leave warning - armed forever.
    final result = await ref
        .read(albumActionsProvider.notifier)
        .deleteItems(album, names);
    if (result.ok && mounted) _clearSelection();
    _report(result, single == null ? 'Deleted $count items' : 'Deleted');
  }

  // -------------------------------------------------------------- captions

  /// How many caption edits are staged for this album.
  ///
  /// Watched rather than read, so the banner and the menu entry appear the
  /// moment a caption is typed in the viewer sitting on top of this screen.
  int get _pendingCount =>
      ref.watch(pendingCaptionsNotifierProvider)[widget.folder]?.length ?? 0;

  /// Commit every staged caption at once.
  ///
  /// On failure the edits stay staged - the notifier only clears them once the
  /// commit lands. Dropping someone's typing because the network blipped is a
  /// worse outcome than making them press Save again.
  Future<void> _saveCaptions(Album album) async {
    if (_savingCaptions) return;
    setState(() => _savingCaptions = true);

    final result = await ref
        .read(pendingCaptionsNotifierProvider.notifier)
        .flush(album);
    if (!mounted) return;

    setState(() => _savingCaptions = false);
    _report(result, 'Captions saved');
  }

  Future<void> _discardCaptions(int count) async {
    final ok = await _confirm(
      title: 'Discard unsaved captions?',
      body:
          '${_plural(count, 'caption')} you typed on this device would be '
          "thrown away. The captions already on your site aren't touched.",
      confirmLabel: 'Discard',
    );
    if (!ok) return;

    await ref
        .read(pendingCaptionsNotifierProvider.notifier)
        .discard(widget.folder);
  }

  /// Back was pressed with captions still staged.
  ///
  /// The edits are NOT discarded on the way out - they are persisted on
  /// purpose, so leaving is a pause rather than a loss. The dialog exists only
  /// because "saved" and "saved on this phone" look identical on screen.
  Future<void> _confirmLeave(int count) async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          'Leave without saving captions?',
          style: context.textTheme.titleLarge,
        ),
        content: Text(
          count == 1
              ? "1 caption is only on this device. It'll still be here when "
                    'you come back.'
              : "$count captions are only on this device. They'll still be "
                    'here when you come back.',
          style: context.textTheme.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Stay'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (leave != true || !mounted) return;

    // Navigator.pop rather than maybePop: PopScope only guards the latter, so
    // this leaves without re-asking the question the user just answered.
    Navigator.of(context).pop();
  }

  // ------------------------------------------------------------- plumbing

  Future<bool> _confirm({
    required String title,
    required String body,
    required String confirmLabel,
  }) async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title, style: context.textTheme.titleLarge),
        content: Text(body, style: context.textTheme.bodyMedium),
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
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  /// One snackbar per mutation. [success] may be empty for calls whose only
  /// interesting outcome is a failure.
  void _report(ActionResult result, String success) {
    if (!mounted) return;
    if (result.ok && success.isEmpty) return;
    final message = result.ok
        ? success
        : (result.error ?? "That didn't go through - try again");
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _popGone() {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route == null) return;
    if (route.isCurrent) {
      Navigator.of(context).pop();
    } else {
      // The viewer or the picker is on top. Removing this route in place beats
      // popping, which would close the wrong screen: when the top one closes
      // the user lands on the album list instead of on an album that is gone.
      Navigator.of(context).removeRoute(route);
    }
  }

  static String _plural(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';

  // ----------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final album = ref.watch(albumByFolderProvider(widget.folder));

    if (album == null) {
      // Deleted from this screen's own menu, or by a sync that picked up a
      // deletion made on github.com. Keeping the last known copy on screen
      // would offer a menu of actions that all fail.
      if (!_renaming) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _popGone());
      }
      return const Scaffold(body: SizedBox.shrink());
    }

    final items = album.allInDisplayOrder;
    // Resolved against the live list, so a stale name left behind by a sync
    // can never inflate the count or enable an action.
    final selected = items.where((i) => _selected.contains(i.name)).toList();
    final selectionMode = selected.isNotEmpty;
    final busy = ref.watch(albumActionsProvider) || _savingCaptions;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final unsaved = _pendingCount;
    final captions = ref.read(pendingCaptionsNotifierProvider.notifier);

    return PopScope(
      canPop: !selectionMode && unsaved == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // Back leaves selection before it leaves the album - the same order the
        // user built the state up in.
        if (selectionMode) {
          _clearSelection();
          return;
        }
        _confirmLeave(unsaved);
      },
      child: Scaffold(
        floatingActionButton: IgnorePointer(
          ignoring: selectionMode,
          child: AnimatedScale(
            scale: selectionMode ? 0 : 1,
            duration: context.motion(const Duration(milliseconds: 160)),
            curve: Curves.easeOut,
            child: FloatingActionButton.extended(
              onPressed: () => _addPhotos(album),
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('Add photos'),
            ),
          ),
        ),
        body: Stack(
          children: [
            CustomScrollView(
              controller: _scroll,
              // Bouncing physics is what makes StretchMode.zoomBackground fire
              // on overscroll: one line of config for the whole "pull the cover
              // open" feel.
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              slivers: [
                _header(album),
                _description(album, items),
                if (unsaved > 0)
                  SliverToBoxAdapter(child: _unsavedCaptions(album, unsaved)),
                if (items.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: EmptyState(
                      icon: Icons.add_photo_alternate_outlined,
                      title: 'This album is empty',
                      body: 'Add some photos or videos to fill it up.',
                    ),
                  )
                else
                  SliverPadding(
                    // No horizontal padding, and 2dp gutters: tight spacing
                    // reads as "a lot of photos", wide spacing reads as "a few
                    // cards". Bottom room is for the FAB and the upload tray.
                    padding: EdgeInsets.only(bottom: 120 + bottomInset),
                    sliver: SliverGrid(
                      // Three across on a phone in any orientation, as
                      // always; as many as fit (eight at 1100px) on desktop.
                      gridDelegate: isDesktop
                          ? const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 150,
                              mainAxisSpacing: 2,
                              crossAxisSpacing: 2,
                            )
                          : const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              mainAxisSpacing: 2,
                              crossAxisSpacing: 2,
                            ),
                      delegate: SliverChildBuilderDelegate((context, index) {
                        final item = items[index];
                        return StaggeredFadeIn(
                          key: ValueKey(item.name),
                          index: index,
                          child: MediaTile(
                            album: album,
                            item: item,
                            // The staged edit when there is one: the note
                            // badge and the tile's alt text have to follow a
                            // caption typed in the viewer, not wait for it to
                            // be committed. Safe as a read - the unsaved count
                            // above is watched, so this rebuilds with it.
                            caption: captions.captionFor(album, item.name),
                            isSelected: _selected.contains(item.name),
                            selectionMode: selectionMode,
                            onTap: () {
                              if (selectionMode) {
                                _toggle(item);
                              } else {
                                _openViewer(album, index);
                              }
                            },
                            onLongPress: () {
                              if (selectionMode) {
                                _toggle(item);
                              } else {
                                _beginSelection(item);
                              }
                            },
                          ),
                        );
                      }, childCount: items.length),
                    ),
                  ),
              ],
            ),
            _selectionBar(album, items, selected, busy),
            if (busy)
              Positioned(
                top: MediaQuery.paddingOf(context).top,
                left: 0,
                right: 0,
                // Every mutation here is a git commit over the network. Two
                // pixels of progress is the difference between "it's working"
                // and "nothing happened".
                child: const LinearProgressIndicator(minHeight: 2),
              ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- header

  Widget _header(Album album) {
    final scheme = context.colorScheme;
    final topInset = MediaQuery.paddingOf(context).top;
    final headerItem = album.cover ?? _firstImage(album);
    final webUrl = ref.watch(configNotifierProvider)?.albumWebUrl(album.slug);
    final unsaved = _pendingCount;

    return ValueListenableBuilder<double>(
      valueListenable: _collapse,
      // Only this subtree repaints while the header collapses; the grid below
      // it is not rebuilt.
      builder: (context, t, _) {
        // White over the photograph, ink over the app bar once it has
        // dissolved into the surface. Lerping both ends means neither theme has
        // a window where the title is invisible.
        final foreground = Color.lerp(Colors.white, scheme.onSurface, t)!;
        final shadows = t > 0.98
            ? const <Shadow>[]
            : <Shadow>[
                Shadow(
                  color: Colors.black.withValues(alpha: 0.55 * (1 - t)),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
              ];
        final iconTheme = IconThemeData(color: foreground, shadows: shadows);

        return SliverAppBar(
          expandedHeight: _expandedHeight,
          pinned: true,
          stretch: true,
          backgroundColor: scheme.surface,
          iconTheme: iconTheme,
          actionsIconTheme: iconTheme,
          actions: [
            PopupMenuButton<_AlbumMenu>(
              tooltip: 'Album options',
              onSelected: (value) {
                switch (value) {
                  case _AlbumMenu.description:
                    _editDescription(album);
                  case _AlbumMenu.rename:
                    _rename(album);
                  case _AlbumMenu.web:
                    _openOnWeb(album);
                  case _AlbumMenu.discardCaptions:
                    _discardCaptions(unsaved);
                  case _AlbumMenu.delete:
                    _confirmDeleteAlbum(album);
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: _AlbumMenu.description,
                  child: Text('Edit description'),
                ),
                const PopupMenuItem(
                  value: _AlbumMenu.rename,
                  child: Text('Rename album'),
                ),
                // Hidden rather than disabled when no site URL is configured:
                // there is no address to open, so the entry would be a promise
                // the app cannot keep.
                if (webUrl != null && webUrl.isNotEmpty)
                  const PopupMenuItem(
                    value: _AlbumMenu.web,
                    child: Text('Open on web'),
                  ),
                // Only offered when there is something to discard - an entry
                // that is always there reads as "captions are usually unsaved".
                if (unsaved > 0)
                  const PopupMenuItem(
                    value: _AlbumMenu.discardCaptions,
                    child: Text('Discard unsaved captions'),
                  ),
                PopupMenuItem(
                  value: _AlbumMenu.delete,
                  child: Text(
                    'Delete album',
                    style: TextStyle(color: scheme.error),
                  ),
                ),
              ],
            ),
          ],
          flexibleSpace: FlexibleSpaceBar(
            stretchModes: const [
              StretchMode.zoomBackground,
              StretchMode.fadeTitle,
            ],
            title: Text(
              album.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.mono(
                context,
                size: 18,
                weight: FontWeight.w600,
                color: foreground,
                letterSpacing: -0.4,
              ).copyWith(shadows: shadows),
            ),
            background: Stack(
              fit: StackFit.expand,
              children: [
                if (headerItem != null)
                  Hero(
                    tag: 'album-${album.folder}',
                    child: RemoteMedia(
                      album: album,
                      item: headerItem,
                      decodeWidth: 1080,
                    ),
                  )
                else
                  ColoredBox(
                    color: scheme.surfaceContainer,
                    child: Icon(
                      Icons.photo_library_outlined,
                      size: 44,
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
                    ),
                  ),
                // Two scrims, because the two things laid over the photo sit at
                // opposite ends of it: the back button and menu up top, the
                // title along the bottom.
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: topInset + kToolbarHeight,
                  child: const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.black45, Colors.transparent],
                      ),
                    ),
                  ),
                ),
                DecoratedBox(decoration: AppTheme.photoScrim(stop: 0.45)),
                // The photo dissolves into the app bar colour as it collapses,
                // so the pinned bar is a plain surface with ink on it rather
                // than a 56px crop of somebody's sky.
                if (t > 0.01)
                  IgnorePointer(
                    child: Opacity(
                      opacity: t,
                      child: ColoredBox(color: scheme.surface),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Fallback header image for an album with no `0.*` cover yet.
  MediaItem? _firstImage(Album album) {
    for (final item in album.allInDisplayOrder) {
      if (item.isImage) return item;
    }
    return null;
  }

  // ----------------------------------------------------------- description

  Widget _description(Album album, List<MediaItem> items) {
    final scheme = context.colorScheme;
    final summary = album.summary;
    final note = album.note;

    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Tooltip(
              message:
                  'Edit summary and note. Photos stay in filename order - the same '
                  'order your site uses.',
              child: InkWell(
                onTap: () => _editDescription(album),
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: summary.isNotEmpty || note.isNotEmpty
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          spacing: 8,
                          children: [
                            if (summary.isNotEmpty)
                              Text(summary, style: context.textTheme.bodyLarge),
                            if (note.isNotEmpty)
                              Text(note, style: context.textTheme.bodyMedium),
                          ],
                        )
                      // A ghost row rather than nothing: an album with no
                      // description should still show where one would go.
                      : Row(
                          children: [
                            Icon(
                              Icons.notes_rounded,
                              size: 18,
                              color: scheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Add a description',
                              style: context.textTheme.bodyLarge?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            ),
            if (items.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                _stats(album, items),
                style: AppTheme.mono(context, size: 11, weight: FontWeight.w600),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// The "you have captions waiting" strip, under the description.
  ///
  /// The copy names the consequence rather than nagging: every commit to the
  /// album repo kicks off a site build, so one save at the end is one build
  /// instead of one per caption.
  Widget _unsavedCaptions(Album album, int count) {
    return StatusBanner(
      icon: Icons.edit_note_rounded,
      tint: context.appColors.warning,
      message:
          '${_plural(count, 'caption')} not saved yet - saving rebuilds your '
          "site, so it's worth doing them all in one go.",
      actionLabel: _savingCaptions ? 'Saving...' : 'Save',
      onAction: () => _saveCaptions(album),
    );
  }

  /// "24 photos - 2 videos - 8.4 MB".
  ///
  /// Counted off the DISPLAYED list, not [Album.photoCount], which excludes the
  /// cover the way the website does. The number under a grid has to match the
  /// grid, or the user counts the tiles and finds the app off by one.
  String _stats(Album album, List<MediaItem> items) {
    final photos = items.where((i) => i.isImage).length;
    final videos = items.where((i) => i.isVideo).length;
    return [
      if (photos > 0) _plural(photos, 'photo'),
      if (videos > 0) _plural(videos, 'video'),
      formatBytes(album.totalBytes),
    ].join(' - ');
  }

  // --------------------------------------------------------- selection bar

  Widget _selectionBar(
    Album album,
    List<MediaItem> items,
    List<MediaItem> selected,
    bool busy,
  ) {
    final scheme = context.colorScheme;
    final single = selected.length == 1 ? selected.first : null;

    // Shown DISABLED rather than hidden when the selection is not a single
    // photo: a control that disappears takes its own rule with it, and the user
    // is left guessing why the cover cannot be changed.
    final alreadyCover = single != null && album.isCover(single);
    final canSetCover = single != null && single.isImage && !alreadyCover;
    final coverTooltip = alreadyCover
        ? 'This one is already the cover'
        : (canSetCover
              ? 'Set as cover'
              : 'Pick a single photo to use as the cover');

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: AnimatedSwitcher(
        duration: context.motion(const Duration(milliseconds: 200)),
        child: selected.isEmpty
            ? const SizedBox.shrink(key: ValueKey('no-selection'))
            : Material(
                key: const ValueKey('selection'),
                color: scheme.surface,
                child: SafeArea(
                  bottom: false,
                  child: SizedBox(
                    height: kToolbarHeight,
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.close_rounded),
                          tooltip: 'Leave selection',
                          onPressed: _clearSelection,
                        ),
                        Expanded(
                          child: Text(
                            '${selected.length} selected',
                            style: AppTheme.mono(
                              context,
                              size: 16,
                              weight: FontWeight.w600,
                              color: scheme.onSurface,
                            ),
                          ),
                        ),
                        Tooltip(
                          message: coverTooltip,
                          child: IconButton(
                            icon: const Icon(Icons.wallpaper_rounded),
                            onPressed: canSetCover && !busy
                                ? () => _setCover(album, single)
                                : null,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline_rounded),
                          tooltip: 'Delete',
                          onPressed: busy
                              ? null
                              : () => _confirmDeleteItems(album, selected),
                        ),
                        PopupMenuButton<_SelectionMenu>(
                          tooltip: 'More',
                          onSelected: (value) {
                            switch (value) {
                              case _SelectionMenu.selectAll:
                                setState(() {
                                  _selected
                                    ..clear()
                                    ..addAll(items.map((i) => i.name));
                                });
                              case _SelectionMenu.clear:
                                _clearSelection();
                            }
                          },
                          itemBuilder: (context) => const [
                            PopupMenuItem(
                              value: _SelectionMenu.selectAll,
                              child: Text('Select all'),
                            ),
                            PopupMenuItem(
                              value: _SelectionMenu.clear,
                              child: Text('Clear selection'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

/// Renamer, with the derived folder and the resulting web address shown live.
///
/// Both previews are the point: the folder is not what the user typed, and the
/// address is what their existing links stop matching.
class _RenameDialog extends StatefulWidget {
  final String initialTitle;
  final String albumsPath;

  const _RenameDialog({required this.initialTitle, required this.albumsPath});

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialTitle,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final folder = folderNameFor(_controller.text);
    final valid = folder.isNotEmpty;

    return AlertDialog(
      title: Text('Rename album', style: context.textTheme.titleLarge),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Album name'),
            onChanged: (_) => setState(() {}),
            onSubmitted: (value) {
              if (folderNameFor(value).isNotEmpty) {
                Navigator.of(context).pop(value);
              }
            },
          ),
          const SizedBox(height: 14),
          Text(
            valid
                ? 'Folder: $folder\n/${widget.albumsPath}/${jekyllSlugify(folder)}/'
                : 'Album names can use letters, numbers, spaces, - and _',
            style: AppTheme.mono(
              context,
              size: 12,
              color: valid
                  ? context.colorScheme.onSurfaceVariant
                  : context.colorScheme.error,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'No photos move - only the folder name changes. Links to the old '
            'address stop working.',
            style: context.textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: valid
              ? () => Navigator.of(context).pop(_controller.text)
              : null,
          child: const Text('Rename'),
        ),
      ],
    );
  }
}
