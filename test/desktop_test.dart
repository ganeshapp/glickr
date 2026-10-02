import 'dart:io';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';

import 'package:glickr/core/platform.dart';
import 'package:glickr/core/providers/gallery_provider.dart';
import 'package:glickr/core/services/desktop_media.dart';
import 'package:glickr/core/services/media_cache_service.dart';
import 'package:glickr/features/picker/presentation/media_picker_screen.dart';

/// The GTK folder dialog, answered by the test.
class _FakeSelector extends FileSelectorPlatform {
  String? answer;

  @override
  Future<String?> getDirectoryPathWithOptions(
    FileDialogOptions options,
  ) async => answer;
}

/// A gallery holding one full page, with more to come, that counts the asks.
class _OnePageGallery extends GalleryNotifier {
  int asks = 0;

  @override
  GalleryState build() {
    final bucket = AssetPathEntity(id: 'all', name: 'Recents');
    return GalleryState(
      access: GalleryAccess.granted,
      buckets: [bucket],
      activeBucket: bucket,
      assets: [for (var i = 0; i < 120; i++) fileAsset('/photos/$i.jpg')],
    );
  }

  @override
  Future<void> requestAndLoad() async {}

  @override
  Future<void> loadMore() async => asks++;
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

    test(
      'HEIC goes through sips on macOS, then the same encoder',
      () async {
        runAs(TargetPlatform.macOS);
        final source = img.Image(width: 400, height: 300);
        source.exif.imageIfd.orientation = 6;
        final heic = p.join(tmp.path, 'source.heic');
        final sips = Process.runSync('sips', [
          '-s', 'format', 'heic', write(source), '--out', heic, //
        ]);
        expect(sips.exitCode, 0, reason: '${sips.stderr}');

        final target = p.join(tmp.path, 'out.jpg');
        final out = await encodeJpeg(heic, target, maxEdge: 160, quality: 85);

        final result = img.decodeJpg(out.readAsBytesSync())!;
        expect(result.exif.isEmpty, isTrue);
        expect((result.width, result.height), (120, 160));
        expect(File('$target.heic.jpg').existsSync(), isFalse);
      },
      skip: !Platform.isMacOS,
    );

    test('HEIC elsewhere is a clear refusal, not a decoder error', () async {
      runAs(TargetPlatform.linux);
      File(p.join(tmp.path, 'a.heic')).writeAsStringSync('');
      expect(
        encodeJpeg(
          p.join(tmp.path, 'a.heic'),
          p.join(tmp.path, 'out.jpg'),
          maxEdge: 160,
          quality: 85,
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('HEIC'),
          ),
        ),
      );
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

  group('desktop folder gallery', () {
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

    test('a folder with no usable photos says why', () async {
      File(p.join(tmp.path, 'IMG_0001.HEIC')).writeAsStringSync('');
      selector.answer = tmp.path;

      await container.read(galleryNotifierProvider.notifier).requestAndLoad();

      final state = container.read(galleryNotifierProvider);
      expect(state.assets, isEmpty);
      expect(state.error, 'That folder has no JPEG, PNG or WebP photos.');
    });

    test('macOS lists HEIC too, since sips can convert it', () async {
      runAs(TargetPlatform.macOS);
      for (final name in ['IMG_0001.HEIC', 'b.jpg', 'c.heif']) {
        File(p.join(tmp.path, name)).writeAsStringSync('');
      }
      selector.answer = tmp.path;

      await container.read(galleryNotifierProvider.notifier).requestAndLoad();

      final state = container.read(galleryNotifierProvider);
      expect(state.error, isNull);
      expect(state.assets.map((a) => p.basename(a.id)), [
        'IMG_0001.HEIC',
        'b.jpg',
        'c.heif',
      ]);
    });

    test('a folder that cannot be read is an error, not a crash', () async {
      selector.answer = p.join(tmp.path, 'gone');

      await container.read(galleryNotifierProvider.notifier).requestAndLoad();

      expect(container.read(galleryNotifierProvider).error, isNotNull);
    });

    test('thumbnails come from the file itself', () {
      final thumb = assetThumbnail(fileAsset('/photos/a.jpg'), 240);
      expect(thumb, isA<ResizeImage>());
      final file = (thumb as ResizeImage).imageProvider as FileImage;
      expect(file.file.path, '/photos/a.jpg');
    });
  });

  group('picker paging', () {
    Future<int> asksFor(WidgetTester tester, Size window) async {
      tester.view.physicalSize = window;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // Photos access already granted, so the phone goes straight to the grid.
      const photos = MethodChannel('com.fluttercandies/photo_manager');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        photos,
        (call) async =>
            call.method == 'getPermissionState'
                ? PermissionState.authorized.index
                : null,
      );
      addTearDown(() => messenger.setMockMethodCallHandler(photos, null));
      final gallery = _OnePageGallery();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [galleryNotifierProvider.overrideWith(() => gallery)],
          child: const MaterialApp(home: MediaPickerScreen()),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('upload in the order'), findsOneWidget);
      // Lets the phone's thumbnail requests, which fail here, run out.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      return gallery.asks;
    }

    // Paging is macOS's, but the grid is every desktop's, and Linux's
    // thumbnails need no photo_manager plugin.
    testWidgets(
      'a window the first page cannot fill still asks for the next one',
      (tester) async {
        expect(await asksFor(tester, const Size(1728, 1079)), 1);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
    );

    testWidgets('a phone waits until the grid is scrolled', (tester) async {
      expect(await asksFor(tester, const Size(390, 844)), 0);
    });
  });

