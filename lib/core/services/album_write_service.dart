import 'dart:convert';
import 'dart:typed_data';

import '../models/album.dart';
import '../models/app_config.dart';
import '../utils/album_captions.dart';
import '../utils/album_conventions.dart';
import 'commit_service.dart';
import 'git_data_service.dart';

/// `album.json` is present in the tree but its contents could not be read.
///
/// Fatal to the commit that raised it, on purpose. Every caller of
/// `_readCaptions` writes the result it gets straight back to the repo, so
/// treating a failed read as "this album has no captions" does not degrade
/// gracefully - it commits the deletion of the sidecar, or truncates it to the
/// single entry being edited and resets the monotonic `next` to 1, which then
/// lets a later upload reuse filenames and inherit dead captions. Aborting
/// costs the user a retry; the fallback costs them their captions.
class CaptionsUnreadableException implements Exception {
  final String folder;
  final Object? cause;

  const CaptionsUnreadableException(this.folder, [this.cause]);

  @override
  String toString() =>
      "Couldn't read the captions for $folder, so nothing was changed. "
      'Check your connection and try again.';
}

/// Every album mutation that does not involve uploading new media.
///
/// All of these are ONE commit each, which is the whole reason glickr uses the
/// Git Data API. Over the Contents API, "set as cover" would be six
/// unsequenced calls that can leave an album with two covers or none, and
/// renaming a 67-file album would re-upload every byte in it.
class AlbumWriteService {
  final GitDataService _git;
  final CommitService _commits;

  AlbumWriteService({
    required GitDataService git,
    required CommitService commits,
  }) : _git = git,
       _commits = commits;

  Future<String> _blob(AppConfig config, String text) {
    return _git.createBlob(
      config.repoOwner,
      config.repoName,
      Uint8List.fromList(utf8.encode(text)),
    );
  }

  /// Replace the album's summary (in `album.json`) and note (`album.md`), as
  /// ONE commit. An empty note deletes `album.md`.
  Future<CommitOutcome> setDescription({
    required AppConfig config,
    required Album album,
    required String summary,
    required String note,
  }) {
    final notePath = config.albumFilePath(album.folder, kNoteFile);
    final trimmed = note.trim();

    return _commits.commit(
      config: config,
      message: 'glickr: update description for ${album.folder}',
      buildEntries: (tree) async {
        final entries = <TreeEntry>[];

        final captions = await _readCaptions(config, tree, album.folder);
        final edited = captions.withSummary(summary);
        // Compared, not blob-checked: album.json's `updated` timestamp makes
        // every encode a new blob.
        if (edited.summary != captions.summary) {
          entries.addAll(
            await _captionEntries(config, tree, album.folder, edited),
          );
        }

        final existing = tree.nodes
            .where((n) => n.isBlob && n.path == notePath)
            .firstOrNull;
        if (trimmed.isEmpty) {
          if (existing != null) {
            entries.add(TreeEntry.delete(notePath, mode: existing.mode));
          }
        } else {
          // Trailing newline so the file is a well-formed text file in git.
          final sha = await _blob(config, '$trimmed\n');
          if (existing?.sha != sha) entries.add(TreeEntry.file(notePath, sha));
        }
        return entries;
      },
    );
  }

  /// Set or clear captions for one or more items, as a SINGLE commit.
  ///
  /// Plural on purpose. Every commit to the album repo triggers the site's
  /// build, so committing one caption at a time meant captioning a 23-photo
  /// album queued 23 builds - the app effectively DDoSing its own site. The UI
  /// stages caption edits locally and flushes them through here in one go.
  ///
  /// A null value clears that item's caption.
  ///
  /// The sidecar is re-read from the repo inside the commit builder rather
  /// than written from local state, so a caption another device added in the
  /// meantime survives instead of being clobbered.
  Future<CommitOutcome> setCaptions({
    required AppConfig config,
    required Album album,
    required Map<String, String?> captions,
  }) {
    if (captions.isEmpty) {
      throw ArgumentError('setCaptions needs at least one entry');
    }
    return _commits.commit(
      config: config,
      message: captions.length == 1
          ? 'glickr: caption ${captions.keys.first} in ${album.folder}'
          : 'glickr: caption ${captions.length} items in ${album.folder}',
      buildEntries: (tree) async {
        var current = await _readCaptions(config, tree, album.folder);
        for (final entry in captions.entries) {
          current = current.withCaption(entry.key, entry.value);
        }
        return _captionEntries(config, tree, album.folder, current);
      },
    );
  }

