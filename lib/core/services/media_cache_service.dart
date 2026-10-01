import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_compress/video_compress.dart';

import '../models/album.dart';
import '../models/app_config.dart';
import '../models/media_item.dart';
import '../platform.dart';

/// Decodes a still frame from the video at [videoPath], or null.
///
/// Injected rather than called directly so the cache's key derivation and
/// fallbacks can be exercised in a test: the real implementation is a platform
/// channel, which no widget test has.
typedef PosterFrameBuilder = Future<Uint8List?> Function(String videoPath);

Future<Uint8List?> _decodePosterFrame(String videoPath) {
  // position is in ms; 1s in rather than frame 0, which on most phone clips is
  // black. Quality is lower than the upload path's cover frame because this
  // one is only ever drawn into a grid cell.
  return VideoCompress.getByteThumbnail(videoPath, quality: 70, position: 1000);
}

/// Disk cache for photo and video bytes.
///
/// THE CACHE KEY IS THE BLOB SHA, NOT THE URL. This is the single most
/// consequential decision in the caching design and the easiest to get wrong.
///
/// glickr must build media URLs pinned to a commit sha, because that is what
/// the website does and a branch-pinned URL is cached by whichever host serves
/// it (so a just-uploaded photo would 404, and a replaced one would serve
/// stale). But the head commit sha changes on EVERY push to ANY album - which
/// means a URL-keyed cache would re-download all 66 thumbnails of one album
/// because a photo was added to a different one.
///
/// A git blob sha is a content hash. Keying on it means a push invalidates
/// exactly the files whose bytes actually changed, and nothing else.
class MediaCacheService {
  /// Grid thumbnails. The site has no separate thumbnail tier - it uses the
  /// full image with `object-fit: cover` - so glickr downloads the full file
  /// once and simply decodes it small for the grid.
  static const String _cacheKey = 'glickrMedia';

  final CacheManager _manager;
  final PosterFrameBuilder _posterFrame;

  MediaCacheService({
    CacheManager? manager,
    int maxObjects = 1200,
    PosterFrameBuilder posterFrame = _decodePosterFrame,
  }) : _manager =
           manager ??
           CacheManager(
             Config(
               _cacheKey,
               // Content-addressed entries can never go stale, so the only
               // reason to evict is space. A year is effectively "never".
               stalePeriod: const Duration(days: 365),
               maxNrOfCacheObjects: maxObjects,
               // sqflite on Android, as by default. Not on macOS, where it
               // looks for an old copy in ~/Documents on every launch - and
               // that raises a folder-access prompt.
               repo: isDesktop
                   ? JsonCacheInfoRepository(databaseName: _cacheKey)
                   : CacheObjectProvider(databaseName: _cacheKey),
               fileService: _UrlExtensionFileService(),
             ),
           ),
       _posterFrame = posterFrame;

  CacheManager get manager => _manager;

  /// Cache key for the still frame derived from the video with this blob sha.
  ///
  /// Deriving it from the blob sha rather than inventing a second namespace
  /// means the poster inherits the video's invalidation exactly: replace the
  /// clip upstream and both entries miss together, because a blob sha is a
  /// content hash. The prefix cannot collide with a real sha, which is 40 hex
  /// characters and never contains a dash.
  static String posterKeyFor(String blobSha) => 'poster-$blobSha';

  /// The already-downloaded file for [item], or null.
  ///
  /// Never triggers a network request, so the grid can render synchronously
  /// from cache and an offline launch shows real photos rather than spinners.
  Future<File?> cachedFile(MediaItem item) async {
    final info = await _manager.getFileFromCache(item.blobSha);
    return info?.file;
  }

  /// Fetch [item], from cache when possible.
  Future<File> fetch({
    required AppConfig config,
    required Album album,
    required MediaItem item,
    required String commitSha,
  }) async {
    final hit = await cachedFile(item);
    if (hit != null) return hit;

    final url = config.mediaUrl(
      commitSha: commitSha,
      folder: album.folder,
      fileName: item.name,
    );
    final downloaded = await _manager.downloadFile(url, key: item.blobSha);
    return downloaded.file;
  }

