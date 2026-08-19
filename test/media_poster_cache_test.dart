import 'dart:io' as io;
import 'dart:typed_data';

// flutter_cache_manager's own File type comes from `file`, not dart:io, so a
// stand-in for it has to speak the same one. It is a transitive dependency
// rather than a declared one, which is all this lint is objecting to.
// ignore: depend_on_referenced_packages
import 'package:file/file.dart' as fs;
// ignore: depend_on_referenced_packages
import 'package:file/local.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glickr/core/models/album.dart';
import 'package:glickr/core/models/app_config.dart';
import 'package:glickr/core/models/media_item.dart';
import 'package:glickr/core/services/media_cache_service.dart';
import 'package:path/path.dart' as p;

/// A video has no bytes an image decoder can read, so an album tile that hands
/// the .mp4 to `Image.file` renders an empty square. What renders instead is a
/// poster frame derived from the clip and cached under its own key.
///
/// NOT TESTED HERE, and not testable in this suite: the decode itself.
/// Extracting a frame is a `video_compress` platform channel call against a
/// real video file, and a widget test has neither the channel nor an asset to
/// feed it. Stubbing the decoder and then asserting the stub ran would only
/// prove the stub. What IS worth pinning is everything around it - the key the
/// poster is stored under, that it is derived once rather than per scroll, and
/// that a clip glickr cannot make a poster for degrades to null instead of
/// taking the grid down.
void main() {
  late io.Directory root;
  late _FakeCacheManager manager;

  setUp(() {
    root = io.Directory.systemTemp.createTempSync('glickr_poster_test');
    manager = _FakeCacheManager(root);
  });

  tearDown(() => root.deleteSync(recursive: true));

  final config = AppConfig(
    repoOwner: 'ganeshapp',
    repoName: 'ganeshapp.github.io',
  );
  final album = Album(folder: 'cycling_trip');
  const video = MediaItem(name: '0002.mp4', blobSha: 'bbb222');

  MediaCacheService service({required PosterFrameBuilder frame}) =>
      MediaCacheService(manager: manager, posterFrame: frame);

  group('posterKeyFor', () {
    test('derives the poster key from the blob sha', () {
      expect(MediaCacheService.posterKeyFor('bbb222'), 'poster-bbb222');
    });

    test('cannot collide with the key the clip itself is cached under', () {
      // A git blob sha is 40 hex characters and never contains a dash, so no
      // real media key can ever equal a poster key. This is what lets the
      // poster live in the same store as the bytes it came from.
      expect(MediaCacheService.posterKeyFor('bbb222'), isNot('bbb222'));
      expect(MediaCacheService.posterKeyFor('bbb222'), contains('-'));
    });

    test('is content-addressed, so a replaced clip misses on both keys', () {
      expect(
        MediaCacheService.posterKeyFor('bbb222'),
        isNot(MediaCacheService.posterKeyFor('ccc333')),
      );
    });
  });

  group('poster', () {
    test('derives the frame once and serves the cache after that', () async {
      var decodes = 0;
      final cache = service(
        frame: (path) async {
          decodes++;
          return Uint8List.fromList(const [1, 2, 3, 4]);
        },
      );

      final first = await cache.poster(
        config: config,
        album: album,
        item: video,
        commitSha: 'a1b2c3',
      );
      final second = await cache.poster(
        config: config,
        album: album,
        item: video,
        commitSha: 'a1b2c3',
      );

      expect(first, isNotNull);
      expect(second!.path, first!.path);
      // The point of the whole exercise: a grid that scrolls past the same
      // video fifty times decodes one frame, not fifty.
      expect(decodes, 1);
      expect(manager.downloads, hasLength(1));
    });

    test('stores the frame under the poster key, not the clip key', () async {
      final cache = service(
        frame: (path) async => Uint8List.fromList(const [1, 2, 3, 4]),
      );
      await cache.poster(
        config: config,
        album: album,
        item: video,
        commitSha: 'a1b2c3',
      );

      expect(manager.files, contains(MediaCacheService.posterKeyFor('bbb222')));
      // The clip's own bytes are still there under their own key, so opening
      // the video in the viewer does not download it a second time.
      expect(manager.files, contains('bbb222'));
    });

    test('reads a cached poster without touching the network', () async {
      final cache = service(
        frame: (path) async => Uint8List.fromList(const [1, 2, 3, 4]),
      );
      await cache.poster(
        config: config,
        album: album,
        item: video,
        commitSha: 'a1b2c3',
      );
      manager.downloads.clear();

      expect(await cache.cachedPoster(video), isNotNull);
      expect(manager.downloads, isEmpty);
    });

    test('returns null rather than throwing when the decode fails', () async {
      final cache = service(
        frame: (path) async => throw StateError('no codec'),
      );

      // A video whose frame cannot be extracted falls back to the tile
      // placeholder. Letting this throw would take down the whole grid the
      // failing tile happens to be in.
      expect(
        await cache.poster(
          config: config,
          album: album,
          item: video,
          commitSha: 'a1b2c3',
        ),
        isNull,
      );
    });

    test('treats an empty frame as no frame', () async {
      final cache = service(frame: (path) async => Uint8List(0));

      expect(
        await cache.poster(
          config: config,
          album: album,
          item: video,
          commitSha: 'a1b2c3',
        ),
        isNull,
      );
      // Nothing cached, so a later attempt can still succeed.
      expect(
        manager.files,
        isNot(contains(MediaCacheService.posterKeyFor('bbb222'))),
      );
    });

    test('returns null when the clip itself cannot be fetched', () async {
      manager.failDownloads = true;
      final cache = service(
        frame: (path) async => Uint8List.fromList(const [1, 2, 3, 4]),
      );

      expect(
        await cache.poster(
          config: config,
          album: album,
          item: video,
          commitSha: 'a1b2c3',
        ),
        isNull,
      );
    });
  });

  test('evicting a clip takes its poster with it', () async {
    final cache = service(
      frame: (path) async => Uint8List.fromList(const [1, 2, 3, 4]),
    );
    await cache.poster(
      config: config,
      album: album,
      item: video,
      commitSha: 'a1b2c3',
    );

    await cache.evict('bbb222');

    // A poster left behind would keep the grid showing a frame from a clip
    // that is no longer in the cache.
    expect(manager.files, isEmpty);
  });
}

