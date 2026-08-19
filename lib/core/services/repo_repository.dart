import 'package:dio/dio.dart';

import '../models/github_repo.dart';
import '../utils/album_conventions.dart';
import 'dio_client.dart';
import 'git_data_service.dart';

/// What glickr found when it looked inside a candidate repo.
enum RepoCheckStatus {
  /// Top-level folders containing renderable media - it already holds albums.
  hasAlbums,

  /// Reachable and writable, but nothing album-shaped yet. Perfectly fine:
  /// this is what an empty album repo looks like before the first upload.
  empty,

  /// Could not tell. Offline, rate-limited, or forbidden. Deliberately
  /// distinct from [empty] so the UI never claims "no albums here" when the
  /// truth is "I couldn't look".
  unknown,
}

class RepoCheckResult {
  final RepoCheckStatus status;
  final int albumCount;
  final int itemCount;
  final int repoBytes;
  final String? message;

  const RepoCheckResult({
    required this.status,
    this.albumCount = 0,
    this.itemCount = 0,
    this.repoBytes = 0,
    this.message,
  });
}

/// Repo listing, verification, and creation.
class RepoRepository {
  final Dio _dio;
  final GitDataService _git;

  RepoRepository({required Dio dio, required GitDataService git})
    : _dio = dio,
      _git = git;

  /// Repos the signed-in user can write to, most recently pushed first.
  ///
  /// Filtered to `permissions.push`, because a repo the user can only read is
  /// a trap: verification would appear to pass and the failure would not
  /// surface until the final ref update, after thirty photos had already been
  /// compressed and uploaded.
  Future<List<GitHubRepo>> listWritableRepos({int maxPages = 3}) async {
    final repos = <GitHubRepo>[];
    for (var page = 1; page <= maxPages; page++) {
      final response = await _dio.get(
        '/user/repos',
        queryParameters: {
          'per_page': 100,
          'page': page,
          'sort': 'pushed',
          'direction': 'desc',
          'affiliation': 'owner,collaborator,organization_member',
        },
      );
      final data = response.data;
      if (data is! List || data.isEmpty) break;
      repos.addAll(
        data
            .whereType<Map>()
            .map((r) => GitHubRepo.fromJson(Map<String, dynamic>.from(r))),
      );
      if (data.length < 100) break;
    }

    final writable = repos.where((r) => r.canPush).toList();
    // Album-shaped names first so the common case is one tap, then most
    // recently pushed.
    writable.sort((a, b) {
      if (a.looksLikeAlbumRepo != b.looksLikeAlbumRepo) {
        return a.looksLikeAlbumRepo ? -1 : 1;
      }
      final ap = a.pushedAt, bp = b.pushedAt;
      if (ap == null || bp == null) return a.name.compareTo(b.name);
      return bp.compareTo(ap);
    });
    return writable;
  }

  /// Look up one repo by owner/name, for the manual-entry escape hatch.
  Future<GitHubRepo?> findRepo(String owner, String name) async {
    try {
      final response = await _dio.get('/repos/$owner/$name');
      final data = response.data;
      if (data is Map) {
        return GitHubRepo.fromJson(Map<String, dynamic>.from(data));
      }
      return null;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  /// Inspect a repo for album-shaped content.
  ///
  /// One request in the common case, and it doubles as a permissions probe:
  /// if the token cannot read the tree, the user finds out here rather than
  /// mid-upload.
  Future<RepoCheckResult> inspect({
    required String owner,
    required String name,
    required String branch,
    String albumRoot = '',
  }) async {
    try {
      final head = await _git.getHead(owner, name, branch);
      final snapshot = await _git.getTree(
        owner,
        name,
        commitSha: head.commitSha!,
        treeSha: head.treeSha!,
      );

      // Counted relative to the album root, so inspecting a whole site repo
      // reports the albums under `assets/albums` rather than mistaking every
      // top-level directory for one.
      final root = albumRoot.replaceAll(RegExp(r'^/+|/+$'), '');
      final prefix = root.isEmpty ? '' : '$root/';
      final folders = <String, int>{};
      for (final node in snapshot.nodes) {
        if (!node.isBlob) continue;
        if (!node.path.startsWith(prefix)) continue;
        final relative = node.path.substring(prefix.length);
        if (!isAlbumMediaPath(relative)) continue;
        final folder = albumFolderOf(relative);
        if (folder == null || folder.startsWith('.')) continue;
        folders[folder] = (folders[folder] ?? 0) + 1;
      }

      if (folders.isEmpty) {
        return RepoCheckResult(
          status: RepoCheckStatus.empty,
          repoBytes: snapshot.totalBytes,
        );
      }
      return RepoCheckResult(
        status: RepoCheckStatus.hasAlbums,
        albumCount: folders.length,
        itemCount: folders.values.fold(0, (a, b) => a + b),
        repoBytes: snapshot.totalBytes,
      );
    } on EmptyRepoException {
      // A brand-new repo with no commits. Valid, and glickr bootstraps it on
      // the first upload.
      return const RepoCheckResult(status: RepoCheckStatus.empty);
    } on DioException catch (e) {
      return RepoCheckResult(
        status: RepoCheckStatus.unknown,
        message: ApiClient.friendlyError(e),
      );
    } catch (e) {
      return RepoCheckResult(
        status: RepoCheckStatus.unknown,
        message: e.toString(),
      );
    }
  }

  /// Create a public repo to hold albums.
  ///
  /// `auto_init` matters: it makes the initial commit, so the first upload has
  /// a parent to build on and never has to take the empty-repo bootstrap path.
  ///
  /// Public is not a default, it is a requirement - the CDN the website reads
  /// through cannot serve a private repo at all. The caller must have shown
  /// the user what that means before getting here.
  Future<GitHubRepo> createAlbumRepo({
    required String name,
    String description = 'Photo albums for my site',
  }) async {
    final response = await _dio.post(
      '/user/repos',
      data: {
        'name': name,
        'private': false,
        'auto_init': true,
        'description': description,
      },
    );
    return GitHubRepo.fromJson(Map<String, dynamic>.from(response.data as Map));
  }
}
