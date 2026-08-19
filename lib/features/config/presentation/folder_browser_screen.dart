import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/services_provider.dart';
import '../../../core/services/dio_client.dart';
import '../../../core/services/git_data_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/album_conventions.dart';
import '../../../core/widgets/empty_state.dart';
import '../../../core/widgets/glickr_shimmer.dart';

/// Pick the repo directory album folders live in.
///
/// Resolves to a repo-relative path - '' for the repository root - or null if
/// the user backed out.
Future<String?> showFolderBrowser(
  BuildContext context, {
  required String owner,
  required String repo,
  required String branch,
  String initialPath = '',
}) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute<String>(
      fullscreenDialog: true,
      builder: (_) => FolderBrowserScreen(
        owner: owner,
        repo: repo,
        branch: branch,
        initialPath: initialPath,
      ),
    ),
  );
}

/// Clean a typed folder name into a repo-relative path under [base].
///
/// Returns null for anything that would not survive a round trip through git:
/// blank input, empty segments, and the `.`/`..` traversal names.
String? joinNewFolderPath(String base, String input) {
  final cleaned = input.trim().replaceAll(RegExp(r'^/+|/+$'), '');
  if (cleaned.isEmpty) return null;

  final segments = cleaned.split('/').map((s) => s.trim()).toList();
  for (final segment in segments) {
    if (segment.isEmpty || segment == '.' || segment == '..') return null;
  }
  final joined = segments.join('/');
  return base.isEmpty ? joined : '$base/$joined';
}

/// One directory in the locally-built tree.
class _Dir {
  _Dir(this.path, this.name);

  final String path;
  final String name;
  final Map<String, _Dir> children = {};
  int fileCount = 0;

  /// True when this directory DIRECTLY holds media the site would render,
  /// which is what makes its parent look like an album root.
  bool hasMedia = false;

  /// Dot-directories are dropped here rather than at build time so their files
  /// still count towards their parent - `.github` is never an album root, but
  /// pretending it does not exist would misreport what is in the root.
  List<_Dir> get subdirectories {
    final dirs = children.values.where((d) => !d.name.startsWith('.')).toList();
    dirs.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return dirs;
  }
}

/// Browse the repo's directories and choose one.
///
/// The whole tree is fetched ONCE and navigated in memory. GitHub's recursive
/// tree endpoint returns every path in a single request, so descending a folder
/// costs nothing - and a per-directory Contents call would spend the user's
/// rate limit on something they are only looking at.
class FolderBrowserScreen extends ConsumerStatefulWidget {
  final String owner;
  final String repo;
  final String branch;
  final String initialPath;

  const FolderBrowserScreen({
    super.key,
    required this.owner,
    required this.repo,
    required this.branch,
    this.initialPath = '',
  });

  @override
  ConsumerState<FolderBrowserScreen> createState() =>
      _FolderBrowserScreenState();
}

