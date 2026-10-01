import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/album.dart';
import '../models/media_item.dart';
import '../services/commit_service.dart';
import '../utils/album_conventions.dart';
import 'albums_provider.dart';
import 'config_provider.dart';
import 'pending_captions_provider.dart';
import 'services_provider.dart';

part 'album_actions_provider.g.dart';

/// Result of a mutation, so callers can show one snackbar and be done.
class ActionResult {
  final bool ok;
  final String? error;
  const ActionResult.success() : ok = true, error = null;
  const ActionResult.failure(this.error) : ok = false;
}

/// Every album mutation the UI can trigger.
///
/// Each one is a single git commit, and each one refreshes the album list
/// afterwards so the local cache and the repo cannot drift.
///
/// Each one also keeps STAGED captions in step with what it just did, HERE
/// rather than in the screen that called it. A staged caption is filed under
/// (folder, filename), so a delete, a rename or a cover swap moves the ground
/// under it - and when that bookkeeping lived in the screens, the album screen
/// did it and the album LIST silently did not: renaming from the list stranded
/// unsaved captions on a dead folder, and deleting from it left them to
/// reattach to the next album that took the name. There is one door per
/// mutation and it is this class; a caller cannot forget what it never had to
/// remember.
@riverpod
class AlbumActions extends _$AlbumActions {
  @override
  bool build() => false; // true while a mutation is in flight

  PendingCaptionsNotifier get _captions =>
      ref.read(pendingCaptionsNotifierProvider.notifier);

  Future<ActionResult> _run(Future<CommitOutcome> Function() operation) async {
    if (ref.read(configNotifierProvider) == null) {
      return const ActionResult.failure('No repository selected');
    }
    state = true;
    try {
      await operation();
      // Re-read rather than patching local state: a commit may have renumbered
      // or renamed things, and guessing at the result is how the app and the
      // repo start disagreeing.
      await ref.read(albumsNotifierProvider.notifier).refresh(force: true);
      return const ActionResult.success();
    } catch (e) {
      return ActionResult.failure(_message(e));
    } finally {
      state = false;
    }
  }

  Future<ActionResult> setDescription(
    Album album, {
    required String summary,
    required String note,
  }) {
    final config = ref.read(configNotifierProvider)!;
    return _run(
      () => ref
          .read(albumWriteServiceProvider)
          .setDescription(
            config: config,
            album: album,
            summary: summary,
            note: note,
          ),
    );
  }

  // There is deliberately NO setCaption here. Captions are the one mutation
  // the user makes in bulk, and a per-caption commit is a per-caption site
  // build - the app DDoSing its own website. Editing a caption stages it
  // through `PendingCaptionsNotifier`, and `flush` sends the lot as one
  // commit. A single-caption door on this class is how that rule got broken
  // last time: the viewer had an Album and a filename in hand and simply
  // called it.

  Future<ActionResult> deleteItems(Album album, Set<String> fileNames) async {
    final config = ref.read(configNotifierProvider)!;
    final result = await _run(
      () => ref
          .read(albumWriteServiceProvider)
          .deleteItems(config: config, album: album, fileNames: fileNames),
    );
    if (result.ok) {
      // A staged caption for a file that is gone can never be saved onto
      // anything: it would inflate the unsaved count with a photo the user
      // cannot open, and flushing it would write a caption into album.json for
      // a file that is not there.
      await _captions.forget(album.folder, fileNames);
    }
    return result;
  }

  Future<ActionResult> deleteAlbum(Album album) async {
    final config = ref.read(configNotifierProvider)!;
    final result = await _run(
      () => ref
          .read(albumWriteServiceProvider)
          .deleteAlbum(config: config, album: album),
    );
    if (result.ok) {
      await ref.read(albumsNotifierProvider.notifier).removeLocal(album.folder);
      // Deleting the folder deletes album.json with it, so a recreated album
      // of the same name starts numbering at 0001.jpg again - staged captions
      // left behind would surface as the captions of unrelated new photos.
      await _captions.discard(album.folder);
    }
    return result;
  }

  /// Rename an album folder.
  ///
  /// Zero bytes move - blob shas are content addresses, so this is pure
  /// metadata - but every public URL for the album changes, which is why the
  /// caller must confirm first.
  Future<ActionResult> renameAlbum(Album album, String newTitle) async {
    final newFolder = folderNameFor(newTitle);
    if (newFolder.isEmpty) {
      return const ActionResult.failure(
        'Album names can use letters, numbers, spaces, - and _',
      );
    }
    if (newFolder == album.folder) {
      return const ActionResult.success();
    }
    final taken = ref
        .read(albumsNotifierProvider)
        .albums
        .any((a) => a.folder == newFolder);
    if (taken) {
      return ActionResult.failure(
        'An album called ${albumTitle(newFolder)} already exists.',
      );
    }

    final config = ref.read(configNotifierProvider)!;
    final result = await _run(
      () => ref
          .read(albumWriteServiceProvider)
          .renameAlbum(config: config, album: album, newFolder: newFolder),
    );
    if (result.ok) {
      // The edits travel with the album. Left under the old folder name they
      // are unreachable - no screen shows them, so they can never be saved or
      // discarded - while still counting towards the sign-out warning.
      await _captions.rekey(album.folder, newFolder);
    }
    return result;
  }

  /// Promote an existing item to be the album cover.
  ///
  /// Images only: the site's cover lookup is scoped to image extensions, so a
  /// video can never be found as one.
  Future<ActionResult> setCover(Album album, MediaItem item) async {
    if (!item.isImage) {
      return const ActionResult.failure('Only a photo can be the album cover');
    }
    // Captured before the commit, which renames both files.
    final incumbent = album.cover?.name;

    final config = ref.read(configNotifierProvider)!;
    final result = await _run(
      () => ref
          .read(albumWriteServiceProvider)
          .setCoverFromExisting(
            config: config,
            album: album,
            fileName: item.name,
          ),
    );
    if (result.ok && incumbent != null && incumbent != item.name) {
      // The commit swaps the two photos' COMMITTED captions along with their
      // filenames, because a caption describes a picture rather than a name. A
      // staged edit has to travel the same way or the next Save would put
      // unsaved typing on the other photo.
      await _captions.swapFiles(album.folder, incumbent, item.name);
    }
    return result;
  }

  String _message(Object error) {
    final text = error.toString();
    return text.startsWith('Exception: ')
        ? text.substring('Exception: '.length)
        : text;
  }
}

/// The live album for [folder], straight from the albums list so it updates
/// whenever a sync or a mutation lands.
@riverpod
Album? albumByFolder(Ref ref, String folder) {
  for (final album in ref.watch(albumsNotifierProvider).albums) {
    if (album.folder == folder) return album;
  }
  return null;
}
