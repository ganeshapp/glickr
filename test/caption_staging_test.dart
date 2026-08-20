import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:glickr/core/models/album.dart';
import 'package:glickr/core/models/app_config.dart';
import 'package:glickr/core/models/media_item.dart';
import 'package:glickr/core/providers/albums_provider.dart';
import 'package:glickr/core/providers/config_provider.dart';
import 'package:glickr/core/providers/pending_captions_provider.dart';
import 'package:glickr/core/providers/services_provider.dart';
import 'package:glickr/core/services/album_repository.dart';
import 'package:glickr/core/services/album_write_service.dart';
import 'package:glickr/core/services/commit_service.dart';
import 'package:glickr/core/services/git_data_service.dart';
import 'package:glickr/core/services/github_rate_gate.dart';
import 'package:glickr/core/services/media_cache_service.dart';
import 'package:glickr/core/theme/app_theme.dart';
import 'package:glickr/features/viewer/presentation/photo_viewer_screen.dart';

/// Captioning is the one thing a user does twenty times in a row, and every
/// commit to the album repo triggers the site's build. So the viewer - the ONLY
/// place in the app where a caption can be typed - must not commit; it stages,
/// and one explicit save sends the lot.
///
/// This drives the real screen rather than the notifier, because the notifier
/// already worked: what shipped broken was the wiring. Nothing called stage(),
/// so the whole staging path was dead code and every caption went out as its
/// own commit.
GitDataService _git() => GitDataService(dio: Dio(), gate: GitHubRateGate());

/// Counts caption commits. Zero is the assertion the viewer has to satisfy
/// while the user is typing; exactly one is what pressing save costs.
///
/// [gate] holds the commit open, the way a real one hangs for a couple of
/// seconds against GitHub. The user does not stop captioning for it.
class _RecordingWriteService extends AlbumWriteService {
  _RecordingWriteService({this.gate})
    : super(git: _git(), commits: CommitService(git: _git()));

  final Future<void>? gate;
  final List<Map<String, String?>> calls = [];

  @override
  Future<CommitOutcome> setCaptions({
    required AppConfig config,
    required Album album,
    required Map<String, String?> captions,
  }) async {
    calls.add(Map<String, String?>.from(captions));
    if (gate != null) await gate;
    return const CommitNoop('sha');
  }
}

/// Offline stand-in for the sync a flush triggers on success.
///
/// [gate] holds one sync open - by default the second, which is the one a save
/// fires once its commit has landed. The screen must not go back to showing
/// the old caption for the length of it.
class _StubRepository extends AlbumRepository {
  _StubRepository({List<Album>? before, List<Album>? after, this.gate})
    : before = before ?? [_album()],
      after = after ?? before ?? [_album()],
      super(git: _git());

  /// What the repo holds when the app starts, and what it holds after the
  /// save - a sync that came back with the pre-save captions would hide the
  /// very revert these tests are looking for.
  final List<Album> before;
  final List<Album> after;
  final Future<void>? gate;
  int _calls = 0;

  @override
  Future<AlbumSyncResult> sync(
    AppConfig config, {
    String? cachedEtag,
    List<Album> cachedAlbums = const [],
    void Function(int done, int total)? onProgress,
  }) async {
    final call = _calls++;
    // The first sync is the app opening; the second is the one a save fires
    // once its commit has landed, and that is the one worth holding open.
    if (call == 1 && gate != null) await gate;
    return AlbumSyncResult(
      albums: call == 0 ? before : after,
      commitSha: 'commit',
      treeSha: 'tree',
      repoBytes: 1024,
      etag: 'W/"1"',
    );
  }
}

/// A cache with nothing in it and no way to fill it, so the viewer renders its
/// "couldn't load this photo" state instead of reaching for the network.
class _EmptyCacheManager implements CacheManager {
  @override
  Future<FileInfo?> getFileFromCache(
    String key, {
    bool ignoreMemCache = false,
  }) async => null;

