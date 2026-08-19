import 'package:hive/hive.dart';

import '../utils/album_conventions.dart';

part 'media_item.g.dart';

/// One file inside an album folder (Hive typeId 2).
///
/// This is a nested VALUE type and deliberately does NOT extend [HiveObject]:
/// a HiveObject carries box-and-key identity that is meaningless for an object
/// stored inside another object's field, and calling `.save()` on one throws
/// at runtime. hive_generator will happily generate an adapter either way, so
/// the mistake only shows up in production.
///
/// MIGRATION SAFETY: fields added after v1 are nullable `xxxRaw` @HiveFields
/// with non-nullable getters supplying the default, so older records keep
/// deserializing. A retired field index is never reused.
@HiveType(typeId: 2)
class MediaItem {
  /// Basename only, e.g. `0001.jpg` or `0.jpg`. Never a path.
  @HiveField(0)
  final String name;

  /// Git blob sha from the tree API.
  ///
  /// This is the byte cache key, not the URL. Media URLs are pinned to the
  /// head COMMIT sha, which changes on every push to any album - so keying the
  /// cache on the URL would re-download every thumbnail in the repo each time
  /// one photo is added. A blob sha is a content hash, so it only changes when
  /// the file actually changes.
  @HiveField(1)
  final String blobSha;

  @HiveField(2)
  final int? sizeRaw;

  /// Caption merged in from `album.json`; null means the file has no entry.
  @HiveField(3)
  final String? captionRaw;

  const MediaItem({
    required this.name,
    required this.blobSha,
    this.sizeRaw,
    this.captionRaw,
  });

  int get size => sizeRaw ?? 0;
  String get caption => captionRaw ?? '';
  bool get hasCaption => (captionRaw?.trim().isNotEmpty) ?? false;

  // Derived, never stored - storing them would let the cache disagree with
  // album_conventions.dart, which is the one file allowed to define these.
  String get ext => extensionOf(name);
  bool get isVideo => isVideoName(name);
  bool get isImage => isImageName(name);

  /// Sequence number glickr assigned, or null for a legacy/hand-added file.
  int? get number => parseSequenceNumber(name);

  MediaItem copyWith({
    String? name,
    String? blobSha,
    int? size,
    String? caption,
    bool clearCaption = false,
  }) {
    return MediaItem(
      name: name ?? this.name,
      blobSha: blobSha ?? this.blobSha,
      sizeRaw: size ?? sizeRaw,
      captionRaw: clearCaption ? null : (caption ?? captionRaw),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MediaItem && other.name == name && other.blobSha == blobSha;

  @override
  int get hashCode => Object.hash(name, blobSha);
}
