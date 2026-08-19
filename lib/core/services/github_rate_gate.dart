import 'dart:async';
import 'dart:collection';

/// The single choke point every content-creating GitHub request passes
/// through.
///
/// GitHub publishes three separate limits that a photo uploader can trip, and
/// only the first has a friendly error:
///
///   * 5,000 requests/hour (primary) - hard to reach here.
///   * "no more than 80 content-generating requests per minute and no more
///     than 500 per hour" (secondary) - a 150-photo album is 150 writes, so
///     this is the one that actually bites.
///   * "If you are making a large number of POST, PATCH, PUT, or DELETE
///     requests, wait at least one second between each request."
///
/// Tripping a secondary limit returns an opaque 403 with no reset time, so the
/// only good strategy is to never reach it. This gate enforces both a
/// concurrency ceiling and a minimum spacing between write STARTS, and parks
/// the whole queue when the hourly budget runs low - which turns an
/// undiagnosable 403 into "resuming at 4:12 PM".
///
/// Reads do not go through the gate: they are 1 point each, not
/// content-generating, and a tree fetch that waited 1.1s would make the app
/// feel broken.
class GitHubRateGate {
  /// Well under the documented 100-concurrent-request ceiling. Three keeps
  /// enough sockets busy that latency overlaps, while bounding peak memory:
  /// each in-flight blob holds its base64 payload, so this number is also a
  /// memory decision, not just a politeness one.
  static const int maxConcurrentWrites = 3;

  /// Honours "wait at least one second between each request", with headroom.
  /// Yields roughly 55 writes/minute against a documented ceiling of 80.
  static const Duration minWriteSpacing = Duration(milliseconds: 1100);

  /// Headroom under the documented 500 content-generating requests per hour.
  static const int hourlyWriteBudget = 450;

  int _inFlight = 0;
  DateTime? _lastStart;
  final Queue<Completer<void>> _waiting = Queue<Completer<void>>();

  /// Start times of writes in the trailing hour, oldest first.
  final Queue<DateTime> _recentWrites = Queue<DateTime>();

  /// Set when GitHub reports the primary limit exhausted; every write waits
  /// until then.
  DateTime? _pausedUntil;

  /// Injectable for tests so a suite does not spend real seconds sleeping.
  final Future<void> Function(Duration) _sleep;
  final DateTime Function() _now;

  GitHubRateGate({
    Future<void> Function(Duration)? sleep,
    DateTime Function()? now,
  }) : _sleep = sleep ?? Future<void>.delayed,
       _now = now ?? DateTime.now;

  /// Writes performed in the trailing hour.
  int get writesThisHour {
    _pruneOldWrites();
    return _recentWrites.length;
  }

  /// Remaining hourly budget, floored at zero.
  int get remainingBudget {
    final left = hourlyWriteBudget - writesThisHour;
    return left < 0 ? 0 : left;
  }

  /// When the queue will unpark, or null when it is running.
  DateTime? get pausedUntil {
    final until = _pausedUntil;
    if (until == null) return null;
    if (!until.isAfter(_now())) {
      _pausedUntil = null;
      return null;
    }
    return until;
  }

  /// When the oldest write in the window ages out, freeing budget.
  DateTime? get budgetFreesAt {
    _pruneOldWrites();
    if (_recentWrites.isEmpty) return null;
    return _recentWrites.first.add(const Duration(hours: 1));
  }

  /// Park every write until [until] - called when GitHub reports the primary
  /// limit exhausted and tells us when it resets.
  void pauseUntil(DateTime until) {
    final current = _pausedUntil;
    if (current == null || until.isAfter(current)) {
      _pausedUntil = until;
    }
  }

  /// Run [action] as a content-creating request, waiting for a slot first.
  ///
  /// Throws [RateBudgetExhausted] rather than queueing forever when the
  /// hourly budget is spent, so the caller can park the batch and tell the
  /// user when it resumes instead of appearing to hang.
  Future<T> run<T>(Future<T> Function() action) async {
    await _acquire();
    try {
      return await action();
    } finally {
      _release();
    }
  }

  Future<void> _acquire() async {
    // Queue behind anyone already waiting, so a burst of writes keeps FIFO
    // order rather than starving whichever future lost the race.
    if (_inFlight >= maxConcurrentWrites || _waiting.isNotEmpty) {
      final completer = Completer<void>();
      _waiting.add(completer);
      // _pumpWaiting reserves the slot before completing us. Claiming it here
      // instead would over-subscribe: between the completion and this future
      // actually resuming, a brand-new caller would see a stale _inFlight,
      // find the queue empty, and take the same slot.
      await completer.future;
    } else {
      _inFlight++;
    }

    final paused = pausedUntil;
    if (paused != null) {
      await _sleep(paused.difference(_now()));
    }

    _pruneOldWrites();
    if (_recentWrites.length >= hourlyWriteBudget) {
      _inFlight--;
      _pumpWaiting();
      throw RateBudgetExhausted(budgetFreesAt ?? _now());
    }

    // Space write STARTS, not completions: GitHub's guidance is about
    // request arrival, and spacing completions would serialise the three
    // concurrent slots into one.
    final last = _lastStart;
    if (last != null) {
      final since = _now().difference(last);
      if (since < minWriteSpacing) {
        await _sleep(minWriteSpacing - since);
      }
    }
    _lastStart = _now();
    _recentWrites.add(_lastStart!);
  }

  void _release() {
    _inFlight--;
    _pumpWaiting();
  }

  void _pumpWaiting() {
    while (_inFlight < maxConcurrentWrites && _waiting.isNotEmpty) {
      final next = _waiting.removeFirst();
      if (next.isCompleted) continue;
      _inFlight++; // reserved on the waiter's behalf, before it resumes
      next.complete();
      return;
    }
  }

  void _pruneOldWrites() {
    final cutoff = _now().subtract(const Duration(hours: 1));
    while (_recentWrites.isNotEmpty && _recentWrites.first.isBefore(cutoff)) {
      _recentWrites.removeFirst();
    }
  }
}

/// Thrown when the hourly content-request budget is spent. Carries the time
/// the budget starts freeing up so the UI can say when uploads resume.
class RateBudgetExhausted implements Exception {
  final DateTime resumesAt;
  const RateBudgetExhausted(this.resumesAt);

  @override
  String toString() =>
      'GitHub limits uploads to 500 files an hour - resuming shortly';
}
