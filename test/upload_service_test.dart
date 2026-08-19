import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glickr/core/models/app_config.dart';
import 'package:glickr/core/models/upload_job.dart';
import 'package:glickr/core/services/commit_service.dart';
import 'package:glickr/core/services/git_data_service.dart';
import 'package:glickr/core/services/media_cache_service.dart';
import 'package:glickr/core/services/media_pipeline_service.dart';
import 'package:glickr/core/services/upload_queue_service.dart';
import 'package:glickr/core/services/upload_service.dart';
import 'package:hive/hive.dart';

/// GitHub, reduced to the four facts [UploadService.run] needs from it: the
/// head, the tree, the text of a blob, and whether anything was written.
class _FakeGit implements GitDataService {
  List<TreeNode> nodes = const [];
  String blobText = '{}';

  int createTreeCalls = 0;
  int createCommitCalls = 0;
  int updateRefCalls = 0;
  int createBlobCalls = 0;
  List<TreeEntry> committedEntries = const [];

  @override
  Future<RefInfo> getHead(
    String owner,
    String repo,
    String branch, {
    String? etag,
  }) async => const RefInfo(commitSha: 'head-commit', treeSha: 'head-tree');

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
  Future<String> fetchBlobText(String owner, String repo, String sha) async =>
      blobText;

  @override
  Future<String> createBlob(
    String owner,
    String repo,
    Uint8List bytes, {
    CancelToken? cancelToken,
    void Function(int sent, int total)? onProgress,
  }) async {
    createBlobCalls++;
    return 'sidecar-blob-$createBlobCalls';
  }

  @override
  Future<String> createTree(
    String owner,
    String repo, {
    required String baseTreeSha,
    required List<TreeEntry> entries,
  }) async {
    createTreeCalls++;
    committedEntries = entries;
    return 'new-tree';
  }

  @override
  Future<String> createCommit(
    String owner,
    String repo, {
    required String message,
    required String treeSha,
    required String parentSha,
  }) async {
    createCommitCalls++;
    return 'new-commit';
  }

  @override
  Future<void> updateRef(
    String owner,
    String repo,
    String branch,
    String commitSha,
  ) async {
    updateRefCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubCache implements MediaCacheService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Box<Map> batches;
  late Box<Map> items;
  late UploadQueueService queue;
  late _FakeGit git;
  late UploadService service;

  final config = AppConfig(repoOwner: 'gapp', repoName: 'albums');

  setUp(() async {
    root = await Directory.systemTemp.createTemp('glickr_upload_test');
    // UploadQueueService.stagingDir goes through path_provider.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => root.path,
        );

    Hive.init(root.path);
    batches = await Hive.openBox<Map>(UploadQueueService.batchBoxName);
    items = await Hive.openBox<Map>(UploadQueueService.itemBoxName);
    queue = UploadQueueService(batches: batches, items: items);

    git = _FakeGit();
    service = UploadService(
      git: git,
      commits: CommitService(git: git),
      queue: queue,
      media: MediaPipelineService(),
      cache: _StubCache(),
    );
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    await Hive.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (await root.exists()) await root.delete(recursive: true);
  });

  UploadBatch batchFor(String folder) => UploadBatch(
    id: 'batch-1',
    albumFolder: folder,
    createdAt: DateTime(2026, 1, 1),
  );

  List<UploadItem> uploadedItems(int count) => [
    for (var i = 1; i <= count; i++)
      UploadItem(
        id: 'item-$i',
        batchId: 'batch-1',
        targetName: '${i.toString().padLeft(4, '0')}.jpg',
        state: UploadItemState.blobCreated,
        blobSha: 'photo-sha-$i',
        stagedBytes: 1000,
        caption: 'caption $i',
      ),
  ];

  TreeNode blob(String path, String sha) =>
      TreeNode(path: path, sha: sha, type: 'blob', size: 1000);

  test('a batch whose blobs are already in the tree commits nothing', () async {
    // The ref update landed but its response was lost, so all three items are
    // still recorded as blob_created and the batch is run again.
    final batch = batchFor('cycling_trip');
    await queue.putJob(batch, uploadedItems(3));
    git
      ..nodes = [
        blob('cycling_trip/0001.jpg', 'photo-sha-1'),
        blob('cycling_trip/0002.jpg', 'photo-sha-2'),
        blob('cycling_trip/0003.jpg', 'photo-sha-3'),
        blob('cycling_trip/album.json', 'captions-sha'),
      ]
      ..blobText = jsonEncode({
        'version': 1,
        'album': 'cycling_trip',
        'pad': 4,
        'next': 4,
        'items': {'0001.jpg': 'caption 1'},
      });

    final outcome = await service.run(batch, config: config);

    expect(outcome, isA<UploadCommitted>());
    expect((outcome as UploadCommitted).commitSha, 'head-commit');
    // Nothing was written: no second copy of the photos, no new sidecar.
    expect(git.createTreeCalls, 0);
    expect(git.createCommitCalls, 0);
    expect(git.updateRefCalls, 0);
    expect(git.createBlobCalls, 0);
    // And the batch is gone, so the queue stops re-running it.
    expect(queue.loadBatches(), isEmpty);
    expect(queue.loadItems(batch.id), isEmpty);
  });

  test('a batch whose blobs are new is still committed', () async {
    final batch = batchFor('cycling_trip');
    await queue.putJob(batch, uploadedItems(2));
    git.nodes = [blob('cycling_trip/0001.jpg', 'someone-elses-photo')];

    final outcome = await service.run(batch, config: config);

    expect(outcome, isA<UploadCommitted>());
    expect((outcome as UploadCommitted).commitSha, 'new-commit');
    expect(git.updateRefCalls, 1);
    final paths = git.committedEntries.map((e) => e.path).toList();
    // 0001.jpg is taken by a file this batch did not upload, so both items
    // move past it, and the captions sidecar rides along in the same commit.
    expect(paths, [
      'cycling_trip/0002.jpg',
      'cycling_trip/0003.jpg',
      'cycling_trip/album.json',
    ]);
  });

  test('a batch with nothing preparable burns an attempt', () async {
    final batch = batchFor('cycling_trip');
    await queue.putJob(batch, [
      UploadItem(
        id: 'item-1',
        batchId: 'batch-1',
        targetName: '0001.jpg',
        state: UploadItemState.failed,
        error: 'This item is no longer in your gallery',
      ),
    ]);

    final outcome = await service.run(batch, config: config);

    expect(outcome, isA<UploadFailed>());
    // Without the increment the batch is eligible forever and a manual retry
    // re-enters this same dead end on every pass.
    final stored = queue.loadBatches().single;
    expect(stored.state, UploadBatchState.failed);
    expect(stored.attempts, 1);
  });
}
