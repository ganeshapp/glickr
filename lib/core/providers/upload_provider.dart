import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/app_config.dart';
import '../models/upload_job.dart';
import '../services/upload_service.dart';
import 'albums_provider.dart';
import 'config_provider.dart';
import 'services_provider.dart';

part 'upload_provider.g.dart';

/// Everything the upload tray needs to render.
class UploadQueueState {
  final List<UploadJob> jobs;

  /// The batch currently running, if any.
  final String? activeBatchId;
  final UploadProgress? progress;

  /// Set while the queue is parked for a reason that will clear on its own.
  final String? waitingReason;
  final DateTime? retryAfter;

  /// The last batch that landed, so the tray can show a success state with a
  /// "View" action before dismissing itself.
  final String? completedFolder;
  final int completedCount;
  final int skippedCount;

  const UploadQueueState({
    this.jobs = const [],
    this.activeBatchId,
    this.progress,
    this.waitingReason,
    this.retryAfter,
    this.completedFolder,
    this.completedCount = 0,
    this.skippedCount = 0,
  });

  bool get isBusy => activeBatchId != null;
  bool get hasWork => jobs.isNotEmpty;
  bool get isWaiting => waitingReason != null;

  bool get hasFailures =>
      jobs.any((j) => j.batch.state == UploadBatchState.failed);

  int get pendingItemCount =>
      jobs.fold(0, (sum, j) => sum + (j.total - j.completed));

  UploadQueueState copyWith({
    List<UploadJob>? jobs,
    String? activeBatchId,
    UploadProgress? progress,
    String? waitingReason,
    DateTime? retryAfter,
    String? completedFolder,
    int? completedCount,
    int? skippedCount,
    bool clearActive = false,
    bool clearWaiting = false,
    bool clearCompleted = false,
  }) {
    return UploadQueueState(
      jobs: jobs ?? this.jobs,
      activeBatchId: clearActive ? null : (activeBatchId ?? this.activeBatchId),
      progress: clearActive ? null : (progress ?? this.progress),
      waitingReason: clearWaiting ? null : (waitingReason ?? this.waitingReason),
      retryAfter: clearWaiting ? null : (retryAfter ?? this.retryAfter),
      completedFolder: clearCompleted
          ? null
          : (completedFolder ?? this.completedFolder),
      completedCount: clearCompleted ? 0 : (completedCount ?? this.completedCount),
      skippedCount: clearCompleted ? 0 : (skippedCount ?? this.skippedCount),
    );
  }
}

/// Owns the upload queue and drains it.
///
/// keepAlive because it must keep listening while no screen is mounted: an
/// upload started from the album screen has to survive the user navigating
/// into the viewer, out to settings, and back.
@Riverpod(keepAlive: true)
class UploadQueueNotifier extends _$UploadQueueNotifier {
  /// The drain in flight, if any.
  ///
  /// Coalesces overlapping drains, so a connectivity event and a manual retry
  /// arriving together cannot run the same batch twice. Holding the future
  /// rather than a bool also lets a second caller AWAIT the running drain
  /// instead of being told "no" by a call that returns instantly.
  Future<void>? _drain;

  bool _cancelRequested = false;

  /// Bumped whenever the queue is torn down under a running drain (logout,
  /// repository change). A drain compares it against the value it captured and
  /// abandons its results if they no longer belong to the current account or
  /// repo - otherwise a commit that lands during sign-out writes the OLD
  /// repo's head sha back into the sync state that was just cleared.
  int _generation = 0;

  StreamSubscription<List<ConnectivityResult>>? _connectivity;
  AppLifecycleListener? _lifecycle;
  Timer? _resumeTimer;

  /// Seam for tests. The real probe goes through a platform channel, which is
  /// not available under `flutter_test`.
  @visibleForTesting
  Future<List<ConnectivityResult>> Function() connectivityProbe =
      () => Connectivity().checkConnectivity();

  @override
  UploadQueueState build() {
    _wireTriggers();
    ref.onDispose(() {
      _connectivity?.cancel();
      _lifecycle?.dispose();
      _resumeTimer?.cancel();
    });

    // Anything left over from a previous run reappears immediately, already
    // showing its real progress - blob shas were persisted per item, so a
    // resumed batch says "4 of 12", not "0 of 12".
    List<UploadJob> jobs;
    try {
      jobs = ref.read(uploadQueueServiceProvider).loadJobs();
    } catch (_) {
      jobs = const [];
    }

    if (jobs.isNotEmpty) {
      // Auto-resume rather than prompting. A "Resume upload?" dialog on launch
      // is friction the user did not ask for and cannot usefully answer.
      Future.microtask(process);
    }
    return UploadQueueState(jobs: jobs);
  }

  void _wireTriggers() {
    try {
      _connectivity = Connectivity().onConnectivityChanged.listen(
        (results) {
          final online = results.any((r) => r != ConnectivityResult.none);
          if (online) process();
        },
        // A platform-channel hiccup in a connectivity plugin must never take
        // the app down.
        onError: (_) {},
      );
    } catch (_) {
      // Connectivity is an optimisation; the queue still drains on resume.
    }
    _lifecycle = AppLifecycleListener(onResume: process);
  }