  @override
  Future<FileInfo> downloadFile(
    String url, {
    String? key,
    Map<String, String>? authHeaders,
    bool force = false,
  }) async => throw StateError('a widget test must not hit the network');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

Album _album() => Album(
  folder: 'cycling_trip',
  items: [
    const MediaItem(name: '0001.jpg', blobSha: 'a'),
    const MediaItem(name: '0002.jpg', blobSha: 'b'),
  ],
);

/// The album as the repo holds it once [captions] are committed - what the
/// sync after a successful save comes back with.
Album _albumWith(Map<String, String> captions) {
  final base = _album();
  return base.copyWith(
    items: [
      for (final item in base.items)
        captions.containsKey(item.name)
            ? item.copyWith(caption: captions[item.name])
            : item,
    ],
  );
}

void main() {
  setUpAll(() {
    Hive.registerAdapter(AppConfigAdapter());
    Hive.registerAdapter(MediaItemAdapter());
    Hive.registerAdapter(AlbumAdapter());
  });

  setUp(() async {
    // Memory-backed boxes: a file-backed one completes its writes on the real
    // event loop, which the fake async a widget test runs in never reaches.
    await Hive.openBox<AppConfig>('app_config', bytes: Uint8List(0));
    await Hive.openBox<Album>('albums_box', bytes: Uint8List(0));
    await Hive.openBox<Map>('sync_state', bytes: Uint8List(0));
    await Hive.openBox<Map>('pending_captions', bytes: Uint8List(0));
  });

  // Closing drops the boxes from the registry, so each test opens its own
  // empty set. A memory box has no disk to delete.
  tearDown(Hive.close);

  Future<ProviderContainer> boot(
    _RecordingWriteService writes, {
    _StubRepository? repository,
  }) async {
    await Hive.box<Album>('albums_box').put('cycling_trip', _album());

    final container = ProviderContainer(
      overrides: [
        albumWriteServiceProvider.overrideWithValue(writes),
        albumRepositoryProvider.overrideWithValue(
          repository ?? _StubRepository(),
        ),
        mediaCacheServiceProvider.overrideWithValue(
          MediaCacheService(manager: _EmptyCacheManager()),
        ),
      ],
    );
    addTearDown(container.dispose);
    // A configured repo, so nothing below can pass merely because the app had
    // nowhere to commit to.
    await container
        .read(configNotifierProvider.notifier)
        .save(AppConfig(repoOwner: 'gapp', repoName: 'photos', branch: 'main'));
    return container;
  }

  Future<Album> openViewer(
    WidgetTester tester,
    ProviderContainer container,
  ) async {
    final album = container.read(albumsNotifierProvider).albums.firstWhere(
      (a) => a.folder == 'cycling_trip',
      orElse: _album,
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: PhotoViewerScreen(album: album, initialIndex: 0),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return album;
  }

  /// Pump long enough for a sheet to open or close and for pending futures to
  /// land, WITHOUT settling.
  ///
  /// A save in flight runs a progress indicator in the top bar, and settling
  /// on an animation that never ends times out - so anything asserting about
  /// the middle of a save has to advance the clock by hand.
  Future<void> pumpThrough(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Type a caption the way the user does: tap the bar reading [label], type,
  /// press the sheet's button.
  Future<void> caption(
    WidgetTester tester,
    String label,
    String text,
  ) async {
    await tester.tap(find.text(label));
    await pumpThrough(tester);
    await tester.enterText(find.byType(TextField), text);
    await pumpThrough(tester);
    // By type, not by label: the button has to work whatever it is called.
    await tester.tap(find.byType(ElevatedButton));
    await pumpThrough(tester);
  }

  testWidgets('typing a caption in the viewer commits nothing', (tester) async {
    final writes = _RecordingWriteService();
    final container = await boot(writes);
    await openViewer(tester, container);

    await tester.tap(find.text('Add a caption'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Summit push');
    // By type, not by label: the button has to be pressable whatever it is
    // called, or this test stops being about commits.
    await tester.tap(find.byType(ElevatedButton));
    await tester.pumpAndSettle();

    expect(
      writes.calls,
      isEmpty,
      reason:
          'a caption edit must stage on the device - one commit per caption '
          'is one site build per caption',
    );

    // ...and the typing has to be on screen straight away. Staging that leaves
    // the old caption showing looks exactly like typing that was thrown away.
    expect(find.text('Summit push'), findsOneWidget);
    expect(find.text('1 unsaved'), findsOneWidget);
  });

  testWidgets('the unsaved pill sends every staged caption as one commit', (
    tester,
  ) async {
    final writes = _RecordingWriteService();
    final container = await boot(writes);
    final album = _album();
    // One caption already waiting, as if it were typed on an earlier photo.
    await container
        .read(pendingCaptionsNotifierProvider.notifier)
        .stage(album, '0002.jpg', 'Puncture');

    await openViewer(tester, container);
    expect(find.text('1 unsaved'), findsOneWidget);

    await tester.tap(find.text('Add a caption'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Summit push');
    await tester.tap(find.byType(ElevatedButton));
    await tester.pumpAndSettle();

    await tester.tap(find.text('2 unsaved'));
    await tester.pumpAndSettle();

    expect(writes.calls.length, 1, reason: 'two captions, one site build');
    expect(writes.calls.single, {
      '0001.jpg': 'Summit push',
      '0002.jpg': 'Puncture',
    });
    // The pill is the only thing telling the user there is unsent work, so it
    // has to go the moment there is none.
    expect(find.textContaining('unsaved'), findsNothing);
    expect(find.text('2 captions saved.'), findsOneWidget);

    // Let the snackbar time out rather than leaving its timer pending.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('there is no pill until something is staged', (tester) async {
    final writes = _RecordingWriteService();
    final container = await boot(writes);
    await openViewer(tester, container);

    // Chrome over a full-bleed photo earns its pixels. Nothing staged, nothing
    // shown.
    expect(find.textContaining('unsaved'), findsNothing);
  });

  testWidgets('a caption typed while the save is in flight is not eaten', (
    tester,
  ) async {
    // A commit takes seconds and the caption bar stays live through it, so
    // this is an ordinary thing to do rather than a race a user has to hunt
    // for. Clearing the whole folder when the commit landed - rather than the
    // entries that went out - erased this typing from the screen, from the
    // device and from GitHub, under a "Caption saved." snackbar.
    final commit = Completer<void>();
    final writes = _RecordingWriteService(gate: commit.future);
    final container = await boot(
      writes,
      repository: _StubRepository(
        after: [
          _albumWith({'0001.jpg': 'Summit push'}),
        ],
      ),
    );
    await openViewer(tester, container);

    await caption(tester, 'Add a caption', 'Summit push');
    expect(find.text('1 unsaved'), findsOneWidget);

    await tester.tap(find.text('1 unsaved'));
    await pumpThrough(tester);
    expect(writes.calls.single, {'0001.jpg': 'Summit push'});

    // Mid-commit second thoughts, typed into a bar the app leaves tappable on
    // purpose: freezing the primary interaction for the length of a network
    // round trip would be its own bug.
    await caption(tester, 'Summit push', 'Summit push, 6am');
    expect(find.text('Summit push, 6am'), findsOneWidget);

    commit.complete();
    await pumpThrough(tester);

    // The commit that landed carried the older text, so the newer one is
    // still unsent work - on screen, and countable.
    expect(find.text('Summit push, 6am'), findsOneWidget);
    expect(find.text('1 unsaved'), findsOneWidget);
    expect(writes.calls.length, 1);

    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the saved caption stays on screen through the sync', (
    tester,
  ) async {
    // The commit has landed by then, so the caption IS saved. Dropping the
    // staged copy before the album knew about it sent the bar back to the old
    // text - or to "Add a caption" - for the length of a full tree read, which
    // is exactly what "my typing vanished" looks like.
    final syncing = Completer<void>();
    final writes = _RecordingWriteService();
    final container = await boot(
      writes,
      repository: _StubRepository(
        after: [
          _albumWith({'0001.jpg': 'Summit push'}),
        ],
        gate: syncing.future,
      ),
    );
    await openViewer(tester, container);

    await caption(tester, 'Add a caption', 'Summit push');
    await tester.tap(find.text('1 unsaved'));
    await pumpThrough(tester);

    // Committed, staging dropped, sync still out. Nothing on screen may move.
    expect(writes.calls.single, {'0001.jpg': 'Summit push'});
    expect(find.textContaining('unsaved'), findsNothing);
    expect(
      find.text('Summit push'),
      findsOneWidget,
      reason: 'the caption reverted while the app confirmed the save',
    );
    expect(find.text('Add a caption'), findsNothing);

    syncing.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('Summit push'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
  });
}
