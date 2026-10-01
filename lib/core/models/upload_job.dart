import '../models/app_config.dart';

/// Lifecycle of one file inside a batch.
abstract final class UploadItemState {
  /// Picked, not yet compressed.
  static const pending = 'pending';

  /// Compressed and written to the staging directory.
  static const staged = 'staged';

  /// Uploaded as a git blob; its sha is known. THE resume anchor.
  static const blobCreated = 'blob_created';

  /// Included in a landed commit.
  static const done = 'done';

  /// Permanently failed. The rest of the batch still goes.
  static const failed = 'failed';
}

/// Lifecycle of a batch.
abstract final class UploadBatchState {
  static const queued = 'queued';
  static const running = 'running';

  /// Waiting on connectivity, Wi-Fi, or a rate-limit window.
  static const waiting = 'waiting';
  static const done = 'done';
  static const failed = 'failed';
}

/// One file in an upload batch.
///
/// Stored as a plain Map in a `Box<Map>` with deliberately NO Hive
/// TypeAdapter, so the queue can never break a Hive migration: a field added
/// here cannot make an in-flight upload undeserializable, which would silently
/// lose the user's photos. Every read in [fromMap] is null-tolerant for the
/// same reason.
class UploadItem {
  final String id;
  final String batchId;

  /// photo_manager asset id, kept only for the thumbnail in the tray. Never
  /// the source of truth: the original can be deleted from the gallery between
  /// queueing and uploading.
  final String? sourceAssetId;

  /// Absolute path of the compressed file under the app's own documents
  /// directory. Deliberately NOT in a cache directory, which Android reaps
  /// under storage pressure - that would destroy a queued upload.
  final String? stagedPath;
  final int stagedBytes;

  /// Final basename, e.g. `0007.jpg`.
  ///
  /// LATE-BOUND on purpose: if the branch moves and the number is taken, this
  /// is rewritten and the file is committed under a new name with the SAME
  /// blob, so nothing is re-uploaded.
  final String targetName;

  final String? caption;
  final bool isVideo;
  final String state;
  final String? blobSha;
  final String? error;

  const UploadItem({
    required this.id,
    required this.batchId,
    required this.targetName,
    this.sourceAssetId,
    this.stagedPath,
    this.stagedBytes = 0,
    this.caption,
    this.isVideo = false,
    this.state = UploadItemState.pending,
    this.blobSha,
    this.error,
  });

  bool get isTerminal =>
      state == UploadItemState.done || state == UploadItemState.failed;

  UploadItem copyWith({
    String? targetName,
    String? stagedPath,
    int? stagedBytes,
    String? caption,
    String? state,
    String? blobSha,
    String? error,
    bool clearError = false,
  }) {
    return UploadItem(
      id: id,
      batchId: batchId,
      sourceAssetId: sourceAssetId,
      stagedPath: stagedPath ?? this.stagedPath,
      stagedBytes: stagedBytes ?? this.stagedBytes,
      targetName: targetName ?? this.targetName,
      caption: caption ?? this.caption,
      isVideo: isVideo,
      state: state ?? this.state,
      blobSha: blobSha ?? this.blobSha,
      error: clearError ? null : (error ?? this.error),
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'batchId': batchId,
    'sourceAssetId': sourceAssetId,
    'stagedPath': stagedPath,
    'stagedBytes': stagedBytes,
    'targetName': targetName,
    'caption': caption,
    'isVideo': isVideo,
    'state': state,
    'blobSha': blobSha,
    'error': error,
  };

  /// Tolerant of every field being missing or the wrong type - a corrupt
  /// record should be skippable, not fatal to the whole queue.
  static UploadItem? fromMap(Map<dynamic, dynamic> map) {
    final id = map['id'];
    final batchId = map['batchId'];
    final targetName = map['targetName'];
    if (id is! String || batchId is! String || targetName is! String) {
      return null;
    }
    return UploadItem(
      id: id,
      batchId: batchId,
      targetName: targetName,
      sourceAssetId: map['sourceAssetId'] as String?,
      stagedPath: map['stagedPath'] as String?,
      stagedBytes: (map['stagedBytes'] as num?)?.toInt() ?? 0,
      caption: map['caption'] as String?,
      isVideo: map['isVideo'] as bool? ?? false,
      state: map['state'] as String? ?? UploadItemState.pending,
      blobSha: map['blobSha'] as String?,
      error: map['error'] as String?,
    );
  }
}

/// One album-level upload: everything in it lands as a single git commit.
class UploadBatch {
  /// Higher than a typical publish queue's three, because a rejected ref
  /// update is a routine event here - any other device pushing while we upload
  /// causes one - and each retry costs four requests and zero bytes.
  static const int maxAttempts = 5;

  final String id;
  final String albumFolder;

  /// True when this batch creates the folder. Only used for copy; the commit
  /// itself is identical either way, because git has no directories.
  final bool isNewAlbum;

  /// For a new album: the `album.json` summary.
  final String? summary;

  /// For a new album: the `album.md` note.
  final String? note;