  group('app directories', () {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    /// The path_provider method [platform] answers [dir] with, or null.
    Future<String?> askedFor(
      TargetPlatform platform,
      Future<Directory> Function() dir,
    ) async {
      runAs(platform);
      String? method;
      messenger.setMockMethodCallHandler(channel, (call) async {
        method = call.method;
        return tmp.path;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await dir();
      return method;
    }

    test('Android keeps the documents directory and its own cache', () async {
      expect(
        await askedFor(TargetPlatform.android, appDataDir),
        'getApplicationDocumentsDirectory',
      );
      expect(
        await askedFor(TargetPlatform.android, appCacheDir),
        'getTemporaryDirectory',
      );
    });

    test('macOS uses Application Support and Caches', () async {
      expect(
        await askedFor(TargetPlatform.macOS, appDataDir),
        'getApplicationSupportDirectory',
      );
      expect(
        await askedFor(TargetPlatform.macOS, appCacheDir),
        'getApplicationCacheDirectory',
      );
    });

    group('Linux', () {
      setUp(() {
        debugEnvironmentOverride = {'HOME': tmp.path};
        addTearDown(() => debugEnvironmentOverride = null);
      });

      test(
        'XDG defaults, named after the app id, private to the user',
        () async {
          // Not path_provider: its Linux answer depends on whether libgio can
          // be dlopen'd, so it moves when libglib2.0-dev is installed.
          expect(await askedFor(TargetPlatform.linux, appDataDir), isNull);
          expect(await askedFor(TargetPlatform.linux, appCacheDir), isNull);

          final data = await appDataDir();
          final cache = await appCacheDir();
          expect(data.path, p.join(tmp.path, '.local/share/com.glickr.glickr'));
          expect(cache.path, p.join(tmp.path, '.cache/com.glickr.glickr'));
          expect(data.statSync().modeString(), 'rwx------');
          expect(cache.statSync().modeString(), 'rwx------');
        },
      );

      test(
        'an absolute XDG variable wins; a relative one is ignored',
        () async {
          runAs(TargetPlatform.linux);
          debugEnvironmentOverride = {
            'HOME': tmp.path,
            'XDG_DATA_HOME': p.join(tmp.path, 'data'),
            'XDG_CACHE_HOME': 'relative',
          };

          expect(
            (await appDataDir()).path,
            p.join(tmp.path, 'data', 'com.glickr.glickr'),
          );
          expect(
            (await appCacheDir()).path,
            p.join(tmp.path, '.cache', 'com.glickr.glickr'),
          );
        },
      );

      test('the media cache is one directory: files, index and the number '
          'Settings shows', () async {
        runAs(TargetPlatform.linux);
        final cache = MediaCacheService();
        await cache.seed(
          blobSha: 'abc123',
          bytes: Uint8List.fromList(List.filled(10, 1)),
          fileExtension: '.jpg',
        );
        await cache.manager.dispose(); // flushes the index

        final root = p.join(tmp.path, '.cache', 'com.glickr.glickr');
        final files = Directory(p.join(root, 'glickrMedia')).listSync();
        expect(files.whereType<File>().single.lengthSync(), 10);
        expect(File(p.join(root, 'glickrMedia.json')).existsSync(), isTrue);
        expect(await cache.cacheSizeBytes(), 10);
      });
    });
  });
}
