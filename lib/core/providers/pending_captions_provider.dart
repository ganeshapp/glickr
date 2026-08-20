import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/album.dart';
import '../models/media_item.dart';
import 'album_actions_provider.dart';
import 'albums_provider.dart';
import 'config_provider.dart';
import 'services_provider.dart';

part 'pending_captions_provider.g.dart';

/// Caption edits made but not yet committed, per album folder.
///
/// Captions are staged locally and flushed as ONE commit, because every commit
/// to the album repo triggers the site's build. Committing on each keystroke-
/// pause meant captioning a 23-photo album queued 23 builds; the app was
/// effectively DDoSing its own website.
///
/// Staged edits are persisted, so closing the app with unsaved captions keeps
/// them rather than quietly dropping the user's typing.
@Riverpod(keepAlive: true)
Box<Map> pendingCaptionsBox(Ref ref) => Hive.box<Map>('pending_captions');

/// folder -> { fileName -> caption }. A null caption means "clear this one",
/// which is why the inner map is nullable-valued rather than just omitting the
/// key: "no pending edit" and "pending edit to empty" are different states.
typedef PendingCaptions = Map<String, Map<String, String?>>;

@Riverpod(keepAlive: true)
class PendingCaptionsNotifier extends _$PendingCaptionsNotifier {
  /// folder -> the entries a commit is carrying right now.
  ///
  /// A commit against GitHub takes seconds, and the user goes on captioning
  /// through it - that is the whole point of a viewer you can swipe. So for
  /// that window the true value for a sent file is neither what the local
  /// [Album] says (it predates the commit) nor what is staged (that IS the
  /// thing being sent): it is the value in flight. Keeping it here is what
  /// lets [stage] and [captionFor] answer correctly mid-save.
  final Map<String, Map<String, String?>> _inFlight = {};

  @override
  PendingCaptions build() {
    final box = ref.watch(pendingCaptionsBoxProvider);
    final out = <String, Map<String, String?>>{};
    for (final key in box.keys) {
      if (key is! String) continue;
      final raw = box.get(key);
      if (raw == null) continue;
      final entries = <String, String?>{};
      raw.forEach((name, caption) {
        if (name is String) entries[name] = caption as String?;
      });
      if (entries.isNotEmpty) out[key] = entries;
    }
    return out;
  }

  /// Edits waiting to be saved for [folder].
  Map<String, String?> forAlbum(String folder) => state[folder] ?? const {};

  int countFor(String folder) => forAlbum(folder).length;

  /// The caption to SHOW for an item: the staged edit when there is one, and
  /// the committed value otherwise. Without this the viewer would show the old
  /// caption straight after the user typed a new one.
  String captionFor(Album album, String fileName) {
    final pending = forAlbum(album.folder);
    if (pending.containsKey(fileName)) return pending[fileName] ?? '';
    return _committedFor(album, fileName);
  }

  /// What the repo holds for [fileName], or is about to hold.
  ///
  /// The baseline both for "is this still an edit?" and for what to show once
  /// nothing is staged. An in-flight commit wins over the local [Album]: the
  /// album only learns the new text when the commit returns, and until then
  /// answering from it would call an already-sent caption "old".
  String _committedFor(Album album, String fileName) {
    final sending = _inFlight[album.folder];
    if (sending != null && sending.containsKey(fileName)) {
      return sending[fileName] ?? '';
    }
    return album.itemNamed(fileName)?.caption ?? '';
  }

  /// Stage one edit. Local and instant - no network, no commit.
  Future<void> stage(Album album, String fileName, String? caption) async {
    final trimmed = caption?.trim();
    final committed = _committedFor(album, fileName);
    final next = Map<String, String?>.from(forAlbum(album.folder));

    if ((trimmed ?? '') == committed) {
      // Typed back to what is already committed - that is not a pending edit,
      // and leaving it staged would show a "1 unsaved" badge for a no-op.
      next.remove(fileName);
    } else {
      next[fileName] = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    }
    await _write(album.folder, next);
  }

  Future<void> discard(String folder) => _write(folder, const {});

  /// Forget staged edits for files that have just left the album.
  ///
  /// An edit is keyed by filename, so deleting a photo with one waiting leaves
  /// an edit that can never apply to anything: it inflates the unsaved count
  /// with a photo the user cannot see, and flushing it would write a caption
  /// into album.json for a file that is not there.
  Future<void> forget(String folder, Set<String> fileNames) async {
    final current = forAlbum(folder);
    if (!fileNames.any(current.containsKey)) return;
    final next = Map<String, String?>.from(current)
      ..removeWhere((name, _) => fileNames.contains(name));
    await _write(folder, next);
  }

  /// Follow a cover change, which swaps two filenames.
  ///
  /// The commit swaps the two files' COMMITTED captions along with them,
  /// because a caption describes a picture rather than a filename. A staged
  /// edit has to travel the same way, or unsaved typing would silently end up
  /// on the other photo the next time the user presses Save.
  Future<void> swapFiles(String folder, String a, String b) async {
    final current = forAlbum(folder);
    final hasA = current.containsKey(a);
    final hasB = current.containsKey(b);
    if (!hasA && !hasB) return;

    final next = Map<String, String?>.from(current);
    // Read both before writing either: they are each other's new value.
    final stagedA = current[a];
    final stagedB = current[b];
    if (hasB) {
      next[a] = stagedB;
    } else {
      next.remove(a);
    }
    if (hasA) {
      next[b] = stagedA;
    } else {
      next.remove(b);
    }
    await _write(folder, next);
  }

