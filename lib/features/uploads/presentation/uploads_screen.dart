import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/upload_job.dart';
import '../../../core/providers/upload_provider.dart';
import '../../../core/services/media_pipeline_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/album_conventions.dart';
import '../../../core/widgets/empty_state.dart';

/// Open the queue detail sheet.
///
/// [context] must sit below a Navigator. The tray cannot supply one of its own
/// - it is mounted above the app's Navigator - so it resolves one first; see
/// `upload_tray.dart`.
Future<void> showUploadsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => const UploadsScreen(),
  );
}

/// The full queue: every batch, every file, and what happened to it.
///
/// The tray answers "is something happening"; this answers "what exactly, and
/// which file went wrong". Those are different questions, and cramming the
/// second into a 56dp pill is what makes upload UI unreadable.
class UploadsScreen extends ConsumerWidget {
  const UploadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(uploadQueueNotifierProvider);
    final rows = _flatten(state.jobs);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.72,
      minChildSize: 0.4,
      maxChildSize: 0.94,
      builder: (context, controller) {
        return Column(
          children: [
            const _Grabber(),
            _Header(state: state),
            Divider(height: 1, color: context.colorScheme.outlineVariant),
            Expanded(
              child: rows.isEmpty
                  // The sheet's scroll controller still has to reach a
                  // scrollable when there is nothing to scroll, or dragging
                  // the sheet stops working the moment the queue drains.
                  ? CustomScrollView(
                      controller: controller,
                      slivers: const [
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: EmptyState(
                            icon: Icons.cloud_upload_outlined,
                            title: 'Nothing uploading',
                            body: 'Uploads in progress will show up here.',
                          ),
                        ),
                      ],
                    )
                  : ListView.builder(
                      controller: controller,
                      padding: const EdgeInsets.only(bottom: 24),
                      itemCount: rows.length,
                      itemBuilder: (context, index) {
                        final row = rows[index];
                        return switch (row) {
                          _JobHeaderRow(:final job) => _JobHeader(job: job),
                          _ItemRow(:final job, :final item) => _ItemTile(
                            job: job,
                            item: item,
                          ),
                        };
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

/// The job/item tree flattened for a builder-backed list, so a queue holding
/// several batches of thirty photos does not build two hundred widgets to show
/// the eight that are on screen.
sealed class _Row {
  const _Row();
}

class _JobHeaderRow extends _Row {
  final UploadJob job;
  const _JobHeaderRow(this.job);
}

class _ItemRow extends _Row {
  final UploadJob job;
  final UploadItem item;
  const _ItemRow(this.job, this.item);
}

List<_Row> _flatten(List<UploadJob> jobs) {
  final rows = <_Row>[];
  for (final job in jobs) {
    rows.add(_JobHeaderRow(job));
    for (final item in job.items) {
      rows.add(_ItemRow(job, item));
    }
  }
  return rows;
}

class _Grabber extends StatelessWidget {
  const _Grabber();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Center(
        child: Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: context.colorScheme.outlineVariant,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}

class _Header extends ConsumerWidget {
  final UploadQueueState state;

  const _Header({required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.colorScheme;
    final hasActions = state.hasWork || state.hasFailures;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 4, 8, hasActions ? 4 : 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Uploads', style: context.textTheme.headlineMedium),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.close_rounded),
                tooltip: 'Close',
              ),
            ],
          ),
          // Actions get their own line: the title plus two labels plus the
          // close button overflow as soon as the user has a large text size.
          if (hasActions)
            Row(
              children: [
                if (state.hasFailures)
                  TextButton(
                    onPressed: () =>
                        ref
                            .read(uploadQueueNotifierProvider.notifier)
                            .retryAll(),
                    child: const Text('Retry all'),
                  ),
                if (state.hasWork)
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: scheme.error),
                    onPressed: () => _confirmCancelAll(context, ref),
                    child: const Text('Cancel all'),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Cancelling stops the queue but cannot un-commit anything that already
/// landed, so the dialog says exactly that instead of implying an undo.
Future<void> _confirmCancelAll(BuildContext context, WidgetRef ref) async {
  final stop = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Stop uploading?'),
      content: const Text(
        "Anything already added to an album stays there. The rest won't be "
        'uploaded.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Keep uploading'),
        ),
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(dialogContext).colorScheme.error,
          ),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Stop'),
        ),
      ],
    ),
  );
  if (stop != true) return;

  await ref.read(uploadQueueNotifierProvider.notifier).cancelAll();
  // There is nothing left to look at, and an empty sheet sitting open reads as
  // if the tap never registered.
  if (context.mounted) await Navigator.of(context).maybePop();
}

class _JobHeader extends StatelessWidget {
  final UploadJob job;

  const _JobHeader({required this.job});

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final error = job.batch.state == UploadBatchState.failed
        ? job.batch.error
        : null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  albumTitle(job.batch.albumFolder),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.textTheme.titleSmall,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${job.completed} of ${job.total}',
                style: AppTheme.mono(context, size: 12),
              ),
            ],
          ),
          if (error != null) ...[
            const SizedBox(height: 4),
            // The raw message rather than a friendly stand-in: it is the only
            // clue the user gets about why five attempts failed, and
            // "something went wrong" is not something anybody can act on.
            Text(
              error,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ],
        ],
      ),
    );
  }
}

class _ItemTile extends ConsumerWidget {
  final UploadJob job;
  final UploadItem item;

  const _ItemTile({required this.job, required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.colorScheme;
    final appColors = context.appColors;
    final failed = item.state == UploadItemState.failed;

    final (String label, Color color) = switch (item.state) {
      UploadItemState.pending => ('Waiting', scheme.onSurfaceVariant),
      UploadItemState.staged => (
        _withSize('Ready', item.stagedBytes),
        scheme.onSurfaceVariant,
      ),
      UploadItemState.blobCreated => (
        _withSize('Uploaded', item.stagedBytes),
        appColors.success,
      ),
      UploadItemState.done => ('Done', appColors.success),
      _ => (item.error ?? "This one didn't upload", scheme.error),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 8, 6),
      child: Row(
        children: [
          // A placeholder, not the real thumbnail: the source asset can be
          // deleted from the gallery between queueing and uploading, so a real
          // preview would be a broken tile about as often as a picture.
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              item.isVideo ? Icons.videocam_rounded : Icons.image_rounded,
              size: 20,
              color: failed ? scheme.error : scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.targetName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.mono(
                    context,
                    size: 13,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.textTheme.bodySmall?.copyWith(color: color),
                ),
              ],
            ),
          ),
          // Remove is offered only when the whole batch is beyond saving. A
          // failed file inside a healthy batch has already been dropped from
          // the commit and the rest of the album still uploads, so there is
          // nothing left to remove - and a button that quietly cancelled the
          // other twenty-nine photos would be the opposite of what it says.
          if (failed && _isBeyondSaving(job))
            TextButton(
              style: TextButton.styleFrom(foregroundColor: scheme.error),
              onPressed: () => ref
                  .read(uploadQueueNotifierProvider.notifier)
                  .cancelBatch(job.batch.id),
              child: const Text('Remove'),
            )
          else
            const SizedBox(width: 8),
        ],
      ),
    );
  }
}

String _withSize(String label, int bytes) =>
    bytes > 0 ? '$label - ${formatBytes(bytes)}' : label;

/// True when nothing left in [job] can still reach the album.
bool _isBeyondSaving(UploadJob job) {
  if (job.batch.state == UploadBatchState.failed) return true;
  return !job.items.any((i) => i.state != UploadItemState.failed);
}