  /// Remove media from an album, dropping their captions in the SAME commit.
  ///
  /// Atomicity matters here specifically: if the file could disappear while
  /// its caption entry survived, a later upload inheriting that filename would
  /// inherit a caption describing a photo nobody can see any more.
  Future<CommitOutcome> deleteItems({
    required AppConfig config,
    required Album album,
    required Set<String> fileNames,
  }) {
    final paths = fileNames
        .map((n) => config.albumFilePath(album.folder, n))
        .toSet();

    return _commits.commit(
      config: config,
      message: fileNames.length == 1
          ? 'glickr: remove ${fileNames.first} from ${album.folder}'
          : 'glickr: remove ${fileNames.length} items from ${album.folder}',
      buildEntries: (tree) async {
        final deletions = CommitService.deletionsFor(tree, paths);
        if (deletions.isEmpty) return const <TreeEntry>[];

        final captions = await _readCaptions(config, tree, album.folder);
        final updated = captions.withoutFiles(fileNames);
        return [
          ...deletions,
          ...await _captionEntries(config, tree, album.folder, updated),
        ];
      },
    );
  }

  /// Delete an entire album folder.
  ///
  /// Git has no directory objects independent of their contents, so removing
  /// every blob under the prefix removes the folder. A 67-file album is three
  /// requests and one commit.
  Future<CommitOutcome> deleteAlbum({
    required AppConfig config,
    required Album album,
  }) {
    final prefix = '${config.albumFolderPath(album.folder)}/';
    return _commits.commit(
      config: config,
      message: 'glickr: delete album ${album.folder}',
      buildEntries: (tree) {
        return tree.nodes
            .where((n) => n.isBlob && n.path.startsWith(prefix))
            .map((n) => TreeEntry.delete(n.path, mode: n.mode))
            .toList();
      },
    );
  }

  /// Rename an album folder.
  ///
  /// Costs zero uploaded bytes at any album size, because blob shas are
  /// content addresses: the same blobs are simply listed at new paths. It does
  /// change every public URL for the album, though, which is why the caller
  /// must confirm first.
  Future<CommitOutcome> renameAlbum({
    required AppConfig config,
    required Album album,
    required String newFolder,
  }) {
    final oldPrefix = '${config.albumFolderPath(album.folder)}/';
    return _commits.commit(
      config: config,
      message: 'glickr: rename ${album.folder} to $newFolder',
      buildEntries: (tree) {
        final entries = <TreeEntry>[];
        for (final node in tree.nodes) {
          if (!node.isBlob || !node.path.startsWith(oldPrefix)) continue;
          final name = node.path.substring(oldPrefix.length);
          entries.add(TreeEntry.delete(node.path, mode: node.mode));
          entries.add(
            TreeEntry.file(
              config.albumFilePath(newFolder, name),
              node.sha,
              mode: node.mode,
            ),
          );
        }
        return entries;
      },
    );
  }

