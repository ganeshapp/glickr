import 'package:hive/hive.dart';

import '../utils/album_conventions.dart';
import 'media_item.dart';

part 'album.g.dart';

/// One album folder in the repo (Hive typeId 1), keyed in `albums_box` by
/// [folder].
///
/// MediaItemAdapter must be registered BEFORE AlbumAdapter in main.dart -
/// getting the order wrong produces an "unknown typeId" that only reproduces
/// against a warm cache, never on a fresh install.
@HiveType(typeId: 1)
class Album extends HiveObject {
  /// Repo folder name - the canonical id, e.g. `cycling_trip`.
  @HiveField(0)
  String folder;

  /// `album.md` body, with any front matter already stripped (the site's
  /// generator tolerates front matter but does not require it, and every
  /// album.md in the real repo is a bare line of prose).
  @HiveField(1)
  String blurb;

  /// Every media file in the folder, cover included. `album.md` and
  /// `album.json` are not items; they are tracked by their own sha fields.
  @HiveField(2)
  List<MediaItem> items;

  /// Git tree sha OF THIS FOLDER. Comes free in the recursive tree response
  /// and is the per-album invalidation key: if it matches, nothing inside the
  /// album changed and there is nothing to refetch.
  @HiveField(3)
  String? treeShaRaw;

  /// Blob sha of `album.md`, used to detect a concurrent edit before
  /// overwriting someone else's description.
  @HiveField(4)
  String? blurbShaRaw;

  /// Blob sha of `album.json`.
  @HiveField(5)
  String? captionsShaRaw;

  /// Verbatim `album.json` text as last fetched.
  ///
  /// Kept so a caption write can be replayed as a delta onto the current
  /// remote copy instead of clobbering it, and so top-level keys a human added
  /// by hand round-trip intact rather than being silently dropped.
  @HiveField(6)
  String? captionsJsonRaw;

  /// Mirror of `album.json`'s monotonic `next`. Never lowered by a deletion,
  /// which is what makes filename reuse impossible.
  @HiveField(7)
  int? nextNumberRaw;

  @HiveField(8)
  DateTime? lastSyncedRaw;

  Album({
    required this.folder,
    this.blurb = '',
    List<MediaItem>? items,
    String? treeSha,
    String? blurbSha,
    String? captionsSha,
    String? captionsJson,
    int? nextNumber,
    DateTime? lastSynced,
  }) : items = items ?? <MediaItem>[],
       treeShaRaw = treeSha,
       blurbShaRaw = blurbSha,
       captionsShaRaw = captionsSha,
       captionsJsonRaw = captionsJson,
       nextNumberRaw = nextNumber,
       lastSyncedRaw = lastSynced;

  String? get treeSha => treeShaRaw;
  String? get blurbSha => blurbShaRaw;
  String? get captionsSha => captionsShaRaw;
  String? get captionsJson => captionsJsonRaw;
  int? get nextNumber => nextNumberRaw;
  DateTime? get lastSynced => lastSyncedRaw;

  /// The title the website shows. Derived, never stored, so it can never drift
  /// from the folder name.
  String get title => albumTitle(folder);

  /// The URL path segment on the site, e.g. `cycling-trip`.
  String get slug => jekyllSlugify(folder);

  /// The album's cover: its first image in display order.
  ///
  /// Derived, not stored, and not a separate file - see [coverNameOf].
  MediaItem? get cover {
    final name = coverNameOf(items.map((i) => i.name));
    return name == null ? null : itemNamed(name);
  }

  /// True when [item] is the one being used as this album's cover.
  bool isCover(MediaItem item) => cover?.name == item.name;

  /// Items in the order the website renders them: sorted by filename with the
  /// cover excluded (falling back to everything when that would empty the
  /// grid, exactly as the site does).
  List<MediaItem> get gallery {
    final byName = {for (final i in items) i.name: i};
    return galleryOrder(byName.keys).map((n) => byName[n]!).toList();
  }

  /// Items in display order INCLUDING the cover.
  ///
  /// The album screen shows the cover - hiding it would read as data loss
  /// ("where did my photo go?"), and it is the only way "Set as cover" is
  /// self-explanatory. It carries a Cover chip instead.
  List<MediaItem> get allInDisplayOrder {
    final byName = {for (final i in items) i.name: i};
    return sortForDisplay(byName.keys).map((n) => byName[n]!).toList();
  }

  int get photoCount => gallery.where((i) => i.isImage).length;
  int get videoCount => gallery.where((i) => i.isVideo).length;

  /// Total bytes this album occupies in the repo, cover included.
  int get totalBytes => items.fold(0, (sum, i) => sum + i.size);

  MediaItem? itemNamed(String name) {
    for (final item in items) {
      if (item.name == name) return item;
    }
    return null;
  }

  Album copyWith({
    String? folder,
    String? blurb,
    List<MediaItem>? items,
    String? treeSha,
    String? blurbSha,
    String? captionsSha,
    String? captionsJson,
    int? nextNumber,
    DateTime? lastSynced,
  }) {
    return Album(
      folder: folder ?? this.folder,
      blurb: blurb ?? this.blurb,
      items: items ?? List<MediaItem>.from(this.items),
      treeSha: treeSha ?? treeShaRaw,
      blurbSha: blurbSha ?? blurbShaRaw,
      captionsSha: captionsSha ?? captionsShaRaw,
      captionsJson: captionsJson ?? captionsJsonRaw,
      nextNumber: nextNumber ?? nextNumberRaw,
      lastSynced: lastSynced ?? lastSyncedRaw,
    );
  }
}
