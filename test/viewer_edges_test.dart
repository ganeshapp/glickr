import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:photo_view/photo_view_gallery.dart';

import 'package:glickr/core/models/album.dart';
import 'package:glickr/core/models/app_config.dart';
import 'package:glickr/core/models/media_item.dart';
import 'package:glickr/core/providers/album_actions_provider.dart';
import 'package:glickr/core/providers/config_provider.dart';
import 'package:glickr/core/providers/services_provider.dart';
import 'package:glickr/core/services/media_cache_service.dart';
import 'package:glickr/core/theme/app_theme.dart';
import 'package:glickr/features/viewer/presentation/photo_viewer_screen.dart';

/// An independent second opinion on the swipe bug: the edges of the album, a
/// video for a neighbour, a real status-bar inset, the chrome hidden, and a
/// swipe taken the instant the hero flight lands.
void main() {
  const screen = Size(390, 844);
  const middle = Offset(195, 422);

  late Directory tempDir;
  late File png;

  // The viewer watches pendingCaptionsNotifierProvider, which reads this box
  // directly. In memory (bytes: empty) so no test touches the real one.
  setUp(() async {
    await Hive.openBox<Map>('pending_captions', bytes: Uint8List(0));
  });

  tearDown(Hive.close);

  setUpAll(() {
    tempDir = Directory.systemTemp.createTempSync('glickr_viewer_edges');
    png = File('${tempDir.path}/frame.png')..writeAsBytesSync(_pngBytes);
  });

  tearDownAll(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// [videoAt] turns those indices into .mp4 items.
  Album albumOf(int count, {Set<int> videoAt = const {}}) {
    return Album(
      folder: 'cycling_trip',
      items: List.generate(count, (i) {
        final ext = videoAt.contains(i) ? 'mp4' : 'jpg';
        return MediaItem(
          name: '${i.toString().padLeft(4, '0')}.$ext',
          blobSha: 'sha$i',
          sizeRaw: 1000 + i,
        );
      }),
    );
  }

  List<Override> overrides(Album album) => [
    configNotifierProvider.overrideWith(_StubConfig.new),
    syncStateNotifierProvider.overrideWith(_StubSync.new),
    mediaCacheServiceProvider.overrideWithValue(_StubCache(png)),
    albumByFolderProvider(album.folder).overrideWithValue(album),
  ];

  /// The viewer pushed over a grid, exactly the way the app opens it.
  Widget pushed(Album album, int initialIndex) {
    return ProviderScope(
      overrides: overrides(album),
      child: MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: Builder(
            builder:
                (context) => Center(
                  child: TextButton(
                    onPressed:
                        () => Navigator.of(context).push(
                          PhotoViewerScreen.route(
                            context,
                            album: album,
                            initialIndex: initialIndex,
                          ),
                        ),
                    child: const Text('the album grid'),
                  ),
                ),
          ),
        ),
      ),
    );
  }

  /// Pump [frames] real frames without ever calling pumpAndSettle.
  ///
  /// photo_view's loading state is a CircularProgressIndicator, which never
  /// stops animating - so pumpAndSettle cannot be used anywhere a page might
  /// still be decoding. Everything here is bounded instead.
  Future<void> frames(WidgetTester tester, [int count = 40]) async {
    for (var i = 0; i < count; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  /// Real file I/O and image decoding need real time; a widget test's fake
  /// clock never delivers it. Waits until the pages have actually decoded
  /// rather than for a fixed number of turns, so a cold image cache (which is
  /// what a single test run has) does not change the outcome.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 100; i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      if (i >= 3 &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty &&
          find.byType(Image).evaluate().isNotEmpty) {
        break;
      }
    }
    await frames(tester);
  }

  Future<void> open(
    WidgetTester tester,
    Album album, {
    required int at,
    double topInset = 0,
    bool settleFirst = true,
  }) async {
    tester.view.physicalSize = screen;
    tester.view.devicePixelRatio = 1.0;
    if (topInset > 0) {
      tester.view.padding = FakeViewPadding(top: topInset);
      tester.view.viewPadding = FakeViewPadding(top: topInset);
    }
    addTearDown(tester.view.reset);
    await tester.pumpWidget(pushed(album, at));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('the album grid'));
    if (settleFirst) {
      await settle(tester);
    } else {
      // Only the route transition and the hero flight - no extra real time, so
      // the pages are still photo_view's loading state.
      await frames(tester, 30);
    }
  }

  String counter(WidgetTester tester, int count) {
    for (var i = 1; i <= count; i++) {
      if (find.text('$i / $count').evaluate().isNotEmpty) return '$i / $count';
    }
    return '<no counter on screen>';
  }

  double? pagerPage(WidgetTester tester) =>
      tester.widget<PageView>(find.byType(PageView)).controller?.page;

  String where(WidgetTester tester, int count) =>
      'counter reads "${counter(tester, count)}", '
      'pager is at ${pagerPage(tester)}';

  /// A thumb-shaped drag: many small moves with advancing timestamps.
  Future<void> swipe(
    WidgetTester tester,
    Offset total, {
    Offset from = middle,
    int steps = 24,
  }) async {
    final gesture = await tester.startGesture(from);
    final step = total / steps.toDouble();
    var elapsed = Duration.zero;
    for (var i = 0; i < steps; i++) {
      elapsed += const Duration(milliseconds: 8);
      await gesture.moveBy(step, timeStamp: elapsed);
      await tester.pump(const Duration(milliseconds: 8));
    }
    await gesture.up(timeStamp: elapsed);
    await frames(tester);
  }

  /// Does a touch at [at] reach the pager, or is something on top of it?
  bool reachesPager(WidgetTester tester, Offset at) {
    final pager = tester.renderObject(find.byType(PageView));
    return tester
        .hitTestOnBinding(at)
        .path
        .map((e) => e.target)
        .contains(pager);
  }

  // --------------------------------------------------- the reported scenario

  testWidgets('the bug as reported: 23 items, opened on item 2, swipe left', (
    tester,
  ) async {
    await open(tester, albumOf(23), at: 1, topInset: 47);
    expect(find.text('2 / 23'), findsOneWidget);

    await swipe(tester, const Offset(-260, 0));

    expect(
      find.text('3 / 23'),
      findsOneWidget,
      reason: 'the exact case from the bug report; ${where(tester, 23)}',
    );
  });

  // ------------------------------------------------------ the album's edges

  testWidgets('the FIRST photo pages forward', (tester) async {
    await open(tester, albumOf(12), at: 0);
    expect(find.text('1 / 12'), findsOneWidget);

    await swipe(tester, const Offset(-260, 0));

    expect(
      find.text('2 / 12'),
      findsOneWidget,
      reason: 'opened on the first item; ${where(tester, 12)}',
    );
  });

  testWidgets('the FIRST photo will not page backwards off the end', (
    tester,
  ) async {
    await open(tester, albumOf(12), at: 0);

    await swipe(tester, const Offset(260, 0));

    expect(find.text('1 / 12'), findsOneWidget);
    expect(find.byType(PhotoViewGallery), findsOneWidget);
  });

  testWidgets('the LAST photo pages backwards', (tester) async {
    await open(tester, albumOf(12), at: 11);
    expect(find.text('12 / 12'), findsOneWidget);

    await swipe(tester, const Offset(260, 0));

    expect(
      find.text('11 / 12'),
      findsOneWidget,
      reason: 'opened on the last item; ${where(tester, 12)}',
    );
  });

  testWidgets('the LAST photo will not page forwards off the end', (
    tester,
  ) async {
    await open(tester, albumOf(12), at: 11);

    await swipe(tester, const Offset(-260, 0));

    expect(find.text('12 / 12'), findsOneWidget);
    expect(find.byType(PhotoViewGallery), findsOneWidget);
  });

  // --------------------------------------------------------------- a video

  testWidgets('pages onto a VIDEO neighbour and off it again', (tester) async {
    final album = albumOf(4, videoAt: {2});
    await open(tester, album, at: 1);
    expect(find.text('2 / 4'), findsOneWidget);

    // Onto the video page, which is a customChild page with
    // disableGestures: true rather than a PhotoView.
    await swipe(tester, const Offset(-260, 0));
    expect(
      find.text('3 / 4'),
      findsOneWidget,
      reason: 'the next page is a video; ${where(tester, 4)}',
    );

    // ...and away from it: the video stage's own opaque tap detector must not
    // hold the drag either.
    await swipe(tester, const Offset(-260, 0));
    expect(
      find.text('4 / 4'),
      findsOneWidget,
      reason: 'swiping off a video page; ${where(tester, 4)}',
    );

    await swipe(tester, const Offset(260, 0));
    expect(find.text('3 / 4'), findsOneWidget);
  });

  // ------------------------------------------------------- chrome, and insets

  testWidgets('swiping works with the chrome HIDDEN', (tester) async {
    await open(tester, albumOf(5), at: 1);

    // Tap the photo to hide the controls; then swipe with nothing drawn on top.
    await tester.tapAt(middle);
    await tester.pump(const Duration(milliseconds: 400));
    await frames(tester);

    await swipe(tester, const Offset(-260, 0));

    expect(
      find.text('3 / 5'),
      findsOneWidget,
      reason: 'swiped with the chrome hidden; ${where(tester, 5)}',
    );
  });

  testWidgets('swiping works under a real status-bar inset', (tester) async {
    await open(tester, albumOf(5), at: 1, topInset: 47);

    // The scrim is the inset plus the bar itself, not the whole screen.
    final backdrop = tester.renderObject<RenderBox>(
      find
          .ancestor(of: find.text('2 / 5'), matching: find.byType(Container))
          .last,
    );
    expect(
      backdrop.size.height,
      lessThan(150),
      reason: 'the top scrim measures ${backdrop.size} with a 47px inset',
    );

    await swipe(tester, const Offset(-260, 0));
    expect(
      find.text('3 / 5'),
      findsOneWidget,
      reason: 'with a 47px status-bar inset; ${where(tester, 5)}',
    );
  });

  testWidgets('a swipe just below the top bar pages, one on it does not', (
    tester,
  ) async {
    await open(tester, albumOf(5), at: 1, topInset: 47);

    final backdrop = tester.renderObject<RenderBox>(
      find
          .ancestor(of: find.text('2 / 5'), matching: find.byType(Container))
          .last,
    );
    final barBottom = backdrop.size.height;

    // Just clear of the bar: the photo takes it.
    expect(reachesPager(tester, Offset(195, barBottom + 10)), isTrue);
    await swipe(
      tester,
      const Offset(-260, 0),
      from: Offset(195, barBottom + 10),
    );
    expect(
      find.text('3 / 5'),
      findsOneWidget,
      reason: 'a swipe ${barBottom + 10}px down the screen; '
          '${where(tester, 5)}',
    );

    // On the bar itself it is still absorbed - the scrim is a DecoratedBox and
    // those are opaque to hit tests. That is the same mechanism as the bug,
    // now confined to the strip the controls actually occupy.
    expect(reachesPager(tester, Offset(195, barBottom - 10)), isFalse);
  });

  // ------------------------------------------------------------ the hero flight

  testWidgets('a swipe taken the moment the hero flight lands still pages', (
    tester,
  ) async {
    // No runAsync: the pages are still photo_view's loading state, which is
    // the tree that exists in the first instants after the flight.
    await open(tester, albumOf(5), at: 1, settleFirst: false);
    expect(find.text('2 / 5'), findsOneWidget);

    await swipe(tester, const Offset(-260, 0));

    expect(
      find.text('3 / 5'),
      findsOneWidget,
      reason: 'swiped as soon as the flight landed; ${where(tester, 5)}',
    );
  });

  testWidgets('most of the screen is the photo, as far as touches go', (
    tester,
  ) async {
    await open(tester, albumOf(5), at: 1, topInset: 47);

    // Walk the middle column of the screen and ask, pixel by pixel, whether a
    // touch there would reach the pager at all. On the shipped build the answer
    // was "nowhere, not one pixel" - which is the user's report exactly.
    var firstY = -1.0;
    var lastY = -1.0;
    for (var y = 1.0; y < 844; y += 1) {
      if (reachesPager(tester, Offset(195, y))) {
        if (firstY < 0) firstY = y;
        lastY = y;
      }
    }

    expect(
      firstY,
      inInclusiveRange(1, 100),
      reason:
          'the pager is reachable from y=$firstY to y=$lastY of 844 - the '
          'chrome is covering the photo',
    );
    expect(
      lastY,
      greaterThan(700),
      reason:
          'the pager is reachable from y=$firstY to y=$lastY of 844 - the '
          'chrome is covering the photo',
    );
  });

}

