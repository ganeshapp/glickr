import 'package:hive/hive.dart';

part 'app_config.g.dart';

/// Compression preset applied to a batch of media before upload.
enum QualityPreset {
  low('Low'),
  medium('Medium'),
  high('High');

  const QualityPreset(this.label);
  final String label;

  static QualityPreset fromName(String? name) => switch (name) {
    'low' => QualityPreset.low,
    'high' => QualityPreset.high,
    _ => QualityPreset.medium,
  };
}

/// Where album media is fetched from.
///
/// [raw] is the default and the only one that works for a site repo. jsDelivr
/// refuses to serve any GitHub package over 50 MB, and that ceiling applies to
/// the WHOLE repository, not to the file being asked for - so a Jekyll site
/// with a few hundred photos in it answers 403 for every image and the grid
/// goes blank with nothing in the logs to explain it. raw.githubusercontent
/// has no such limit, serves public repos without auth, and is fresh the
/// instant the commit lands, so a just-uploaded photo is fetchable
/// immediately instead of 404ing until a CDN edge warms up.
enum MediaSource {
  raw('raw.githubusercontent.com', 'https://raw.githubusercontent.com'),
  jsdelivr('jsDelivr', 'https://cdn.jsdelivr.net/gh');

  const MediaSource(this.label, this.defaultBase);

  final String label;

  /// Host and path prefix that [AppConfig.mediaUrl] builds on.
  final String defaultBase;

  static MediaSource fromName(String? name) => switch (name) {
    'jsdelivr' => MediaSource.jsdelivr,
    _ => MediaSource.raw,
  };
}

/// App configuration (Hive typeId 0), stored under the single key
/// `current_config`.
///
/// MIGRATION SAFETY: every field is either required-from-v1 or a nullable
/// `xxxRaw` @HiveField paired with a non-nullable getter that supplies the
/// default. Records written by older builds therefore deserialize forever.
/// Prefer the getters over the raw fields everywhere.
///
/// Deliberately ABSENT: the branch head sha. That is cache state, not user
/// settings, and lives in the disposable `sync_state` box so that clearing the
/// cache can never wipe the user's repo choice.
@HiveType(typeId: 0)
class AppConfig extends HiveObject {
  @HiveField(0)
  String repoOwner;

  @HiveField(1)
  String repoName;

  @HiveField(2)
  String branch;

  /// `low` | `medium` | `high`, stored as a String rather than a Hive enum:
  /// an enum adapter pins ordinals forever, so reordering the enum silently
  /// remaps every existing record.
  @HiveField(3)
  String? qualityPresetRaw;

  /// Public site base used by "View on web", e.g. `https://gapp.in`.
  @HiveField(4)
  String? siteUrlRaw;

  /// Path under [siteUrl] where album pages are generated.
  @HiveField(5)
  String? albumsPathRaw;

  /// Host base for media URLs, overriding [MediaSource.defaultBase].
  ///
  /// Only for a fork pointing at its own mirror; nothing in the app writes it.
  /// It must match whatever [mediaSourceRaw] selects, because the two sources
  /// spell the commit sha differently (`/sha/` vs `@sha/`).
  @HiveField(6)
  String? mediaBaseRaw;

  /// When true, queued uploads wait for Wi-Fi instead of spending mobile data.
  @HiveField(7)
  bool? wifiOnlyUploadsRaw;

  /// Disk budget for the media byte cache, in MB.
  @HiveField(8)
  int? cacheBudgetMbRaw;

  /// Set once the "your site rebuilds on its own" card has been shown, so it
  /// appears after the first successful upload and never again.
  @HiveField(9)
  bool? rebuildNoticeSeenRaw;

  /// Directory inside the repo that album folders live in.
  ///
  /// Empty means the repo root, which is the layout of a dedicated album repo
  /// (`album/cycling_trip/0001.jpg`). Pointing glickr at a site repo instead
  /// wants something like `assets/albums`, so albums land at
  /// `assets/albums/cycling_trip/0001.jpg` and the rest of the repo is left
  /// alone.
  @HiveField(10)
  String? albumRootRaw;

  /// `raw` | `jsdelivr`, stored as a String for the same reason the quality
  /// preset is: a Hive enum adapter pins ordinals forever.
  ///
  /// Field 11, not a reuse of 6: records written before this existed decode
  /// with a null here and therefore land on [MediaSource.raw], which is the
  /// source that works for every repo layout.
  @HiveField(11)
  String? mediaSourceRaw;

  AppConfig({
    required this.repoOwner,
    required this.repoName,
    this.branch = 'main',
    String? qualityPreset,
    String? siteUrl,
    String? albumsPath,
    String? mediaBase,
    bool? wifiOnlyUploads,
    int? cacheBudgetMb,
    bool? rebuildNoticeSeen,
    String? albumRoot,
    String? mediaSource,
  }) : qualityPresetRaw = qualityPreset,
       siteUrlRaw = siteUrl,
       albumsPathRaw = albumsPath,
       mediaBaseRaw = mediaBase,
       wifiOnlyUploadsRaw = wifiOnlyUploads,
       cacheBudgetMbRaw = cacheBudgetMb,
       rebuildNoticeSeenRaw = rebuildNoticeSeen,
       albumRootRaw = albumRoot,
       mediaSourceRaw = mediaSource;

