import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/album.dart';
import '../models/media_item.dart';
import '../services/commit_service.dart';
import '../utils/album_conventions.dart';
import 'albums_provider.dart';
import 'config_provider.dart';
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
@riverpod
class AlbumActions extends _$AlbumActions {
  @override
  bool build() => false; // true while a mutation is in flight

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

  Future<ActionResult> setDescription(Album album, String blurb) {
    final config = ref.read(configNotifierProvider)!;
    return _run(
      () => ref
          .read(albumWriteServiceProvider)
          .setBlurb(config: config, album: album, blurb: blurb),
    );
  }

  /// Commit ONE caption, immediately.
  ///
  /// Not what the UI should call. Every commit triggers the site's build, and
  /// captioning an album a photo at a time queued one build per photo. Screens
  /// stage edits through `PendingCaptionsNotifier` and flush them as a single
  /// commit; this stays for callers that really do have exactly one caption
  /// and no album screen to save from.
  Future<ActionResult> setCaption(
    Album album,
    String fileName,
    String? caption,
  ) {
    final config = ref.read(configNotifierProvider)!;
    return _run(
      () => ref
          .read(albumWriteServiceProvider)
          .setCaption(
            config: config,
            album: album,
            fileName: fileName,
            caption: caption,
          ),
    );
  }

  Future<ActionResult> deleteItems(Album album, Set<String> fileNames) {
    final config = ref.read(configNotifierProvider)!;
    return _run(
      () => ref
          .read(albumWriteServiceProvider)
          .deleteItems(config: config, album: album, fileNames: fileNames),
    );
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
    }
    return result;
  }

  /// Rename an album folder.
  ///
  /// Zero bytes move - blob shas are content addresses, so this is pure
  /// metadata - but every public URL for the album changes, which is why the
  /// caller must confirm first.
  Future<ActionResult> renameAlbum(Album album, String newTitle) {
    final newFolder = folderNameFor(newTitle);
    if (newFolder.isEmpty) {
      return Future.value(
        const ActionResult.failure(
          'Album names can use letters, numbers, spaces, - and _',
        ),
      );
    }
    if (newFolder == album.folder) {
      return Future.value(const ActionResult.success());
    }
    final taken = ref
        .read(albumsNotifierProvider)
        .albums
        .any((a) => a.folder == newFolder);
    if (taken) {
      return Future.value(
        ActionResult.failure('An album called ${albumTitle(newFolder)} already exists.'),
      );
    }

    final config = ref.read(configNotifierProvider)!;
    return _run(
      () => ref
          .read(albumWriteServiceProvider)
          .renameAlbum(config: config, album: album, newFolder: newFolder),
    );
  }

  /// Promote an existing item to be the album cover.
  ///
  /// Images only: the site's cover lookup is scoped to image extensions, so a
  /// video can never be found as one.
  Future<ActionResult> setCover(Album album, MediaItem item) {
    if (!item.isImage) {
      return Future.value(
        const ActionResult.failure('Only a photo can be the album cover'),
      );
    }
    final config = ref.read(configNotifierProvider)!;
    return _run(
      () => ref
          .read(albumWriteServiceProvider)
          .setCoverFromExisting(
            config: config,
            album: album,
            fileName: item.name,
          ),
    );
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
