import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/app_config.dart';
import '../../../core/models/github_repo.dart';
import '../../../core/providers/albums_provider.dart';
import '../../../core/providers/auth_provider.dart';
import '../../../core/providers/config_provider.dart';
import '../../../core/providers/pending_captions_provider.dart';
import '../../../core/providers/services_provider.dart';
import '../../../core/providers/upload_provider.dart';
import '../../../core/services/dio_client.dart';
import '../../../core/services/media_pipeline_service.dart'
    show MediaPipelineService, formatBytes;
import '../../../core/services/repo_repository.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/relative_time.dart';
import '../../../core/widgets/empty_state.dart';
import '../../../core/widgets/glickr_shimmer.dart';
import '../../../core/widgets/remote_media.dart' show StaggeredFadeIn;
import 'folder_browser_screen.dart';

/// GitHub Pages' published-site limit, and the point at which it is worth
/// mentioning. Surfaced only once a repo is close, because "you have 900 MB of
/// headroom" is noise and "you have 40 MB" is the difference between the site
/// working and not.

/// One question: which repo holds the albums?
///
/// Everything else on this screen exists to answer it - the picker, the
/// verification chip, the create-repo escape hatch. Branch, site URL and
/// albums path are real settings but nobody arrives here to change them, so
/// they live behind a collapsed disclosure rather than turning the screen into
/// a form.
class RepoSetupScreen extends ConsumerStatefulWidget {
  /// True on first run, when this screen IS the app. The AuthWrapper watches
  /// the config and re-routes once it is saved, so onboarding never pops.
  final bool isOnboarding;

  const RepoSetupScreen({super.key, this.isOnboarding = false});

  @override
  ConsumerState<RepoSetupScreen> createState() => _RepoSetupScreenState();
}

