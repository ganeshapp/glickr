import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import 'github_rate_gate.dart';

/// A single entry in a tree write. `sha == null` deletes the path.
class TreeEntry {
  final String path;
  final String? sha;
  final String mode;

  const TreeEntry.file(this.path, String this.sha, {this.mode = '100644'});
  const TreeEntry.delete(this.path, {this.mode = '100644'}) : sha = null;

  Map<String, dynamic> toJson() => {
    'path': path,
    'mode': mode,
    'type': 'blob',
    // Explicit null is meaningful here - it is how the API expresses a
    // deletion - so this key must always be present.
    'sha': sha,
  };
}

/// One blob in a repo tree listing.
class TreeNode {
  final String path;
  final String sha;
  final String type; // 'blob' | 'tree'
  final int size;
  final String mode;

  const TreeNode({
    required this.path,
    required this.sha,
    required this.type,
    this.size = 0,
    this.mode = '100644',
  });

  bool get isBlob => type == 'blob';
  bool get isTree => type == 'tree';
}

/// A whole-repo snapshot at one commit.
class TreeSnapshot {
  final String commitSha;
  final String treeSha;
  final List<TreeNode> nodes;

  /// True when GitHub could not fit the repo in one response (documented cap:
  /// 100,000 entries or 7 MB). The caller must fall back to walking folder
  /// trees individually.
  final bool truncated;

  const TreeSnapshot({
    required this.commitSha,
    required this.treeSha,
    required this.nodes,
    this.truncated = false,
  });

  /// Total bytes of every blob - the number that matters, because size limits
  /// are measured against the whole repository, not the file being served.
  int get totalBytes =>
      nodes.where((n) => n.isBlob).fold(0, (sum, n) => sum + n.size);
}

/// The repo has no commits yet, so there is no ref, no tree, and nothing to
/// build a commit on. Recoverable: one Contents-API PUT bootstraps it.
class EmptyRepoException implements Exception {
  const EmptyRepoException();
  @override
  String toString() => 'This repository is empty';
}

/// Someone else pushed while we were uploading, so our ref update was
/// rejected. Recoverable and routine, not an error the user should see:
/// rebuild the tree on the new head and retry. Costs zero re-uploaded bytes,
/// because the blobs are already on GitHub and content-addressed.
class NonFastForwardException implements Exception {
  const NonFastForwardException();
  @override
  String toString() => 'The branch moved while uploading';
}

/// The git blob id for [bytes], computed locally.
///
/// Git object ids are `sha1("blob " + length + "\0" + content)`. Computing it
/// on device lets a resumed upload skip files GitHub already has without
/// spending a request to find out - and it means the resume path does not
/// depend on the (true, but undocumented) fact that re-POSTing identical bytes
/// returns the identical sha.
String gitBlobSha(Uint8List bytes) {
  // The separator is a NUL byte, written as an escape so this source file
  // stays plain ASCII - a raw 0x00 in a Dart literal is a trap for every
  // editor and diff tool that touches it. Using a space instead produces a
  // plausible-looking hash that matches nothing GitHub has, which would make
  // the resume path re-upload every file forever.
  final header = utf8.encode('blob ${bytes.length}\u0000');
  // Hashed in chunks so an 18 MB video is never copied into a second buffer
  // just to prepend a 20-byte header.
  final sink = _DigestSink();
  final input = sha1.startChunkedConversion(sink);
  input.add(header);
  input.add(bytes);
  input.close();
  return sink.value.toString();
}

/// Collects the single [Digest] a chunked hash conversion emits. Hand-rolled
/// rather than depending on `package:convert` just for its `AccumulatorSink`,
/// since exactly one value is ever produced.
class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// Thin, stateless wrapper over GitHub's Git Data API.
///
/// glickr writes through this rather than the Contents API for one reason
/// that changes everything downstream: the Contents API is one commit per
/// file. Thirty photos would be thirty commits, thirty cache generations (so
/// every other album's cached thumbnails miss), and thirty chances to leave
/// an album half-written. The Git Data API makes any number of files - plus
/// album.md and album.json - a single atomic commit, makes deletes and
/// renames atomic too, and makes uploads resumable for free.
class GitDataService {
  final Dio _dio;
  final GitHubRateGate _gate;

  GitDataService({required Dio dio, required GitHubRateGate gate})
    : _dio = dio,
      _gate = gate;

  String _base(String owner, String repo) => '/repos/$owner/$repo';

