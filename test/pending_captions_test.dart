import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:glickr/core/models/album.dart';
import 'package:glickr/core/models/app_config.dart';
import 'package:glickr/core/models/media_item.dart';
import 'package:glickr/core/providers/album_actions_provider.dart';
import 'package:glickr/core/providers/albums_provider.dart';
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
///
/// [gate], when set, holds the commit open the way a real one is held open for
/// a couple of seconds against GitHub. That window is not academic: the user
/// goes on captioning through it, and what happens to that typing when the
/// commit lands is the whole subject of half this file.
class _RecordingWriteService extends AlbumWriteService {
  _RecordingWriteService({this.fails = false, this.gate})
    : super(git: _git(), commits: CommitService(git: _git()));

  final bool fails;
  final Future<void>? gate;
  final List<Map<String, String?>> calls = [];
  final List<String> renames = [];
  final List<String> deletes = [];

  @override
  Future<CommitOutcome> setCaptions({
    required AppConfig config,
    required Album album,
    required Map<String, String?> captions,
  }) async {
    calls.add(Map<String, String?>.from(captions));
    if (gate != null) await gate;
    if (fails) throw Exception('the network blipped');
    return const CommitNoop('sha');
  }

  @override
  Future<CommitOutcome> renameAlbum({
    required AppConfig config,
    required Album album,
    required String newFolder,
  }) async {
    renames.add('${album.folder} -> $newFolder');
    return const CommitNoop('sha');
  }

  @override
  Future<CommitOutcome> deleteAlbum({
    required AppConfig config,
    required Album album,
  }) async {
    deletes.add(album.folder);
    return const CommitNoop('sha');
  }
}

/// Offline stand-in for the sync a flush triggers on success.
///
/// [gate] holds the sync open, which is the OTHER window that matters: a
/// caption must not visibly revert to its old text while the app is off
/// confirming the commit that saved it.
class _StubRepository extends AlbumRepository {
  _StubRepository(this.albums, {this.gate, this.fails = false})
    : super(git: _git());

  final List<Album> albums;
  final Future<void>? gate;
  final bool fails;

