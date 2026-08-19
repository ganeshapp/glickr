import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:glickr/core/models/album.dart';
import 'package:glickr/core/models/app_config.dart';
import 'package:glickr/core/models/media_item.dart';
import 'package:glickr/core/providers/albums_provider.dart';
import 'package:glickr/core/providers/config_provider.dart';
import 'package:glickr/core/providers/services_provider.dart';
import 'package:glickr/core/services/album_repository.dart';
import 'package:glickr/core/services/git_data_service.dart';
import 'package:glickr/core/services/github_rate_gate.dart';

/// An [AlbumRepository] that never touches the network, counts its calls and
/// can be held open so a test can act while a sync is mid-flight.
class _RecordingRepository extends AlbumRepository {
  _RecordingRepository()
    : super(git: GitDataService(dio: Dio(), gate: GitHubRateGate()));

  int syncCalls = 0;
  final List<String> syncedRepos = [];

  /// When set, [sync] waits on it instead of returning at once.
  Completer<void>? gate;

  @override
  Future<AlbumSyncResult> sync(
    AppConfig config, {
    String? cachedEtag,
    List<Album> cachedAlbums = const [],
    void Function(int done, int total)? onProgress,
  }) async {
    syncCalls++;
    syncedRepos.add('${config.repoOwner}/${config.repoName}');
    final pending = gate;
    if (pending != null) {
      await pending.future;
    } else {
      await Future<void>.delayed(Duration.zero);
    }
    return AlbumSyncResult(
      albums: [Album(folder: '${config.repoName}_trip')],
      commitSha: 'commit-$syncCalls',
      treeSha: 'tree-$syncCalls',
      repoBytes: 1024,
      etag: 'W/"$syncCalls"',
    );
  }
}

AppConfig _config({String repo = 'photos'}) =>
    AppConfig(repoOwner: 'gapp', repoName: repo, branch: 'main');

void main() {
  late Directory hiveDir;

  setUpAll(() {
    hiveDir = Directory.systemTemp.createTempSync('glickr_albums_sync');
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
    await Hive.box<AppConfig>('app_config').clear();
    await Hive.box<Album>('albums_box').clear();
    await Hive.box<Map>('sync_state').clear();
  });

  Future<(ProviderContainer, _RecordingRepository)> boot({
    AppConfig? config,
  }) async {
    final repository = _RecordingRepository();
    final container = ProviderContainer(
      overrides: [albumRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);
    await container
        .read(configNotifierProvider.notifier)
        .save(config ?? _config());
    // A live listener is what makes the notifier behave as it does on screen:
    // dependency changes are flushed instead of waiting for the next read.
    container.listen(albumsNotifierProvider, (_, _) {}, fireImmediately: true);
    return (container, repository);
  }

  group('AlbumsNotifier', () {
    test('a completed sync does not schedule another one', () async {
      final (container, repository) = await boot();

      await pumpEventQueue();
      expect(repository.syncCalls, 1);

      // Writing the sync state is the last thing a sync does. Give the
      // container every chance to react to it; it must not answer with a
      // second network round-trip.
      await pumpEventQueue();
      await pumpEventQueue();
      expect(repository.syncCalls, 1);

      final state = container.read(albumsNotifierProvider);
      expect(state, isA<AlbumsLoaded>());
      expect(state.albums.single.folder, 'photos_trip');
    });

    test('clearCache empties the album box and nothing refills it', () async {
      final (container, repository) = await boot();
      await pumpEventQueue();
      expect(Hive.box<Album>('albums_box').length, 1);

      await container.read(albumsNotifierProvider.notifier).clearCache();
      await pumpEventQueue();
      await pumpEventQueue();

      expect(Hive.box<Album>('albums_box').isEmpty, isTrue);
      expect(Hive.box<Map>('sync_state').isEmpty, isTrue);
      expect(container.read(albumsNotifierProvider), isA<AlbumsInitial>());
      expect(repository.syncCalls, 1);
    });

    test('a sync in flight when the cache is cleared writes nothing', () async {
      final (container, repository) = await boot();
      repository.gate = Completer<void>();
      // Force a refresh that will sit in the network for the whole test.
      unawaited(container.read(albumsNotifierProvider.notifier).refresh());
      await pumpEventQueue();
      expect(repository.syncCalls, 1);

      await container.read(albumsNotifierProvider.notifier).clearCache();
      repository.gate!.complete();
      await pumpEventQueue();

      // The response belongs to the repo the user just walked away from.
      expect(Hive.box<Album>('albums_box').isEmpty, isTrue);
      expect(Hive.box<Map>('sync_state').isEmpty, isTrue);
      expect(container.read(albumsNotifierProvider), isA<AlbumsInitial>());
    });

    test('pointing at another repo syncs the new one', () async {
      final (container, repository) = await boot();
      await pumpEventQueue();
      expect(repository.syncedRepos, ['gapp/photos']);

      await container.read(albumsNotifierProvider.notifier).clearCache();
      await container
          .read(configNotifierProvider.notifier)
          .save(_config(repo: 'travel'));
      await pumpEventQueue();

      expect(repository.syncedRepos, ['gapp/photos', 'gapp/travel']);
      expect(
        container.read(albumsNotifierProvider).albums.single.folder,
        'travel_trip',
      );
    });
  });
}