  void _reload() {
    try {
      state = state.copyWith(
        jobs: ref.read(uploadQueueServiceProvider).loadJobs(),
      );
    } catch (_) {
      // Leave the previous list rather than blanking the tray.
    }
  }

  /// Add a batch and start draining.
  Future<void> enqueueJob(UploadJob job) async {
    _cancelRequested = false;
    state = state.copyWith(
      jobs: [...state.jobs, job],
      clearCompleted: true,
      clearWaiting: true,
    );
    unawaited(process());
  }

  /// Drain the queue, one batch at a time.
  ///
  /// Awaiting the returned future always means "the queue has settled", even
  /// when another trigger got there first: an overlapping call joins the drain
  /// already running rather than returning a future that is already complete.
  Future<void> process({bool manual = false}) {
    final running = _drain;
    if (running != null) return running;
    final drain = _drainQueue(manual: manual).whenComplete(() => _drain = null);
    _drain = drain;
    return drain;
  }

  Future<void> _drainQueue({required bool manual}) async {
    final config = ref.read(configNotifierProvider);
    if (config == null) return;

    _cancelRequested = false;
    final generation = _generation;
    // Compression pins the CPU and the screen going off mid-transcode can have
    // the OS reclaim the hardware encoder session.
    await _setWakelock(true);

    try {
      // Every batch is attempted at most ONCE per drain pass.
      //
      // Nothing else bounds this loop. A batch that cannot produce an
      // uploadable item is rewritten as `failed` without burning an attempt,
      // and a manual drain deliberately accepts `failed` batches, so selection
      // by state alone re-picks the same batch on the very next iteration -
      // forever, with the wakelock held and the drain never releasing. The
      // queue only ever shrinks or changes state through work done here, so
      // "already tried in this pass" is the only progress guarantee available.
      final attempted = <String>{};

      while (true) {
        if (_cancelRequested || generation != _generation) break;
        _reload();

        final next = state.jobs
            .map((j) => j.batch)
            .where(
              (b) =>
                  !attempted.contains(b.id) &&
                  b.state != UploadBatchState.done &&
                  // An auto drain leaves failed batches alone; only an
                  // explicit retry (manual) picks them back up.
                  (manual || b.state != UploadBatchState.failed),
            )
            .firstOrNull;
        if (next == null) break;
        attempted.add(next.id);

        // Enforced per drain rather than at enqueue time: the user can queue
        // on Wi-Fi and walk out of range, and this is the point where the
        // bytes would actually be spent.
        if (await _blockedByWifiOnly(config)) {
          state = state.copyWith(
            waitingReason: 'Waiting for Wi-Fi',
            clearActive: true,
          );
          // The connectivity listener drains again when the transport changes,
          // and no attempt was burned, so the batch is untouched.
          return;
        }

        state = state.copyWith(
          activeBatchId: next.id,
          clearWaiting: true,
          clearCompleted: true,
        );

        final outcome = await ref
            .read(uploadServiceProvider)
            .run(
              next,
              config: config,
              isCancelled: () => _cancelRequested,
              onProgress: _onProgress,
            );

        // The queue was torn down while this batch ran (logout, repo change).
        // Its result describes a repository that is no longer configured, so
        // applying it would resurrect state the user asked to be rid of.
        if (generation != _generation) return;

        switch (outcome) {
          case UploadCommitted(
            :final itemCount,
            :final skippedCount,
            :final commitSha,
          ):
            // The commit sha we just created IS the head, so the CDN URLs
            // built from it are correct immediately - and the bytes are
            // already seeded into the cache, so nothing has to be downloaded.
            await ref
                .read(syncStateNotifierProvider.notifier)
                .save(
                  RepoSyncState(
                    commitSha: commitSha,
                    // Etag deliberately dropped: the branch definitely moved,
                    // so the next refresh must not be answered with a 304.
                    lastSynced: DateTime.now(),
                    repoBytes: ref.read(syncStateNotifierProvider).repoBytes,
                  ),
                );
            state = state.copyWith(
              completedFolder: next.albumFolder,
              completedCount: itemCount,
              skippedCount: skippedCount,
              clearActive: true,
            );
            unawaited(ref.read(albumsNotifierProvider.notifier).refresh());

          case UploadDeferred(:final reason, :final retryAfter):
            // A cancel surfaces as a deferral because `run` only samples
            // `isCancelled` at its item boundaries, so it reports back long
            // after `cancelAll` has emptied the queue. Parking that in the
            // waiting state would leave the tray promising that uploads
            // "resume automatically" over a queue that no longer exists and
            // that nothing will ever come back to clear.
            if (_cancelRequested) {
              _resumeTimer?.cancel();
              state = state.copyWith(clearActive: true, clearWaiting: true);
              _reload();
              return;
            }
            state = state.copyWith(
              waitingReason: reason,
              retryAfter: retryAfter,
              clearActive: true,
            );
            _scheduleResume(retryAfter);
            // Stop draining: whatever blocked this batch blocks the next.
            _reload();
            return;

          case UploadFailed():
            state = state.copyWith(clearActive: true);
        }
        _reload();
      }
    } finally {
      state = state.copyWith(clearActive: true);
      await _setWakelock(false);
    }
  }

