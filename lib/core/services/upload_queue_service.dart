import 'dart:io';

import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/upload_job.dart';

/// Hive-backed persistence for the upload queue.
///
/// Records are PLAIN MAPS in a `Box<Map>` with no TypeAdapter, on purpose: a
/// TypeAdapter ties the queue's on-disk format to a generated class, so adding
/// a field could make an in-flight batch undeserializable after an app update.
/// For a queue whose payload is the user's photos, "the schema changed so your
/// upload vanished" is not an acceptable failure mode. Every read is
/// null-tolerant and a corrupt record is skipped rather than taking the whole
/// queue down with it.
class UploadQueueService {
  static const String batchBoxName = 'upload_batches';
  static const String itemBoxName = 'upload_items';

  final Box<Map> _batches;
  final Box<Map> _items;

  UploadQueueService({required Box<Map> batches, required Box<Map> items})
    : _batches = batches,
      _items = items;

  /// Where compressed files wait for their turn.
  ///
  /// Under the app's documents directory rather than a cache directory:
  /// Android reclaims cache directories under storage pressure, which would
  /// silently destroy a queued upload between the user picking photos and the
  /// network coming back.
  static Future<Directory> stagingDir(String batchId) async {
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(root.path, 'pending_uploads', batchId));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  List<UploadBatch> loadBatches() {
    final out = <UploadBatch>[];
    for (final key in _batches.keys) {
      try {
        final raw = _batches.get(key);
        if (raw == null) continue;
        final batch = UploadBatch.fromMap(raw);
        if (batch != null) out.add(batch);
      } catch (_) {
        // Unreadable record: skip it rather than failing the queue.
      }
    }
    out.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return out;
  }

  List<UploadItem> loadItems(String batchId) {
    final out = <UploadItem>[];
    for (final key in _items.keys) {
      try {
        final raw = _items.get(key);
        if (raw == null) continue;
        final item = UploadItem.fromMap(raw);
        if (item != null && item.batchId == batchId) out.add(item);
      } catch (_) {
        // Skip.
      }
    }
    // Filename order is upload order is the order the site displays.
    out.sort((a, b) => a.targetName.compareTo(b.targetName));
    return out;
  }

  List<UploadJob> loadJobs() {
    return loadBatches()
        .map((b) => UploadJob(batch: b, items: loadItems(b.id)))
        .toList();
  }

  Future<void> putBatch(UploadBatch batch) =>
      _batches.put(batch.id, batch.toMap());

  Future<void> putItem(UploadItem item) => _items.put(item.id, item.toMap());

  /// Write a batch and all its items in one go.
  ///
  /// Called BEFORE any network work so the number range the batch claimed is
  /// crash-safe, and so a second batch started in the same session cannot
  /// claim the same numbers.
  Future<void> putJob(UploadBatch batch, List<UploadItem> items) async {
    await _items.putAll({for (final i in items) i.id: i.toMap()});
    await _batches.put(batch.id, batch.toMap());
  }

  /// Remove a batch, its items, and its staged files.
  Future<void> removeBatch(String batchId) async {
    final itemKeys = <dynamic>[];
    for (final key in _items.keys) {
      try {
        final raw = _items.get(key);
        if (raw != null && raw['batchId'] == batchId) itemKeys.add(key);
      } catch (_) {
        // A record we cannot even read the batchId from is garbage anyway.
        itemKeys.add(key);
      }
    }
    await _items.deleteAll(itemKeys);
    await _batches.delete(batchId);
    await _deleteStaging(batchId);
  }

  /// Every number this device has already claimed for [folder] but not yet
  /// committed.
  ///
  /// Consulted when allocating a new batch so two batches queued back to back
  /// cannot both start at the same number.
  int? reservedMaxFor(String folder) {
    int? max;
    for (final batch in loadBatches()) {
      if (batch.albumFolder != folder) continue;
      if (batch.state == UploadBatchState.done) continue;
      for (final item in loadItems(batch.id)) {
        final stem = p.basenameWithoutExtension(item.targetName);
        final n = int.tryParse(stem);
        if (n == null) continue;
        if (max == null || n > max) max = n;
      }
    }
    return max;
  }

  /// Drop everything.
  ///
  /// Called on logout and on repository change. A queued batch carries its own
  /// bytes and its own target folder; left in place it would flush into
  /// whatever repository is configured next, which is somewhere between
  /// surprising and a privacy incident.
  Future<void> clear() async {
    final ids = loadBatches().map((b) => b.id).toList();
    await _items.clear();
    await _batches.clear();
    for (final id in ids) {
      await _deleteStaging(id);
    }
    await _deleteStagingRoot();
  }

  Future<void> _deleteStaging(String batchId) async {
    try {
      final dir = await stagingDir(batchId);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // Storage cleanup is best-effort.
    }
  }

  Future<void> _deleteStagingRoot() async {
    try {
      final root = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(root.path, 'pending_uploads'));
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // Best-effort.
    }
  }

  /// Delete staging directories with no surviving batch.
  ///
  /// Runs at startup. Without it, a batch removed while the process was dead
  /// leaves its compressed files on disk forever.
  Future<void> pruneOrphanStaging() async {
    try {
      final root = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(root.path, 'pending_uploads'));
      if (!await dir.exists()) return;
      final live = loadBatches().map((b) => b.id).toSet();
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! Directory) continue;
        if (live.contains(p.basename(entity.path))) continue;
        await entity.delete(recursive: true);
      }
    } catch (_) {
      // Best-effort.
    }
  }
}
