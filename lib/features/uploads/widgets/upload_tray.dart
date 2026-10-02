import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_navigator.dart';
import '../../../core/models/upload_job.dart';
import '../../../core/providers/upload_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/album_conventions.dart';
import '../../../core/utils/relative_time.dart';
import '../presentation/uploads_screen.dart';

/// The persistent upload indicator.
///
/// Mounted ABOVE the Navigator in main.dart so an upload stays visible while
/// the user moves between screens. That buys three constraints this widget has
/// to live with: there is no Scaffold around it, so it supplies its own
/// [Material] and [SafeArea]; there is no Navigator above it either, so it
/// navigates through [appNavigatorKey]; and it shares a Stack with every
/// screen in the app, so it must occupy no more of that Stack than it draws
/// in - see [_fabClearance].
class UploadTray extends ConsumerStatefulWidget {
  const UploadTray({super.key});

  @override
  ConsumerState<UploadTray> createState() => _UploadTrayState();
}

class _UploadTrayState extends ConsumerState<UploadTray> {
  static const _slide = Duration(milliseconds: 260);
  static const _grow = Duration(milliseconds: 180);

  /// How long the success pill stays up before it clears itself.
  static const _completedDwell = Duration(seconds: 4);

  /// Bottom margin that keeps the pill off the screens' floating action
  /// button, which the tray would otherwise both hide and swallow the taps of.
  ///
  /// `endFloat` parks a FAB [kFloatingActionButtonMargin] above the safe area
  /// and FABs are at most 56 tall, so the band [0, 72] above the inset belongs
  /// to the FAB. The tray is already inside a bottom [SafeArea], so this is
  /// measured from the same origin: 72 for the FAB plus 12 of air.
  static const double _fabClearance = 84;

  /// Beyond this the pill is a stretched line of text with a chevron a hand's
  /// width away from it. Keeps the tray off the corners of a tablet, where a
  /// FAB may sit outside the band [_fabClearance] accounts for.
  static const double _maxWidth = 520;

  Timer? _dismissTimer;
  Timer? _exitTimer;

  /// The last pill that had something to say, held for the length of the exit
  /// animation. Without it the tray would blink out of existence rather than
  /// leaving, because the state it was rendering is already gone.
  _TraySpec? _retained;

