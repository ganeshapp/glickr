import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glickr/core/models/album.dart';
import 'package:glickr/core/models/app_config.dart';
import 'package:glickr/core/models/media_item.dart';
import 'package:glickr/core/services/album_repository.dart';
import 'package:glickr/core/services/git_data_service.dart';
import 'package:glickr/core/services/github_rate_gate.dart';

/// A Git Data API that serves one in-memory tree. A blob sha with no entry in
/// [blobs] throws when fetched, standing in for an offline moment or a 5xx.
class _StubGit extends GitDataService {
  _StubGit(this.nodes) : super(dio: Dio(), gate: GitHubRateGate());

  final List<TreeNode> nodes;
  final Map<String, String> blobs = {};
  final List<String> fetched = [];

  @override
  Future<RefInfo> getHead(
    String owner,
    String repo,
    String branch, {
    String? etag,
  }) async => const RefInfo(commitSha: 'c2', treeSha: 't2');

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
    fetched.add(sha);
    final text = blobs[sha];
    if (text == null) throw StateError('blob $sha is unreachable');
    return text;
  }
}

/// The repo after album.json changed: the folder's tree sha moved too.
const _tree = <TreeNode>[
  TreeNode(path: 'trip', sha: 'TREE2', type: 'tree'),
  TreeNode(path: 'trip/0001.jpg', sha: 'B1', type: 'blob', size: 1000),
  TreeNode(path: 'trip/album.json', sha: 'SJ2', type: 'blob', size: 180),
];

const _newCaptions = '{"next":14,"items":{"0001.jpg":"6am start, rewritten"}}';

Album _cachedAlbum() => Album(
  folder: 'trip',
  items: const [MediaItem(name: '0001.jpg', blobSha: 'B1', sizeRaw: 1000)],
  treeSha: 'TREE1',
  captionsSha: 'SJ1',
  captionsJson: '{"next":9,"items":{"0001.jpg":"6am start"}}',
  nextNumber: 9,
);

void main() {
  final config = AppConfig(repoOwner: 'o', repoName: 'r');

  test('a failed sidecar fetch keeps the captions already cached', () async {
    final git = _StubGit(_tree); // SJ2 is not in blobs: the fetch throws
    final repo = AlbumRepository(git: git);

    final result = await repo.sync(config, cachedAlbums: [_cachedAlbum()]);
    final album = result.albums.single;

    expect(album.items.single.caption, '6am start');
    expect(album.nextNumber, 9);
    // The sha must not be adopted for content that never arrived, or every
    // later sync compares equal and the captions stay invisible for good.
    expect(album.captionsSha, 'SJ1');
    expect(album.treeSha, isNull);
  });

  test('the next sync after a failed fetch retries and heals', () async {
    final failing = _StubGit(_tree);
    final repo = AlbumRepository(git: failing);
    final broken = (await repo.sync(
      config,
      cachedAlbums: [_cachedAlbum()],
    )).albums;

    final git = _StubGit(_tree)..blobs['SJ2'] = _newCaptions;
    final healed = (await AlbumRepository(
      git: git,
    ).sync(config, cachedAlbums: broken)).albums.single;

    expect(git.fetched, ['SJ2']);
    expect(healed.items.single.caption, '6am start, rewritten');
    expect(healed.captionsSha, 'SJ2');
    expect(healed.treeSha, 'TREE2');
    expect(healed.nextNumber, 14);
  });

  test('a cache poisoned by an older build is refetched', () async {
    // Pre-fix records hold the current sha with empty text. Sha comparison
    // alone calls that up to date; the unchanged-folder fast path never even
    // looks. Only the missing text gives it away.
    final git = _StubGit(_tree)..blobs['SJ2'] = _newCaptions;
    final poisoned = Album(
      folder: 'trip',
      items: const [MediaItem(name: '0001.jpg', blobSha: 'B1', sizeRaw: 1000)],
      treeSha: 'TREE2',
      captionsSha: 'SJ2',
      captionsJson: '',
    );

    final album = (await AlbumRepository(
      git: git,
    ).sync(config, cachedAlbums: [poisoned])).albums.single;

    expect(album.items.single.caption, '6am start, rewritten');
    expect(album.nextNumber, 14);
  });

  test('an unchanged folder costs no requests at all', () async {
    final git = _StubGit(_tree)..blobs['SJ2'] = _newCaptions;
    final synced = (await AlbumRepository(
      git: git,
    ).sync(config, cachedAlbums: [_cachedAlbum()])).albums;
    git.fetched.clear();

    final again = (await AlbumRepository(
      git: git,
    ).sync(config, cachedAlbums: synced)).albums.single;

    expect(git.fetched, isEmpty);
    expect(again.items.single.caption, '6am start, rewritten');
  });

  test('summary comes from album.json and the note from album.md', () async {
    final git = _StubGit([
      ..._tree,
      const TreeNode(path: 'trip/album.md', sha: 'SM', type: 'blob', size: 30),
    ])
      ..blobs['SJ2'] = '{"summary":"Coast ride","items":{}}'
      ..blobs['SM'] = '---\nlayout: x\n---\nWho came: everyone\n';

    final album = (await AlbumRepository(git: git).sync(config)).albums.single;

    expect(album.summary, 'Coast ride');
    expect(album.note, 'Who came: everyone');
    // The summary rides on the album.json already read for captions.
    expect(git.fetched..sort(), ['SJ2', 'SM']);
  });
}