class _RepoSetupScreenState extends ConsumerState<RepoSetupScreen>
    with WidgetsBindingObserver {
  final _search = TextEditingController();
  final _branch = TextEditingController();
  final _siteUrl = TextEditingController();
  final _albumsPath = TextEditingController();
  final _manual = TextEditingController();

  /// Every field on this screen that can end up under the keyboard. They are
  /// tracked as a group because the screen has to scroll whichever one has
  /// focus back into view; see [_revealField].
  final _branchFocus = FocusNode(debugLabel: 'branch');
  final _siteUrlFocus = FocusNode(debugLabel: 'siteUrl');
  final _albumsPathFocus = FocusNode(debugLabel: 'albumsPath');
  final _manualFocus = FocusNode(debugLabel: 'manual');

  /// Anchors the selection panel, which sits below the whole picker, so a tap
  /// on a repo can bring the verdict about it into view.
  final _panelKey = GlobalKey();

  /// Null until the first load resolves - distinct from an empty list, which
  /// is a real answer with its own (quite different) empty state.
  List<GitHubRepo>? _repos;
  String? _listError;
  bool _loadingList = true;

  GitHubRepo? _selected;
  RepoCheckResult? _check;
  bool _checking = false;

  /// Repo directory albums live in; '' is the repo root. Not a controller
  /// because it is never typed - the folder browser is the only way to set it,
  /// so a half-typed path can never be saved.
  String _albumRoot = '';

  /// Bumped on every verification. A slow `inspect()` for a repo the user has
  /// already moved off would otherwise land last and describe the wrong repo -
  /// and this screen's whole job is telling the truth about a repo.
  int _checkToken = 0;

  bool _saving = false;
  bool _lookingUp = false;

  @override
  void initState() {
    super.initState();
    final config = ref.read(configNotifierProvider);
    if (config != null) {
      _branch.text = config.branch;
      _siteUrl.text = config.siteUrl;
      _albumsPath.text = config.albumsPath;
      _albumRoot = config.albumRoot;
    } else {
      _albumsPath.text = 'albums';
    }
    _search.addListener(() => setState(() {}));
    for (final node in _typedFields) {
      node.addListener(() => _revealField(node));
    }
    WidgetsBinding.instance.addObserver(this);
    _loadRepos();
  }

  List<FocusNode> get _typedFields => [
    _branchFocus,
    _siteUrlFocus,
    _albumsPathFocus,
    _manualFocus,
  ];

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _search.dispose();
    _branch.dispose();
    _siteUrl.dispose();
    _albumsPath.dispose();
    _manual.dispose();
    _branchFocus.dispose();
    _siteUrlFocus.dispose();
    _albumsPathFocus.dispose();
    _manualFocus.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- keyboard

  /// The keyboard sliding in is a metrics change, and it lands one or more
  /// frames after the tap that summoned it.
  ///
  /// Focus alone is not enough to go on: at the moment a field is tapped the
  /// viewport is still full height, so scrolling then decides the field is
  /// already visible - and it is, right up until the keyboard covers it.
  @override
  void didChangeMetrics() {
    for (final node in _typedFields) {
      if (node.hasFocus) {
        _revealField(node);
        return;
      }
    }
  }

  /// Scroll a focused field into the viewport.
  ///
  /// `adjustResize` plus the Scaffold means the viewport itself shrinks by
  /// `MediaQuery.viewInsetsOf(context).bottom`, so "inside the viewport" and
  /// "clear of the keyboard" are the same thing, and one scrollable spanning
  /// the screen is all it takes to get there.
  void _revealField(FocusNode node) {
    if (!node.hasFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !node.hasFocus) return;
      final target = node.context;
      if (target == null) return;
      Scrollable.ensureVisible(
        target,
        // Halfway up the remaining space, so the helper text under the field
        // is readable too - these fields are mostly explained by it.
        alignment: 0.5,
        duration: context.motion(const Duration(milliseconds: 220)),
        curve: Curves.easeOutCubic,
      );
    });
  }

  // ------------------------------------------------------------------ data

  Future<void> _loadRepos() async {
    setState(() {
      _loadingList = true;
      _listError = null;
    });

    try {
      final repos = await ref.read(repoRepositoryProvider).listWritableRepos();
      if (!mounted) return;
      setState(() {
        _repos = repos;
        _loadingList = false;
      });
      _autoSelect(repos);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingList = false;
        _listError = _friendly(e);
      });
    }
  }

  /// Pre-answer the question when the answer is obvious, so the common case is
  /// open screen, see the repo already checked, tap the button.
  ///
  /// The saved repo wins over an album-shaped name: someone who reopens this
  /// screen is auditing their current choice, and silently pointing the
  /// verification at a different repo would be answering a question they did
  /// not ask.
  void _autoSelect(List<GitHubRepo> repos) {
    if (_selected != null || repos.isEmpty) return;

    final saved = ref.read(configNotifierProvider);
    GitHubRepo? match;
    if (saved != null) {
      for (final repo in repos) {
        if (repo.ownerLogin == saved.repoOwner && repo.name == saved.repoName) {
          match = repo;
          break;
        }
      }
    }
    // listWritableRepos sorts album-shaped names first, so the head of the
    // list is the only candidate worth testing.
    match ??= repos.first.looksLikeAlbumRepo ? repos.first : null;
    if (match != null) _select(match);
  }

  /// Tapping a tile in the picker, as opposed to restoring a saved choice.
  ///
  /// The panel that reports what is inside the repo now lives below the whole
  /// list, so a tap on a repo near the top would otherwise leave the verdict
  /// off screen. Only user taps scroll: auto-selecting on open should not yank
  /// the list out from under someone who came here to browse it.
  void _selectFromPicker(GitHubRepo repo) {
    _select(repo);
    // Post-frame because the panel does not exist until this selection builds.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _panelKey.currentContext;
      if (!mounted || target == null) return;
      Scrollable.ensureVisible(
        target,
        duration: context.motion(const Duration(milliseconds: 260)),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Future<void> _select(GitHubRepo repo) async {
    final saved = ref.read(configNotifierProvider);
    final isSaved =
        saved != null &&
        saved.repoOwner == repo.ownerLogin &&
        saved.repoName == repo.name;

    // A branch the user typed for repo A means nothing on repo B, so it resets
    // per selection - except back onto the configured repo, where their own
    // stored branch is the right answer. The album folder resets for the same
    // reason, and harder: `assets/albums` on a site repo is a path that almost
    // certainly does not exist in the next repo along.
    final branch = isSaved ? saved.branch : repo.defaultBranch;
    final albumRoot = isSaved ? saved.albumRoot : '';
    setState(() {
      _selected = repo;
      _branch.text = branch;
      _albumRoot = albumRoot;
    });
    await _verify(repo, branch, albumRoot);
  }

  Future<void> _verify(GitHubRepo repo, String branch, String albumRoot) async {
    final token = ++_checkToken;
    setState(() {
      _check = null;
      _checking = true;
    });

    // inspect() converts its own failures into RepoCheckStatus.unknown, so
    // there is nothing here to catch.
    final result = await ref
        .read(repoRepositoryProvider)
        .inspect(
          owner: repo.ownerLogin,
          name: repo.name,
          branch: branch,
          albumRoot: albumRoot,
        );
    if (!mounted || token != _checkToken) return;
    setState(() {
      _check = result;
      _checking = false;
    });
  }

  void _reverify() {
    final repo = _selected;
    if (repo == null) return;
    _verify(repo, _effectiveBranch(repo), _albumRoot);
  }

  /// Browse the repo for the folder albums live in.
  ///
  /// The chip above describes whatever folder is chosen, so a new folder means
  /// a fresh count - otherwise "Found 3 albums" would keep describing a
  /// directory the user just navigated away from.
  Future<void> _pickAlbumRoot() async {
    final repo = _selected;
    if (repo == null) return;
    final branch = _effectiveBranch(repo);

    final picked = await showFolderBrowser(
      context,
      owner: repo.ownerLogin,
      repo: repo.name,
      branch: branch,
      initialPath: _albumRoot,
    );
    if (picked == null || !mounted || picked == _albumRoot) return;

    setState(() => _albumRoot = picked);
    await _verify(repo, branch, picked);
  }

  String _effectiveBranch(GitHubRepo repo) {
    final typed = _branch.text.trim();
    return typed.isEmpty ? repo.defaultBranch : typed;
  }

  List<GitHubRepo> get _filtered {
    final all = _repos ?? const <GitHubRepo>[];
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return all;
    return all
        .where(
          (r) =>
              r.name.toLowerCase().contains(query) ||
              r.fullName.toLowerCase().contains(query),
        )
        .toList();
  }

  String _friendly(Object e) =>
      e is DioException ? ApiClient.friendlyError(e) : e.toString();

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  // ----------------------------------------------------------------- write

  Future<void> _useThisRepo() async {
    final repo = _selected;
    if (repo == null || _saving) return;

    final existing = ref.read(configNotifierProvider);
    final repoChanged =
        existing != null &&
        (existing.repoOwner != repo.ownerLogin ||
            existing.repoName != repo.name);
    // A folder change is every bit as destructive to the caches as a repo
    // change - albums under `assets/albums` are simply not the albums under
    // the root - so it takes the same path, with its own wording.
    final rootChanged = existing != null && existing.albumRoot != _albumRoot;

    if (repoChanged || rootChanged) {
      final confirmed = await _confirmChange(repoChanged: repoChanged);
      if (!confirmed || !mounted) return;
      // Both caches are keyed to the old repo and folder, and neither survives
      // the switch: cached albums would show folders that do not exist here,
      // and a queued batch would flush its bytes into whatever is configured
      // now.
      await ref.read(albumsNotifierProvider.notifier).clearCache();
      await ref.read(uploadQueueNotifierProvider.notifier).clear();
      // Staged captions are keyed by album FOLDER, and glickr names files by
      // the same 0001.jpg convention in every repo - so left behind they would
      // not just linger, they would collide: one repo's unsaved caption shown
      // over another repo's photo, and committed into its album.json on Save.
      await ref.read(pendingCaptionsNotifierProvider.notifier).clear();
      if (!mounted) return;
    }

    setState(() => _saving = true);

    final siteUrl = _siteUrl.text.trim();
    final albumsPath = _albumsPath.text.trim();
    final config =
        existing?.copyWith(
          repoOwner: repo.ownerLogin,
          repoName: repo.name,
          branch: _effectiveBranch(repo),
          siteUrl: siteUrl,
          albumsPath: albumsPath,
          albumRoot: _albumRoot,
        ) ??
        AppConfig(
          repoOwner: repo.ownerLogin,
          repoName: repo.name,
          branch: _effectiveBranch(repo),
          siteUrl: siteUrl,
          albumsPath: albumsPath,
          albumRoot: _albumRoot,
        );

    try {
      await ref.read(configNotifierProvider.notifier).save(config);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _say('Could not save that - ${_friendly(e)}');
      return;
    }

    if (!mounted) return;
    setState(() => _saving = false);
    // During onboarding the AuthWrapper is watching the config and swaps the
    // whole route out; popping here would tear down a screen that is already
    // being replaced.
    if (!widget.isOnboarding) Navigator.of(context).pop();
  }

  Future<bool> _confirmChange({required bool repoChanged}) async {
    // Captions typed but never saved are about to go with everything else, so
    // they get named here rather than discovered missing later.
    final unsaved = ref
        .read(pendingCaptionsNotifierProvider)
        .values
        .fold<int>(0, (total, album) => total + album.length);
    final captionsNote = switch (unsaved) {
      0 => '',
      1 => " One caption you haven't saved yet goes with them.",
      _ => " $unsaved captions you haven't saved yet go with them.",
    };

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          repoChanged ? 'Change repository?' : 'Change albums folder?',
        ),
        content: Text(
          (repoChanged
                  ? 'Cached albums and any uploads still waiting are specific '
                        'to this repository, and will be removed. This cannot '
                        'be undone.'
                  : 'glickr will look for albums in the new folder. Cached '
                        'albums and any uploads still waiting are cleared.') +
              captionsNote,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Change'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _createRepo(String? login) async {
    final nameController = TextEditingController(text: 'album');
    try {
      final created = await showDialog<GitHubRepo>(
        context: context,
        builder: (dialogContext) =>
            _CreateRepoDialog(controller: nameController, login: login),
      );
      if (created == null || !mounted) return;

      setState(() {
        _repos = [created, ...?_repos];
        _search.clear();
      });
      await _select(created);
      if (!mounted) return;
      // A repo that did not exist a second ago needs no deliberation, so the
      // create flow finishes the job. _useThisRepo still asks before dropping
      // caches if this is a switch rather than first-time setup.
      await _useThisRepo();
    } finally {
      nameController.dispose();
    }
  }

  Future<void> _lookupManual() async {
    final raw = _manual.text.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    final parts = raw.split('/');
    if (parts.length != 2 || parts.any((p) => p.trim().isEmpty)) {
      _say('Type it as owner/name - for example octocat/album.');
      return;
    }

    setState(() => _lookingUp = true);
    try {
      final repo = await ref
          .read(repoRepositoryProvider)
          .findRepo(parts[0].trim(), parts[1].trim());
      if (!mounted) return;
      if (repo == null) {
        _say("Couldn't find $raw. Check the spelling, and that your sign-in "
            'can see it.');
        return;
      }
      setState(() => _repos = [repo, ...?_repos]);
      await _select(repo);
    } catch (e) {
      if (mounted) _say(_friendly(e));
    } finally {
      if (mounted) setState(() => _lookingUp = false);
    }
  }

  // ------------------------------------------------------------------- ui

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authNotifierProvider);
    final login = switch (auth) {
      AuthAuthenticated(user: final user) => user.login,
      _ => null,
    };
    final repos = _repos;
    final hasRepos = repos != null && repos.isNotEmpty;
    // Not padding for the keyboard - the Scaffold has already taken this much
    // height off the body. It is slack under the last field, so that a field
    // near the end of the content can still be scrolled up into a viewport the
    // keyboard has cut down to a couple of hundred pixels.
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.isOnboarding,
        title: Text(widget.isOnboarding ? 'setup' : 'repository'),
        actions: [
          IconButton(
            tooltip: 'Reload the list',
            onPressed: _loadingList ? null : _loadRepos,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: DecoratedBox(
        decoration: AppTheme.backgroundGradient(context),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              // Everything except the button scrolls together. Two scroll
              // regions - a picker that could move and a panel that could not
              // - are what left the Advanced fields with nowhere to go once
              // the keyboard covered them.
              Expanded(
                child: CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(child: _header(login)),
                    SliverToBoxAdapter(child: _createCard(login)),
                    if (hasRepos) SliverToBoxAdapter(child: _searchField()),
                    ..._listSlivers(),
                    SliverToBoxAdapter(child: _selectionPanel()),
                    SliverToBoxAdapter(child: SizedBox(height: keyboard)),
                  ],
                ),
              ),
              // Outside the scrollable, so it rides just above the keyboard
              // instead of being stranded behind it.
              _bottomBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(String? login) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Where do your albums live?',
            style: context.textTheme.headlineMedium,
          ),
          const SizedBox(height: 6),
          Text(
            'Pick the GitHub repo your site pulls albums from.',
            style: context.textTheme.bodyMedium,
          ),
          if (login != null) ...[
            const SizedBox(height: 8),
            Text(
              'Signed in as @$login',
              style: context.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }

  Widget _createCard(String? login) {
    final scheme = context.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      child: InkWell(
        onTap: () => _createRepo(login),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: scheme.primary),
          ),
          child: Row(
            children: [
              Icon(Icons.add_rounded, color: scheme.primary, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Create a repo for my albums',
                      style: context.textTheme.labelLarge?.copyWith(
                        color: scheme.primary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'glickr sets it up with the right layout.',
                      style: context.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _searchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: TextField(
        controller: _search,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Search your repositories',
          prefixIcon: const Icon(Icons.search_rounded, size: 20),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 12,
          ),
          suffixIcon: _search.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.close_rounded, size: 18),
                  onPressed: _search.clear,
                ),
        ),
      ),
    );
  }

  /// The picker, as slivers - it shares the screen's one scroll view with the
  /// header above it and the selection panel below it.
  List<Widget> _listSlivers() {
    if (_loadingList && _repos == null) return [_skeleton()];

    final repos = _repos;
    if (repos == null) {
      return [
        _escapeHatch(
          EmptyState(
            icon: Icons.cloud_off_rounded,
            title: "Couldn't load your repositories",
            body: _listError ?? 'Something went wrong reaching GitHub.',
            action: OutlinedButton.icon(
              onPressed: _loadRepos,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Try again'),
            ),
          ),
        ),
      ];
    }

    if (repos.isEmpty) {
      return [
        _escapeHatch(
          EmptyState(
            icon: Icons.folder_off_rounded,
            title: 'No repositories found',
            body:
                "glickr can only see public repositories you can write to. If "
                "your album repo is private, make it public - the CDN your "
                "site reads through can't serve a private repo anyway. Or "
                'enter it by hand below.',
            action: TextButton.icon(
              onPressed: _loadRepos,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Refresh'),
            ),
          ),
        ),
      ];
    }

    final filtered = _filtered;
    if (filtered.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(32, 24, 32, 24),
            child: Text(
              'Nothing matches "${_search.text.trim()}".',
              textAlign: TextAlign.center,
              style: context.textTheme.bodyMedium,
            ),
          ),
        ),
      ];
    }

    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        sliver: SliverList.builder(
          itemCount: filtered.length,
          itemBuilder: (context, index) => StaggeredFadeIn(
            index: index,
            child: _repoTile(filtered[index]),
          ),
        ),
      ),
    ];
  }

  /// Manual owner/name entry, shown whenever the picker cannot offer the repo
  /// itself. A GitHub App that is not installed on the album repo makes that
  /// repo invisible to `/user/repos` but perfectly readable by name, so
  /// without this the user is stuck on a screen with no way forward.
  Widget _escapeHatch(Widget child) {
    return SliverFillRemaining(
      // Takes exactly what is left of the viewport, keyboard included, and
      // lets the empty state scroll inside it. That keeps the owner/name field
      // at the bottom of what is visible instead of pushing it below a long
      // empty state - on a screen with no repos it is the only way forward.
      hasScrollBody: true,
      child: Column(
        children: [
          Expanded(child: child),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Or type it yourself', style: context.textTheme.titleSmall),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _manual,
                        focusNode: _manualFocus,
                        autocorrect: false,
                        style: AppTheme.mono(
                          context,
                          color: context.colorScheme.onSurface,
                        ),
                        decoration: const InputDecoration(
                          hintText: 'owner/name',
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 12,
                          ),
                        ),
                        onSubmitted: (_) => _lookupManual(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    OutlinedButton(
                      onPressed: _lookingUp ? null : _lookupManual,
                      child: _lookingUp
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Find'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _skeleton() {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      sliver: SliverList.builder(
        itemCount: 6,
        itemBuilder: (context, index) => const Padding(
          padding: EdgeInsets.only(bottom: 10),
          child: GlickrShimmer(child: ShimmerBlock(height: 66, radius: 14)),
        ),
      ),
    );
  }

  Widget _repoTile(GitHubRepo repo) {
    final scheme = context.colorScheme;
    final selected = _selected?.id == repo.id;
    // An album-shaped name is a hint, not a decision, so it gets a softer
    // version of the selected border rather than one that looks identical.
    final borderColor = selected
        ? scheme.primary
        : repo.looksLikeAlbumRepo
        ? scheme.primary.withValues(alpha: 0.5)
        : scheme.outline.withValues(alpha: 0.35);

    final meta = <String>[
      if (repo.pushedAt != null) 'updated ${relativeTime(repo.pushedAt)}',
      if (repo.sizeKb > 0) formatBytes(repo.sizeKb * 1024),
    ].join('  ·  ');

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: selected
            ? scheme.primary.withValues(alpha: 0.10)
            : scheme.surfaceContainer,
        animationDuration: context.motion(const Duration(milliseconds: 180)),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: borderColor, width: selected ? 1.8 : 1),
        ),
        child: InkWell(
          onTap: () => _selectFromPicker(repo),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(
                  repo.looksLikeAlbumRepo
                      ? Icons.photo_library_rounded
                      : Icons.folder_rounded,
                  size: 20,
                  color: repo.looksLikeAlbumRepo
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              repo.fullName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTheme.mono(
                                context,
                                size: 14,
                                weight: FontWeight.w600,
                                color: scheme.onSurface,
                              ),
                            ),
                          ),
                          if (repo.isPrivate) ...[
                            const SizedBox(width: 6),
                            Icon(
                              Icons.lock_rounded,
                              size: 13,
                              color: context.appColors.warning,
                            ),
                          ],
                        ],
                      ),
                      if (meta.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(meta, style: context.textTheme.bodySmall),
                      ],
                    ],
                  ),
                ),
                if (selected) ...[
                  const SizedBox(width: 10),
                  Icon(
                    Icons.check_circle_rounded,
                    size: 20,
                    color: scheme.primary,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Everything the user needs to judge the selected repo, sitting between the
  /// picker and the button that commits it.
  ///
  /// It is part of the screen's one scroll view rather than a bounded box of
  /// its own: bounded, it could not lift its own fields above the keyboard,
  /// and the picker above it could not scroll them there either.
  Widget _selectionPanel() {
    final repo = _selected;
    if (repo == null) return const SizedBox.shrink();
    final colors = context.appColors;
    final result = _check;

    return Column(
      key: _panelKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            repo.fullName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTheme.mono(
              context,
              size: 13,
              weight: FontWeight.w600,
              color: context.colorScheme.onSurface,
            ),
          ),
        ),
        if (_checking)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Text(
                  'Looking inside this repo',
                  style: context.textTheme.bodySmall,
                ),
              ],
            ),
          )
        else if (result != null)
          ..._checkBanners(result, colors),
        _albumRootRow(),
        if (!repo.canPush)
          StatusBanner(
            icon: Icons.edit_off_rounded,
            tint: colors.warning,
            message:
                "You can't push to this repo, so uploads will fail when "
                'they try to commit.',
          ),
        if (repo.isPrivate)
          StatusBanner(
            icon: Icons.lock_rounded,
            tint: colors.warning,
            message:
                "This repo is private. The CDN your site uses can't read "
                "private repos, so albums won't appear on your website.",
          ),
        _advanced(repo),
      ],
    );
  }

  List<Widget> _checkBanners(RepoCheckResult result, AppColors colors) {
    final banners = <Widget>[
      switch (result.status) {
        RepoCheckStatus.hasAlbums => StatusBanner(
          icon: Icons.check_circle_rounded,
          tint: colors.success,
          message:
              'Found ${_count(result.albumCount, 'album')} - '
              '${_count(result.itemCount, 'photo')}',
        ),
        RepoCheckStatus.empty => StatusBanner(
          icon: Icons.info_outline,
          tint: colors.info,
          message:
              "No albums here yet - that's fine, you'll make the first one.",
        ),
        // Never rendered as "empty": saying "no albums here" when the truth is
        // "I couldn't look" is how someone ends up wiping a repo.
        RepoCheckStatus.unknown => StatusBanner(
          icon: Icons.help_outline,
          tint: colors.warning,
          message:
              "Couldn't check this repo - ${result.message ?? 'no details'}",
        ),
      },
    ];

    if (result.repoBytes >= MediaPipelineService.repoWarnBytes) {
      banners.add(
        StatusBanner(
          icon: Icons.data_usage_rounded,
          tint: colors.warning,
          message:
              'This repo is already ${formatBytes(result.repoBytes)} of the '
              '${formatBytes(MediaPipelineService.repoCeilingBytes)} '
              'GitHub Pages will publish.',
        ),
      );
    }
    return banners;
  }

  String _count(int n, String noun) => '$n ${n == 1 ? noun : '${noun}s'}';

  /// Which folder inside the repo albums go in - a first-class question, not
  /// an advanced one. Pointing glickr at a site repo is only useful if this is
  /// visible at the moment the repo is chosen.
  Widget _albumRootRow() {
    final scheme = context.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Material(
        color: scheme.surfaceContainer,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: scheme.outline.withValues(alpha: 0.35)),
        ),
        child: InkWell(
          onTap: _pickAlbumRoot,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
            child: Row(
              children: [
                Icon(
                  Icons.folder_open_rounded,
                  size: 18,
                  color: scheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Albums folder', style: context.textTheme.titleSmall),
                      const SizedBox(height: 3),
                      Text(
                        _albumRoot.isEmpty ? 'Repository root' : _albumRoot,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.mono(
                          context,
                          size: 13,
                          weight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'The directory in the repo that album folders are '
                        'created in.',
                        style: context.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                TextButton(
                  onPressed: _pickAlbumRoot,
                  child: const Text('Change'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _advanced(GitHubRepo repo) {
    return Theme(
      // ExpansionTile draws its own hairlines above and below, which read as
      // a section break this panel does not have.
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        title: Text('Advanced', style: context.textTheme.titleSmall),
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expansionAnimationStyle: AnimationStyle(
          duration: context.motion(const Duration(milliseconds: 200)),
        ),
        // Expanding the disclosure adds height below everything else, so the
        // fields land at the very bottom of the scroll - exactly where the
        // keyboard covers them. Their focus nodes scroll them back up.
        onExpansionChanged: (expanded) {
          if (!expanded) FocusScope.of(context).unfocus();
        },
        children: [
          TextField(
            controller: _branch,
            focusNode: _branchFocus,
            autocorrect: false,
            style: AppTheme.mono(
              context,
              color: context.colorScheme.onSurface,
            ),
            decoration: InputDecoration(
              labelText: 'Branch',
              hintText: repo.defaultBranch,
              helperText: 'The branch your site builds from.',
            ),
            // Re-check on commit rather than on every keystroke: a wrong
            // branch is the difference between "no albums" and "128 photos",
            // and the user should see that flip.
            onSubmitted: (_) => _reverify(),
            onTapOutside: (_) {
              FocusScope.of(context).unfocus();
              _reverify();
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _siteUrl,
            focusNode: _siteUrlFocus,
            autocorrect: false,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Site URL',
              hintText: 'https://example.com',
              helperText: "Where 'View on web' sends you. Leave it empty to "
                  'hide that action.',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _albumsPath,
            focusNode: _albumsPathFocus,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Album page URL path',
              hintText: 'albums',
              // Named at length because it is one word away from the Albums
              // folder row above, and they are completely different things.
              helperText: 'The address album pages sit under on your site - '
                  'not a folder in the repo.',
            ),
          ),
        ],
      ),
    );
  }

  Widget _bottomBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          // Held while verification is in flight: the chip is the only thing
          // on screen that can change the user's mind, so they should not be
          // able to commit before it lands.
          onPressed: _selected == null || _saving || _checking
              ? null
              : _useThisRepo,
          child: _saving
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Use this repo'),
        ),
      ),
    );
  }
}

/// The create-repo dialog, stateful so a rejected name (usually "you already
/// have one called that") can be reported without throwing away what the user
/// typed.
class _CreateRepoDialog extends ConsumerStatefulWidget {
  final TextEditingController controller;
  final String? login;

  const _CreateRepoDialog({required this.controller, required this.login});

  @override
  ConsumerState<_CreateRepoDialog> createState() => _CreateRepoDialogState();
}

class _CreateRepoDialogState extends ConsumerState<_CreateRepoDialog> {
  bool _creating = false;
  String? _error;

  Future<void> _create() async {
    final name = widget.controller.text.trim();
    if (name.isEmpty || _creating) return;

    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final repo = await ref
          .read(repoRepositoryProvider)
          .createAlbumRepo(name: name);
      if (!mounted) return;
      Navigator.of(context).pop(repo);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _creating = false;
        _error = e is DioException && e.response?.statusCode == 422
            // The overwhelmingly common 422 here, and the generic GitHub text
            // ("Repository creation failed") explains nothing.
            ? 'GitHub turned that name down - you may already have a repo '
                  'called "$name".'
            : e is DioException
            ? ApiClient.friendlyError(e)
            : e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final name = widget.controller.text.trim();
    final owner = widget.login ?? 'your-account';

    return AlertDialog(
      title: const Text('Create a repo'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: widget.controller,
              autofocus: true,
              autocorrect: false,
              enabled: !_creating,
              style: AppTheme.mono(context, color: scheme.onSurface),
              decoration: const InputDecoration(labelText: 'Repository name'),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _create(),
            ),
            const SizedBox(height: 10),
            Text(
              'github.com/$owner/${name.isEmpty ? '…' : name}',
              style: AppTheme.mono(context, size: 12),
            ),
            const SizedBox(height: 16),
            Text(
              'Album repos have to be public. The CDN your site uses only '
              'serves public repositories, so anything you upload can be read '
              "by anyone with the link. Don't put private photos here.",
              style: context.textTheme.bodySmall,
            ),
            if (_error != null) ...[
              const SizedBox(height: 14),
              Text(
                _error!,
                style: context.textTheme.bodySmall?.copyWith(
                  color: scheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _creating ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _creating || name.isEmpty ? null : _create,
          child: _creating
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Create'),
        ),
      ],
    );
  }
}
