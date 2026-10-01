import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/album.dart';
import '../../../core/models/app_config.dart';
import '../../../core/providers/album_actions_provider.dart';
import '../../../core/providers/albums_provider.dart';
import '../../../core/providers/auth_provider.dart';
import '../../../core/providers/config_provider.dart';
import '../../../core/services/media_pipeline_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/album_conventions.dart';
import '../../../core/utils/external_url.dart';
import '../../../core/utils/relative_time.dart';
import '../../../core/widgets/empty_state.dart';
import '../../../core/widgets/glickr_shimmer.dart';
import '../../../core/widgets/remote_media.dart' show StaggeredFadeIn;
import '../../config/presentation/repo_setup_screen.dart';
import '../../picker/presentation/media_picker_screen.dart';
import '../../settings/presentation/about_screen.dart';
import '../../settings/presentation/settings_screen.dart';
import '../widgets/album_card.dart';
import '../widgets/description_dialog.dart';
import 'album_detail_screen.dart';

enum _MenuAction { sort, openSite, changeRepo, about }

enum _AlbumAction { openWeb, rename, describe, delete }

/// Home: every album folder in the configured repo.
class AlbumsScreen extends ConsumerStatefulWidget {
  const AlbumsScreen({super.key});

  @override
  ConsumerState<AlbumsScreen> createState() => _AlbumsScreenState();
}

class _AlbumsScreenState extends ConsumerState<AlbumsScreen> {
  final TextEditingController _searchController = TextEditingController();
  bool _searching = false;
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final state = ref.watch(albumsNotifierProvider);
    // Sorting and filtering live in the provider, not here, so the grid and
    // anything else that needs "the albums as shown" cannot disagree.
    final albums = ref.watch(visibleAlbumsProvider(_query));
    final loaded = state is AlbumsLoaded ? state : null;
    final blocked = loaded?.isOverRepoLimit ?? false;

