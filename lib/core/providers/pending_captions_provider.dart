import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/album.dart';
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
    return album.itemNamed(fileName)?.caption ?? '';
  }

  /// Stage one edit. Local and instant - no network, no commit.
  Future<void> stage(Album album, String fileName, String? caption) async {
    final trimmed = caption?.trim();
    final committed = album.itemNamed(fileName)?.caption ?? '';
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
    final entries = forAlbum(album.folder);
    if (entries.isEmpty) return const ActionResult.success();

    final config = ref.read(configNotifierProvider);
    if (config == null) {
      return const ActionResult.failure('No repository selected');
    }

    try {
      await ref
          .read(albumWriteServiceProvider)
          .setCaptions(config: config, album: album, captions: entries);
      // Cleared only after the commit lands, so a failure leaves the user's
      // typing exactly where it was rather than losing it.
      await _write(album.folder, const {});
      await ref.read(albumsNotifierProvider.notifier).refresh(force: true);
      return const ActionResult.success();
    } catch (e) {
      final text = e.toString();
      return ActionResult.failure(
        text.startsWith('Exception: ')
            ? text.substring('Exception: '.length)
            : text,
      );
    }
  }

  /// Drop everything. Called on logout and repository change - a staged
  /// caption belongs to one repo's album and means nothing in the next.
  Future<void> clear() async {
    await ref.read(pendingCaptionsBoxProvider).clear();
    state = const {};
  }
}