  Future<void> _write(String folder, Map<String, String?> entries) async {
    final box = ref.read(pendingCaptionsBoxProvider);
    if (entries.isEmpty) {
      await box.delete(folder);
    } else {
      await box.put(folder, entries);
    }
    final next = PendingCaptions.from(state);
    if (entries.isEmpty) {
      next.remove(folder);
    } else {
      next[folder] = entries;
    }
    state = next;
  }

  /// Commit every staged edit for [album] in one commit, then refresh.
  Future<ActionResult> flush(Album album) async {
    // A snapshot, and from here on the only thing this call may act on. The
    // user keeps captioning while the commit is in the air, so the staged map
    // at the end of it is not the one that went out.
    final sent = Map<String, String?>.from(forAlbum(album.folder));
    if (sent.isEmpty) return const ActionResult.success();

    final config = ref.read(configNotifierProvider);
    if (config == null) {
      return const ActionResult.failure('No repository selected');
    }

    _inFlight[album.folder] = sent;
    try {
      await ref
          .read(albumWriteServiceProvider)
          .setCaptions(config: config, album: album, captions: sent);

      // Order matters, and this is the order:
      //
      // 1. the local album adopts what was just committed, so every caption
      //    reader has the new text BEFORE the staged copy goes away. Clearing
      //    first left readers falling back to the old committed value for the
      //    whole length of the refresh below - the user watching the text they
      //    just saved revert is indistinguishable from the save failing.
      await _adoptCommitted(album.folder, sent);
      // 2. only the entries this commit carried are dropped. Anything typed
      //    while it was in flight is unsent work and stays staged; wiping the
      //    folder would destroy it under a "saved" snackbar.
      await _dropSent(album.folder, sent);
    } catch (e) {
      final text = e.toString();
      return ActionResult.failure(
        text.startsWith('Exception: ')
            ? text.substring('Exception: '.length)
            : text,
      );
    } finally {
      // Cleared before the refresh: from here the local album is the authority
      // on these captions, and a later stage() must compare against it.
      _inFlight.remove(album.folder);
    }

    // Outside the try, and its own failure swallowed: the commit has landed
    // and the captions are saved. A sync that fails afterwards is a stale
    // list, not a failed save, and reporting it as one would send the user
    // back to retype and re-commit - a second commit, a second site build.
    try {
      await ref.read(albumsNotifierProvider.notifier).refresh(force: true);
    } catch (_) {
      // refresh() already folds network failures into the album state; this
      // catches only the unexpected, and even then the save stands.
    }
    return const ActionResult.success();
  }

  /// Write [committed] into the local album, as the commit just did remotely.
  ///
  /// Optimistic on purpose. The authoritative copy arrives with the refresh
  /// that follows, but that refresh is a full tree read - seconds - and it can
  /// be skipped outright when one is already in flight, or fail into a cached
  /// list. None of that may be visible as the user's caption disappearing.
  Future<void> _adoptCommitted(
    String folder,
    Map<String, String?> committed,
  ) async {
    final albums = ref.read(albumsNotifierProvider.notifier);
    final live = albums.byFolder(folder);
    // No local album to patch - it was deleted or never cached. Adding one
    // back from a caption commit would resurrect it in the list.
    if (live == null) return;

    var changed = false;
    final items = <MediaItem>[];
    for (final item in live.items) {
      if (!committed.containsKey(item.name)) {
        items.add(item);
        continue;
      }
      final text = committed[item.name];
      final next = (text == null || text.isEmpty)
          ? item.copyWith(clearCaption: true)
          : item.copyWith(caption: text);
      changed = changed || next.caption != item.caption;
      items.add(next);
    }
    if (!changed) return;
    await albums.upsert(live.copyWith(items: items));
  }

  /// Drop the entries a commit carried, keeping everything else.
  ///
  /// "Everything else" is the point: a caption typed during the commit is
  /// keyed by a filename that may well have been in it, so the entries are
  /// matched by VALUE too. Same value, that is the one that was saved; a
  /// different one, the user has retyped it since and it is still unsent.
  Future<void> _dropSent(String folder, Map<String, String?> sent) async {
    final current = forAlbum(folder);
    final keep = <String, String?>{};
    current.forEach((name, caption) {
      if (!sent.containsKey(name) || sent[name] != caption) {
        keep[name] = caption;
      }
    });
    if (keep.length == current.length) return;
    await _write(folder, keep);
  }

  /// Move staged edits to a new folder name, after the folder was renamed.
  ///
  /// Edits are filed under the folder name, so a rename leaves them on a
  /// folder that no longer exists: unreachable from the album screen, so they
  /// can never be saved or discarded, still counted by the sign-out warning,
  /// and waiting to reattach to any future album that takes the old name.
  Future<void> rekey(String from, String to) async {
    if (from == to) return;
    final moving = forAlbum(from);
    if (moving.isEmpty) return;

    // Anything already filed under the new name is an orphan from an older
    // album of that name; the edits travelling with the album being renamed
    // are the live ones, so they win.
    final merged = Map<String, String?>.from(forAlbum(to))..addAll(moving);
    await _write(from, const {});
    await _write(to, merged);
  }

  /// Drop everything. Called on logout and repository change - a staged
  /// caption belongs to one repo's album and means nothing in the next.
  Future<void> clear() async {
    // Including anything mid-commit: that commit belongs to the repo being
    // left, and its entries must not come back as a baseline afterwards.
    _inFlight.clear();
    await ref.read(pendingCaptionsBoxProvider).clear();
    state = const {};
  }
}