  @override
  Future<AlbumSyncResult> sync(
    AppConfig config, {
    String? cachedEtag,
    List<Album> cachedAlbums = const [],
    void Function(int done, int total)? onProgress,
  }) async {
    if (gate != null) await gate;
    if (fails) throw Exception('GitHub is unreachable');
    return AlbumSyncResult(
      albums: albums,
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

/// The album as the repo holds it once [captions] have been committed - what a
/// sync after a successful save comes back with.
Album _albumWith(Map<String, String?> captions) {
  final base = _album();
  return base.copyWith(
    items: [
      for (final item in base.items)
        if (!captions.containsKey(item.name))
          item
        else if (captions[item.name] == null)
          item.copyWith(clearCaption: true)
        else
          item.copyWith(caption: captions[item.name]),
    ],
  );
}

/// Let every already-scheduled future run, [until] is satisfied, or the bound
/// is reached.
///
/// This was a fixed four turns, which was enough on an idle machine and not
/// enough under the full suite: `PendingCaptionsNotifier._write` awaits
/// `box.put`, which is real file I/O against a temp Hive directory, and the
/// flush chain (commit -> adopt into the album -> drop the staged copy ->
/// notify) needs however many event-loop turns that I/O takes rather than a
/// number picked in advance. It passed alone every time and failed about one
/// full-suite run in three. Waiting on the CONDITION is what makes it
/// deterministic; the turn count is only a backstop so a genuine regression
/// still fails instead of hanging.
Future<void> settle({bool Function()? until}) async {
  for (var i = 0; i < 200; i++) {
    await Future<void>.delayed(Duration.zero);
    if (until != null && until()) return;
    // Microtask turns alone do not let real file I/O land.
    if (i % 20 == 19) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }
}

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

  /// A booted app with [album] already in the album list, because a caption is
  /// always an edit to something the user is looking at.
  Future<ProviderContainer> boot(
    _RecordingWriteService writes, {
    AlbumRepository? repository,
    Album? cached,
  }) async {
    final seed = cached ?? _album();
    await Hive.box<Album>('albums_box').put(seed.folder, seed);

    final container = ProviderContainer(
      overrides: [
        albumWriteServiceProvider.overrideWithValue(writes),
        albumRepositoryProvider.overrideWithValue(
          repository ?? _StubRepository([_album()]),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container
        .read(configNotifierProvider.notifier)
        .save(AppConfig(repoOwner: 'gapp', repoName: 'photos', branch: 'main'));
    // Reading the list also arms its first sync. Let it land here, so a test
    // asserting on what is on screen after a save is not racing it.
    container.read(albumsNotifierProvider);
    await settle();
    return container;
  }

  /// The album as the app currently holds it - the committed captions, after
  /// whatever a flush has written back into the list.
  Album live(ProviderContainer container) => container
      .read(albumsNotifierProvider)
      .albums
      .firstWhere((a) => a.folder == 'cycling_trip');

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

    test('a deleted photo takes its staged caption with it', () async {
      // Left behind, it could never be saved onto anything: it would inflate
      // the unsaved count for a photo the user cannot open.
      final container = await boot(_RecordingWriteService());
      final album = _album();
      final captions = container.read(
        pendingCaptionsNotifierProvider.notifier,
      );

      await captions.stage(album, '0001.jpg', '6am start');
      await captions.stage(album, '0002.jpg', 'Puncture');
      await captions.forget(album.folder, {'0001.jpg'});

      expect(captions.forAlbum(album.folder), {'0002.jpg': 'Puncture'});
    });

    test('staged captions follow the photos through a cover swap', () async {
      // Setting a cover swaps two filenames, and the commit swaps their
      // committed captions with them because a caption describes a picture.
      // Unsaved typing has to travel the same way or Save puts it on the
      // wrong photo.
      final container = await boot(_RecordingWriteService());
      final album = _album();
      final captions = container.read(
        pendingCaptionsNotifierProvider.notifier,
      );

      await captions.stage(album, '0002.jpg', 'Make this the cover');
      await captions.swapFiles(album.folder, '0001.jpg', '0002.jpg');

      expect(captions.forAlbum(album.folder), {
        '0001.jpg': 'Make this the cover',
      });
    });
  });

  group('a save that is still in flight', () {
    test('keeps a caption typed while the commit was in the air', () async {
      // A commit takes seconds against GitHub and the user goes on captioning
      // through it. Clearing the whole folder afterwards - rather than the
      // entries that actually went out - threw that typing away: never
      // committed, erased from the device, and reverted on screen under a
      // "Caption saved." snackbar.
      final gate = Completer<void>();
      final writes = _RecordingWriteService(gate: gate.future);
      final container = await boot(
        writes,
        repository: _StubRepository([
          _albumWith({'0001.jpg': 'Summit push'}),
        ]),
      );
      final album = _album();
      final captions = container.read(
        pendingCaptionsNotifierProvider.notifier,
      );

      await captions.stage(album, '0001.jpg', 'Summit push');
      final saving = captions.flush(album);
      await settle();
      expect(writes.calls.single, {'0001.jpg': 'Summit push'});

      // Mid-commit: the user swipes on and captions another photo.
      await captions.stage(album, '0002.jpg', 'Puncture');
      expect(captions.countFor(album.folder), 2);

      gate.complete();
      expect((await saving).ok, isTrue);
      await settle();

      // The one that was sent is saved and gone; the one typed after it is
      // still waiting, still on screen, and still the only copy that exists.
      expect(captions.forAlbum(album.folder), {'0002.jpg': 'Puncture'});
      expect(captions.captionFor(live(container), '0002.jpg'), 'Puncture');
      expect(writes.calls.length, 1, reason: 'still one commit, one build');
    });

    test('re-editing a caption mid-commit leaves the new text unsaved', () async {
      final gate = Completer<void>();
      final writes = _RecordingWriteService(gate: gate.future);
      final container = await boot(
        writes,
        repository: _StubRepository([
          _albumWith({'0001.jpg': 'Summit push'}),
        ]),
      );
      final album = _album();
      final captions = container.read(
        pendingCaptionsNotifierProvider.notifier,
      );

      await captions.stage(album, '0001.jpg', 'Summit push');
      final saving = captions.flush(album);
      await settle();

      // Same file, second thoughts. This edit is NOT in the commit that is in
      // the air, so it has to survive it as unsent work.
      await captions.stage(album, '0001.jpg', 'Summit push, 6am');
      gate.complete();
      await saving;
      await settle();

      expect(captions.forAlbum(album.folder), {'0001.jpg': 'Summit push, 6am'});
      expect(
        captions.captionFor(live(container), '0001.jpg'),
        'Summit push, 6am',
      );
    });

    test('clearing a caption mid-commit is still an edit', () async {
      // The subtle one: "typed back to what is already committed" is not an
      // edit, but what is "already committed" changes the moment a commit is
      // in the air. Measured against the stale local album, clearing a caption
      // during the commit that sets it looks like a no-op and is dropped -
      // and the text the user just deleted comes back.
      final gate = Completer<void>();
      final writes = _RecordingWriteService(gate: gate.future);
      final container = await boot(
        writes,
        repository: _StubRepository([
          _albumWith({'0001.jpg': 'Summit push'}),
        ]),
      );
      final album = _album();
      final captions = container.read(
        pendingCaptionsNotifierProvider.notifier,
      );

      await captions.stage(album, '0001.jpg', 'Summit push');
      final saving = captions.flush(album);
      await settle();

      await captions.stage(album, '0001.jpg', '');
      gate.complete();
      await saving;
      await settle();

      expect(captions.forAlbum(album.folder), {'0001.jpg': null});
      expect(captions.captionFor(live(container), '0001.jpg'), '');
    });
  });

  group('a save that has just landed', () {
    test('shows the saved text before the sync that confirms it', () async {
      // The commit has landed, so the caption IS saved. Clearing the staged
      // copy before the album knows about it left every reader falling back to
      // the old committed value for the length of a full tree read - the user
      // watching the text they just saved revert is indistinguishable from the
      // save having failed.
      final gate = Completer<void>();
      final writes = _RecordingWriteService();
      final container = await boot(
        writes,
        repository: _StubRepository([
          _albumWith({'0001.jpg': 'Summit push'}),
        ], gate: gate.future),
      );
      final album = _album();
      final captions = container.read(
        pendingCaptionsNotifierProvider.notifier,
      );

      await captions.stage(album, '0001.jpg', 'Summit push');
      final saving = captions.flush(album);
      await settle();

      // Mid-sync, with nothing staged any more: the album itself has to carry
      // the caption by now.
      expect(captions.countFor(album.folder), 0);
      expect(captions.captionFor(live(container), '0001.jpg'), 'Summit push');

      gate.complete();
      await saving;
      await settle();
      expect(captions.captionFor(live(container), '0001.jpg'), 'Summit push');
    });

    test('reports success and keeps the text when the sync fails', () async {
      // The sync is confirmation, not the save. Reporting its failure as a
      // failed save sends the user back to retype and re-commit - a second
      // site build for a caption that is already published.
      final writes = _RecordingWriteService();
      final container = await boot(
        writes,
        repository: _StubRepository(const [], fails: true),
      );
      final album = _album();
      final captions = container.read(
        pendingCaptionsNotifierProvider.notifier,
      );

      await captions.stage(album, '0001.jpg', 'Summit push');
      final result = await captions.flush(album);
      await settle();

      expect(result.ok, isTrue);
      expect(writes.calls.length, 1);
      expect(captions.countFor(album.folder), 0);
      expect(captions.captionFor(live(container), '0001.jpg'), 'Summit push');
    });
  });

  group('AlbumActions keeps staged captions in step', () {
    test('a rename takes them to the new folder', () async {
      // Filed under the folder name. Left on the old one they are unreachable:
      // no screen shows them, so they can never be saved or discarded, while
      // they still inflate the sign-out warning and wait to reattach to any
      // future album that takes the name back.
      // The stub's sync keeps returning the album under its OLD folder, which
      // is exactly why the rename must not be measured by the album list: what
      // is being asserted is where the unsaved captions ended up.
      final writes = _RecordingWriteService();
      final container = await boot(writes);
      final captions = container.read(
        pendingCaptionsNotifierProvider.notifier,
      );
      final album = _album();

      await captions.stage(album, '0001.jpg', '6am start');
      await captions.stage(album, '0002.jpg', 'Puncture');

      final result = await container
          .read(albumActionsProvider.notifier)
          .renameAlbum(album, 'Korea 2026');
      await settle();

      expect(result.ok, isTrue);
      expect(writes.renames, ['cycling_trip -> korea_2026']);
      expect(captions.forAlbum('cycling_trip'), isEmpty);
      expect(captions.forAlbum('korea_2026'), {
        '0001.jpg': '6am start',
        '0002.jpg': 'Puncture',
      });
      // ...and reachable again: the detail screen for the new folder counts
      // them, so they can be saved or thrown away like any other.
      expect(captions.countFor('korea_2026'), 2);
      // Nothing was committed on the way past. The user left them unsaved on
      // purpose, and a rename is not permission to publish them.
      expect(writes.calls, isEmpty);
    });

    test('deleting the album takes them with it', () async {
      // Deleting the folder deletes album.json, so a recreated album of the
      // same name numbers from 0001.jpg again - staged captions left behind
      // would surface as the captions of unrelated new photos.
      final writes = _RecordingWriteService();
      final container = await boot(
        writes,
        repository: _StubRepository(const []),
      );
      final captions = container.read(
        pendingCaptionsNotifierProvider.notifier,
      );
      final album = _album();

      await captions.stage(album, '0001.jpg', '6am start');
      await captions.stage(album, '0002.jpg', 'Puncture');

      final result = await container
          .read(albumActionsProvider.notifier)
          .deleteAlbum(album);
      await settle();

      expect(result.ok, isTrue);
      expect(writes.deletes, ['cycling_trip']);
      expect(captions.forAlbum('cycling_trip'), isEmpty);
      // Off the device too, or the next launch reads them back in.
      expect(Hive.box<Map>('pending_captions').get('cycling_trip'), isNull);
    });
  });
}