class _StubConfig extends ConfigNotifier {
  @override
  AppConfig? build() => null;
}

class _StubSync extends SyncStateNotifier {
  @override
  RepoSyncState build() => const RepoSyncState(commitSha: 'commit');
}

class _StubCache extends MediaCacheService {
  _StubCache(this.file) : super(manager: _NoManager());

  final File file;

  @override
  Future<File?> cachedFile(MediaItem item) async => file;

  @override
  Future<File?> cachedPoster(MediaItem item) async => file;

  @override
  Future<File> fetch({
    required AppConfig config,
    required Album album,
    required MediaItem item,
    required String commitSha,
  }) async => file;

  @override
  Future<void> evict(String blobSha) async {}
}

class _NoManager implements CacheManager {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('the cache manager is stubbed out');
}

/// A real, decodable 120x180 PNG.
final List<int> _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAHgAAAC0CAIAAADQLH9KAAAB6UlEQVR42u3Q4UYeAAAAwE+S'
  'JEmSJMkkSZIkSSZJJpkkSZIkSZIkSZJMkiSZSZJMkiRJkiRJkiRJkiRJkiRJkiTpMfrRPcFx'
  'gUBQcEhoWHhEZFR0TGxcfELij6TklNS09IzMrOyc3Lyf+QWFRb+KS36XlpVXVFZV19TW1Tc0'
  'NjW3tLa1d3R2dff0/unrHxgcGh75+290bHxi8v/U9Mzs3PzC4tLyyura+sbm1vbO7t7+weHR'
  '8cnp2fnF5dX1ze3d/cPj0/PL69v7x3fxA6JFixYtWrRo0aJFixYtWrRo0aJFixYtWrRo0aJF'
  'ixYtWrRo0aJFixYtWrRo0aJFixYtWrRo0aJFixYtWrRo0aJFixYtWrRo0aJFixYtWrRo0aJF'
  'ixYtWrRo0aJFixYtWrRo0aJFixYtWrRo0aJFixYtWrRo0aJFixYtWrRo0aJFixYtWrRo0aJF'
  'ixYtWrRo0aJFixYtWrRo0aJFixYtWrRo0aJFixYtWrRo0aJFixYtWrRo0aJFixYtWrRo0aJF'
  'ixYtWrRo0aJFixYtWrRo0aJFixYtWrRo0aJFixYtWrRo0aJFixYtWrRo0aJFixYtWrRo0aJF'
  'ixYtWrRo0aJFixYtWrRo0aJFixYtWrRo0aJFixYtWrRo0aJFf43/CbyCvsscL7p0AAAAAElF'
  'TkSuQmCC',
);