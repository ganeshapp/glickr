import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:photo_view/photo_view_gallery.dart';
// The gesture detector photo_view installs on a real image page is not
// exported, and "is it in the tree at all?" is part of the question here.
// ignore: implementation_imports
import 'package:photo_view/src/core/photo_view_gesture_detector.dart';

import 'package:glickr/core/models/album.dart';
import 'package:glickr/core/models/app_config.dart';
import 'package:glickr/core/models/media_item.dart';
import 'package:glickr/core/providers/album_actions_provider.dart';
import 'package:glickr/core/providers/config_provider.dart';
import 'package:glickr/core/providers/services_provider.dart';
import 'package:glickr/core/services/media_cache_service.dart';
import 'package:glickr/core/theme/app_theme.dart';
import 'package:glickr/features/viewer/presentation/photo_viewer_screen.dart';

/// Touching the viewer: swiping between photos, dragging it away, zooming in.
///
/// The bug this file exists for: "I can't swipe between images in an album. If
/// I open one, then I have to press back and then click on the next photo."
///
/// The cause was not a gesture conflict at all. `_topBar`'s Column had no
/// `mainAxisSize`, so it filled the whole height the chrome's `Align` offered
/// it; the gradient `Container` sized itself to that Column, and
/// `RenderDecoratedBox.hitTestSelf` is true anywhere inside a rectangular
/// decoration. The top bar was therefore a screen-sized pointer trap sitting
/// over the pager. Its own buttons still worked - `hitTestChildren` runs before
/// `hitTestSelf` - which is exactly why the screen looked alive while every
/// gesture aimed at the photo (swipe, pinch, tap-to-hide-chrome, and
/// drag-to-dismiss) was silently eaten.
///
/// So these tests come in pairs: the geometry that caused it, and each gesture
/// that was lost to it. Everything the screen would fetch is stubbed, and the
/// byte cache hands back one real PNG on disk for every item, so the pages are
/// genuine `PhotoView`s with photo_view's own gesture stack installed - not the
/// `customChild` placeholder pages, which pass `disableGestures: true` and
/// would quietly be a different widget tree from the one the user is touching.
void main() {
  const screen = Size(390, 844);

  /// The middle of the screen: below the top bar, above the caption bar, and
  /// squarely on the photo.
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
    tempDir = Directory.systemTemp.createTempSync('glickr_viewer_swipe');
    png = File('${tempDir.path}/frame.png')..writeAsBytesSync(_pngBytes);
  });

  tearDownAll(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Album albumOf(int count) {
    return Album(
      folder: 'cycling_trip',
      items: List.generate(
        count,
        (i) => MediaItem(
          name: '${i.toString().padLeft(4, '0')}.jpg',
          blobSha: 'sha$i',
          sizeRaw: 1000 + i,
        ),
      ),
    );
  }

  List<Override> overrides(Album album) => [
    // Nothing may touch Hive or the network.
    configNotifierProvider.overrideWith(_StubConfig.new),
    syncStateNotifierProvider.overrideWith(_StubSync.new),
    mediaCacheServiceProvider.overrideWithValue(_StubCache(png)),
    // The screen watches the LIVE album, which otherwise resolves through
    // albumsNotifierProvider - and that opens a Hive box in build().
    albumByFolderProvider(album.folder).overrideWithValue(album),
  ];

  Widget harness(Album album, {int initialIndex = 1}) {
    return ProviderScope(
      overrides: overrides(album),
      child: MaterialApp(
        theme: AppTheme.lightTheme,
        home: PhotoViewerScreen(album: album, initialIndex: initialIndex),
      ),
    );
  }

  /// The viewer as the app really opens it: pushed with [PhotoViewerScreen.route]
  /// over the grid, so there is something to go back to. Drag-to-dismiss cannot
  /// be observed on a root route - `maybePop` has nothing to pop.
  Widget pushedHarness(Album album, {int initialIndex = 1}) {
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

  /// Let the real file read and image decode finish.
  ///
  /// [WidgetTester.runAsync] is what makes the FileImage resolve at all: both
  /// are real I/O, and the fake clock a widget test runs on never delivers
  /// them. Without this the pages stay on photo_view's loading spinner, which
  /// has no gesture detector on it - a tree the user never sees.
  /// Waits for the pages to have actually DECODED, rather than for a fixed
  /// number of turns.
  ///
  /// Six turns plus `pumpAndSettle` was enough only against a warm image cache.
  /// Run cold - which is what happens when these tests run first, so it showed
  /// up as order-dependence under `--test-randomize-ordering-seed` - the
  /// FileImage had not decoded yet, photo_view was still showing its
  /// CircularProgressIndicator, and `pumpAndSettle` timed out on an animation
  /// that never ends. Ending on fixed pumps rather than pumpAndSettle is the
  /// other half: a spinner on screen must not be able to hang the test.
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
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  void sizeScreen(WidgetTester tester) {
    tester.view.physicalSize = screen;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<void> open(WidgetTester tester, Album album, {int at = 1}) async {
    sizeScreen(tester);
    await tester.pumpWidget(harness(album, initialIndex: at));
    await settle(tester);
  }

  /// Open the viewer over a grid, the way the app does.
  Future<void> openOverGrid(
    WidgetTester tester,
    Album album, {
    int at = 1,
  }) async {
    sizeScreen(tester);
    await tester.pumpWidget(pushedHarness(album, initialIndex: at));
    await tester.pumpAndSettle();
    await tester.tap(find.text('the album grid'));
    await settle(tester);
  }

  /// What the on-screen counter reads, e.g. "2 / 5".
  String counter(WidgetTester tester, int count) {
    for (var i = 1; i <= count; i++) {
      if (find.text('$i / $count').evaluate().isNotEmpty) return '$i / $count';
    }
    return '<no counter on screen>';
  }

  /// The pager's own idea of where it is, independent of the chrome.
  double? pagerPage(WidgetTester tester) =>
      tester.widget<PageView>(find.byType(PageView)).controller?.page;

  String where(WidgetTester tester, int count) =>
      'counter reads "${counter(tester, count)}", '
      'pager is at ${pagerPage(tester)}';

  /// The gradient Container the top bar is wrapped in.
  Finder topBarBackdrop(String counterText) =>
      find
          .ancestor(
            of: find.text(counterText),
            matching: find.byType(Container),
          )
          .last;

  /// The decoded photo on page [index], found through the hero tag the screen
  /// puts on it. Its rect is measured through photo_view's own `Transform`, so
  /// it reports where the pixels actually are - which is how zoom, pan and the
  /// drag-to-dismiss offset are all observed here.
  Finder photoOf(int index) => find.descendant(
    of: find.byWidgetPredicate(
      (w) =>
          w is Hero &&
          w.tag == 'media-cycling_trip/${index.toString().padLeft(4, '0')}.jpg',
    ),
    matching: find.byType(Image),
  );

  /// A drag delivered the way a thumb delivers one: many small moves carrying
  /// advancing timestamps, rather than one jump.
  ///
  /// [WidgetTester.drag] collapses the whole delta into one or two move
  /// events, which is not how a real gesture arena gets resolved - so it can
  /// hide exactly the kind of recogniser competition this file is looking for.
  Future<void> swipe(
    WidgetTester tester,
    Offset total, {
    int steps = 24,
    Duration stepTime = const Duration(milliseconds: 8),
    Offset from = middle,
  }) async {
    final gesture = await tester.startGesture(from);
    final step = total / steps.toDouble();
    var elapsed = Duration.zero;
    for (var i = 0; i < steps; i++) {
      elapsed += stepTime;
      await gesture.moveBy(step, timeStamp: elapsed);
      await tester.pump(stepTime);
    }
    await gesture.up(timeStamp: elapsed);
    await tester.pumpAndSettle();
  }

  /// photo_view's own zoom gesture. The two taps have to be closer together
  /// than [kDoubleTapTimeout], and the settle afterwards has to advance real
  /// time or the scale animation never runs.
  Future<void> doubleTap(WidgetTester tester, [Offset at = middle]) async {
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(at);
    await tester.pumpAndSettle();
  }

  /// A single tap, waited out past [kDoubleTapTimeout].
  ///
  /// photo_view always registers a DoubleTapGestureRecognizer, which holds the
  /// arena open; without advancing the clock the single tap never resolves.
  Future<void> singleTap(WidgetTester tester, [Offset at = middle]) async {
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  /// The chrome layer's opacity - 1 when the controls are showing, 0 when a tap
  /// on the photo has hidden them.
  double chromeOpacity(WidgetTester tester, String counterText) =>
      tester
          .widget<AnimatedOpacity>(
            find
                .ancestor(
                  of: find.text(counterText),
                  matching: find.byType(AnimatedOpacity),
                )
                .first,
          )
          .opacity;

  // ------------------------------------------------------------- the controls

  testWidgets('the viewer opens on the item it was given, showing real '
      'PhotoView pages', (tester) async {
    await open(tester, albumOf(5));

    expect(find.text('2 / 5'), findsOneWidget);
    expect(find.byType(PhotoViewGallery), findsOneWidget);
    // The stubbed bytes really did decode, so photo_view's own recogniser is
    // in the arena exactly as it is on device. If this fails, every other
    // assertion in this file is about the wrong widget tree.
    expect(
      find.byType(PhotoViewGestureDetector),
      findsWidgets,
      reason: 'the pages are still loading placeholders',
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('the pager itself works when driven directly, so only the '
      'gesture is lost', (tester) async {
    await open(tester, albumOf(5));
    expect(find.text('2 / 5'), findsOneWidget);

    // Nothing is wrong with the PageView, the controller or the callback -
    // which is what rules out "the pager does not know it has 5 items".
    tester.widget<PageView>(find.byType(PageView)).controller?.jumpToPage(2);
    await tester.pumpAndSettle();

    expect(find.text('3 / 5'), findsOneWidget);
  });

  // ------------------------------------------------------- the cause: geometry

  testWidgets('the top bar is a strip, not a full-screen pointer trap', (
    tester,
  ) async {
    await open(tester, albumOf(5));

    final backdrop = tester.renderObject<RenderBox>(topBarBackdrop('2 / 5'));

    // A back button, a counter and a 2px progress line. Anything approaching
    // the height of the screen means the Column went unbounded again.
    expect(
      backdrop.size.width,
      screen.width,
      reason: 'the top bar should still span the screen horizontally',
    );
    expect(
      backdrop.size.height,
      lessThan(200),
      reason:
          'the top bar backdrop is ${backdrop.size} on a $screen screen, so '
          'it covers the photo',
    );
  });

  testWidgets(
    'the photo is what a touch in the middle of the screen lands on',
    (tester) async {
      await open(tester, albumOf(5));

      final backdrop = tester.renderObject<RenderBox>(topBarBackdrop('2 / 5'));
      final path =
          tester
              .hitTestOnBinding(middle)
              .path
              .map((entry) => entry.target)
              .toList();

      // Nothing belonging to the chrome may be on the hit path over the middle
      // of the photo...
      expect(
        path,
        isNot(contains(backdrop)),
        reason:
            'the top bar backdrop absorbs the touch: RenderDecoratedBox.'
            'hitTestSelf returns true anywhere inside a BoxDecoration, so a '
            'full-height gradient swallows every pointer before the PageView '
            'can be hit-tested',
      );
      // ...and the pager must be on it, which is the positive form of the same
      // claim and the thing every gesture below depends on.
      expect(
        path,
        contains(tester.renderObject(find.byType(PageView))),
        reason: 'the touch never reaches the pager: $path',
      );
    },
  );

  // ------------------------------------------------------------------ paging

  testWidgets('a horizontal FLING pages to the next photo', (tester) async {
    await open(tester, albumOf(5));
    expect(find.text('2 / 5'), findsOneWidget);

    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1200);
    await tester.pumpAndSettle();

    expect(
      find.text('3 / 5'),
      findsOneWidget,
      reason: 'a fling left should advance one page; ${where(tester, 5)}',
    );
  });

  testWidgets('a slow, perfectly HORIZONTAL drag pages to the next photo', (
    tester,
  ) async {
    await open(tester, albumOf(5));
    expect(find.text('2 / 5'), findsOneWidget);

    await swipe(tester, const Offset(-260, 0));

    expect(
      find.text('3 / 5'),
      findsOneWidget,
      reason: 'a 260px drag left should advance one page; ${where(tester, 5)}',
    );
  });

  testWidgets('a horizontal drag WITH VERTICAL NOISE pages to the next photo', (
    tester,
  ) async {
    await open(tester, albumOf(5));
    expect(find.text('2 / 5'), findsOneWidget);

    // A real thumb never travels a perfect line: 260px across, 26px down.
    // A 10:1 ratio is well inside what anyone would call a horizontal swipe,
    // but it is enough to feed the drag-to-dismiss recogniser.
    await swipe(tester, const Offset(-260, 26));

    expect(
      find.text('3 / 5'),
      findsOneWidget,
      reason: 'a mostly-horizontal drag should still page; ${where(tester, 5)}',
    );
  });

  testWidgets('a horizontal drag that STARTS with a vertical nudge still '
      'pages', (tester) async {
    await open(tester, albumOf(5));
    expect(find.text('2 / 5'), findsOneWidget);

    // The first few pixels of a thumb swipe are often downward - the finger
    // rolls before it slides. If the vertical recogniser claims the arena on
    // those, the rest of the swipe is lost.
    final gesture = await tester.startGesture(middle);
    var elapsed = Duration.zero;
    for (var i = 0; i < 4; i++) {
      elapsed += const Duration(milliseconds: 8);
      await gesture.moveBy(const Offset(-1, 3), timeStamp: elapsed);
      await tester.pump(const Duration(milliseconds: 8));
    }
    for (var i = 0; i < 20; i++) {
      elapsed += const Duration(milliseconds: 8);
      await gesture.moveBy(const Offset(-13, 0), timeStamp: elapsed);
      await tester.pump(const Duration(milliseconds: 8));
    }
    await gesture.up(timeStamp: elapsed);
    await tester.pumpAndSettle();

    expect(
      find.text('3 / 5'),
      findsOneWidget,
      reason: 'the swipe began with a 12px vertical roll; ${where(tester, 5)}',
    );
  });

  testWidgets('swiping back reaches the previous photo', (tester) async {
    await open(tester, albumOf(5));
    expect(find.text('2 / 5'), findsOneWidget);

    await swipe(tester, const Offset(260, 0));

    expect(
      find.text('1 / 5'),
      findsOneWidget,
      reason: 'a drag right should go back one page; ${where(tester, 5)}',
    );
  });

  testWidgets('swiping keeps working over the album, one page at a time', (
    tester,
  ) async {
    await openOverGrid(tester, albumOf(5), at: 0);
    expect(find.text('1 / 5'), findsOneWidget);

    // Through the real route the app pushes - opaque: false, hero flight and
    // all - rather than as a bare root screen.
    for (var page = 2; page <= 5; page++) {
      await swipe(tester, const Offset(-260, 0));
      expect(
        find.text('$page / 5'),
        findsOneWidget,
        reason: 'swipe $page of 5 did not land; ${where(tester, 5)}',
      );
    }

    // ...and the far end is a wall, not a crash or a dismiss.
    await swipe(tester, const Offset(-260, 0));
    expect(find.text('5 / 5'), findsOneWidget);
    expect(find.byType(PhotoViewGallery), findsOneWidget);
  });

  // -------------------------------------------------------- drag-to-dismiss

  testWidgets('a vertical drag moves the photo with the finger', (
    tester,
  ) async {
    await openOverGrid(tester, albumOf(5));
    final start = tester.getRect(photoOf(1));

    final gesture = await tester.startGesture(middle);
    var elapsed = Duration.zero;
    for (var i = 0; i < 20; i++) {
      elapsed += const Duration(milliseconds: 8);
      await gesture.moveBy(const Offset(0, 4), timeStamp: elapsed);
      await tester.pump(const Duration(milliseconds: 8));
    }

    // Still held, 80px down. The photo follows the finger and shrinks a little
    // - if the pointer never reached the drag recogniser, neither happens.
    // It travels a little less than 80: DragStartBehavior.start discards the
    // ~18px of touch slop the recogniser needs before it claims the gesture.
    final held = tester.getRect(photoOf(1));
    expect(
      held.center.dy - start.center.dy,
      inInclusiveRange(80 - 18 - 4, 80),
      reason: 'the photo did not follow the finger: $start -> $held',
    );
    expect(
      held.height,
      lessThan(start.height),
      reason: 'the photo should scale down as it is dragged away',
    );

    // Released short of the threshold: it springs back and the viewer stays.
    await gesture.up(timeStamp: elapsed);
    await tester.pumpAndSettle();
    expect(tester.getRect(photoOf(1)), rectMoreOrLessEquals(start));
    expect(find.byType(PhotoViewGallery), findsOneWidget);
    expect(find.text('2 / 5'), findsOneWidget);
  });

  testWidgets('a long drag down dismisses the viewer', (tester) async {
    await openOverGrid(tester, albumOf(5));
    expect(find.byType(PhotoViewGallery), findsOneWidget);

    // Past _dismissDistance (120px).
    await swipe(tester, const Offset(0, 220));

    expect(
      find.byType(PhotoViewGallery),
      findsNothing,
      reason: 'a 220px drag down should have closed the viewer',
    );
    expect(find.text('the album grid'), findsOneWidget);
  });

  testWidgets(
    'on desktop the arrow keys page and Escape closes the viewer',
    (tester) async {
      await openOverGrid(tester, albumOf(3), at: 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await settle(tester);
      expect(counter(tester, 3), '2 / 3', reason: where(tester, 3));

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await settle(tester);
      expect(counter(tester, 3), '1 / 3', reason: where(tester, 3));

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(PhotoViewGallery), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets('a quick flick down dismisses without travelling far', (
    tester,
  ) async {
    await openOverGrid(tester, albumOf(5));

    // 90px in 40ms: short of _dismissDistance, but well past
    // _dismissVelocity (700px/s).
    await swipe(
      tester,
      const Offset(0, 90),
      steps: 10,
      stepTime: const Duration(milliseconds: 4),
    );

    expect(
      find.byType(PhotoViewGallery),
      findsNothing,
      reason: 'a fast flick down should have closed the viewer',
    );
    expect(find.text('the album grid'), findsOneWidget);
  });

  testWidgets('a horizontal swipe does not dismiss the viewer', (tester) async {
    await openOverGrid(tester, albumOf(5));

    await swipe(tester, const Offset(-260, 26));

    expect(find.byType(PhotoViewGallery), findsOneWidget);
    expect(find.text('3 / 5'), findsOneWidget);
  });

  // ----------------------------------------------------------- zoom and pan

  testWidgets('double tap zooms the photo in', (tester) async {
    await open(tester, albumOf(5));
    final contained = tester.getRect(photoOf(1));

    await doubleTap(tester);

    final zoomed = tester.getRect(photoOf(1));
    expect(
      zoomed.width,
      greaterThan(contained.width),
      reason: 'double tap did not zoom: $contained -> $zoomed',
    );
    // Zoomed to "covered", so the photo now overflows the screen sideways -
    // which is what makes panning meaningful at all.
    expect(zoomed.left, lessThan(0));
    expect(zoomed.right, greaterThan(screen.width));
  });

  testWidgets('while zoomed, a drag PANS the photo instead of paging', (
    tester,
  ) async {
    await open(tester, albumOf(5));
    await doubleTap(tester);
    final zoomed = tester.getRect(photoOf(1));

    await swipe(tester, const Offset(-40, 0));

    final panned = tester.getRect(photoOf(1));
    expect(
      panned.left,
      closeTo(zoomed.left - 40, 1),
      reason: 'the photo should have panned 40px: $zoomed -> $panned',
    );
    expect(
      find.text('2 / 5'),
      findsOneWidget,
      reason: 'panning a zoomed photo must not turn the page; '
          '${where(tester, 5)}',
    );
    expect(pagerPage(tester), 1.0);
  });

  testWidgets('while zoomed, a vertical drag does not dismiss the viewer', (
    tester,
  ) async {
    await openOverGrid(tester, albumOf(5));
    await doubleTap(tester);
    final zoomed = tester.getRect(photoOf(1));

    // _gallery drops its vertical recogniser while _zoomed, so photo_view owns
    // this drag. At "covered" the photo is exactly screen-height, so there is
    // nowhere to pan to - but it must not fly away either.
    await swipe(tester, const Offset(0, 220));

    expect(
      find.byType(PhotoViewGallery),
      findsOneWidget,
      reason: 'dragging a zoomed photo down must not close the viewer',
    );
    expect(tester.getRect(photoOf(1)), rectMoreOrLessEquals(zoomed));
  });

  testWidgets('a zoomed photo pages only once its edge is reached', (
    tester,
  ) async {
    await open(tester, albumOf(5));
    await doubleTap(tester);

    // Pan to the right-hand edge of the photo. Still page 2 - every one of
    // these drags went into the photo, not the pager.
    await swipe(tester, const Offset(-40, 0));
    expect(find.text('2 / 5'), findsOneWidget);
    await swipe(tester, const Offset(-200, 0));
    expect(
      find.text('2 / 5'),
      findsOneWidget,
      reason: 'panning to the edge must not page; ${where(tester, 5)}',
    );

    final atEdge = tester.getRect(photoOf(1));
    expect(
      atEdge.right,
      closeTo(screen.width, 1),
      reason: 'the pan should have stopped at the photo edge, not before it',
    );

    // Now that there is nothing left to pan, photo_view hands the drag over
    // and the same gesture turns the page.
    await swipe(tester, const Offset(-260, 0));
    expect(
      find.text('3 / 5'),
      findsOneWidget,
      reason: 'a swipe from the photo edge should page; ${where(tester, 5)}',
    );
    // The new page comes in unzoomed.
    expect(tester.getRect(photoOf(2)).left, 0);
  });

  // ------------------------------------------------------------- tap the photo

  testWidgets('tapping the photo hides and shows the chrome', (tester) async {
    await open(tester, albumOf(5));
    expect(chromeOpacity(tester, '2 / 5'), 1);

    await singleTap(tester);
    expect(
      chromeOpacity(tester, '2 / 5'),
      0,
      reason: 'a tap on the photo should have hidden the controls',
    );

    await singleTap(tester);
    expect(chromeOpacity(tester, '2 / 5'), 1);
  });

  testWidgets('the controls themselves still take their own taps', (
    tester,
  ) async {
    await openOverGrid(tester, albumOf(5));

    // hitTestChildren runs before hitTestSelf, so these worked even while the
    // top bar was swallowing everything else - which is what made the bug look
    // like "only swiping is broken".
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    expect(find.byType(PhotoViewGallery), findsNothing);
    expect(find.text('the album grid'), findsOneWidget);
  });
}

// ------------------------------------------------------------------- stubs

/// No repo configured. Nothing here needs one - the cache stub answers first -
/// but the provider still has to exist without opening a Hive box.
class _StubConfig extends ConfigNotifier {
  @override
  AppConfig? build() => null;
}

class _StubSync extends SyncStateNotifier {
  @override
  RepoSyncState build() => const RepoSyncState(commitSha: 'commit');
}

/// Every item resolves, instantly and from "disk", to the same real PNG.
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

/// Stands in for the real [CacheManager] purely so [MediaCacheService]'s
/// constructor does not build one - which would reach for a temp directory
/// through path_provider, a plugin no widget test has.
class _NoManager implements CacheManager {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('the cache manager is stubbed out');
}

/// A real, decodable 120x180 PNG. Small enough to inline; big enough that
/// photo_view computes a sane "contained" scale for it, which is what puts the
/// gallery in the not-zoomed state where it yields the horizontal drag.
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
