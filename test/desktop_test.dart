import 'dart:io';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'package:glickr/core/platform.dart';
import 'package:glickr/core/providers/gallery_provider.dart';
import 'package:glickr/core/services/linux_media.dart';

/// The GTK folder dialog, answered by the test.
class _FakeSelector extends FileSelectorPlatform {
  String? answer;

  @override
  Future<String?> getDirectoryPathWithOptions(
    FileDialogOptions options,
  ) async => answer;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('glickr_desktop_test');
    addTearDown(() => tmp.delete(recursive: true));
  });

  void runAs(TargetPlatform platform) {
    debugDefaultTargetPlatformOverride = platform;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
  }

  group('encodeJpeg', () {
    String write(img.Image image) {
      final path = p.join(tmp.path, 'source.jpg');
      File(path).writeAsBytesSync(img.encodeJpg(image));
      return path;
    }

    test('applies the rotation, caps the long edge and drops EXIF', () async {
      final source = img.Image(width: 400, height: 300);
      source.exif.imageIfd.orientation = 6; // 90 degrees: really 300x400
      source.exif.gpsIfd.gpsLatitude = 12.97;
      final out = await encodeJpeg(
        write(source),
        p.join(tmp.path, 'out.jpg'),
        maxEdge: 160,
        quality: 85,
      );

      final result = img.decodeJpg(out.readAsBytesSync())!;
      expect(result.exif.isEmpty, isTrue);
      expect((result.width, result.height), (120, 160));
    });

    test('never upscales', () async {
      final out = await encodeJpeg(
        write(img.Image(width: 100, height: 80)),
        p.join(tmp.path, 'out.jpg'),
        maxEdge: 160,
        quality: 85,
      );

      final result = img.decodeJpg(out.readAsBytesSync())!;
      expect((result.width, result.height), (100, 80));
    });

    test('rejects a file that is not an image', () async {
      final source = File(p.join(tmp.path, 'notes.jpg'))
        ..writeAsStringSync('not a photo');
      expect(
        encodeJpeg(
          source.path,
          p.join(tmp.path, 'out.jpg'),
          maxEdge: 160,
          quality: 85,
        ),
        throwsFormatException,
      );
    });
  });

  group('Linux folder gallery', () {
    late _FakeSelector selector;
    late ProviderContainer container;

    setUp(() {
      runAs(TargetPlatform.linux);
      selector = _FakeSelector();
      FileSelectorPlatform.instance = selector;
      container = ProviderContainer();
      addTearDown(container.dispose);
      // Keeps the autoDispose provider alive, as the picker screen does.
      container.listen(galleryNotifierProvider, (_, _) {});
    });

    test('lists the photos in the folder by file name', () async {
      for (final name in ['b.JPG', 'a.png', 'c.txt', 'd.heic']) {
        File(p.join(tmp.path, name)).writeAsStringSync('');
      }
      Directory(p.join(tmp.path, 'e.jpg')).createSync();
      selector.answer = tmp.path;

      await container.read(galleryNotifierProvider.notifier).requestAndLoad();

      final state = container.read(galleryNotifierProvider);
      expect(state.access, GalleryAccess.granted);
      expect(state.hasMore, isFalse);
      expect(state.assets.map((a) => p.basename(a.id)), ['a.png', 'b.JPG']);
    });

    test('cancelling the dialog keeps the folder already showing', () async {
      File(p.join(tmp.path, 'a.jpg')).writeAsStringSync('');
      selector.answer = tmp.path;
      final notifier = container.read(galleryNotifierProvider.notifier);
      await notifier.requestAndLoad();

      selector.answer = null;
      await notifier.requestAndLoad();

      expect(container.read(galleryNotifierProvider).assets, hasLength(1));
    });

    test('thumbnails come from the file itself', () {
      final thumb = assetThumbnail(fileAsset('/photos/a.jpg'), 240);
      expect(thumb, isA<ResizeImage>());
      final file = (thumb as ResizeImage).imageProvider as FileImage;
      expect(file.file.path, '/photos/a.jpg');
    });
  });

  group('appDataDir', () {
    const channel = MethodChannel('plugins.flutter.io/path_provider');

    Future<String> askedFor(TargetPlatform platform) async {
      runAs(platform);
      String? method;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            method = call.method;
            return tmp.path;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      await appDataDir();
      return method!;
    }

    test('Android keeps the documents directory', () async {
      expect(
        await askedFor(TargetPlatform.android),
        'getApplicationDocumentsDirectory',
      );
    });

    test('desktop uses application support, not ~/Documents', () async {
      expect(
        await askedFor(TargetPlatform.linux),
        'getApplicationSupportDirectory',
      );
      expect(
        await askedFor(TargetPlatform.macOS),
        'getApplicationSupportDirectory',
      );
    });
  });
}
