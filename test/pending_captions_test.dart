import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:glickr/core/models/album.dart';
import 'package:glickr/core/models/app_config.dart';
import 'package:glickr/core/models/media_item.dart';
import 'package:glickr/core/providers/config_provider.dart';
import 'package:glickr/core/providers/pending_captions_provider.dart';
import 'package:glickr/core/providers/services_provider.dart';
import 'package:glickr/core/services/album_repository.dart';
import 'package:glickr/core/services/album_write_service.dart';
import 'package:glickr/core/services/commit_service.dart';
import 'package:glickr/core/services/git_data_service.dart';
import 'package:glickr/core/services/github_rate_gate.dart';

GitDataService _git() => GitDataService(dio: Dio(), gate: GitHubRateGate());

/// Records every caption commit, so a test can assert on how MANY there were -
/// which is the whole point of staging.
class _RecordingWriteService extends AlbumWriteService {
  _RecordingWriteService({this.fails = false})
    : super(git: _git(), commits: CommitService(git: _git()));

  final bool fails;
  final List<Map<String, String?>> calls = [];

  @override
  Future<CommitOutcome> setCaptions({
    required AppConfig config,
    required Album album,
    required Map<String, String?> captions,
  }) async {
    calls.add(Map<String, String?>.from(captions));
    if (fails) throw Exception('the network blipped');
    return const CommitNoop('sha');
  }
}

/// Offline stand-in for the sync a flush triggers on success.
class _StubRepository extends AlbumRepository {
  _StubRepository(this.album) : super(git: _git());

  final Album album;

  @override
  Future<AlbumSyncResult> sync(
    AppConfig config, {
    String? cachedEtag,
    List<Album> cachedAlbums = const [],
    void Function(int done, int total)? onProgress,
  }) async {
    return AlbumSyncResult(
      albums: [album],
      commitSha: 'commit',
      treeSha: 'tree',
      repoBytes: 1024,
      etag: 'W/"1"',
    );
  }
}

Album _album() => Album(
  folder: 'cycling_trip',
  items: [
    const MediaItem(name: '0001.jpg', blobSha: 'a'),
    const MediaItem(name: '0002.jpg', blobSha: 'b'),
    const MediaItem(name: '0003.jpg', blobSha: 'c', captionRaw: 'Summit'),
  ],
);

void main() {
  late Directory hiveDir;

  setUpAll(() {
    hiveDir = Directory.systemTemp.createTempSync('glickr_pending_captions');
    Hive.init(hiveDir.path);
    Hive.registerAdapter(AppConfigAdapter());
    Hive.registerAdapter(MediaItemAdapter());
    Hive.registerAdapter(AlbumAdapter());
  });

  tearDownAll(() async {
    await Hive.close();
    hiveDir.deleteSync(recursive: true);
  });

  setUp(() async {
    await Hive.openBox<AppConfig>('app_config');
    await Hive.openBox<Album>('albums_box');
    await Hive.openBox<Map>('sync_state');
    await Hive.openBox<Map>('pending_captions');
    await Hive.box<AppConfig>('app_config').clear();
    await Hive.box<Album>('albums_box').clear();
    await Hive.box<Map>('sync_state').clear();
    await Hive.box<Map>('pending_captions').clear();
  });

  Future<ProviderContainer> boot(_RecordingWriteService writes) async {
    final container = ProviderContainer(
      overrides: [
        albumWriteServiceProvider.overrideWithValue(writes),
        albumRepositoryProvider.overrideWithValue(_StubRepository(_album())),
      ],
    );
    addTearDown(container.dispose);
    await container
        .read(configNotifierProvider.notifier)
        .save(AppConfig(repoOwner: 'gapp', repoName: 'photos', branch: 'main'));
    return container;
  }

  group('PendingCaptionsNotifier', () {
    test('several staged edits leave as ONE commit', () async {
      // The bug this exists for: one commit per caption meant one site build
      // per caption.
      final writes = _RecordingWriteService();
      final container = await boot(writes);
      final album = _album();
      final captions = container.read(
        pendingCaptionsNotifierProvider.notifier,
      );

      await captions.stage(album, '0001.jpg', '6am start');
      await captions.stage(album, '0002.jpg', 'Puncture');
      await captions.stage(album, '0003.jpg', ''); // clears a committed one

      expect(captions.countFor(album.folder), 3);
      expect(writes.calls, isEmpty, reason: 'staging must not commit');

      final result = await captions.flush(album);

      expect(result.ok, isTrue);
      expect(writes.calls.length, 1);
      expect(writes.calls.single, {
        '0001.jpg': '6am start',
        '0002.jpg': 'Puncture',
        '0003.jpg': null,
      });
      expect(captions.countFor(album.folder), 0);
    });

    test('a failed flush keeps every staged edit', () async {
      // Losing someone's typing because the network blipped is worse than
      // making them press Save again.
      final writes = _RecordingWriteService(fails: true);
      final container = await boot(writes);
      final album = _album();
      final captions = container.read(
        pendingCaptionsNotifierProvider.notifier,
      );

      await captions.stage(album, '0001.jpg', '6am start');
      await captions.stage(album, '0002.jpg', 'Puncture');

      final result = await captions.flush(album);

      expect(result.ok, isFalse);
      expect(result.error, 'the network blipped');
      expect(captions.forAlbum(album.folder), {
        '0001.jpg': '6am start',
        '0002.jpg': 'Puncture',
      });
      // Still on disk too, so an app kill after a failed save keeps them.
      expect(Hive.box<Map>('pending_captions').get(album.folder), isNotNull);

      // And a retry once the network is back sends all of them, still in one
      // commit.
      expect(writes.calls.length, 1);
    });

    test('typing a caption back to the committed text is not an edit', () async {
      final writes = _RecordingWriteService();
      final container = await boot(writes);
      final album = _album();
      final captions = container.read(
        pendingCaptionsNotifierProvider.notifier,
      );

      await captions.stage(album, '0003.jpg', 'Changed');
      expect(captions.countFor(album.folder), 1);

      await captions.stage(album, '0003.jpg', 'Summit');
      expect(captions.countFor(album.folder), 0);
      expect(captions.captionFor(album, '0003.jpg'), 'Summit');
    });
  });
}
