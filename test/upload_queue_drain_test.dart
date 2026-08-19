import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glickr/core/models/app_config.dart';
import 'package:glickr/core/models/upload_job.dart';
import 'package:glickr/core/providers/config_provider.dart';
import 'package:glickr/core/providers/services_provider.dart';
import 'package:glickr/core/providers/upload_provider.dart';
import 'package:glickr/core/services/media_pipeline_service.dart';
import 'package:glickr/core/services/upload_queue_service.dart';
import 'package:glickr/core/services/upload_service.dart';

/// A drain that runs a batch more often than this is not draining, it is
/// spinning. Tripping it fails the test fast instead of hanging the suite.
const _runCeiling = 25;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeQueueService queue;
  late _FakeUploadService uploads;
  late ProviderContainer container;

  ProviderContainer boot({AppConfig? config}) {
    final c = ProviderContainer(
      overrides: [
        uploadQueueServiceProvider.overrideWithValue(queue),
        uploadServiceProvider.overrideWithValue(uploads),
        mediaPipelineServiceProvider.overrideWithValue(_FakeMediaPipeline()),
        configNotifierProvider.overrideWith(
          () => _FakeConfigNotifier(
            config ?? AppConfig(repoOwner: 'gapp', repoName: 'albums'),
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  UploadBatch batch(String id, {String state = UploadBatchState.queued}) {
    return UploadBatch(
      id: id,
      albumFolder: 'cycling_trip',
      createdAt: DateTime(2024, 1, 1),
      state: state,
    );
  }

  /// Builds the notifier and waits for the auto-resume drain it schedules.
  ///
  /// One turn of the event loop is enough to get that drain started; `process`
  /// then hands back the future of the drain already running, so this joins it
  /// rather than guessing at a delay.
  Future<void> settle(ProviderContainer c) async {
    final notifier = c.read(uploadQueueNotifierProvider.notifier);
    await Future<void>.delayed(Duration.zero);
    await notifier.process();
  }

  setUp(() {
    queue = _FakeQueueService();
    uploads = _FakeUploadService();
  });

  group('draining the queue', () {
    test('a manual retry attempts a permanently failing batch exactly once',
        () async {
      queue.batches['b1'] = batch('b1', state: UploadBatchState.failed);
      // What UploadService does when nothing in the batch can be prepared: it
      // rewrites the batch as failed WITHOUT burning an attempt, so the batch
      // record is byte-for-byte re-selectable next iteration.
      uploads.onRun = (b) async {
        await queue.putBatch(
          b.copyWith(state: UploadBatchState.failed, error: 'nothing to send'),
        );
        return const UploadFailed('nothing to send');
      };

      container = boot();
      await settle(container);
      uploads.runs.clear();

      await container.read(uploadQueueNotifierProvider.notifier).retryAll();

      expect(uploads.runs, ['b1']);
    });

    test('a manual retry attempts each failing batch once, not the first one '
        'forever', () async {
      queue.batches['b1'] = batch('b1', state: UploadBatchState.failed);
      queue.batches['b2'] = batch('b2', state: UploadBatchState.failed);
      uploads.onRun = (b) async {
        await queue.putBatch(b.copyWith(state: UploadBatchState.failed));
        return const UploadFailed('nope');
      };

      container = boot();
      await settle(container);
      uploads.runs.clear();

      await container.read(uploadQueueNotifierProvider.notifier).retryAll();

      expect(uploads.runs, ['b1', 'b2']);
    });

    test('an automatic drain leaves failed batches alone', () async {
      queue.batches['b1'] = batch('b1', state: UploadBatchState.failed);
      queue.batches['b2'] = batch('b2');
      uploads.onRun = (b) async => const UploadFailed('stub');

      container = boot();
      await settle(container);
      uploads.runs.clear();

      await container.read(uploadQueueNotifierProvider.notifier).process();

      expect(uploads.runs, ['b2']);
    });
  });

  group('cancelling', () {
    test('clears the waiting state instead of parking the tray on it',
        () async {
      queue.batches['b1'] = batch('b1');
      container = boot();
      final notifier = container.read(uploadQueueNotifierProvider.notifier);

      // The real service only samples isCancelled at item boundaries, so its
      // 'Cancelled' deferral lands AFTER cancelAll has emptied the queue.
      uploads.onRun = (b) async {
        await notifier.cancelAll();
        return const UploadDeferred('Cancelled');
      };

      await settle(container);

      final state = container.read(uploadQueueNotifierProvider);
      expect(state.waitingReason, isNull);
      expect(state.isWaiting, isFalse);
      expect(state.jobs, isEmpty);
    });

    test('cancelling the waiting batch clears the reason it was waiting for',
        () async {
      queue.batches['b1'] = batch('b1');
      uploads.onRun = (b) async =>
          const UploadDeferred('Waiting for a connection');

      container = boot();
      await settle(container);
      expect(container.read(uploadQueueNotifierProvider).waitingReason,
          'Waiting for a connection');

      await container
          .read(uploadQueueNotifierProvider.notifier)
          .cancelBatch('b1');

      expect(container.read(uploadQueueNotifierProvider).waitingReason, isNull);
    });
  });

  group('wifi-only uploads', () {
    test('parks the queue on mobile data rather than spending it', () async {
      queue.batches['b1'] = batch('b1');
      uploads.onRun = (b) async => const UploadFailed('stub');

      container = boot(
        config: AppConfig(
          repoOwner: 'gapp',
          repoName: 'albums',
          wifiOnlyUploads: true,
        ),
      );
      final notifier = container.read(uploadQueueNotifierProvider.notifier);
      notifier.connectivityProbe = () async => [ConnectivityResult.mobile];

      await settle(container);
      await notifier.process();

      expect(uploads.runs, isEmpty);
      expect(container.read(uploadQueueNotifierProvider).waitingReason,
          'Waiting for Wi-Fi');
      // No attempt burned: the batch must be untouched for the resume.
      expect(queue.batches['b1']!.attempts, 0);
      expect(queue.batches['b1']!.state, UploadBatchState.queued);
    });

    test('uploads on Wi-Fi with the same setting on', () async {
      queue.batches['b1'] = batch('b1');
      uploads.onRun = (b) async => const UploadFailed('stub');

      container = boot(
        config: AppConfig(
          repoOwner: 'gapp',
          repoName: 'albums',
          wifiOnlyUploads: true,
        ),
      );
      final notifier = container.read(uploadQueueNotifierProvider.notifier);
      notifier.connectivityProbe = () async => [ConnectivityResult.wifi];

      await settle(container);
      await notifier.process();

      expect(uploads.runs, contains('b1'));
      expect(container.read(uploadQueueNotifierProvider).waitingReason, isNull);
    });

    test('an unreadable transport does not block the queue', () async {
      queue.batches['b1'] = batch('b1');
      uploads.onRun = (b) async => const UploadFailed('stub');

      container = boot(
        config: AppConfig(
          repoOwner: 'gapp',
          repoName: 'albums',
          wifiOnlyUploads: true,
        ),
      );
      final notifier = container.read(uploadQueueNotifierProvider.notifier);
      notifier.connectivityProbe = () async => throw StateError('no channel');

      await settle(container);
      await notifier.process();

      expect(uploads.runs, contains('b1'));
    });
  });
}

class _FakeQueueService implements UploadQueueService {
  final Map<String, UploadBatch> batches = {};

  @override
  List<UploadJob> loadJobs() => batches.values
      .map((b) => UploadJob(batch: b, items: const []))
      .toList();

  @override
  Future<void> putBatch(UploadBatch batch) async {
    batches[batch.id] = batch;
  }

  @override
  Future<void> removeBatch(String batchId) async {
    batches.remove(batchId);
  }

  @override
  Future<void> clear() async => batches.clear();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeUploadService implements UploadService {
  final List<String> runs = [];
  Future<UploadOutcome> Function(UploadBatch batch)? onRun;

  @override
  Future<UploadOutcome> run(
    UploadBatch batch, {
    required AppConfig config,
    void Function(UploadProgress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    runs.add(batch.id);
    if (runs.length > _runCeiling) {
      throw StateError('drain did not terminate: ${runs.length} runs');
    }
    return await onRun!(batch);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeMediaPipeline implements MediaPipelineService {
  @override
  Future<void> cancelVideo() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeConfigNotifier extends ConfigNotifier {
  _FakeConfigNotifier(this.value);
  final AppConfig? value;

  @override
  AppConfig? build() => value;
}
