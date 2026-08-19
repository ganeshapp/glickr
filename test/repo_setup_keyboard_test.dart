import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glickr/core/models/app_config.dart';
import 'package:glickr/core/models/github_repo.dart';
import 'package:glickr/core/models/github_user.dart';
import 'package:glickr/core/providers/auth_provider.dart';
import 'package:glickr/core/providers/config_provider.dart';
import 'package:glickr/core/providers/services_provider.dart';
import 'package:glickr/core/services/repo_repository.dart';
import 'package:glickr/core/theme/app_theme.dart';
import 'package:glickr/features/config/presentation/repo_setup_screen.dart';

/// The repo setup screen with the keyboard up.
///
/// This is the bug the file exists for: the user opened Advanced, tapped Site
/// URL, and the keyboard covered the field completely with no way to scroll it
/// back. The screen had two scroll regions - the repo picker, and a
/// height-bounded panel docked above the button - and neither could lift the
/// Advanced fields out from under the keyboard.
///
/// The keyboard is raised through `tester.view.viewInsets` rather than by
/// wrapping the screen in a `MediaQuery`, for two reasons: an ancestor
/// MediaQuery stops WidgetsApp installing its own, so the Scaffold would never
/// see the inset change, and only the view fires the metrics notification a
/// real keyboard fires.
void main() {
  const screen = Size(390, 844);
  const keyboard = 320.0;

  /// Everything from this y downwards is behind the keyboard.
  final coveredTop = screen.height - keyboard;

  final album = GitHubRepo(
    id: 1,
    name: 'album',
    fullName: 'gapp/album',
    ownerLogin: 'gapp',
    isPrivate: false,
    defaultBranch: 'main',
    htmlUrl: 'https://github.com/gapp/album',
    pushedAt: DateTime(2026, 8, 1),
  );

  Widget harness({List<GitHubRepo> repos = const []}) {
    return ProviderScope(
      overrides: [
        repoRepositoryProvider.overrideWithValue(_FakeRepoRepository(repos)),
        configNotifierProvider.overrideWith(_UnconfiguredNotifier.new),
        authNotifierProvider.overrideWith(_SignedInNotifier.new),
      ],
      child: MaterialApp(
        theme: AppTheme.lightTheme,
        home: const RepoSetupScreen(isOnboarding: true),
      ),
    );
  }

  void phone(WidgetTester tester) {
    tester.view.physicalSize = screen;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  void raiseKeyboard(WidgetTester tester) {
    tester.view.viewInsets = const FakeViewPadding(bottom: keyboard);
  }

  Finder fieldLabelled(String label) =>
      find.ancestor(of: find.text(label), matching: find.byType(TextField));

  /// Open Advanced and put the cursor in one of its fields, with the keyboard
  /// still down - the order the user did it in.
  Future<Finder> focusAdvancedField(WidgetTester tester, String label) async {
    await tester.pumpWidget(harness(repos: [album]));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Advanced'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();

    final field = fieldLabelled(label);
    expect(field, findsOneWidget);

    // Scrolling to a field with the keyboard down is not the part that broke.
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    await tester.tap(field);
    await tester.pump();

    return field;
  }

  void expectClearOfKeyboard(WidgetTester tester, Finder finder, String what) {
    final rect = tester.getRect(finder);
    expect(
      rect.bottom,
      lessThanOrEqualTo(coveredTop),
      reason: '$what is behind the keyboard: $rect',
    );
    expect(
      rect.top,
      greaterThanOrEqualTo(0),
      reason: '$what was scrolled off the top instead: $rect',
    );
  }

  testWidgets('keeps the focused Site URL field clear of the keyboard', (
    tester,
  ) async {
    phone(tester);

    final siteUrl = await focusAdvancedField(tester, 'Site URL');

    // The keyboard arrives a beat after the tap that summoned it.
    raiseKeyboard(tester);
    await tester.pumpAndSettle();

    expectClearOfKeyboard(tester, siteUrl, 'the Site URL field');
  });

  testWidgets('lifts the last Advanced field, the one with no room below it', (
    tester,
  ) async {
    phone(tester);

    final path = await focusAdvancedField(tester, 'Album page URL path');

    // This one sits at the very bottom of the content, so with the keyboard
    // down it cannot be scrolled up at all - it starts inside the region the
    // keyboard is about to cover, which is what makes this worth asserting.
    expect(tester.getRect(path).bottom, greaterThan(coveredTop));

    raiseKeyboard(tester);
    await tester.pumpAndSettle();

    expectClearOfKeyboard(tester, path, 'the album page URL path field');
  });

  testWidgets('leaves the primary button reachable with the keyboard up', (
    tester,
  ) async {
    phone(tester);

    await focusAdvancedField(tester, 'Site URL');
    raiseKeyboard(tester);
    await tester.pumpAndSettle();

    expectClearOfKeyboard(
      tester,
      find.widgetWithText(ElevatedButton, 'Use this repo'),
      'the Use this repo button',
    );
  });

  testWidgets('keeps the manual owner/name field reachable when the list is '
      'empty', (tester) async {
    phone(tester);

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    final manual = find.byType(TextField);
    expect(manual, findsOneWidget);
    expect(find.text('No repositories found'), findsOneWidget);

    await tester.tap(manual);
    await tester.pump();
    raiseKeyboard(tester);
    await tester.pumpAndSettle();

    expectClearOfKeyboard(tester, manual, 'the owner/name field');
  });

  testWidgets('still shows the verdict, the album root and the picker', (
    tester,
  ) async {
    phone(tester);

    await tester.pumpWidget(harness(repos: [album]));
    await tester.pumpAndSettle();

    // Auto-selected, verified, and everything the screen promises is present.
    expect(find.text('gapp/album'), findsWidgets);
    expect(find.textContaining('No albums here yet'), findsOneWidget);
    expect(find.text('Albums folder'), findsOneWidget);
    expect(find.text('Create a repo for my albums'), findsOneWidget);
    expect(find.text('Search your repositories'), findsOneWidget);
    expect(find.text('Advanced'), findsOneWidget);
    expect(find.text('Use this repo'), findsOneWidget);
  });
}

class _FakeRepoRepository implements RepoRepository {
  final List<GitHubRepo> repos;

  _FakeRepoRepository(this.repos);

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

/// First run: nothing saved yet, so no Hive box is touched.
class _UnconfiguredNotifier extends ConfigNotifier {
  @override
  AppConfig? build() => null;
}

class _SignedInNotifier extends AuthNotifier {
  @override
  AuthState build() =>
      const AuthAuthenticated(GitHubUser(id: 1, login: 'gapp', avatarUrl: ''));
}
