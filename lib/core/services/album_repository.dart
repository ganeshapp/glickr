import 'dart:async';

import '../models/album.dart';
import '../models/app_config.dart';
import '../models/media_item.dart';
import '../utils/album_captions.dart';
import '../utils/album_conventions.dart';
import 'git_data_service.dart';

/// Outcome of a repo sync.
class AlbumSyncResult {
  final List<Album> albums;
  final String commitSha;
  final String treeSha;
  final String? etag;

  /// Sum of every blob in the repo. The number that matters, because the host
  /// refuses to serve a GitHub repo over 50 MB at all - and the failure mode
  /// is a 403 that looks like a broken website, not a quota message.
  final int repoBytes;

  /// True when the tree API could not return the whole repo in one response.
  /// Albums are still listed, but item lists may be incomplete.
  final bool truncated;

  const AlbumSyncResult({
    required this.albums,
    required this.commitSha,
    required this.treeSha,
    required this.repoBytes,
    this.etag,
    this.truncated = false,
  });
}

/// Nothing changed since the caller's cached snapshot.
class AlbumSyncUnchanged implements Exception {
  const AlbumSyncUnchanged();
}

/// Turns a GitHub tree into the album model, applying the site's rules.
///
/// This is the only place that decides what an album "is", and it deliberately
/// mirrors `_plugins/albums.rb` rather than inventing a nicer structure: if
/// the app groups files differently from the site, the user sees albums that
/// do not exist on their website.
class AlbumRepository {
  final GitDataService _git;

  AlbumRepository({required GitDataService git}) : _git = git;

  /// Read the whole repo and rebuild the album list.
  ///
  /// [cachedEtag] enables a conditional head request. A 304 answer costs no
  /// primary rate limit at all, so a pull-to-refresh against an unchanged repo
  /// is effectively free - which is what makes refreshing on every resume
  /// affordable.
  ///
  /// [cachedAlbums] lets unchanged albums keep their already-fetched note and
  /// captions: each folder carries its own tree sha, so an album whose sha
  /// still matches needs no further requests at all.
  Future<AlbumSyncResult> sync(
    AppConfig config, {
    String? cachedEtag,
    List<Album> cachedAlbums = const [],
    void Function(int done, int total)? onProgress,
  }) async {
    final head = await _git.getHead(
      config.repoOwner,
      config.repoName,
      config.branch,
      etag: cachedEtag,
    );
    if (head.unchanged) throw const AlbumSyncUnchanged();

    final snapshot = await _git.getTree(
      config.repoOwner,
      config.repoName,
      commitSha: head.commitSha!,
      treeSha: head.treeSha!,
    );

    final byFolder = groupTree(snapshot, config);
    final cachedByFolder = {for (final a in cachedAlbums) a.folder: a};

    final albums = <Album>[];
    final needsFetch = <AlbumFolderGroup>[];

    for (final group in byFolder) {
      final cached = cachedByFolder[group.folder];
      // A folder's tree sha changes if and only if something inside it
      // changed, so an unchanged album costs zero requests.
      if (cached != null &&
          cached.treeSha != null &&
          cached.treeSha == group.treeSha &&
          !_hasUnreadSidecar(cached)) {
        albums.add(_rebuildFromCache(cached, group));
      } else {
        needsFetch.add(group);
      }
    }

    var done = 0;
    onProgress?.call(0, needsFetch.length);

    for (final group in needsFetch) {
      final album = await _buildAlbum(
        config,
        group,
        cached: cachedByFolder[group.folder],
      );
      albums.add(album);
      done++;
      onProgress?.call(done, needsFetch.length);
    }

    albums.sort((a, b) => a.folder.compareTo(b.folder));

    return AlbumSyncResult(
      albums: albums,
      commitSha: snapshot.commitSha,
      treeSha: snapshot.treeSha,
      repoBytes: snapshot.totalBytes,
      etag: head.etag,
      truncated: snapshot.truncated,
    );
  }

  /// Group a repo tree into candidate albums.
  ///
  /// Applies the site's two-segment rule: only `<folder>/<file>` paths count,
  /// so a nested `cycling_trip/raw/x.jpg` is ignored exactly as the site
  /// ignores it. A folder with no renderable media is dropped, because the
  /// site skips those too and showing one would promise a page that does not
  /// exist.
  static List<AlbumFolderGroup> groupTree(
    TreeSnapshot snapshot,
    AppConfig config,
  ) {
    final treeShas = <String, String>{};
    final groups = <String, AlbumFolderGroup>{};

    for (final node in snapshot.nodes) {
      // Everything is judged RELATIVE to the album root, so pointing glickr at
      // a whole site repo cannot make it mistake `_posts/` or `assets/css/`
      // for albums.
      final relative = config.albumRelativePath(node.path);
      if (relative == null) continue;

      if (node.isTree && !relative.contains('/')) {
        if (relative.isNotEmpty) treeShas[relative] = node.sha;
        continue;
      }
      if (!node.isBlob) continue;

      final parts = relative.split('/');
      if (parts.length != 2) continue;
      final folder = parts[0];
      final name = parts[1];
      if (folder.isEmpty || folder.startsWith('.')) continue;

      final group = groups.putIfAbsent(folder, () => AlbumFolderGroup(folder));
      if (name == kNoteFile) {
        group.noteSha = node.sha;
      } else if (name == kCaptionsFile) {
        group.captionsSha = node.sha;
      } else if (isRenderableName(name)) {
        group.media.add(
          MediaItem(name: name, blobSha: node.sha, sizeRaw: node.size),
        );
      }
    }

    final result = <AlbumFolderGroup>[];
    for (final group in groups.values) {
      if (group.media.isEmpty) continue;
      group.treeSha = treeShas[group.folder];
      result.add(group);
    }
    result.sort((a, b) => a.folder.compareTo(b.folder));
    return result;
  }

