/// The contract between glickr and the Jekyll site that renders the album
/// repo.
///
/// Every rule here is a direct port of `_plugins/albums.rb` in the site repo.
/// If the site's generator changes, this file changes with it - and if the two
/// ever disagree, the app shows something the website doesn't, which is the
/// worst failure mode this app has. That is why these are pure functions with
/// unit tests rather than logic scattered through widgets.
library;

/// Image extensions the site renders. Ported from `albums.rb` IMAGE_EXT.
const Set<String> kImageExtensions = {
  '.jpg',
  '.jpeg',
  '.png',
  '.gif',
  '.webp',
  '.avif',
};

/// Video extensions the site renders. Ported from `albums.rb` VIDEO_EXT.
const Set<String> kVideoExtensions = {'.mp4', '.webm', '.mov'};

/// Sidecar files that live inside an album folder but are not media.
const String kBlurbFile = 'album.md';
const String kCaptionsFile = 'album.json';

/// Zero-pad width for filenames glickr creates.
///
/// Four, not the three the concept notes sketched. The site sorts filenames
/// with a plain byte comparison, and `"1000.jpg" < "999.jpg"` in that order -
/// so at three digits the 1000th photo silently jumps to the front of the
/// album and every one after it lands in the wrong place. That is a
/// correctness cliff, not a capacity limit, and four digits removes it for
/// free: there are no numbered files in the repo yet, so the migration cost
/// today is zero.
const int kDefaultPadWidth = 4;

/// Reader-side bound. Hand-created and legacy files may use any width, so
/// parsing accepts 1-6 digits even though writing always uses
/// [kDefaultPadWidth].
const int kMaxParsedDigits = 6;

/// Lowercase extension of [name] including the dot, or '' when it has none.
String extensionOf(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0) return '';
  return name.substring(dot).toLowerCase();
}

/// [name] without its extension.
String stemOf(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0) return name;
  return name.substring(0, dot);
}

bool isImageName(String name) => kImageExtensions.contains(extensionOf(name));

bool isVideoName(String name) => kVideoExtensions.contains(extensionOf(name));

/// True when [name] is media the site will render.
bool isRenderableName(String name) => isImageName(name) || isVideoName(name);

/// The album's cover: the FIRST image in display order, or null when the album
/// has no images at all.
///
/// There is no separate cover file. There used to be - a dedicated `0.jpg` -
/// and it meant the cover was stored twice, once as `0.jpg` and once numbered,
/// so a 23-photo album published 24 files with the cover appearing in its own
/// album twice and a caption attaching to only one of the two copies.
///
/// Since files sort by name, "first image" is the same rule with none of that.
/// It is also backwards compatible: an older album that still contains a
/// `0.jpg` sorts it first anyway, so it stays the cover.
///
/// Images only - a video cannot be a cover, because the site needs something
/// it can put in an `<img>`.
String? coverNameOf(Iterable<String> names) {
  for (final name in sortForDisplay(names)) {
    if (isImageName(name)) return name;
  }
  return null;
}

/// The album title the site will display, derived from the folder name.
///
/// Ports `folder.tr("_-", "  ").split.map(&:capitalize).join(" ")`. Ruby's
/// `capitalize` downcases the tail, so this is deliberately lossy in the same
/// way the site is: `NYC_trip` renders as "Nyc Trip" on the website, and the
/// app must agree rather than showing a prettier title than the user will get.
String albumTitle(String folder) {
  return folder
      .replaceAll(RegExp(r'[_-]'), ' ')
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .map((w) => w[0].toUpperCase() + w.substring(1).toLowerCase())
      .join(' ');
}

/// The URL slug Jekyll gives the generated album page.
///
/// Ports `Jekyll::Utils.slugify` in its default mode: every run of
/// non-alphanumeric characters becomes a single hyphen, leading and trailing
/// hyphens are dropped, and the result is downcased.
///
/// The underscore-to-hyphen step is the one that matters: the folder is
/// `cycling_trip` but the page is at `/albums/cycling-trip/`. Getting it wrong
/// 404s the app's "View on web" button - the one moment the user is showing
/// somebody else what they made.
String jekyllSlugify(String folder) {
  return folder
      .replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '')
      .toLowerCase();
}