  /// Desktop: Cmd+Q and the window's close button end the process, and a
  /// commit in flight with it. Refuse while a batch is running and say why.
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onExitRequested: _onExitRequested);
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    _exitTimer?.cancel();
    _lifecycle?.dispose();
    super.dispose();
  }

  Future<AppExitResponse> _onExitRequested() async {
    if (!ref.read(uploadQueueNotifierProvider).isBusy) {
      return AppExitResponse.exit;
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text(
          'An upload is still running - wait for it, or cancel it, before '
          'quitting.',
        ),
      ),
    );
    return AppExitResponse.cancel;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<UploadQueueState>(uploadQueueNotifierProvider, _onQueueChanged);
    final state = ref.watch(uploadQueueNotifierProvider);
    final spec = _specFor(context, state);

    if (spec != null) {
      _exitTimer?.cancel();
      _exitTimer = null;
      _retained = spec;
    } else if (_retained != null && _exitTimer == null) {
      _exitTimer = Timer(context.motion(_slide), () {
        if (!mounted) return;
        setState(() => _retained = null);
      });
    }

    final shown = spec ?? _retained;
    // Zero-size, so it hit-tests as nothing: with no pill to show the tray
    // must not leave a band of the Stack claimed, or it takes the taps meant
    // for whatever the screen below put down there.
    if (shown == null) return const SizedBox.shrink();

    return SafeArea(
      top: false,
      // `spec == null` is the pill on its way out. It is still painted, but it
      // is no longer something the user can aim at.
      child: IgnorePointer(
        ignoring: spec == null,
        child: AnimatedSlide(
          // Fractional over the padded box, so this is "past everything this
          // widget occupies" however tall the pill grew, clearance included -
          // and the Stack in main.dart clips whatever hangs below.
          offset: spec == null ? const Offset(0, 1.4) : Offset.zero,
          duration: context.motion(_slide),
          curve: Curves.easeOutCubic,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, _fabClearance),
            child: Align(
              // heightFactor 1: shrink-wrap the pill vertically. Aligning
              // without it would expand into the unbounded height a Stack
              // child is offered and put the tray back over the FAB.
              heightFactor: 1,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _maxWidth),
                child: AnimatedSize(
                  duration: context.motion(_grow),
                  curve: Curves.easeOut,
                  alignment: Alignment.bottomCenter,
                  child: _pill(context, shown),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _pill(BuildContext context, _TraySpec spec) {
    final scheme = context.colorScheme;
    // Blended into the surface rather than laid over it at low alpha: the tray
    // floats above the photo viewer, and a translucent chip on a bright cover
    // loses its own text.
    final background = Color.alphaBlend(
      spec.tint.withValues(alpha: 0.14),
      scheme.surfaceContainerHigh,
    );

    return Material(
      color: background,
      elevation: 6,
      shadowColor: Colors.black.withValues(alpha: 0.45),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: spec.tint.withValues(alpha: 0.35)),
      ),
      child: InkWell(
        onTap: _openSheet,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Row(
            children: [
              const SizedBox(width: 16),
              _leading(context, spec),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      spec.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.textTheme.titleSmall?.copyWith(
                        fontSize: 13.5,
                      ),
                    ),
                    if (spec.detail != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        spec.detail!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        // Tabular figures: the counter and the compression
                        // percentage change several times a second, and
                        // proportional digits make the whole line twitch.
                        style: AppTheme.mono(context, size: 11),
                      ),
                    ],
                  ],
                ),
              ),
              if (spec.actionLabel != null)
                TextButton(
                  onPressed: spec.onAction,
                  child: Text(spec.actionLabel!),
                ),
              // Decorative: the whole pill is the tap target, so exposing this
              // as a second button would only add a duplicate stop.
              const ExcludeSemantics(
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Icon(Icons.chevron_right_rounded, size: 22),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _leading(BuildContext context, _TraySpec spec) {
    if (spec.kind != _TrayKind.running) {
      return Icon(spec.icon, size: 20, color: spec.tint);
    }

    final value = spec.progress;
    if (value == null) {
      return SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2.5, color: spec.tint),
      );
    }

    // Progress arrives in steps of at least a percent - the notifier throttles
    // by value, not by time - and a ring that jumps between those steps reads
    // as stalled. The tween sweeps across them instead.
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: value),
      duration: context.motion(const Duration(milliseconds: 400)),
      curve: Curves.easeOut,
      builder:
          (context, animated, _) => SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              value: animated,
              strokeWidth: 2.5,
              color: spec.tint,
              backgroundColor: spec.tint.withValues(alpha: 0.22),
            ),
          ),
    );
  }

  /// What the tray should say right now, or null when it should not be here.
  ///
  /// The branches are near enough mutually exclusive in the notifier - taking
  /// a batch clears the waiting and completed fields, deferring one clears the
  /// active field - so this ordering only settles the moments in between.
  _TraySpec? _specFor(BuildContext context, UploadQueueState state) {
    final scheme = context.colorScheme;
    final appColors = context.appColors;

    // Covers the gap between enqueueing a batch and the queue picking it up.
    // Failures have to be excluded explicitly: a permanently failed batch
    // stays in `jobs`, so `hasWork` alone would report "Queued" forever over
    // an upload that has already given up.
    final queuedButIdle =
        state.hasWork && !state.isWaiting && !state.hasFailures;

    if (state.isBusy || queuedButIdle) {
      final progress = state.progress;
      final folder = progress?.albumFolder ?? _firstFolder(state);
      final where = folder == null ? '' : ' to ${albumTitle(folder)}';

      if (progress == null) {
        return _TraySpec(
          kind: _TrayKind.running,
          tint: scheme.primary,
          title: state.isBusy ? 'Uploading$where' : 'Queued$where',
          detail: 'Getting ready',
        );
      }
      return _TraySpec(
        kind: _TrayKind.running,
        tint: scheme.primary,
        // Weighted by bytes, which is what UploadJob.progress reports. Item
        // count would park the ring at 92% for the entire time a 16 MB video
        // among eleven photos actually takes.
        progress: progress.progress,
        title: 'Uploading$where - ${progress.done} of ${progress.total}',
        detail:
            progress.itemProgress != null
                ? 'Compressing ${(progress.itemProgress! * 100).round()}%'
                : progress.currentLabel,
      );
    }

    final waiting = state.waitingReason;
    if (waiting != null) {
      final retryAfter = state.retryAfter;
      return _TraySpec(
        kind: _TrayKind.waiting,
        // Warning, not error. Being in a tunnel is not a failure and not
        // something the user did, and colouring it like one trains them to
        // ignore the colour that does mean something went wrong.
        tint: appColors.warning,
        icon: Icons.cloud_off_rounded,
        title: '$waiting - uploads resume automatically.',
        detail:
            retryAfter == null ? null : 'Retrying at ${clockTime(retryAfter)}',
      );
    }

    if (state.hasFailures) {
      final count = _failedItemCount(state);
      return _TraySpec(
        kind: _TrayKind.failed,
        tint: scheme.error,
        icon: Icons.error_outline_rounded,
        title:
            count == 1 ? "1 item didn't upload" : "$count items didn't upload",
        detail: 'Open to see which ones',
        actionLabel: 'Retry',
        onAction:
            () => ref.read(uploadQueueNotifierProvider.notifier).retryAll(),
      );
    }

    final completed = state.completedFolder;
    if (completed != null) {
      final n = state.completedCount;
      final skipped = state.skippedCount;
      return _TraySpec(
        kind: _TrayKind.completed,
        tint: appColors.success,
        icon: Icons.check_circle_rounded,
        title:
            'Added ${n == 1 ? '1 item' : '$n items'} to '
            '${albumTitle(completed)}',
        detail:
            skipped == 0
                ? null
                : '${skipped == 1 ? '1 file' : '$skipped files'} skipped',
        actionLabel: 'View',
        onAction: _viewCompleted,
      );
    }

    return null;
  }

  String? _firstFolder(UploadQueueState state) =>
      state.jobs.isEmpty ? null : state.jobs.first.batch.albumFolder;

  int _failedItemCount(UploadQueueState state) {
    var count = 0;
    for (final job in state.jobs) {
      if (job.batch.state != UploadBatchState.failed) continue;
      count += job.total - job.completed;
    }
    return count;
  }

  void _onQueueChanged(UploadQueueState? previous, UploadQueueState next) {
    _syncDismissTimer(next);

    final milestone = _milestone(previous, next);
    if (milestone == null) return;
    // Milestones only, and deliberately NOT a live region: byte-level progress
    // fires many times a second, and a live region would have a screen reader
    // read every one of them, which makes the rest of the app unusable.
    SemanticsService.announce(milestone, Directionality.of(context));
  }

  void _syncDismissTimer(UploadQueueState state) {
    _dismissTimer?.cancel();
    _dismissTimer = null;
    if (state.completedFolder == null) return;
    // Not routed through context.motion: this is reading time, not animation,
    // and reduced motion must not swallow the confirmation entirely.
    _dismissTimer = Timer(_completedDwell, () {
      if (!mounted) return;
      ref.read(uploadQueueNotifierProvider.notifier).dismissCompleted();
    });
  }

  String? _milestone(UploadQueueState? previous, UploadQueueState next) {
    if (next.completedFolder != null && previous?.completedFolder == null) {
      final n = next.completedCount;
      return 'Added ${n == 1 ? '1 item' : '$n items'} to '
          '${albumTitle(next.completedFolder!)}';
    }
    if (next.hasFailures && !(previous?.hasFailures ?? false)) {
      final count = _failedItemCount(next);
      return count == 1 ? "1 item didn't upload" : "$count items didn't upload";
    }
    final waiting = next.waitingReason;
    if (waiting != null && waiting != previous?.waitingReason) {
      return '$waiting. Uploads resume automatically.';
    }
    if (next.isBusy && !(previous?.isBusy ?? false)) {
      final folder = next.progress?.albumFolder ?? _firstFolder(next);
      if (folder == null) return 'Upload started';
      return 'Uploading to ${albumTitle(folder)}';
    }
    return null;
  }

  void _openSheet() {
    // The tray's own context has no Navigator above it, so the sheet has to be
    // opened against the root navigator's context instead.
    final navigator = appNavigatorKey.currentContext;
    if (navigator == null) return;
    unawaited(showUploadsSheet(navigator));
  }

  /// "View" returns to the album grid rather than deep-linking into the album.
  ///
  /// The tray sits above the Navigator, so it has no route table to push
  /// against, and naming a route here would tie a global widget to whatever
  /// the album screen ends up being called. The grid is one tap from the album
  /// and already shows the new cover and count, which is most of what "View"
  /// promises.
  void _viewCompleted() {
    ref.read(uploadQueueNotifierProvider.notifier).dismissCompleted();
    appNavigatorKey.currentState?.popUntil((route) => route.isFirst);
  }
}

enum _TrayKind { running, waiting, failed, completed }

/// One rendering of the tray.
///
/// Every state pairs its colour with a glyph - the ring, the struck-out cloud,
/// the cross, the tick - because somebody who cannot separate amber from red
/// has nothing else to go on in a single line of text.
class _TraySpec {
  final _TrayKind kind;
  final Color tint;
  final IconData? icon;
  final double? progress;
  final String title;
  final String? detail;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _TraySpec({
    required this.kind,
    required this.tint,
    required this.title,
    this.icon,
    this.progress,
    this.detail,
    this.actionLabel,
    this.onAction,
  });
}
