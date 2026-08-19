import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glickr/core/app_navigator.dart';
import 'package:glickr/core/providers/upload_provider.dart';
import 'package:glickr/core/theme/app_theme.dart';
import 'package:glickr/features/uploads/widgets/upload_tray.dart';
import 'package:glickr/main.dart';

/// The upload tray shares a Stack with the entire app: it is mounted above the
/// Navigator so an upload stays visible across screens. Two things follow, and
/// both are invisible until someone tries to use the app while an upload is
/// running.
///
///   * It is painted last, so anything it occupies it also takes taps from -
///     including the "Add photos" FAB, which sits in the same corner.
///   * It is a SIBLING of the Navigator, not a descendant, so it cannot reach
///     one through the element tree and has to go through [appNavigatorKey].
void main() {
  Widget app({required UploadQueueState queue, required VoidCallback onFab}) {
    return ProviderScope(
      overrides: [
        uploadQueueNotifierProvider.overrideWith(() => _StubQueue(queue)),
      ],
      child: MaterialApp(
        navigatorKey: appNavigatorKey,
        theme: AppTheme.lightTheme,
        builder: (context, child) => RootOverlay(child: child),
        home: Scaffold(
          body: const SizedBox.expand(),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: onFab,
            icon: const Icon(Icons.add),
            label: const Text('Add photos'),
          ),
        ),
      ),
    );
  }

  const waiting = UploadQueueState(waitingReason: 'No connection');

  testWidgets('leaves the FAB tappable while a pill is showing', (
    tester,
  ) async {
    var fabTaps = 0;
    await tester.pumpWidget(app(queue: waiting, onFab: () => fabTaps++));
    await tester.pumpAndSettle();

    // The tray really is up - otherwise this proves nothing.
    expect(find.textContaining('No connection'), findsOneWidget);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();

    expect(fabTaps, 1);
  });

  testWidgets('sits clear of the FAB rather than on top of it', (tester) async {
    await tester.pumpWidget(app(queue: waiting, onFab: () {}));
    await tester.pumpAndSettle();

    final fab = tester.getRect(find.byType(FloatingActionButton));
    final pill = tester.getRect(
      find.descendant(
        of: find.byType(UploadTray),
        matching: find.byType(InkWell),
      ),
    );

    // Not merely "the tap landed": the pill must not be drawn over the FAB
    // either, or the FAB is invisible for as long as an upload runs.
    expect(pill.overlaps(fab), isFalse);
    expect(pill.bottom, lessThanOrEqualTo(fab.top));
  });

  testWidgets('claims no hit-test area when there is nothing to show', (
    tester,
  ) async {
    var fabTaps = 0;
    await tester.pumpWidget(
      app(queue: const UploadQueueState(), onFab: () => fabTaps++),
    );
    await tester.pumpAndSettle();

    expect(tester.getSize(find.byType(UploadTray)).height, 0);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    expect(fabTaps, 1);
  });

  testWidgets('opens the uploads sheet from above the Navigator', (
    tester,
  ) async {
    await tester.pumpWidget(app(queue: waiting, onFab: () {}));
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('No connection'));
    await tester.pumpAndSettle();

    // This is the only route to the queue detail sheet in the whole app: if
    // the tray cannot resolve a Navigator, "Retry all", "Cancel all" and
    // per-item status are unreachable and a stuck batch can never be cleared.
    expect(find.text('Nothing uploading'), findsOneWidget);
  });
}

class _StubQueue extends UploadQueueNotifier {
  _StubQueue(this._state);

  final UploadQueueState _state;

  /// Deliberately does not call super: the real build() wires connectivity and
  /// lifecycle listeners and reads Hive boxes that no widget test has.
  @override
  UploadQueueState build() => _state;
}
