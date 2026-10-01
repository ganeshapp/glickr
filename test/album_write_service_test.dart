import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glickr/core/models/album.dart';
import 'package:glickr/core/models/app_config.dart';
import 'package:glickr/core/services/album_write_service.dart';
import 'package:glickr/core/services/commit_service.dart';
import 'package:glickr/core/services/git_data_service.dart';
import 'package:glickr/core/services/github_rate_gate.dart';

/// A Git Data API that serves one in-memory tree.
///
/// A blob sha with no entry in [blobs] throws when fetched, which is how a
/// timeout, a 5xx or a secondary-rate-limit 403 reaches the caller.
class _StubGit extends GitDataService {
  _StubGit(this.nodes) : super(dio: Dio(), gate: GitHubRateGate());

  final List<TreeNode> nodes;
  final Map<String, String> blobs = {};

  /// Text of every blob this test created, in order.
  final List<String> written = [];

  /// Entries of the tree that was committed, or null if none ever was.
  List<TreeEntry>? committed;
  int commits = 0;

  @override
  Future<RefInfo> getHead(
    String owner,
    String repo,
    String branch, {
    String? etag,
  }) async => const RefInfo(commitSha: 'c1', treeSha: 't1');

  @override
  Future<TreeSnapshot> getTree(
    String owner,
    String repo, {
    required String commitSha,
    required String treeSha,
    bool recursive = true,
  }) async =>
      TreeSnapshot(commitSha: commitSha, treeSha: treeSha, nodes: nodes);

  @override
  Future<String> fetchBlobText(String owner, String repo, String sha) async {
    final text = blobs[sha];
    if (text == null) throw StateError('blob $sha is unreachable');
    return text;
  }

  @override
  Future<String> createBlob(
    String owner,
    String repo,
    Uint8List bytes, {
    CancelToken? cancelToken,
    void Function(int sent, int total)? onProgress,
  }) async {
    final text = utf8.decode(bytes);
    written.add(text);
    // Git blobs are content addresses: identical text, identical sha.
    final known = blobs.entries.where((e) => e.value == text).firstOrNull;
    if (known != null) return known.key;
    final sha = 'created${written.length}';
    blobs[sha] = text;
    return sha;
  }

  @override
  Future<String> createTree(
    String owner,
    String repo, {
    required String baseTreeSha,
    required List<TreeEntry> entries,
  }) async {
    committed = entries;
    commits++;
    return 'tree2';
  }

  @override
  Future<String> createCommit(
    String owner,
    String repo, {
    required String message,
    required String treeSha,
    required String parentSha,
  }) async => 'c2';

  @override
  Future<void> updateRef(
    String owner,
    String repo,
    String branch,
    String commitSha,
  ) async {}
}

const _withSidecar = <TreeNode>[
  TreeNode(path: 'trip', sha: 'TREE1', type: 'tree'),
  TreeNode(path: 'trip/0001.jpg', sha: 'B1', type: 'blob', size: 1000),
  TreeNode(path: 'trip/0002.jpg', sha: 'B2', type: 'blob', size: 1000),
  TreeNode(path: 'trip/album.json', sha: 'SJ', type: 'blob', size: 180),
];

const _threeCaptions = '''
{
  "version": 1,
  "album": "trip",
  "pad": 4,
  "next": 12,
  "items": {
    "0001.jpg": "6am start",
    "0002.jpg": "Puncture"
  }
}
''';

AlbumWriteService _service(_StubGit git) =>
    AlbumWriteService(git: git, commits: CommitService(git: git));

TreeEntry? _entryFor(List<TreeEntry>? entries, String path) =>
    entries?.where((e) => e.path == path).firstOrNull;