    final status = _statusArea(loaded);

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _refresh,
        color: scheme.primary,
        backgroundColor: scheme.surfaceContainerHigh,
        child: CustomScrollView(
          // AlwaysScrollable under the bouncing physics so pull-to-refresh
          // still works on the empty and error states, where the content does
          // not fill the viewport and a plain scroll view would refuse the
          // drag outright.
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          slivers: [
            _appBar(),
            if (status != null) SliverToBoxAdapter(child: status),
            _content(state, albums),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        // Straight into the picker rather than a "new album" dialog: an empty
        // album is a dead end, because the website skips folders with no
        // media. Naming happens inside the upload flow instead.
        onPressed: blocked ? null : _openPicker,
        backgroundColor: blocked ? scheme.surfaceContainerHighest : null,
        foregroundColor: blocked ? scheme.onSurfaceVariant : null,
        tooltip: blocked
            ? 'Uploads are paused - your repo is over '
                  '${formatBytes(MediaPipelineService.repoBlockBytes, decimals: 0)}. '
                  'Free some space, or move to a host without a size limit.'
            : 'Add photos',
        icon: const Icon(Icons.add_photo_alternate_rounded),
        label: const Text('Add photos'),
      ),
    );
  }

  Future<void> _refresh() async {
    HapticFeedback.mediumImpact();
    await ref.read(albumsNotifierProvider.notifier).refresh(force: true);
  }

  // ----------------------------------------------------------------- app bar

  Widget _appBar() {
    final scheme = context.colorScheme;
    final config = ref.watch(configNotifierProvider);
    final auth = ref.watch(authNotifierProvider);
    final user = auth is AuthAuthenticated ? auth.user : null;
    final hasSite = config != null && config.siteUrl.isNotEmpty;

    return SliverAppBar(
      pinned: true,
      floating: true,
      // Taller than the 56 default because the title is two lines: the repo
      // name, and under it the owner/repo it actually resolves to.
      toolbarHeight: 64,
      backgroundColor: scheme.surface,
      leading: IconButton(
        tooltip: 'Settings',
        onPressed: _openSettings,
        icon: CircleAvatar(
          radius: 15,
          backgroundColor: scheme.surfaceContainerHigh,
          // foregroundImage rather than backgroundImage so the fallback icon
          // shows through when the avatar cannot be fetched - an offline
          // launch is a normal state here, not an error.
          foregroundImage: user == null ? null : NetworkImage(user.avatarUrl),
          onForegroundImageError: user == null ? null : (_, _) {},
          child: Icon(
            Icons.person_outline_rounded,
            size: 17,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
      title: _searching ? _searchField() : _repoTitle(config),
      actions: [
        IconButton(
          tooltip: _searching ? 'Close search' : 'Search albums',
          icon: Icon(_searching ? Icons.close_rounded : Icons.search_rounded),
          onPressed: _toggleSearch,
        ),
        if (!_searching)
          PopupMenuButton<_MenuAction>(
            tooltip: 'More',
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: _onMenuAction,
            itemBuilder: (context) => <PopupMenuEntry<_MenuAction>>[
              _menuItem(_MenuAction.sort, Icons.sort_rounded, 'Sort'),
              // Hidden rather than shown-and-broken when no site URL is set:
              // the link would 404 on a repo with no published site.
              if (hasSite)
                _menuItem(
                  _MenuAction.openSite,
                  Icons.language_rounded,
                  'Open site',
                ),
              _menuItem(
                _MenuAction.changeRepo,
                Icons.swap_horiz_rounded,
                'Change repository',
              ),
              _menuItem(_MenuAction.about, Icons.info_outline_rounded, 'About'),
            ],
          ),
      ],
    );
  }

  PopupMenuItem<_MenuAction> _menuItem(
    _MenuAction value,
    IconData icon,
    String label,
  ) {
    return PopupMenuItem<_MenuAction>(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 18, color: context.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Text(label),
        ],
      ),
    );
  }

  Widget _repoTitle(AppConfig? config) {
    if (config == null) return const Text('glickr');
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          // The same folder-to-title transform the site applies to album
          // folders, so `photo-albums` reads as "Photo Albums" here too.
          albumTitle(config.repoName),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          config.repoSlug,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTheme.mono(context, size: 11),
        ),
      ],
    );
  }

  Widget _searchField() {
    return TextField(
      controller: _searchController,
      autofocus: true,
      textInputAction: TextInputAction.search,
      style: context.textTheme.titleMedium,
      cursorColor: context.colorScheme.primary,
      onChanged: (value) => setState(() => _query = value),
      // The app-wide input decoration is a filled, bordered box, which inside
      // an app bar reads as a second toolbar. Stripped back to a bare line.
      decoration: InputDecoration(
        isDense: true,
        filled: false,
        contentPadding: EdgeInsets.zero,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        hintText: 'Search albums',
        suffixIconConstraints: const BoxConstraints(
          minWidth: 36,
          minHeight: 36,
        ),
        suffixIcon: _query.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.cancel_rounded, size: 18),
                onPressed: () => setState(() {
                  _searchController.clear();
                  _query = '';
                }),
              ),
      ),
    );
  }

  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      if (!_searching) {
        _searchController.clear();
        _query = '';
      }
    });
  }

  // ------------------------------------------------------------------ status

  /// The one status line that matters most right now, or null when there is
  /// nothing worth saying. Only ever one - stacking a sync failure on top of a
  /// size warning buries the grid the user came here for.
  Widget? _statusArea(AlbumsLoaded? loaded) {
    if (loaded == null) return null;

    final scheme = context.colorScheme;
    final warning = context.appColors.warning;
    final ceiling = formatBytes(
      MediaPipelineService.repoCeilingBytes,
      decimals: 0,
    );

    if (loaded.syncError != null && loaded.albums.isNotEmpty) {
      return StatusBanner(
        icon: Icons.sync_problem_rounded,
        message: 'Sync failed - showing cached data',
        tint: scheme.error,
        actionLabel: 'Retry',
        onAction: () =>
            ref.read(albumsNotifierProvider.notifier).refresh(force: true),
      );
    }

    if (loaded.truncated) {
      return StatusBanner(
        icon: Icons.warning_amber_rounded,
        message: 'This repo is very large - some items may be missing',
        tint: warning,
      );
    }

    if (loaded.isOverRepoLimit) {
      return StatusBanner(
        icon: Icons.storage_rounded,
        message:
            'Your repo is ${formatBytes(loaded.repoBytes)} of $ceiling. '
            'New uploads are paused until you free some space.',
        tint: scheme.error,
      );
    }

    if (loaded.isNearRepoLimit) {
      return StatusBanner(
        icon: Icons.storage_rounded,
        message:
            'Your repo is ${formatBytes(loaded.repoBytes)} of $ceiling. '
            "Past $ceiling your site's CDN stops serving photos.",
        tint: warning,
      );
    }

    final parts = <String>[
      if (loaded.lastSynced != null)
        'Last synced ${relativeTime(loaded.lastSynced)}',
      if (loaded.syncTotal != null)
        'Syncing ${loaded.syncDone ?? 0} of ${loaded.syncTotal}',
    ];
    if (parts.isEmpty) return null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Text(
        parts.join('  -  '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTheme.mono(context, size: 11),
      ),
    );
  }

  // ----------------------------------------------------------------- content

  static const SliverGridDelegate _gridDelegate =
      SliverGridDelegateWithMaxCrossAxisExtent(
        // Max extent rather than a fixed column count: 2 up on a phone, 3 in
        // landscape, 4 on a tablet, with no per-form-factor branching.
        maxCrossAxisExtent: 220,
        childAspectRatio: 0.78,
        mainAxisSpacing: 14,
        crossAxisSpacing: 14,
      );

  // The bottom inset clears both the FAB and the upload tray, which is mounted
  // above the Navigator and therefore floats over the last row of this grid.
  static const EdgeInsets _gridPadding = EdgeInsets.fromLTRB(16, 4, 16, 120);

  Widget _content(AlbumsState state, List<Album> albums) {
    // AlbumsNotifier moves to AlbumsLoaded(albums: [], isRefreshing: true) the
    // moment a refresh starts, so "loaded but empty" is also the cold-start
    // shape - checking isRefreshing keeps that from flashing "No albums yet"
    // at someone who has thirty.
    final refreshing = state is AlbumsLoaded && state.isRefreshing;
    if (state.albums.isEmpty && (state is AlbumsInitial || refreshing)) {
      return SliverPadding(
        padding: _gridPadding,
        sliver: SliverGrid(
          gridDelegate: _gridDelegate,
          delegate: SliverChildBuilderDelegate(
            (_, _) => const AlbumCardSkeleton(),
            childCount: 6,
          ),
        ),
      );
    }

    if (state is AlbumsError && state.albums.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: EmptyState(
          icon: Icons.cloud_off_rounded,
          title: "Couldn't load your albums",
          body: state.message,
          action: ElevatedButton(
            onPressed: _refresh,
            child: const Text('Retry'),
          ),
        ),
      );
    }

    if (albums.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: _query.trim().isEmpty
            ? const EmptyState(
                icon: Icons.photo_library_outlined,
                title: 'No albums yet',
                body:
                    'Albums you make will show up here.\n'
                    'Tap the button below to start your first one.',
                hint:
                    'Pick some photos and give them a name - glickr does the '
                    'rest.',
              )
            : const EmptyState(
                icon: Icons.search_off_rounded,
                title: 'No albums match',
                body: 'Try a different search',
              ),
      );
    }

    return SliverPadding(
      padding: _gridPadding,
      sliver: SliverGrid(
        gridDelegate: _gridDelegate,
        delegate: SliverChildBuilderDelegate((context, index) {
          final album = albums[index];
          return StaggeredFadeIn(
            index: index,
            child: AlbumCard(
              album: album,
              onTap: () => _openAlbum(album),
              onLongPress: () => _showAlbumActions(album),
            ),
          );
        }, childCount: albums.length),
      ),
    );
  }

  // -------------------------------------------------------------- navigation

  void _openSettings() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
  }

  void _openPicker() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => const MediaPickerScreen(targetAlbum: null),
      ),
    );
  }

  void _openAlbum(Album album) {
    final duration = context.motion(const Duration(milliseconds: 300));
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: duration,
        reverseTransitionDuration: duration,
        pageBuilder: (_, _, _) => AlbumDetailScreen(folder: album.folder),
        transitionsBuilder: (context, animation, secondary, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          );
          // A short rise plus a fade, not a full-height slide: the cover photo
          // is flying via Hero at the same time, and a large translation
          // underneath it makes the two read as separate, competing motions.
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.05),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
  }

  // ------------------------------------------------------------------- menus

  Future<void> _onMenuAction(_MenuAction action) async {
    switch (action) {
      case _MenuAction.sort:
        _showSortSheet();
      case _MenuAction.openSite:
        final config = ref.read(configNotifierProvider);
        if (config == null || config.siteUrl.isEmpty) return;
        await openExternalUrl(context, config.siteUrl);
      case _MenuAction.changeRepo:
        // Not onboarding: the user already has a repo, so the setup screen
        // shows its switcher rather than its first-run copy.
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const RepoSetupScreen()),
        );
      case _MenuAction.about:
        // The real About screen, shared with Settings. It describes glickr
        // itself - never the album repo that happens to be selected.
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const AboutScreen()),
        );
    }
  }

  void _showSortSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Consumer(
          builder: (context, ref, _) {
            final current = ref.watch(albumSortNotifierProvider);
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
                  child: Text(
                    'Sort albums',
                    style: context.textTheme.titleMedium,
                  ),
                ),
                for (final sort in AlbumSort.values)
                  RadioListTile<AlbumSort>(
                    value: sort,
                    groupValue: current,
                    title: Text(sort.label),
                    onChanged: (value) {
                      if (value == null) return;
                      ref
                          .read(albumSortNotifierProvider.notifier)
                          .setSort(value);
                      Navigator.of(sheetContext).pop();
                    },
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 6, 20, 20),
                  child: Text(
                    "Name A-Z is the default because it's the order your "
                    'website shows albums in.',
                    style: context.textTheme.bodySmall,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  // -------------------------------------------------------- album long-press

  Future<void> _showAlbumActions(Album album) async {
    final config = ref.read(configNotifierProvider);
    final webUrl = config == null ? '' : config.albumWebUrl(album.slug);
    final scheme = context.colorScheme;

    // The sheet returns a choice and closes; the dialogs open afterwards from
    // the screen's context. Opening a dialog from a route that is already
    // animating out is how a confirm gets dismissed along with its sheet.
    final action = await showModalBottomSheet<_AlbumAction>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(album.title, style: context.textTheme.titleMedium),
              subtitle: Text(
                album.folder,
                style: AppTheme.mono(context, size: 11),
              ),
            ),
            const Divider(height: 1),
            if (webUrl.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.open_in_new_rounded),
                title: const Text('Open on web'),
                onTap: () =>
                    Navigator.of(sheetContext).pop(_AlbumAction.openWeb),
              ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline_rounded),
              title: const Text('Rename album'),
              onTap: () => Navigator.of(sheetContext).pop(_AlbumAction.rename),
            ),
            ListTile(
              leading: const Icon(Icons.notes_rounded),
              title: const Text('Edit description'),
              onTap: () =>
                  Navigator.of(sheetContext).pop(_AlbumAction.describe),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline_rounded, color: scheme.error),
              title: Text(
                'Delete album',
                style: TextStyle(color: scheme.error),
              ),
              onTap: () => Navigator.of(sheetContext).pop(_AlbumAction.delete),
            ),
          ],
        ),
      ),
    );

    if (action == null || !mounted) return;
    switch (action) {
      case _AlbumAction.openWeb:
        await openExternalUrl(context, webUrl);
      case _AlbumAction.rename:
        await _renameAlbum(album);
      case _AlbumAction.describe:
        await _editDescription(album);
      case _AlbumAction.delete:
        await _deleteAlbum(album);
    }
  }

  Future<void> _deleteAlbum(Album album) async {
    // Counts every file in the folder, cover included - unlike the card's
    // caption, which counts what the website renders. Delete really does take
    // the cover with it, so understating the number here would be a lie.
    final count = album.items.length;
    final confirmed = await _confirm(
      title: 'Delete ${album.title}?',
      body:
          'This deletes the folder and all $count '
          '${count == 1 ? 'item' : 'items'} from GitHub. '
          'This cannot be undone from the app.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    HapticFeedback.heavyImpact();
    final result = await ref
        .read(albumActionsProvider.notifier)
        .deleteAlbum(album);
    _snack(
      result.ok
          ? 'Deleted ${album.title}'
          : result.error ?? "Couldn't delete this album",
    );
  }

  Future<void> _renameAlbum(Album album) async {
    final controller = TextEditingController(text: album.title);
    String? typed;
    try {
      typed = await showDialog<String>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) {
            final folder = folderNameFor(controller.text);
            return AlertDialog(
              title: const Text('Rename album'),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: controller,
                      autofocus: true,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Album name',
                      ),
                      onChanged: (_) => setDialogState(() {}),
                    ),
                    const SizedBox(height: 12),
                    // The folder is derived, never typed, and it is what every
                    // URL is built from - so it is shown live rather than
                    // discovered after the fact.
                    Text(
                      folder.isEmpty
                          ? 'Album names can use letters, numbers, spaces, '
                                '- and _'
                          : 'Folder: $folder',
                      style: AppTheme.mono(context, size: 11),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: folder.isEmpty
                      ? null
                      : () => Navigator.of(dialogContext).pop(controller.text),
                  child: const Text('Next'),
                ),
              ],
            );
          },
        ),
      );
    } finally {
      controller.dispose();
    }

    if (typed == null || !mounted) return;

    final newFolder = folderNameFor(typed);
    // The same folder means the same URLs and the same bytes: nothing to
    // confirm and nothing to commit.
    if (newFolder == album.folder) return;

    final config = ref.read(configNotifierProvider);
    // The configured albums path, not a hardcoded /albums/ - a fork can
    // publish its album pages anywhere, and a wrong URL in a warning about
    // URLs is worse than no warning.
    final albumsPath = config?.albumsPath ?? 'albums';
    final confirmed = await _confirm(
      title: 'Rename album?',
      body:
          'The web address changes from /$albumsPath/${album.slug} to '
          '/$albumsPath/${jekyllSlugify(newFolder)}. '
          'Links to the old address will stop working.',
      confirmLabel: 'Rename',
    );
    if (!confirmed || !mounted) return;

    final result = await ref
        .read(albumActionsProvider.notifier)
        .renameAlbum(album, typed);
    _snack(
      result.ok
          ? 'Renamed to ${albumTitle(newFolder)}'
          : result.error ?? "Couldn't rename this album",
    );
  }

  Future<void> _editDescription(Album album) async {
    final edit = await showDescriptionDialog(context, album);
    if (edit == null || !mounted) return;

    final result = await ref
        .read(albumActionsProvider.notifier)
        .setDescription(album, summary: edit.summary, note: edit.note);
    _snack(
      result.ok
          ? 'Description saved'
          : result.error ?? "Couldn't save the description",
    );
  }

  // ------------------------------------------------------------------ shared

  Future<bool> _confirm({
    required String title,
    required String body,
    required String confirmLabel,
    bool destructive = false,
  }) async {
    final scheme = context.colorScheme;
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: destructive
                ? TextButton.styleFrom(foregroundColor: scheme.error)
                : null,
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}
