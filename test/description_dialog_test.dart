import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glickr/core/models/album.dart';
import 'package:glickr/core/theme/app_theme.dart';
import 'package:glickr/features/albums/widgets/description_dialog.dart';

/// The dialog autofocuses the summary, so it always opens with the keyboard
/// up - and on a small phone two fields and a help line do not fit above it.
void main() {
  testWidgets('fits a small phone with the keyboard up', (tester) async {
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1.0;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.lightTheme, home: const Scaffold()),
    );
    showDescriptionDialog(
      tester.element(find.byType(Scaffold)),
      Album(folder: 'trip'),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