  void _onProgress(UploadProgress progress) {
    // Throttled by value rather than time: the transcoder emits progress far
    // faster than the eye can read, and an unthrottled notifier would rebuild
    // the tray hundreds of times a second.
    final previous = state.progress;
    if (previous != null &&
        previous.batchId == progress.batchId &&
        previous.currentLabel == progress.currentLabel &&
        (progress.progress - previous.progress).abs() < 0.01 &&
        ((progress.itemProgress ?? 0) - (previous.itemProgress ?? 0)).abs() <
            0.02) {
      return;
    }
    state = state.copyWith(progress: progress);
  }

  void _scheduleResume(DateTime? retryAfter) {
    _resumeTimer?.cancel();
    if (retryAfter == null) return;
    final wait = retryAfter.difference(DateTime.now());
    if (wait.isNegative) return;
    _resumeTimer = Timer(wait + const Duration(seconds: 2), process);
  }

  /// Stop the run in progress. Already-committed batches are untouched: the
  /// album genuinely changed, and claiming a rollback the app is not doing
  /// would be a lie.
  Future<void> cancelAll() async {
    _cancelRequested = true;
    _resumeTimer?.cancel();
    await ref.read(mediaPipelineServiceProvider).cancelVideo();
    for (final job in state.jobs) {
      await ref.read(uploadQueueServiceProvider).removeBatch(job.batch.id);
    }
    _reload();
    state = state.copyWith(clearActive: true, clearWaiting: true);
  }

  Future<void> cancelBatch(String batchId) async {
    final wasActive = state.activeBatchId == batchId;
    if (wasActive) {
      _cancelRequested = true;
      await ref.read(mediaPipelineServiceProvider).cancelVideo();
    }
    await ref.read(uploadQueueServiceProvider).removeBatch(batchId);
    _reload();
    // The waiting state describes a batch, not the queue: keeping it after the
    // batch it belonged to is gone leaves the tray parked on a reason that can
    // never resolve. Cancelling the last batch outright clears it too.
    if (wasActive || !state.hasWork) {
      _resumeTimer?.cancel();
      state = state.copyWith(clearActive: true, clearWaiting: true);
    }
  }

  /// Retry everything, including batches that exhausted their attempts.
  Future<void> retryAll() async {
    for (final job in state.jobs) {
      if (job.batch.state != UploadBatchState.failed) continue;
      await ref
          .read(uploadQueueServiceProvider)
          .putBatch(
            job.batch.copyWith(
              state: UploadBatchState.queued,
              attempts: 0,
              clearError: true,
            ),
          );
    }
    _reload();
    await process(manual: true);
  }

  void dismissCompleted() {
    state = state.copyWith(clearCompleted: true);
  }

  /// Drop everything. Called on logout and repository change: a queued batch
  /// carries its own bytes and its own target folder, and would otherwise
  /// flush into whatever repo is configured next.
  Future<void> clear() async {
    _cancelRequested = true;
    _generation++;
    _resumeTimer?.cancel();
    await ref.read(uploadQueueServiceProvider).clear();
    state = const UploadQueueState();
  }

  /// True when the user asked for Wi-Fi-only uploads and the only transport
  /// available would spend mobile data.
  ///
  /// An unreadable transport counts as allowed. The switch is a courtesy about
  /// the user's data plan, and a platform-channel failure must not be able to
  /// park every upload indefinitely. `none` is allowed through for the same
  /// reason in reverse: being offline is not a Wi-Fi problem, and the upload
  /// service's own deferral says something truer about it.
  Future<bool> _blockedByWifiOnly(AppConfig config) async {
    if (!config.wifiOnlyUploads) return false;

    List<ConnectivityResult> transports;
    try {
      transports = await connectivityProbe();
    } catch (_) {
      return false;
    }

    // vpn and other are in here because they MASK the real transport rather
    // than describing one: Android reports a VPN as `vpn` alone, so treating
    // them as metered would block a user on VPN-over-Wi-Fi forever.
    const unmetered = {
      ConnectivityResult.wifi,
      ConnectivityResult.ethernet,
      ConnectivityResult.vpn,
      ConnectivityResult.other,
    };
    if (transports.isEmpty) return false;
    if (transports.every((t) => t == ConnectivityResult.none)) return false;
    return !transports.any(unmetered.contains);
  }

  Future<void> _setWakelock(bool enable) async {
    try {
      await WakelockPlus.toggle(enable: enable);
    } catch (_) {
      // Keeping the screen on is a nicety, never a requirement.
    }
  }
}