  /// README default: medium.
  QualityPreset get quality => QualityPreset.fromName(qualityPresetRaw);

  String get siteUrl => (siteUrlRaw ?? '').replaceAll(RegExp(r'/+$'), '');

  String get albumsPath {
    final raw = albumsPathRaw;
    if (raw == null || raw.isEmpty) return 'albums';
    return raw.replaceAll(RegExp(r'^/+|/+$'), '');
  }

  MediaSource get mediaSource => MediaSource.fromName(mediaSourceRaw);

  String get mediaBase => (mediaBaseRaw?.isNotEmpty ?? false)
      ? mediaBaseRaw!
      : mediaSource.defaultBase;

  bool get wifiOnlyUploads => wifiOnlyUploadsRaw ?? false;
  int get cacheBudgetMb => cacheBudgetMbRaw ?? 300;
  bool get rebuildNoticeSeen => rebuildNoticeSeenRaw ?? false;

  String get repoSlug => '$repoOwner/$repoName';

  /// Repo directory album folders live in; '' means the repo root.
  String get albumRoot =>
      (albumRootRaw ?? '').replaceAll(RegExp(r'^/+|/+$'), '');

  /// Human label for the album root, for settings rows and confirmations.
  String get albumRootLabel =>
      albumRoot.isEmpty ? 'Repository root' : albumRoot;

  /// Repo path of an album folder, e.g. `assets/albums/cycling_trip`.
  String albumFolderPath(String folder) =>
      albumRoot.isEmpty ? folder : '$albumRoot/$folder';

  /// Repo path of one file in an album.
  String albumFilePath(String folder, String fileName) =>
      '${albumFolderPath(folder)}/$fileName';

  /// [repoPath] relative to [albumRoot], or null when it falls outside.
  ///
  /// This is the single place that decides whether a file in the repo is part
  /// of an album at all, so pointing glickr at a site repo cannot make it
  /// treat `_posts/` or `assets/css/` as albums.
  String? albumRelativePath(String repoPath) {
    if (albumRoot.isEmpty) return repoPath;
    final prefix = '$albumRoot/';
    if (!repoPath.startsWith(prefix)) return null;
    return repoPath.substring(prefix.length);
  }

  /// Where a given album is published, e.g.
  /// `https://gapp.in/albums/cycling-trip/`. Empty when no site URL is set,
  /// which the UI treats as "hide the View on web action" rather than
  /// offering a link that 404s.
  String albumWebUrl(String slug) {
    if (siteUrl.isEmpty) return '';
    return '$siteUrl/$albumsPath/$slug/';
  }

  /// Commit-pinned URL for one file in an album.
  ///
  /// Always pinned to a commit sha, never to the branch. On raw a branch URL
  /// is served with a five-minute cache and no way to bust it, and on jsDelivr
  /// a branch ref is cached for around 12 hours - so `main` would serve stale
  /// bytes, or 404, right after an upload. A sha-pinned URL is immutable, is
  /// cached effectively forever, and makes the commit sha the whole cache
  /// invalidation strategy.
  ///
  /// The two sources differ only in how they spell the ref: raw separates it
  /// with a slash, jsDelivr with `@`.
  String mediaUrl({
    required String commitSha,
    required String folder,
    required String fileName,
  }) {
    final segments = [
      ...albumRoot.split('/').where((s) => s.isNotEmpty),
      folder,
      fileName,
    ].map(Uri.encodeComponent).join('/');
    final ref = switch (mediaSource) {
      MediaSource.raw => '$repoOwner/$repoName/$commitSha',
      MediaSource.jsdelivr => '$repoOwner/$repoName@$commitSha',
    };
    return '$mediaBase/$ref/$segments';
  }

  AppConfig copyWith({
    String? repoOwner,
    String? repoName,
    String? branch,
    QualityPreset? quality,
    String? siteUrl,
    String? albumsPath,
    String? mediaBase,
    bool? wifiOnlyUploads,
    int? cacheBudgetMb,
    bool? rebuildNoticeSeen,
    String? albumRoot,
    MediaSource? mediaSource,
  }) {
    return AppConfig(
      repoOwner: repoOwner ?? this.repoOwner,
      repoName: repoName ?? this.repoName,
      branch: branch ?? this.branch,
      qualityPreset: quality?.name ?? qualityPresetRaw,
      siteUrl: siteUrl ?? siteUrlRaw,
      albumsPath: albumsPath ?? albumsPathRaw,
      mediaBase: mediaBase ?? mediaBaseRaw,
      wifiOnlyUploads: wifiOnlyUploads ?? wifiOnlyUploadsRaw,
      cacheBudgetMb: cacheBudgetMb ?? cacheBudgetMbRaw,
      rebuildNoticeSeen: rebuildNoticeSeen ?? rebuildNoticeSeenRaw,
      albumRoot: albumRoot ?? albumRootRaw,
      mediaSource: mediaSource?.name ?? mediaSourceRaw,
    );
  }
}
