import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';
import 'package:uuid/uuid.dart';

import '../models/album.dart';
import '../models/app_config.dart';
import '../models/upload_job.dart';
import '../platform.dart';
import '../utils/album_captions.dart';
import '../utils/album_conventions.dart';
import 'commit_service.dart';
import 'git_data_service.dart';
import 'github_rate_gate.dart';
import 'linux_media.dart';
import 'media_cache_service.dart';
import 'media_pipeline_service.dart';
import 'upload_queue_service.dart';

/// What the engine is doing right now, for the upload tray.
class UploadProgress {
  final String batchId;
  final String albumFolder;

  /// 0..1 across the whole batch, weighted by bytes.
  final double progress;
  final int done;
  final int total;
  final String? currentLabel;

  /// Sub-progress of the item being compressed, when it is a video.
  final double? itemProgress;

  const UploadProgress({
    required this.batchId,
    required this.albumFolder,
    required this.progress,
    required this.done,
    required this.total,
    this.currentLabel,
    this.itemProgress,
  });
}

/// Result of running one batch.
sealed class UploadOutcome {
  const UploadOutcome();
}

class UploadCommitted extends UploadOutcome {
  final String commitSha;
  final int itemCount;
  final int skippedCount;
  const UploadCommitted({
    required this.commitSha,
    required this.itemCount,
    this.skippedCount = 0,
  });
}

/// Stopped for a reason that will clear on its own - offline, waiting for
/// Wi-Fi, rate-limited. The batch stays queued and no attempt is burned.
class UploadDeferred extends UploadOutcome {
  final String reason;
  final DateTime? retryAfter;
  const UploadDeferred(this.reason, {this.retryAfter});
}

class UploadFailed extends UploadOutcome {
  final String message;
  const UploadFailed(this.message);
}

/// Stages, compresses, uploads and commits a batch of media.
///
/// The shape of this class is dictated by one requirement: an upload of thirty
/// photos over a flaky mobile connection must be able to die at any point and
/// pick up where it left off. That is why every blob sha is persisted the
/// instant it comes back, and why filenames are assigned late.
class UploadService {
  static const _uuid = Uuid();

  final GitDataService _git;
  final CommitService _commits;
  final UploadQueueService _queue;
  final MediaPipelineService _media;
  final MediaCacheService _cache;

  UploadService({
    required GitDataService git,
    required CommitService commits,
    required UploadQueueService queue,
    required MediaPipelineService media,
    required MediaCacheService cache,
  }) : _git = git,
       _commits = commits,
       _queue = queue,
       _media = media,
       _cache = cache;

  /// Build a batch from picked assets and persist it before doing any work.
  ///
  /// Numbers are reserved here, against three sources at once: what is already
  /// in the album, the album's monotonic high-water mark, and anything an
  /// earlier queued batch has claimed. Writing the whole batch to Hive before
  /// touching the network is what makes the reservation survive a crash.
  Future<UploadJob> enqueue({
    required AppConfig config,
    required List<AssetEntity> assets,
    required String albumFolder,
    required QualityPreset preset,
    bool isNewAlbum = false,
    String? summary,
    String? note,
    Album? existingAlbum,
    Map<String, String> captions = const {},
    String? coverAssetId,
  }) async {
    final batchId = _uuid.v4();

    // The cover is not a separate file - it is simply the album's first image.
    // So "make this the cover" means "give this one the lowest number", which
    // is done by ordering the assets here rather than by tagging one of them.
    // That is the whole mechanism; nothing downstream knows about covers.
    final ordered = [...assets];
    if (coverAssetId != null) {
      final index = ordered.indexWhere((a) => a.id == coverAssetId);
      if (index > 0) ordered.insert(0, ordered.removeAt(index));
    }

    final existingNames = existingAlbum?.items.map((i) => i.name) ?? const [];
    final pad = padWidthFor(existingNames);
    var next = nextSequenceNumber(
      existingNames: existingNames,
      highWaterMark: existingAlbum?.nextNumber,
      reservedMax: _queue.reservedMaxFor(albumFolder),
    );

    final items = <UploadItem>[];
    for (final asset in ordered) {
      final ext = targetExtensionFor(asset);
      items.add(
        UploadItem(
          id: _uuid.v4(),
          batchId: batchId,
          sourceAssetId: asset.id,
          targetName: sequenceFilename(next, ext, pad: pad),
          caption: captions[asset.id],
          isVideo: asset.type == AssetType.video,
        ),
      );
      next++;
    }

    final batch = UploadBatch(
      id: batchId,
      albumFolder: albumFolder,
      createdAt: DateTime.now(),
      isNewAlbum: isNewAlbum,
      summary: summary,
      note: note,
      qualityPresetName: preset.name,
    );

    await _queue.putJob(batch, items);
    return UploadJob(batch: batch, items: items);
  }

