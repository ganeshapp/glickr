import 'dart:io';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glickr/core/services/desktop_media.dart';
import 'package:glickr/core/providers/config_provider.dart';
import 'package:glickr/core/models/app_config.dart';
import 'package:glickr/core/widgets/desktop_photo_drop_target.dart';
import 'package:glickr/features/picker/presentation/media_picker_screen.dart';
import 'package:image/image.dart' as img;

class _Config extends ConfigNotifier {
  @override
  AppConfig? build() => null;
}

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('drop_test');
  });
  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await dir.delete(recursive: true);
  });
  test(
    'file drops filter unsupported files and directories, deduplicate and retain order',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      for (final name in ['b.JPG', 'a.png', 'movie.mp4', 'mac.heic']) {
        await File('${dir.path}/$name').writeAsBytes([1]);
      }
      await Directory('${dir.path}/folder.jpg').create();
      final photos = await droppedPhotoAssets([
        for (final name in [
          'b.JPG',
          'movie.mp4',
          'a.png',
          'b.JPG',
          'folder.jpg',
          'missing.png',
          'mac.heic',
        ])
          '${dir.path}/$name',
      ]);
      expect(photos.map((a) => a.id), [
        '${dir.path}/b.JPG',
        '${dir.path}/a.png',
      ]);
    },
  );
  testWidgets(
    'dropped photos open already selected without opening a folder dialog',
    (tester) async {
      final file = File('${dir.path}/test.png');
      file.writeAsBytesSync(img.encodePng(img.Image(width: 8, height: 8)));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [configNotifierProvider.overrideWith(_Config.new)],
          child: MaterialApp(
            home: MediaPickerScreen(droppedAssets: [fileAsset(file.path)]),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Next - 1 selected'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant({TargetPlatform.linux}),
  );
  testWidgets('drop targets are disabled behind another route', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: DesktopPhotoDropTarget(
          onPhotos: (_) async {},
          child: const Scaffold(body: Text('Albums')),
        ),
      ),
    );
    expect(tester.widget<DropTarget>(find.byType(DropTarget)).enable, isTrue);
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Review')),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<DropTarget>(find.byType(DropTarget, skipOffstage: false))
          .enable,
      isFalse,
    );
  }, variant: TargetPlatformVariant({TargetPlatform.linux}));
}