  /// Make an existing album item the cover, by swapping it with the album's
  /// current first image.
  ///
  /// The cover is not a separate file - it is whichever image sorts first - so
  /// "set as cover" means "make this the first photo". That is a swap of two
  /// names, which git expresses as four tree entries against the same base:
  /// both paths are rewritten in one commit, so there is no intermediate state
  /// where a name is taken twice, and no bytes move because blob shas are
  /// content addresses.
  ///
  /// Only two files change, so every other photo's URL survives - which is why
  /// this is a swap rather than a renumber of the whole album.
  Future<CommitOutcome> setCoverFromExisting({
    required AppConfig config,
    required Album album,
    required String fileName,
  }) {
    if (!isImageName(fileName)) {
      throw ArgumentError('Only an image can be an album cover');
    }

    return _commits.commit(
      config: config,
      message: 'glickr: make $fileName the cover of ${album.folder}',
      buildEntries: (tree) async {
        final prefix = '${config.albumFolderPath(album.folder)}/';
        final inFolder = {
          for (final node in tree.nodes)
            if (node.isBlob && node.path.startsWith(prefix))
              node.path.substring(prefix.length): node,
        };

        final chosen = inFolder[fileName];
        if (chosen == null) return const <TreeEntry>[];

        final currentCover = coverNameOf(inFolder.keys);
        // Already first: nothing to do, and returning an empty list makes the
        // commit a no-op rather than an empty commit.
        if (currentCover == null || currentCover == fileName) {
          return const <TreeEntry>[];
        }
        final incumbent = inFolder[currentCover]!;

        var captions = await _readCaptions(config, tree, album.folder);
        final chosenCaption = captions.captionFor(fileName);
        final incumbentCaption = captions.captionFor(currentCover);

        final entries = <TreeEntry>[
          TreeEntry.file(
            '$prefix$currentCover',
            chosen.sha,
            mode: chosen.mode,
          ),
          TreeEntry.file(
            '$prefix$fileName',
            incumbent.sha,
            mode: incumbent.mode,
          ),
        ];

        // The captions swap with the photos - a caption describes a picture,
        // not a filename.
        captions = captions
            .withCaption(currentCover, chosenCaption.isEmpty ? null : chosenCaption)
            .withCaption(fileName, incumbentCaption.isEmpty ? null : incumbentCaption);
        entries.addAll(
          await _captionEntries(config, tree, album.folder, captions),
        );
        return entries;
      },
    );
  }

  /// Current `album.json` for [folder], read from the tree being committed on.
  ///
  /// The returned value is always the sidecar's ACTUAL contents. "There is no
  /// sidecar" and "I could not read the sidecar" are different answers and
  /// only the first one is legitimately empty: the caller turns whatever comes
  /// back into the new album.json, so guessing empty here rewrites the file
  /// with the guess. Throws [CaptionsUnreadableException] rather than guessing.
  Future<AlbumCaptions> _readCaptions(
    AppConfig config,
    TreeSnapshot tree,
    String folder,
  ) async {
    final path = config.albumFilePath(folder, kCaptionsFile);
    final node = tree.nodes
        .where((n) => n.isBlob && n.path == path)
        .firstOrNull;
    if (node == null) return AlbumCaptions.empty(folder);

    final String text;
    try {
      text = await _git.fetchBlobText(
        config.repoOwner,
        config.repoName,
        node.sha,
      );
    } catch (e) {
      throw CaptionsUnreadableException(folder, e);
    }
    // fetchBlobText also returns '' when it cannot make sense of the response
    // (a proxy that ignores the raw media type, say), which is indistinguishable
    // from a genuinely empty file at this layer. The tree listing settles it:
    // it carries the blob's real size, so no bytes back for a non-empty blob
    // means the read failed, not that the file is empty.
    if (text.isEmpty && node.size > 0) {
      throw CaptionsUnreadableException(folder);
    }
    return AlbumCaptions.parse(folder, text);
  }

  /// Tree entries that write [captions], or remove the file when it would
  /// carry nothing worth keeping.
  ///
  /// [captions] must have come from [_readCaptions] on this same [tree]: the
  /// "empty means delete the file" branch below is only safe when the emptiness
  /// was observed, never when it was assumed.
  Future<List<TreeEntry>> _captionEntries(
    AppConfig config,
    TreeSnapshot tree,
    String folder,
    AlbumCaptions captions,
  ) async {
    final path = config.albumFilePath(folder, kCaptionsFile);
    final existing = tree.nodes
        .where((n) => n.isBlob && n.path == path)
        .firstOrNull;

    if (captions.isEmpty) {
      return existing == null
          ? const <TreeEntry>[]
          : [TreeEntry.delete(path, mode: existing.mode)];
    }
    final sha = await _blob(config, captions.encode());
    if (existing != null && existing.sha == sha) return const <TreeEntry>[];
    return [TreeEntry.file(path, sha)];
  }
}