  /// Head commit sha of [branch].
  ///
  /// Throws [EmptyRepoException] on 409. GitHub documents that status as
  /// "the Git repository is empty or unavailable", where unavailable means
  /// still being provisioned - so a repo created seconds ago can 409 while
  /// perfectly healthy. Callers that just created a repo should retry with
  /// backoff before concluding it is genuinely empty.
  ///
  /// [etag] enables a conditional request: a 304 costs no primary rate limit
  /// at all, which is what makes pull-to-refresh essentially free.
  Future<RefInfo> getHead(
    String owner,
    String repo,
    String branch, {
    String? etag,
  }) async {
    try {
      final response = await _dio.get(
        '${_base(owner, repo)}/commits/$branch',
        options: Options(
          headers: {if (etag != null) 'If-None-Match': etag},
          validateStatus: (s) => s == 200 || s == 304,
        ),
      );
      if (response.statusCode == 304) {
        return RefInfo.unchanged(etag!);
      }
      final data = response.data as Map;
      return RefInfo(
        commitSha: data['sha'] as String,
        treeSha: (data['commit'] as Map)['tree']['sha'] as String,
        etag: response.headers.value('etag'),
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 409) throw const EmptyRepoException();
      rethrow;
    }
  }

  /// The whole repo at [commitSha] in one request.
  ///
  /// The album layout is strictly two levels deep, so one recursive call
  /// returns everything the app needs: folders, files, sizes, and each
  /// folder's own tree sha for per-album invalidation.
  Future<TreeSnapshot> getTree(
    String owner,
    String repo, {
    required String commitSha,
    required String treeSha,
    bool recursive = true,
  }) async {
    final response = await _dio.get(
      '${_base(owner, repo)}/git/trees/$treeSha',
      queryParameters: {if (recursive) 'recursive': '1'},
    );
    final data = response.data as Map;
    final raw = (data['tree'] as List?) ?? const [];
    return TreeSnapshot(
      commitSha: commitSha,
      treeSha: treeSha,
      truncated: data['truncated'] as bool? ?? false,
      nodes: raw.map((n) {
        final node = n as Map;
        return TreeNode(
          path: node['path'] as String,
          sha: node['sha'] as String,
          type: node['type'] as String,
          size: (node['size'] as num?)?.toInt() ?? 0,
          mode: node['mode'] as String? ?? '100644',
        );
      }).toList(),
    );
  }

  /// Create a blob and return its sha.
  ///
  /// Idempotent by construction: identical bytes always produce the identical
  /// sha and no duplicate object, so a crash between GitHub storing the blob
  /// and glickr recording the sha costs one redundant request and can never
  /// corrupt state.
  Future<String> createBlob(
    String owner,
    String repo,
    Uint8List bytes, {
    CancelToken? cancelToken,
    void Function(int sent, int total)? onProgress,
  }) {
    return _gate.run(() async {
      // Built as a pre-rendered string rather than a Map so Dio serialises it
      // in one pass. jsonEncode of a Map would copy the whole base64 payload
      // again, and for an 18 MB video that second copy is ~24 MB of Dart heap
      // on a device that may not have it to spare. Base64 output is
      // alphanumeric plus '+/=', so it never needs JSON escaping.
      final body = '{"content":"${base64Encode(bytes)}","encoding":"base64"}';
      final response = await _dio.post(
        '${_base(owner, repo)}/git/blobs',
        data: body,
        cancelToken: cancelToken,
        onSendProgress: onProgress,
        options: Options(contentType: Headers.jsonContentType),
      );
      return (response.data as Map)['sha'] as String;
    });
  }

  /// Create a tree from [baseTreeSha] plus [entries], returning its sha.
  ///
  /// [baseTreeSha] is required and non-nullable ON PURPOSE. GitHub documents
  /// that omitting base_tree "creates a tree from only provided entries; files
  /// from the parent commit not listed will appear deleted" - so a single
  /// forgotten field wipes the entire album repository in one commit. Making
  /// it impossible to omit is cheaper than remembering.
  Future<String> createTree(
    String owner,
    String repo, {
    required String baseTreeSha,
    required List<TreeEntry> entries,
  }) {
    return _gate.run(() async {
      final response = await _dio.post(
        '${_base(owner, repo)}/git/trees',
        data: {
          'base_tree': baseTreeSha,
          'tree': entries.map((e) => e.toJson()).toList(),
        },
      );
      return (response.data as Map)['sha'] as String;
    });
  }