  final String qualityPresetName;
  final DateTime createdAt;
  final String state;
  final int attempts;
  final String? error;

  const UploadBatch({
    required this.id,
    required this.albumFolder,
    required this.createdAt,
    this.isNewAlbum = false,
    this.summary,
    this.note,
    this.qualityPresetName = 'medium',
    this.state = UploadBatchState.queued,
    this.attempts = 0,
    this.error,
  });

  QualityPreset get preset => QualityPreset.fromName(qualityPresetName);

  bool get isTerminal =>
      state == UploadBatchState.done || state == UploadBatchState.failed;

  bool get canAutoRetry => attempts < maxAttempts;

  UploadBatch copyWith({
    String? state,
    int? attempts,
    String? error,
    bool clearError = false,
  }) {
    return UploadBatch(
      id: id,
      albumFolder: albumFolder,
      createdAt: createdAt,
      isNewAlbum: isNewAlbum,
      summary: summary,
      note: note,
      qualityPresetName: qualityPresetName,
      state: state ?? this.state,
      attempts: attempts ?? this.attempts,
      error: clearError ? null : (error ?? this.error),
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'albumFolder': albumFolder,
    'isNewAlbum': isNewAlbum,
    'summary': summary,
    'note': note,
    'qualityPresetName': qualityPresetName,
    'createdAt': createdAt.toIso8601String(),
    'state': state,
    'attempts': attempts,
    'error': error,
  };

  static UploadBatch? fromMap(Map<dynamic, dynamic> map) {
    final id = map['id'];
    final folder = map['albumFolder'];
    if (id is! String || folder is! String) return null;
    return UploadBatch(
      id: id,
      albumFolder: folder,
      createdAt:
          DateTime.tryParse(map['createdAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      isNewAlbum: map['isNewAlbum'] as bool? ?? false,
      summary: map['summary'] as String?,
      note: map['note'] as String?,
      qualityPresetName: map['qualityPresetName'] as String? ?? 'medium',
      state: map['state'] as String? ?? UploadBatchState.queued,
      attempts: (map['attempts'] as num?)?.toInt() ?? 0,
      error: map['error'] as String?,
    );
  }
}

/// A batch plus its items, as the UI consumes it.
class UploadJob {
  final UploadBatch batch;
  final List<UploadItem> items;

  const UploadJob({required this.batch, required this.items});

  int get total => items.length;
  int get completed =>
      items.where((i) => i.state == UploadItemState.done).length;
  int get failed => items.where((i) => i.state == UploadItemState.failed).length;

  /// Progress by BYTES, not item count.
  ///
  /// A 16 MB video sitting among eleven photos makes item-count progress lie
  /// badly: the bar would sit at 11/12 for the entire time that actually
  /// matters.
  ///
  /// Two invariants that a plain sum over [UploadItem.stagedBytes] breaks:
  ///
  ///   * THE DENOMINATOR MUST NOT GROW AS THE RUN PROCEEDS. An item only
  ///     learns its `stagedBytes` once it has been compressed, so weighting an
  ///     uncompressed item at zero means a RESUMED batch - whose only sized
  ///     items are the ones already uploaded - starts at 1.0 and then counts
  ///     backwards as stage 1 sizes the rest. Unsized items therefore stand in
  ///     at the mean of the sized ones, which keeps the total roughly fixed
  ///     from the first frame to the last.
  ///   * 1.0 MEANS LANDED, NOT UPLOADED. Every blob is on GitHub before the
  ///     commit that publishes it, so a batch can be 100% uploaded with its
  ///     single riskiest request still outstanding. A full ring there reads as
  ///     a hang, so progress is held just short until every item is terminal.
  double get progress {
    if (total == 0) return 0;

    final sized = items.where((i) => i.stagedBytes > 0).toList();
    if (sized.isEmpty) return _capped(completed / total);

    final estimate =
        sized.fold<int>(0, (sum, i) => sum + i.stagedBytes) / sized.length;
    double weightOf(UploadItem i) =>
        i.stagedBytes > 0 ? i.stagedBytes.toDouble() : estimate;

    final totalWeight = items.fold<double>(0, (sum, i) => sum + weightOf(i));
    if (totalWeight <= 0) return _capped(completed / total);

    // `failed` counts as resolved work: it will never move again, and leaving
    // it out would pin a batch with one bad file below 1.0 forever.
    final doneWeight = items
        .where(
          (i) =>
              i.state == UploadItemState.done ||
              i.state == UploadItemState.blobCreated ||
              i.state == UploadItemState.failed,
        )
        .fold<double>(0, (sum, i) => sum + weightOf(i));
    return _capped(doneWeight / totalWeight);
  }

  /// Clamp to 0..1, reserving 1.0 for a batch whose items have all landed.
  double _capped(double ratio) {
    final clamped = ratio.clamp(0.0, 1.0);
    if (clamped < 1 || items.every((i) => i.isTerminal)) return clamped;
    return 0.99;
  }

  int get totalBytes => items.fold<int>(0, (sum, i) => sum + i.stagedBytes);
}