class _FolderBrowserScreenState extends ConsumerState<FolderBrowserScreen> {
  _Dir? _root;
  String _path = '';
  bool _loading = true;
  bool _emptyRepo = false;
  bool _truncated = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _path = widget.initialPath.replaceAll(RegExp(r'^/+|/+$'), '');
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _emptyRepo = false;
    });

    try {
      final git = ref.read(gitDataServiceProvider);
      final head = await git.getHead(widget.owner, widget.repo, widget.branch);
      final snapshot = await git.getTree(
        widget.owner,
        widget.repo,
        commitSha: head.commitSha!,
        treeSha: head.treeSha!,
      );
      if (!mounted) return;
      setState(() {
        _root = _buildTree(snapshot);
        _truncated = snapshot.truncated;
        _loading = false;
      });
    } on EmptyRepoException {
      if (!mounted) return;
      setState(() {
        _emptyRepo = true;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is DioException ? ApiClient.friendlyError(e) : e.toString();
      });
    }
  }

  _Dir _buildTree(TreeSnapshot snapshot) {
    final root = _Dir('', '');
    for (final node in snapshot.nodes) {
      final segments = node.path.split('/').where((s) => s.isNotEmpty).toList();
      if (segments.isEmpty) continue;
      if (node.isTree) {
        _descend(root, segments);
      } else {
        final parent = _descend(root, segments.sublist(0, segments.length - 1));
        parent.fileCount++;
        if (isRenderableName(segments.last)) parent.hasMedia = true;
      }
    }
    return root;
  }

  _Dir _descend(_Dir root, List<String> segments) {
    var dir = root;
    final walked = <String>[];
    for (final segment in segments) {
      walked.add(segment);
      final path = walked.join('/');
      dir = dir.children.putIfAbsent(segment, () => _Dir(path, segment));
    }
    return dir;
  }

  /// The directory at [_path], or null when it does not exist in this commit -
  /// which is the normal state for a folder the user just named.
  _Dir? get _current {
    final root = _root;
    if (root == null) return null;
    if (_path.isEmpty) return root;
    var dir = root;
    for (final segment in _path.split('/')) {
      final next = dir.children[segment];
      if (next == null) return null;
      dir = next;
    }
    return dir;
  }

  void _goTo(String path) {
    HapticFeedback.selectionClick();
    setState(() => _path = path);
  }

  void _use(String path) {
    HapticFeedback.mediumImpact();
    Navigator.of(context).pop(path);
  }

  Future<void> _promptNewFolder() async {
    final controller = TextEditingController();
    try {
      final typed = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('New folder'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: AppTheme.mono(
                    context,
                    color: context.colorScheme.onSurface,
                  ),
                  decoration: const InputDecoration(hintText: 'albums'),
                  onSubmitted: (text) =>
                      Navigator.of(dialogContext).pop(text.trim()),
                ),
                const SizedBox(height: 14),
                Text(
                  _path.isEmpty
                      ? "It'll sit in the repository root."
                      : "It'll sit inside $_path.",
                  style: context.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Text(
                  "git has no empty folders, so you won't see this one on "
                  'GitHub until your first upload puts a photo in it.',
                  style: context.textTheme.bodySmall,
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
              onPressed: () =>
                  Navigator.of(dialogContext).pop(controller.text.trim()),
              child: const Text('Use it'),
            ),
          ],
        ),
      );
      if (typed == null || !mounted) return;

      final path = joinNewFolderPath(_path, typed);
      if (path == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("That isn't a folder name - try letters, numbers "
                'and dashes.'),
          ),
        );
        return;
      }
      _use(path);
    } finally {
      controller.dispose();
    }
  }

  // -------------------------------------------------------------------- ui

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('albums folder'),
        actions: [
          IconButton(
            tooltip: 'New folder',
            onPressed: _promptNewFolder,
            icon: const Icon(Icons.create_new_folder_outlined),
          ),
        ],
      ),
      body: DecoratedBox(
        decoration: AppTheme.backgroundGradient(context),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              _breadcrumb(),
              _hint(),
              Expanded(
                child: AnimatedSwitcher(
                  duration: context.motion(const Duration(milliseconds: 160)),
                  // Keyed on the load flag too, so the skeleton cross-fades
                  // into the real list instead of snapping.
                  child: KeyedSubtree(
                    key: ValueKey('$_loading|$_path'),
                    child: _body(),
                  ),
                ),
              ),
              _bottomBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _breadcrumb() {
    final segments = _path.isEmpty ? const <String>[] : _path.split('/');
    final crumbs = <Widget>[_crumb('Repository root', '', segments.isEmpty)];
    var walked = '';
    for (var i = 0; i < segments.length; i++) {
      walked = walked.isEmpty ? segments[i] : '$walked/${segments[i]}';
      crumbs.add(_separator());
      crumbs.add(_crumb(segments[i], walked, i == segments.length - 1));
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: crumbs,
        ),
      ),
    );
  }

  Widget _crumb(String label, String path, bool isCurrent) {
    final scheme = context.colorScheme;
    return InkWell(
      // The current crumb is not a destination, so it is not tappable - but it
      // still reads as part of the same trail.
      onTap: isCurrent ? null : () => _goTo(path),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Text(
          label,
          style: AppTheme.mono(
            context,
            size: 13,
            weight: isCurrent ? FontWeight.w600 : FontWeight.w400,
            color: isCurrent ? scheme.onSurface : scheme.primary,
          ),
        ),
      ),
    );
  }

  Widget _separator() {
    return Icon(
      Icons.chevron_right_rounded,
      size: 16,
      color: context.colorScheme.onSurfaceVariant,
    );
  }

  /// The one line that makes this screen self-explanatory: it names what glickr
  /// can already see in the folder the user is standing in.
  Widget _hint() {
    if (_truncated) {
      return StatusBanner(
        icon: Icons.warning_amber_rounded,
        tint: context.appColors.warning,
        message:
            "This repo is too big for GitHub to list in one go, so some "
            'folders are missing below. You can still type the path.',
      );
    }

    final current = _current;
    if (current == null) return const SizedBox.shrink();
    final albums = current.subdirectories.where((d) => d.hasMedia).length;
    if (albums == 0) return const SizedBox.shrink();

    return StatusBanner(
      icon: Icons.photo_library_outlined,
      tint: context.appColors.success,
      message:
          'Looks like albums already live here - '
          '${_count(albums, 'album')} found.',
    );
  }

  Widget _body() {
    if (_loading) return _skeleton();

    if (_error != null) {
      return EmptyState(
        icon: Icons.cloud_off_rounded,
        title: "Couldn't read this repo",
        body: _error!,
        action: OutlinedButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: const Text('Try again'),
        ),
      );
    }

    if (_emptyRepo) {
      return EmptyState(
        icon: Icons.inventory_2_outlined,
        title: 'Nothing in here yet',
        body: "This repo has no files, so there are no folders to browse. "
            'Albums will go in the repository root unless you name a folder '
            'for them.',
        hint: "A folder you name now appears on GitHub with your first "
            'upload - git has no empty folders to create ahead of time.',
        action: OutlinedButton.icon(
          onPressed: _promptNewFolder,
          icon: const Icon(Icons.create_new_folder_outlined, size: 18),
          label: const Text('Name a folder'),
        ),
      );
    }

    final current = _current;
    if (current == null) {
      // The configured album root does not exist in this commit. Normal for a
      // folder that has not had its first upload yet, so it is stated rather
      // than corrected.
      return EmptyState(
        icon: Icons.folder_off_outlined,
        title: 'Not on GitHub yet',
        body: "There's no $_path in this branch. That's fine - it appears "
            "with your first upload. Tap 'Use this folder' to keep it, or "
            'step back up the trail above.',
      );
    }

    final dirs = current.subdirectories;
    if (dirs.isEmpty) {
      return EmptyState(
        icon: Icons.folder_open_outlined,
        title: 'No folders in here',
        body: current.fileCount == 0
            ? 'This folder is empty. Albums put here would be the only thing '
                  'in it.'
            : '${_count(current.fileCount, 'file')}, but no folders. Albums '
                  'put here would sit alongside them.',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      itemCount: dirs.length,
      itemBuilder: (context, index) => _dirTile(dirs[index]),
    );
  }

  Widget _dirTile(_Dir dir) {
    final scheme = context.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: scheme.surfaceContainer,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: scheme.outline.withValues(alpha: 0.35)),
        ),
        child: InkWell(
          onTap: () => _goTo(dir.path),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(Icons.folder_rounded, size: 20, color: scheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        dir.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.mono(
                          context,
                          size: 14,
                          weight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(_contents(dir), style: context.textTheme.bodySmall),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _contents(_Dir dir) {
    final folders = dir.subdirectories.length;
    final parts = <String>[
      if (folders > 0) _count(folders, 'folder'),
      if (dir.fileCount > 0) _count(dir.fileCount, 'file'),
    ];
    return parts.isEmpty ? 'Empty' : parts.join(' - ');
  }

  String _count(int n, String noun) => '$n ${n == 1 ? noun : '${noun}s'}';

  Widget _skeleton() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      itemCount: 6,
      itemBuilder: (context, index) => const Padding(
        padding: EdgeInsets.only(bottom: 8),
        child: GlickrShimmer(child: ShimmerBlock(height: 60, radius: 14)),
      ),
    );
  }

  Widget _bottomBar() {
    final scheme = context.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(color: scheme.outline.withValues(alpha: 0.35)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Albums will go in', style: context.textTheme.bodySmall),
          const SizedBox(height: 4),
          Text(
            _path.isEmpty ? 'Repository root' : _path,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppTheme.mono(
              context,
              size: 14,
              weight: FontWeight.w600,
              color: scheme.primary,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _loading ? null : () => _use(_path),
              child: const Text('Use this folder'),
            ),
          ),
        ],
      ),
    );
  }
}