  Future<String> createCommit(
    String owner,
    String repo, {
    required String message,
    required String treeSha,
    required String parentSha,
  }) {
    return _gate.run(() async {
      final response = await _dio.post(
        '${_base(owner, repo)}/git/commits',
        data: {
          'message': message,
          'tree': treeSha,
          // Never omit parents: an empty list makes a ROOT commit, orphaning
          // the entire history of the repo.
          'parents': [parentSha],
        },
      );
      return (response.data as Map)['sha'] as String;
    });
  }

  /// Point [branch] at [commitSha].
  ///
  /// Always a fast-forward - `force` is never sent. A forced update would
  /// silently discard whatever another device or a GitHub Action pushed while
  /// we were uploading, and there is no recovering the user's photos after
  /// that. A rejected update throws [NonFastForwardException], which the
  /// caller handles by rebuilding on the new head.
  Future<void> updateRef(
    String owner,
    String repo,
    String branch,
    String commitSha,
  ) {
    return _gate.run(() async {
      try {
        await _dio.patch(
          // Note the path form: `heads/main`, with no `refs/` prefix.
          '${_base(owner, repo)}/git/refs/heads/$branch',
          data: {'sha': commitSha, 'force': false},
        );
      } on DioException catch (e) {
        final status = e.response?.statusCode;
        final data = e.response?.data;
        final message = (data is Map && data['message'] is String)
            ? (data['message'] as String).toLowerCase()
            : '';
        if (status == 422 &&
                (message.contains('fast forward') ||
                    message.contains('fast-forward')) ||
            status == 409) {
          throw const NonFastForwardException();
        }
        rethrow;
      }
    });
  }

  /// Create the first commit in an empty repo.
  ///
  /// The Git Data endpoints need an existing object database and ref, so they
  /// cannot bootstrap an empty repository. GitHub's own guidance is to use the
  /// Contents API once to initialise it - after which the normal batch flow
  /// works, and no special root-commit case is needed anywhere else.
  Future<String> bootstrapEmptyRepo(
    String owner,
    String repo,
    String branch, {
    required String path,
    required String content,
    required String message,
  }) {
    return _gate.run(() async {
      final response = await _dio.put(
        '${_base(owner, repo)}/contents/$path',
        data: {
          'message': message,
          'content': base64Encode(utf8.encode(content)),
          'branch': branch,
        },
      );
      return ((response.data as Map)['commit'] as Map)['sha'] as String;
    });
  }

  /// Raw bytes of one file, for private repos.
  ///
  /// Both media hosts glickr can use - raw.githubusercontent and jsDelivr -
  /// serve public repositories only and ignore auth headers entirely, so this
  /// is the only documented authenticated path to file content. Slower and
  /// rate-limited, hence a fallback rather than the default.
  Future<Uint8List> fetchContentBytes(
    String owner,
    String repo, {
    required String path,
    required String ref,
    CancelToken? cancelToken,
  }) async {
    final response = await _dio.get<List<int>>(
      '${_base(owner, repo)}/contents/$path',
      queryParameters: {'ref': ref},
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.bytes,
        headers: {'Accept': 'application/vnd.github.raw'},
      ),
    );
    return Uint8List.fromList(response.data ?? const []);
  }

  /// Text of one blob by sha. Used for `album.md` and `album.json`, which are
  /// small and need to be read at an exact commit.
  Future<String> fetchBlobText(String owner, String repo, String sha) async {
    final response = await _dio.get(
      '${_base(owner, repo)}/git/blobs/$sha',
      options: Options(headers: {'Accept': 'application/vnd.github.raw'}),
    );
    final data = response.data;
    if (data is String) return data;
    // Some proxies ignore the raw media type and return the JSON envelope.
    if (data is Map && data['content'] is String) {
      final normalized = (data['content'] as String).replaceAll('\n', '');
      return utf8.decode(base64Decode(normalized), allowMalformed: true);
    }
    return '';
  }
}

/// Result of a head lookup. [unchanged] means the server answered 304 and the
/// caller's cached snapshot is still exact.
class RefInfo {
  final String? commitSha;
  final String? treeSha;
  final String? etag;
  final bool unchanged;

  const RefInfo({
    required this.commitSha,
    required this.treeSha,
    this.etag,
  }) : unchanged = false;

  const RefInfo.unchanged(String this.etag)
    : commitSha = null,
      treeSha = null,
      unchanged = true;
}
