import 'package:flutter_test/flutter_test.dart';
import 'package:glickr/core/models/upload_job.dart';

/// Progress is what the tray ring draws, so the properties that matter are
/// monotonicity and honesty at the two ends, not the exact value in between.
void main() {
  UploadItem item(
    int n, {
    required String state,
    int stagedBytes = 0,
  }) {
    return UploadItem(
      id: 'i$n',
      batchId: 'b',
      targetName: '${n.toString().padLeft(4, '0')}.jpg',
      state: state,
      stagedBytes: stagedBytes,
      blobSha: state == UploadItemState.pending ? null : 'sha-$n',
    );
  }

  UploadJob jobOf(List<UploadItem> items) => UploadJob(
    batch: UploadBatch(id: 'b', albumFolder: 'trip', createdAt: DateTime(2026)),
    items: items,
  );

  group('UploadJob.progress', () {
    test('is 0 for a freshly queued batch', () {
      final job = jobOf([
        for (var i = 1; i <= 30; i++) item(i, state: UploadItemState.pending),
      ]);

      expect(job.progress, 0);
    });

    test('reaches 1.0 only once every item has landed', () {
      final uploaded = jobOf([
        for (var i = 1; i <= 3; i++)
          item(i, state: UploadItemState.blobCreated, stagedBytes: 1000),
      ]);
      // Every byte is on GitHub, but the commit that publishes them has not
      // been made yet, so this must not read as finished.
      expect(uploaded.progress, lessThan(1.0));
      expect(uploaded.progress, greaterThan(0.9));

      final committed = jobOf([
        for (var i = 1; i <= 3; i++)
          item(i, state: UploadItemState.done, stagedBytes: 1000),
      ]);
      expect(committed.progress, 1.0);
    });

    test('reaches 1.0 when the last unfinished item fails', () {
      final job = jobOf([
        item(1, state: UploadItemState.done, stagedBytes: 1000),
        item(2, state: UploadItemState.failed),
      ]);

      expect(job.progress, 1.0);
    });

    test(
      'does not start full and count backwards when a batch is resumed',
      () {
        // The app was killed after 12 of 30 blobs were created: those 12 know
        // their size, the other 18 have never been compressed.
        final resumed = jobOf([
          for (var i = 1; i <= 12; i++)
            item(i, state: UploadItemState.blobCreated, stagedBytes: 1000),
          for (var i = 13; i <= 30; i++) item(i, state: UploadItemState.pending),
        ]);

        expect(resumed.progress, lessThan(0.5));
        expect(resumed.progress, greaterThan(0.3));

        // Stage 1 now compresses the remaining 18 at a comparable size. The
        // ring must keep climbing rather than falling back towards zero.
        final afterStaging = jobOf([
          for (var i = 1; i <= 12; i++)
            item(i, state: UploadItemState.blobCreated, stagedBytes: 1000),
          for (var i = 13; i <= 30; i++)
            item(i, state: UploadItemState.staged, stagedBytes: 1000),
        ]);
        expect(afterStaging.progress, greaterThanOrEqualTo(resumed.progress));
      },
    );

    test('weights bytes, not item count', () {
      // One 16 MB video among eleven 1 MB photos: the video alone is more than
      // half the work.
      const mb = 1024 * 1024;
      final job = jobOf([
        item(1, state: UploadItemState.blobCreated, stagedBytes: 16 * mb),
        for (var i = 2; i <= 12; i++)
          item(i, state: UploadItemState.staged, stagedBytes: mb),
      ]);

      expect(job.progress, greaterThan(0.5));
    });
  });
}
