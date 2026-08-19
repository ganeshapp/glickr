import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/album.dart';
import '../models/app_config.dart';
import '../models/media_item.dart';

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

  MediaCacheService({CacheManager? manager, int maxObjects = 1200})
    : _manager =
          manager ??
          CacheManager(
            Config(
              _cacheKey,
              // Content-addressed entries can never go stale, so the only
              // reason to evict is space. A year is effectively "never".
              stalePeriod: const Duration(days: 365),
              maxNrOfCacheObjects: maxObjects,
            ),
          );

  CacheManager get manager => _manager;

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
  Future<void> evict(String blobSha) => _manager.removeFile(blobSha);

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