  /// The already-generated poster frame for video [item], or null.
  ///
  /// Never triggers a network request, for the same reason [cachedFile] does
  /// not: an offline grid should show the posters it already has.
  Future<File?> cachedPoster(MediaItem item) async {
    final info = await _manager.getFileFromCache(posterKeyFor(item.blobSha));
    return info?.file;
  }

  /// A still frame for video [item], generated once and then cached.
  ///
  /// A video has no bytes an image decoder can read, so a tile that hands the
  /// .mp4 to `Image.file` renders nothing. This makes the frame the grid draws
  /// instead.
  ///
  /// Deriving it needs the clip itself, so the first call downloads the whole
  /// file. Everything after that is a cache read.
  ///
  /// Returns null on ANY failure - an unreachable host, a codec the device
  /// cannot decode, a clip shorter than the seek position. A video glickr
  /// cannot make a poster for falls back to the tile placeholder; it must
  /// never take the grid down with it.
  Future<File?> poster({
    required AppConfig config,
    required Album album,
    required MediaItem item,
    required String commitSha,
  }) async {
    if (isLinux) return null; // no frame decoder: don't fetch a whole clip
    final key = posterKeyFor(item.blobSha);
    final hit = await _manager.getFileFromCache(key);
    if (hit != null) return hit.file;

    try {
      final video = await fetch(
        config: config,
        album: album,
        item: item,
        commitSha: commitSha,
      );
      final bytes = await _posterFrame(video.absolute.path);
      if (bytes == null || bytes.isEmpty) return null;
      return await _manager.putFile(
        // The URL is only an identifier here; the key is what lookups use.
        'glickr://$key',
        bytes,
        key: key,
        fileExtension: 'jpg',
        maxAge: const Duration(days: 365),
      );
    } catch (_) {
      return null;
    }
  }

  /// Store bytes glickr just uploaded under their blob sha.
  ///
  /// Seeding from the local file the moment a commit lands means the photos
  /// the user just added are viewable instantly, with no download and no
  /// dependency on the media host having caught up with the push.
  Future<void> seed({
    required String blobSha,
    required Uint8List bytes,
    required String fileExtension,
  }) async {
    await _manager.putFile(
      // The URL is only an identifier here; the key is what lookups use.
      'glickr://$blobSha',
      bytes,
      key: blobSha,
      fileExtension: fileExtension.replaceFirst('.', ''),
      maxAge: const Duration(days: 365),
    );
  }

  /// Drop one entry, for when a file's bytes were replaced upstream.
  ///
  /// Takes the poster with it. The two are one logical entry, and a poster
  /// left behind after a truncated video was evicted would keep the grid
  /// showing a frame from a clip that is no longer there.
  Future<void> evict(String blobSha) async {
    await _manager.removeFile(blobSha);
    await _manager.removeFile(posterKeyFor(blobSha));
  }

  Future<void> clear() => _manager.emptyCache();

  /// Bytes currently held on disk, for the Settings "Cached media" row.
  ///
  /// Walks the cache directory directly, because flutter_cache_manager exposes
  /// no size API. Treats every failure as zero: this is a display number, and
  /// Android may reclaim the directory underneath us at any moment.
  Future<int> cacheSizeBytes() async {
    try {
      final root = await getTemporaryDirectory();
      final dir = Directory(p.join(root.path, _cacheKey));
      if (!await dir.exists()) return 0;
      var total = 0;
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        try {
          total += await entity.length();
        } catch (_) {
          // Vanished mid-walk; skip it.
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }
}

/// raw.githubusercontent.com serves every video as application/octet-stream,
/// so the cache would name it .bin - and AVFoundation (macOS player, poster
/// frames) and the Linux desktop's default-app lookup go by the extension.
class _UrlExtensionFileService extends HttpFileService {
  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async => _WithExtension(
    await super.get(url, headers: headers),
    p.extension(Uri.parse(url).path),
  );
}

class _WithExtension implements FileServiceResponse {
  _WithExtension(this._inner, this.fileExtension);
  final FileServiceResponse _inner;
  @override
  final String fileExtension;
  @override
  Stream<List<int>> get content => _inner.content;
  @override
  int? get contentLength => _inner.contentLength;
  @override
  int get statusCode => _inner.statusCode;
  @override
  DateTime get validTill => _inner.validTill;
  @override
  String? get eTag => _inner.eTag;
}