  /// True when the cache claims an `album.json` it holds no text for.
  ///
  /// The invariant is "a recorded captionsSha means its bytes are cached". A
  /// record that breaks it can only have been written by a build that stored
  /// the empty string after a failed fetch, and the unchanged-folder fast path
  /// would otherwise preserve that hole for as long as the folder sits still.
  /// Refetching is one request and restores the album's captions.
  static bool _hasUnreadSidecar(Album cached) =>
      cached.captionsSha != null && (cached.captionsJson ?? '').isEmpty;

  /// Reuse a cached album's text sidecars while taking fresh media metadata.
  Album _rebuildFromCache(Album cached, AlbumFolderGroup group) {
    final captions = AlbumCaptions.parse(group.folder, cached.captionsJson);
    return cached.copyWith(
      items: _withCaptions(group.media, captions),
      treeSha: group.treeSha,
      noteSha: group.noteSha,
      captionsSha: group.captionsSha,
      nextNumber: captions.next,
      lastSynced: DateTime.now(),
    );
  }

  Future<Album> _buildAlbum(
    AppConfig config,
    AlbumFolderGroup group, {
    Album? cached,
  }) async {
    var note = cached?.note ?? '';
    var captionsJson = cached?.captionsJson;
    // Shas are the record of WHAT WAS SUCCESSFULLY READ, not of what the tree
    // currently holds. A sha is only adopted once its bytes are in hand -
    // recording the new sha after a failed fetch would make every later sync
    // compare equal, skip the refetch, and keep serving the empty result
    // forever. Same reason treeSha is withheld below.
    var noteSha = cached?.noteSha;
    var captionsSha = cached?.captionsSha;
    var complete = true;

    // Only refetch a sidecar whose blob sha actually moved.
    if (group.noteSha != null && group.noteSha != cached?.noteSha) {
      final text = await _blobTextOrNull(config, group.noteSha!);
      if (text == null) {
        complete = false;
      } else {
        note = stripFrontMatter(text).trim();
        noteSha = group.noteSha;
      }
    } else {
      noteSha = group.noteSha;
      if (group.noteSha == null) note = '';
    }

    // Refetch when the sha moved, and also when the cache holds a sha but no
    // text for it - the fingerprint of a pre-fix record poisoned by a failed
    // fetch, which sha comparison alone would call up to date for ever.
    if (group.captionsSha != null &&
        (group.captionsSha != cached?.captionsSha ||
            (cached?.captionsJson ?? '').isEmpty)) {
      final text = await _blobTextOrNull(config, group.captionsSha!);
      if (text == null) {
        complete = false;
      } else {
        captionsJson = text;
        captionsSha = group.captionsSha;
      }
    } else {
      captionsSha = group.captionsSha;
      if (group.captionsSha == null) captionsJson = null;
    }

    final captions = AlbumCaptions.parse(group.folder, captionsJson);

    return Album(
      folder: group.folder,
      note: note,
      items: _withCaptions(group.media, captions),
      // Withholding the folder's tree sha is what actually re-arms the retry:
      // with it recorded, the next sync takes the `cached.treeSha == group
      // .treeSha` fast path and never looks at the sidecars at all.
      treeSha: complete ? group.treeSha : null,
      noteSha: noteSha,
      captionsSha: captionsSha,
      captionsJson: captionsJson,
      nextNumber: captions.next,
      lastSynced: DateTime.now(),
    );
  }

  /// Sidecar text, or null when it could not be fetched.
  ///
  /// A bad sidecar must not fail the whole sync - the user would lose access
  /// to every album over one bad file - but it must not be mistaken for an
  /// empty one either, so the failure is reported rather than flattened to ''.
  Future<String?> _blobTextOrNull(AppConfig config, String sha) async {
    try {
      return await _git.fetchBlobText(config.repoOwner, config.repoName, sha);
    } catch (_) {
      return null;
    }
  }

  static List<MediaItem> _withCaptions(
    List<MediaItem> media,
    AlbumCaptions captions,
  ) {
    final byName = captions.captionsByName;
    return media
        .map(
          (item) => byName.containsKey(item.name)
              ? item.copyWith(caption: byName[item.name])
              : item,
        )
        .toList();
  }
}

/// Remove YAML front matter from an `album.md`.
///
/// The site tolerates front matter but strips it before rendering, so glickr
/// shows the same note the website shows.
String stripFrontMatter(String text) {
  final match = RegExp(
    r'^---\s*\n.*?\n---\s*\n',
    dotAll: true,
  ).matchAsPrefix(text);
  if (match == null) return text;
  return text.substring(match.end);
}

/// Mutable accumulator used while grouping a tree into albums.
class AlbumFolderGroup {
  final String folder;
  final List<MediaItem> media = [];
  String? treeSha;
  String? noteSha;
  String? captionsSha;

  AlbumFolderGroup(this.folder);
}