/// Stands in for the real cache manager, which needs sqlite and a platform
/// temp directory that no test binary has.
class _FakeCacheManager implements CacheManager {
  _FakeCacheManager(this.root);

  final io.Directory root;
  final Map<String, fs.File> files = <String, fs.File>{};
  final List<String> downloads = <String>[];
  bool failDownloads = false;

  fs.File _write(String key, List<int> bytes, String extension) {
    final file = const LocalFileSystem().file(
      p.join(root.path, '$key.$extension'),
    );
    file.writeAsBytesSync(bytes);
    files[key] = file;
    return file;
  }

  @override
  Future<FileInfo?> getFileFromCache(
    String key, {
    bool ignoreMemCache = false,
  }) async {
    final file = files[key];
    if (file == null) return null;
    return FileInfo(file, FileSource.Cache, DateTime(2100), 'glickr://$key');
  }

  @override
  Future<FileInfo> downloadFile(
    String url, {
    String? key,
    Map<String, String>? authHeaders,
    bool force = false,
  }) async {
    if (failDownloads) throw const io.SocketException('offline');
    downloads.add(url);
    final file = _write(key ?? url, const [0, 0, 0, 32], 'mp4');
    return FileInfo(file, FileSource.Online, DateTime(2100), url);
  }

  @override
  Future<fs.File> putFile(
    String url,
    Uint8List fileBytes, {
    String? key,
    String? eTag,
    Duration maxAge = const Duration(days: 30),
    String fileExtension = 'file',
  }) async {
    return _write(key ?? url, fileBytes, fileExtension);
  }

  @override
  Future<void> removeFile(String key) async {
    files.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
