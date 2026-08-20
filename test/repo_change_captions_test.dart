import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:glickr/core/models/album.dart';
import 'package:glickr/core/models/app_config.dart';
import 'package:glickr/core/models/github_repo.dart';
import 'package:glickr/core/models/github_user.dart';
import 'package:glickr/core/models/media_item.dart';
import 'package:glickr/core/providers/auth_provider.dart';
import 'package:glickr/core/providers/config_provider.dart';
import 'package:glickr/core/providers/pending_captions_provider.dart';
import 'package:glickr/core/providers/services_provider.dart';
import 'package:glickr/core/services/album_repository.dart';
import 'package:glickr/core/services/git_data_service.dart';
import 'package:glickr/core/services/github_rate_gate.dart';
import 'package:glickr/core/services/repo_repository.dart';
import 'package:glickr/core/services/upload_queue_service.dart';
import 'package:glickr/core/theme/app_theme.dart';
import 'package:glickr/features/config/presentation/repo_setup_screen.dart';

/// Changing repository has to take unsaved captions with it.
///
/// A staged caption is filed under an album FOLDER, and glickr names files by
/// the same 0001.jpg convention in every repo - so folders and filenames
/// collide across repos by construction. Left behind, one repo's unsaved
/// caption is shown over another repo's photo and committed into its
/// album.json on Save. The albums cache and the upload queue were already
/// being cleared here; the captions box was the one that was not.
GitDataService _git() => GitDataService(dio: Dio(), gate: GitHubRateGate());

class _StubRepository extends AlbumRepository {
  _StubRepository() : super(git: _git());

  @override
  Future<AlbumSyncResult> sync(
    AppConfig config, {
    String? cachedEtag,
    List<Album> cachedAlbums = const [],
    void Function(int done, int total)? onProgress,
  }) async => throw StateError('a widget test must not hit the network');
}

/// The real queue clear() deletes its staging directories, which goes through
/// path_provider - a platform channel that answers on the real event loop, and
/// so never answers inside a widget test's fake async. Boxes only here; the
/// queue is not what is under test, it is just one of the things a repo change
/// clears on its way to the captions.
class _BoxOnlyQueueService extends UploadQueueService {
  _BoxOnlyQueueService()
    : super(
        batches: Hive.box<Map>('upload_batches'),
        items: Hive.box<Map>('upload_items'),
      );

  @override
  Future<void> clear() async {
    await Hive.box<Map>('upload_items').clear();
    await Hive.box<Map>('upload_batches').clear();
  }
}

class _FakeRepoRepository implements RepoRepository {
  _FakeRepoRepository(this.repos);

  final List<GitHubRepo> repos;

  @override
  Future<List<GitHubRepo>> listWritableRepos({int maxPages = 3}) async => repos;

  @override
  Future<RepoCheckResult> inspect({
    required String owner,
    required String name,
    required String branch,
    String albumRoot = '',
  }) async => const RepoCheckResult(status: RepoCheckStatus.empty);

  @override
  Future<GitHubRepo?> findRepo(String owner, String name) async => null;

  @override
  Future<GitHubRepo> createAlbumRepo({
    required String name,
    String description = '',
  }) => throw UnimplementedError();
}

class _SignedInNotifier extends AuthNotifier {
  @override
  AuthState build() =>
      const AuthAuthenticated(GitHubUser(id: 1, login: 'gapp', avatarUrl: ''));
}

final _otherRepo = GitHubRepo(
  id: 2,
  name: 'album',
  fullName: 'gapp/album',
  ownerLogin: 'gapp',
  isPrivate: false,
  defaultBranch: 'main',
  htmlUrl: 'https://github.com/gapp/album',
  pushedAt: DateTime(2026, 8, 1),
);

Album _album() => Album(
  folder: 'travel',
  items: [const MediaItem(name: '0001.jpg', blobSha: 'a')],
);

void main() {
  setUpAll(() {
    Hive.registerAdapter(AppConfigAdapter());
    Hive.registerAdapter(MediaItemAdapter());
    Hive.registerAdapter(AlbumAdapter());
  });

  setUp(() async {
    await Hive.openBox<AppConfig>('app_config', bytes: Uint8List(0));
    await Hive.openBox<Album>('albums_box', bytes: Uint8List(0));
    await Hive.openBox<Map>('sync_state', bytes: Uint8List(0));
    await Hive.openBox<Map>('pending_captions', bytes: Uint8List(0));
    await Hive.openBox<Map>('upload_batches', bytes: Uint8List(0));
    await Hive.openBox<Map>('upload_items', bytes: Uint8List(0));
  });

  tearDown(Hive.close);

  testWidgets('changing repository clears staged captions', (tester) async {
    final container = ProviderContainer(
      overrides: [
        repoRepositoryProvider.overrideWithValue(
          _FakeRepoRepository([_otherRepo]),
        ),
        albumRepositoryProvider.overrideWithValue(_StubRepository()),
        uploadQueueServiceProvider.overrideWithValue(_BoxOnlyQueueService()),
        authNotifierProvider.overrideWith(_SignedInNotifier.new),
      ],
    );
    addTearDown(container.dispose);

    // Already pointed at one repo, with a caption typed and not yet saved.
    await container
        .read(configNotifierProvider.notifier)
        .save(AppConfig(repoOwner: 'gapp', repoName: 'photos', branch: 'main'));
    await container
        .read(pendingCaptionsNotifierProvider.notifier)
        .stage(_album(), '0001.jpg', 'Bibimbap in Seoul');
    expect(container.read(pendingCaptionsNotifierProvider), isNotEmpty);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.lightTheme,
          // Pushed, as Settings and the album list push it: the screen pops
          // itself when it is done, and a root route cannot be popped.
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          const RepoSetupScreen(isOnboarding: false),
                    ),
                  ),
                  child: const Text('Open settings'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();

    // The only repo offered is not the configured one, so it is auto-selected
    // and pressing the button is a repo CHANGE.
    expect(find.text('gapp/album'), findsWidgets);
    await tester.tap(find.widgetWithText(ElevatedButton, 'Use this repo'));
    await tester.pumpAndSettle();

    expect(find.text('Change repository?'), findsOneWidget);
    // Named in the warning, rather than discovered missing afterwards.
    expect(find.textContaining("One caption you haven't saved"), findsOneWidget);

    // Scoped to the dialog: the screen behind it has its own Change button,
    // for the albums folder.
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(TextButton, 'Change'),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      container.read(pendingCaptionsNotifierProvider),
      isEmpty,
      reason: "the previous repo's unsaved captions would be shown over, and "
          "committed into, the new repo's albums",
    );
    // Off the device too, or the next launch reads them straight back in.
    expect(Hive.box<Map>('pending_captions').isEmpty, isTrue);
    expect(container.read(configNotifierProvider)?.repoName, 'album');
  });
}