  /// Run one batch to completion: compress, upload blobs, land one commit.
  Future<UploadOutcome> run(
    UploadBatch batch, {
    required AppConfig config,
    void Function(UploadProgress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    var items = _queue.loadItems(batch.id);
    if (items.isEmpty) {
      await _queue.removeBatch(batch.id);
      return const UploadFailed('This upload had no items left');
    }

    await _queue.putBatch(
      batch.copyWith(state: UploadBatchState.running, clearError: true),
    );

    void report({String? label, double? itemProgress}) {
      final job = UploadJob(batch: batch, items: items);
      onProgress?.call(
        UploadProgress(
          batchId: batch.id,
          albumFolder: batch.albumFolder,
          progress: job.progress,
          done: job.completed,
          total: job.total,
          currentLabel: label,
          itemProgress: itemProgress,
        ),
      );
    }

    try {
      // ---- Stage 1: compress everything that still needs it -------------
      final staging = await UploadQueueService.stagingDir(batch.id);

      for (var index = 0; index < items.length; index++) {
        if (isCancelled?.call() ?? false) {
          return const UploadDeferred('Cancelled');
        }
        final item = items[index];
        if (item.state != UploadItemState.pending) continue;

        // A staged file from a previous run is still good; do not redo the
        // slowest step in the app for nothing.
        final existingPath = item.stagedPath;
        if (existingPath != null && await File(existingPath).exists()) {
          final bytes = await File(existingPath).length();
          if (bytes > 0) {
            items[index] = item.copyWith(
              state: UploadItemState.staged,
              stagedBytes: bytes,
            );
            await _queue.putItem(items[index]);
            continue;
          }
        }

        report(label: item.targetName);
        try {
          final processed = await _stage(
            item: item,
            batch: batch,
            staging: staging,
            onVideoProgress: item.isVideo
                ? (v) => report(label: item.targetName, itemProgress: v)
                : null,
          );
          items[index] = item.copyWith(
            state: UploadItemState.staged,
            stagedPath: processed.file.path,
            stagedBytes: processed.bytes,
            clearError: true,
          );
        } on MediaProcessingException catch (e) {
          // One unconvertible file must never fail a thirty-item album.
          items[index] = item.copyWith(
            state: UploadItemState.failed,
            error: e.message,
          );
        }
        await _queue.putItem(items[index]);
      }

      // ---- Stage 2: one blob per file, resumable -------------------------
      for (var index = 0; index < items.length; index++) {
        if (isCancelled?.call() ?? false) {
          return const UploadDeferred('Cancelled');
        }
        final item = items[index];
        if (item.state != UploadItemState.staged) continue;

        final path = item.stagedPath;
        if (path == null || !await File(path).exists()) {
          items[index] = item.copyWith(
            state: UploadItemState.failed,
            error: 'The prepared file is missing - pick it again',
          );
          await _queue.putItem(items[index]);
          continue;
        }

        report(label: item.targetName);
        final bytes = await File(path).readAsBytes();
        final sha = await _git.createBlob(
          config.repoOwner,
          config.repoName,
          bytes,
        );

        // Persisted per item, immediately. If the app dies now, the next run
        // starts from here rather than re-uploading everything.
        items[index] = item.copyWith(
          state: UploadItemState.blobCreated,
          blobSha: sha,
        );
        await _queue.putItem(items[index]);

        // Seed the byte cache from the file we already have, so the photo is
        // viewable the instant the commit lands - no download, and no waiting
        // out any cold-cache window on a freshly pushed path.
        await _cache.seed(
          blobSha: sha,
          bytes: bytes,
          fileExtension: p.extension(item.targetName),
        );
      }

      final uploadable = items
          .where((i) => i.state == UploadItemState.blobCreated)
          .toList();
      final skipped = items
          .where((i) => i.state == UploadItemState.failed)
          .length;

      if (uploadable.isEmpty) {
        // An attempt is burned even though nothing was tried. Every item here
        // is already terminal, so a re-run cannot produce a different answer;
        // without the increment the batch stays eligible forever and a manual
        // retry re-enters this same dead end on every pass.
        await _queue.putBatch(
          batch.copyWith(
            state: UploadBatchState.failed,
            attempts: batch.attempts + 1,
            error: 'Nothing could be prepared for upload',
          ),
        );
        return const UploadFailed('None of these files could be uploaded');
      }

      // ---- Stage 3: one commit ------------------------------------------
      report(label: 'Saving to GitHub');
      final outcome = await _commits.commit(
        config: config,
        message: _commitMessage(batch, uploadable.length),
        // Rebuilt against a FRESH tree on every attempt. If the branch moved
        // and our numbers are taken, this re-numbers and re-paths the same
        // blobs; nothing is uploaded twice.
        buildEntries: (tree) =>
            _buildEntries(config, batch, uploadable, tree),
      );

      final commitSha = switch (outcome) {
        CommitApplied(commitSha: final sha) => sha,
        CommitNoop(:final commitSha) => commitSha,
      };

      for (final item in uploadable) {
        await _queue.putItem(item.copyWith(state: UploadItemState.done));
      }
      await _queue.removeBatch(batch.id);

      return UploadCommitted(
        commitSha: commitSha,
        itemCount: uploadable.length,
        skippedCount: skipped,
      );
    } catch (e) {
      final deferred = _deferralFor(e);
      if (deferred != null) {
        await _queue.putBatch(batch.copyWith(state: UploadBatchState.waiting));
        return deferred;
      }
      final attempts = batch.attempts + 1;
      final failed = attempts >= UploadBatch.maxAttempts;
      await _queue.putBatch(
        batch.copyWith(
          state: failed ? UploadBatchState.failed : UploadBatchState.queued,
          attempts: attempts,
          error: e.toString(),
        ),
      );
      return UploadFailed(e.toString());
    }
  }

  Future<ProcessedMedia> _stage({
    required UploadItem item,
    required UploadBatch batch,
    required Directory staging,
    void Function(double)? onVideoProgress,
  }) async {
    final assetId = item.sourceAssetId;
    if (assetId == null) {
      throw const MediaProcessingException('This item is no longer available');
    }
    final asset =
        isLinux ? fileAsset(assetId) : await AssetEntity.fromId(assetId);
    if (asset == null) {
      // The user deleted it from their gallery after queueing.
      throw const MediaProcessingException(
        'This item is no longer in your gallery',
      );
    }

    final target = p.join(staging.path, item.targetName);
    final processed = asset.type == AssetType.video
        ? await _media.processVideo(
            asset: asset,
            preset: batch.preset,
            targetPath: target,
            onProgress: onVideoProgress,
          )
        : await _media.processPhoto(
            asset: asset,
            preset: batch.preset,
            targetPath: target,
          );

    if (processed.bytes > MediaPipelineService.maxFileBytes) {
      await processed.file.delete().catchError((_) => processed.file);
      throw MediaProcessingException(
        '${item.targetName} is ${formatBytes(processed.bytes)} after '
        'compression (limit '
        '${formatBytes(MediaPipelineService.maxFileBytes)}). '
        'Try a shorter clip or a lower quality.',
      );
    }
    return processed;
  }

  /// The tree entries for one batch: the media, the cover, `album.md`, and
  /// `album.json`, all in a single commit.
  Future<List<TreeEntry>> _buildEntries(
    AppConfig config,
    UploadBatch batch,
    List<UploadItem> items,
    TreeSnapshot tree,
  ) async {
    final folder = batch.albumFolder;
    final prefix = '${config.albumFolderPath(folder)}/';
    final existingNames = <String>{};

    // Blob shas already published in this album. A git blob sha is a content
    // address, so this answers "which of these exact files are in the repo"
    // independently of what they are called.
    final publishedShas = <String>{};
    String? captionsSha;
    String? noteSha;

    for (final node in tree.nodes) {
      if (!node.isBlob || !node.path.startsWith(prefix)) continue;
      final name = node.path.substring(prefix.length);
      if (name.contains('/')) continue;
      if (name == kCaptionsFile) {
        captionsSha = node.sha;
        continue;
      }
      if (name == kNoteFile) {
        noteSha = node.sha;
        continue;
      }
      existingNames.add(name);
      publishedShas.add(node.sha);
    }

    var captions = AlbumCaptions.empty(folder);
    var captionsReadable = true;
    if (captionsSha != null) {
      try {
        captions = AlbumCaptions.parse(
          folder,
          await _git.fetchBlobText(
            config.repoOwner,
            config.repoName,
            captionsSha,
          ),
        );
      } catch (_) {
        // Unreadable captions must not block the photos - but they must not be
        // rewritten from nothing either. An album.json that exists and could
        // not be read is NOT an album with no captions: writing a fresh one
        // would delete every caption in the album and reset the monotonic
        // high-water mark, which is exactly what lets a later upload inherit a
        // deleted photo's caption. Commit the media, leave the sidecar alone.
        captionsReadable = false;
      }
    }

    // Re-derive names against the tree we are actually committing on. On a
    // first attempt this reproduces what enqueue() reserved; after a rebase it
    // moves everything past whatever landed in the meantime.
    final pad = padWidthFor(existingNames);
    var next = nextSequenceNumber(
      existingNames: existingNames,
      highWaterMark: captions.next,
    );

    // The number space is shared across extensions - the site sorts one merged
    // list - so allocation tracks NUMBERS, not filenames. Checking names would
    // happily hand out 0002.jpg next to an existing 0002.mp4.
    final usedNumbers = <int>{
      for (final existing in existingNames)
        if (parseSequenceNumber(existing) != null)
          parseSequenceNumber(existing)!,
    };

    final entries = <TreeEntry>[];
    for (final item in items) {
      // Finding this item's blob already under the album prefix means these
      // exact bytes are published in this album ALREADY - which is what a
      // batch that resumes after its ref update landed but whose response was
      // lost looks like. Committing it again would not retry anything: every
      // name is taken, so all of it would be renumbered and the album would
      // hold a second copy of every photo. Skipping is also what lets the
      // entry list come back empty, so CommitService reports a no-op and run()
      // clears the batch instead of publishing duplicates.
      if (publishedShas.contains(item.blobSha)) continue;

      final ext = p.extension(item.targetName);
      // Allocated from the live counter rather than the name reserved at
      // enqueue time, since a name reserved before a rebase may be taken by
      // now. The picker shows selection ORDER, not filenames, so nothing the
      // user saw depends on the reserved value.
      //
      // There is deliberately no cover handling here. The cover is simply
      // whichever image sorts first, so ordering the assets at enqueue time is
      // the entire mechanism. Writing a separate `0.jpg` - which is what this
      // used to do - stored the cover twice, so an album published one more
      // file than the user picked and showed its cover twice, with the caption
      // attached to only one of the two copies.
      while (usedNumbers.contains(next)) {
        next++;
      }
      final name = sequenceFilename(next, ext, pad: pad);
      usedNumbers.add(next);
      next++;
      existingNames.add(name);

      entries.add(TreeEntry.file('$prefix$name', item.blobSha!));
      final caption = item.caption;
      if (caption != null && caption.trim().isNotEmpty) {
        captions = captions.withCaption(name, caption);
      }
    }

    // Zero when every file in the batch was already in the tree.
    final mediaEntryCount = entries.length;

    // Never lowered by a deletion: this is what stops a future upload from
    // inheriting a deleted photo's caption.
    captions = captions.withNext(next).withPad(pad);

    // Summary and note are only written when the album has none yet, so an
    // upload never silently overwrites one edited on another device.
    if (captions.summary.isEmpty) {
      captions = captions.withSummary(batch.summary ?? '');
    }
    final note = batch.note?.trim();
    if (note != null && note.isNotEmpty && noteSha == null) {
      final sha = await _git.createBlob(
        config.repoOwner,
        config.repoName,
        Uint8List.fromList(utf8.encode('$note\n')),
      );
      entries.add(TreeEntry.file('$prefix$kNoteFile', sha));
    }

    // The sidecar only ever changes as a consequence of committing media in
    // this same commit, so with no media there is nothing to record - and
    // rewriting it anyway would defeat the no-op above, since `updated` is a
    // timestamp and every re-encode produces a different blob.
    if (mediaEntryCount > 0 && captionsReadable && !captions.isEmpty) {
      final sha = await _git.createBlob(
        config.repoOwner,
        config.repoName,
        Uint8List.fromList(utf8.encode(captions.encode())),
      );
      entries.add(TreeEntry.file('$prefix$kCaptionsFile', sha));
    }

    return entries;
  }

  String _commitMessage(UploadBatch batch, int count) {
    final noun = count == 1 ? 'item' : 'items';
    return batch.isNewAlbum
        ? 'glickr: create album ${batch.albumFolder} with $count $noun'
        : 'glickr: add $count $noun to ${batch.albumFolder}';
  }

  /// Classify an error as "will clear on its own" rather than a failure.
  ///
  /// Getting this wrong in either direction is costly: treating a tunnel as a
  /// failure burns the retry budget and greets the user with three false
  /// errors, while treating a real failure as transient loops forever.
  UploadDeferred? _deferralFor(Object error) {
    if (error is RateBudgetExhausted) {
      return UploadDeferred(
        'GitHub limits uploads to 500 files an hour',
        retryAfter: error.resumesAt,
      );
    }
    final message = error.toString().toLowerCase();
    if (message.contains('no internet') ||
        message.contains('connection') ||
        message.contains('timed out') ||
        message.contains('timeout') ||
        message.contains('socket')) {
      return const UploadDeferred('Waiting for a connection');
    }
    if (message.contains('rate limit') || message.contains('throttl')) {
      return const UploadDeferred('GitHub is rate-limiting requests');
    }
    return null;
  }

}