/// The folder name glickr creates for a human-typed album title.
///
/// Trim, collapse whitespace, lowercase, spaces to underscores, then drop
/// anything outside `[a-z0-9_-]`. The user never has to type snake_case; the
/// create-album field shows them the derived folder live so there is no
/// surprise later.
///
/// Note this does not round-trip symmetrically, and that is fine as long as
/// the UI shows both: "Cycling Trip" -> `cycling_trip` -> "Cycling Trip", but
/// "BarCamp Days" -> `barcamp_days` -> "Barcamp Days".
String folderNameFor(String title) {
  final collapsed = title.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  return collapsed
      .replaceAll(' ', '_')
      .replaceAll(RegExp(r'[^a-z0-9_-]'), '')
      .replaceAll(RegExp(r'_{2,}'), '_')
      .replaceAll(RegExp(r'^[_-]+|[_-]+$'), '');
}

/// The sequence number encoded by [name], or null when it is a legacy or
/// hand-authored name that glickr did not create.
///
/// STRICT on purpose. The real album repo contains files like
/// `climbing/1547454978506.jpg` and `climbing/1792024187752037.mp4` - all
/// digits, but millisecond timestamps rather than sequence numbers. A naive
/// `int.tryParse(stem)` would take the maximum to 1.5 trillion and generate a
/// filename that breaks both the pad width and the sort order.
///
/// `0` is excluded because it is the cover sentinel, never a gallery number.
int? parseSequenceNumber(String name) {
  final stem = stemOf(name);
  if (stem.isEmpty || stem.length > kMaxParsedDigits) return null;
  for (final unit in stem.codeUnits) {
    if (unit < 0x30 || unit > 0x39) return null;
  }
  final n = int.parse(stem);
  return n == 0 ? null : n;
}

/// Filename for sequence number [n] with extension [ext] (including the dot).
String sequenceFilename(int n, String ext, {int pad = kDefaultPadWidth}) {
  return '${n.toString().padLeft(pad, '0')}$ext';
}

/// The first sequence number a new batch may claim in an album.
///
/// Takes the maximum of three independent sources so a number can never be
/// reissued:
///   * [highWaterMark] - `album.json`'s monotonic `next`, which deletion never
///     lowers. This is the primary defence against the caption-inheritance
///     hazard, where a deleted `0003.jpg`'s slot is taken by a later upload.
///   * the highest number actually present in [existingNames].
///   * [reservedMax] - numbers already claimed by queued-but-uncommitted
///     batches on this device.
int nextSequenceNumber({
  required Iterable<String> existingNames,
  int? highWaterMark,
  int? reservedMax,
}) {
  var next = 1;
  for (final name in existingNames) {
    final n = parseSequenceNumber(name);
    if (n != null && n + 1 > next) next = n + 1;
  }
  if (highWaterMark != null && highWaterMark > next) next = highWaterMark;
  if (reservedMax != null && reservedMax + 1 > next) next = reservedMax + 1;
  return next;
}

/// The pad width to use when appending to an existing album.
///
/// Adopts the widest width already present so an album never mixes widths -
/// `0001.jpg` sorts before `001.jpg`, so mixing them silently reorders the
/// album on the website. Falls back to [kDefaultPadWidth] for a fresh album.
int padWidthFor(Iterable<String> existingNames) {
  var width = 0;
  for (final name in existingNames) {
    if (parseSequenceNumber(name) == null) continue;
    final len = stemOf(name).length;
    if (len > width) width = len;
  }
  return width == 0 ? kDefaultPadWidth : width;
}

/// Orders media the way the site does: one lexicographic sort over the union
/// of images and videos.
///
/// `albums.rb` re-sorts `(images + videos)` together rather than keeping them
/// in separate groups, which is why glickr allocates photos and videos from a
/// single number space - segregated counters would produce both `0007.jpg`
/// and `0007.mp4`.
List<String> sortForDisplay(Iterable<String> names) {
  final sorted = names.where(isRenderableName).toList()..sort();
  return sorted;
}

/// The album's items in display order, cover included.
///
/// Nothing is excluded. The cover is not a separate file - it is just the
/// first image in this same list - so leaving it out would make a photo the
/// user uploaded vanish from the album it is the cover of, which reads as
/// data loss. The user still has to be able to see, caption and delete it.
List<String> galleryOrder(Iterable<String> names) => sortForDisplay(names);

/// True when [path] is a file the site will render as part of an album.
///
/// The site only looks at paths exactly two segments deep
/// (`albums.rb` does `next unless parts.size == 2`), so a nested
/// `cycling_trip/raw/0001.jpg` is invisible to it. glickr must never create
/// one, and must ignore any it finds.
bool isAlbumMediaPath(String path) {
  final parts = path.split('/');
  if (parts.length != 2) return false;
  return isRenderableName(parts[1]);
}

/// The album folder a two-segment repo [path] belongs to, or null.
String? albumFolderOf(String path) {
  final parts = path.split('/');
  if (parts.length != 2 || parts[0].isEmpty) return null;
  return parts[0];
}