void main() {
  final config = AppConfig(repoOwner: 'o', repoName: 'r');
  final album = Album(folder: 'trip');

  group('an unreadable album.json', () {
    test('aborts a caption write instead of truncating the sidecar', () async {
      final git = _StubGit(_withSidecar); // SJ is not in blobs: fetch throws

      await expectLater(
        _service(git).setCaptions(
          config: config,
          album: album,
          captions: const {'0002.jpg': 'new text'},
        ),
        throwsA(isA<CaptionsUnreadableException>()),
      );

      // The dangerous outcome is not the throw, it is a commit built from
      // guessed-empty captions: that would drop 0001.jpg's caption and reset
      // `next` from 12 to 1, freeing filenames for reuse.
      expect(git.committed, isNull);
      expect(git.written, isEmpty);
    });

    test('aborts a delete instead of committing album.json away', () async {
      final git = _StubGit(_withSidecar);

      await expectLater(
        _service(git).deleteItems(
          config: config,
          album: album,
          fileNames: {'0001.jpg'},
        ),
        throwsA(isA<CaptionsUnreadableException>()),
      );

      expect(git.committed, isNull);
    });

    test('aborts a cover change instead of losing every caption', () async {
      final git = _StubGit(_withSidecar);

      await expectLater(
        _service(git).setCoverFromExisting(
          config: config,
          album: album,
          fileName: '0002.jpg',
        ),
        throwsA(isA<CaptionsUnreadableException>()),
      );

      expect(git.committed, isNull);
    });

    test('counts no bytes back for a non-empty blob as a failed read', () async {
      // fetchBlobText answers '' for any response shape it cannot parse, which
      // is indistinguishable from an empty file without the tree's size.
      final git = _StubGit(_withSidecar)..blobs['SJ'] = '';

      await expectLater(
        _service(git).setCaptions(
          config: config,
          album: album,
          captions: const {'0002.jpg': 'new text'},
        ),
        throwsA(isA<CaptionsUnreadableException>()),
      );
      expect(git.committed, isNull);
    });
  });

  group('a readable album.json', () {
    test('keeps the other captions and the high-water mark', () async {
      final git = _StubGit(_withSidecar)..blobs['SJ'] = _threeCaptions;

      final outcome = await _service(git).setCaptions(
        config: config,
        album: album,
        captions: const {'0002.jpg': 'new text'},
      );

      expect(outcome, isA<CommitApplied>());
      final json = jsonDecode(git.written.single) as Map;
      expect(json['next'], 12);
      expect((json['items'] as Map)['0001.jpg'], '6am start');
      expect((json['items'] as Map)['0002.jpg'], 'new text');
      expect(_entryFor(git.committed, 'trip/album.json')?.sha, isNotNull);
    });

    test('still removes a sidecar that is genuinely empty now', () async {
      // The delete branch is only safe because the emptiness was observed.
      final git = _StubGit(_withSidecar)
        ..blobs['SJ'] = '{"next":1,"items":{"0001.jpg":"only one"}}';

      await _service(git).setCaptions(
        config: config,
        album: album,
        captions: const {'0001.jpg': null},
      );

      final entry = _entryFor(git.committed, 'trip/album.json');
      expect(entry, isNotNull);
      expect(entry!.sha, isNull); // null sha is how the API spells "delete"
    });
  });

  test('an album with no album.json writes a fresh one', () async {
    final git = _StubGit(const [
      TreeNode(path: 'trip', sha: 'TREE1', type: 'tree'),
      TreeNode(path: 'trip/0001.jpg', sha: 'B1', type: 'blob', size: 1000),
    ]);

    await _service(git).setCaptions(
      config: config,
      album: album,
      captions: const {'0001.jpg': 'first caption'},
    );

    expect(_entryFor(git.committed, 'trip/album.json')?.sha, isNotNull);
    expect(
      (jsonDecode(git.written.single) as Map)['items'],
      {'0001.jpg': 'first caption'},
    );
  });
  group('setDescription', () {
    const described = <TreeNode>[
      ..._withSidecar,
      TreeNode(path: 'trip/album.md', sha: 'SM', type: 'blob', size: 9),
    ];
    const sidecar = '''
{
  "version": 1,
  "album": "trip",
  "pad": 4,
  "next": 12,
  "summary": "Old summary",
  "credits": "Photos by G",
  "items": {
    "0001.jpg": "6am start"
  }
}
''';

    _StubGit describedGit() => _StubGit(described)
      ..blobs['SJ'] = sidecar
      ..blobs['SM'] = 'Long day\n';

    test('writes both files in one commit, keeping the captions', () async {
      final git = describedGit();

      final outcome = await _service(git).setDescription(
        config: config,
        album: album,
        summary: ' Coast ride ',
        note: 'Who came: everyone',
      );

      expect(outcome, isA<CommitApplied>());
      expect(git.commits, 1);
      expect(git.committed!.map((e) => e.path).toSet(), {
        'trip/album.json',
        'trip/album.md',
      });
      final json =
          jsonDecode(git.blobs[_entryFor(git.committed, 'trip/album.json')!.sha]!)
              as Map;
      expect(json['summary'], 'Coast ride');
      expect(json['next'], 12);
      expect(json['pad'], 4);
      expect(json['credits'], 'Photos by G');
      expect(json['items'], {'0001.jpg': '6am start'});
      expect(
        git.blobs[_entryFor(git.committed, 'trip/album.md')!.sha],
        'Who came: everyone\n',
      );
    });

    test('an empty note deletes album.md', () async {
      final git = describedGit();

      await _service(git).setDescription(
        config: config,
        album: album,
        summary: 'Old summary',
        note: '  ',
      );

      // Summary unchanged, so album.json is left alone entirely.
      expect(git.committed!.map((e) => e.path), ['trip/album.md']);
      expect(git.committed!.single.sha, isNull);
    });

    test('commits nothing when neither changed', () async {
      final git = describedGit();

      final outcome = await _service(git).setDescription(
        config: config,
        album: album,
        summary: 'Old summary',
        note: 'Long day',
      );

      expect(outcome, isA<CommitNoop>());
      expect(git.committed, isNull);
    });

    test('a summary for an album with no album.json writes a fresh one', () async {
      final git = _StubGit(const [
        TreeNode(path: 'trip', sha: 'TREE1', type: 'tree'),
        TreeNode(path: 'trip/0001.jpg', sha: 'B1', type: 'blob', size: 1000),
      ]);

      await _service(git).setDescription(
        config: config,
        album: album,
        summary: 'Coast ride',
        note: '',
      );

      expect(git.committed!.map((e) => e.path), ['trip/album.json']);
      expect((jsonDecode(git.written.single) as Map)['summary'], 'Coast ride');
    });
  });
}
