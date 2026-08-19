/// "Last synced 2h ago" and friends.
///
/// Hand-rolled rather than pulling in `intl`: the app ships one locale, and
/// this is the only place it formats a time.
String relativeTime(DateTime? then, {DateTime? now}) {
  if (then == null) return 'never';
  final delta = (now ?? DateTime.now()).difference(then);

  if (delta.isNegative) return 'just now';
  if (delta.inSeconds < 45) return 'just now';
  if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
  if (delta.inHours < 24) return '${delta.inHours}h ago';
  if (delta.inDays == 1) return 'yesterday';
  if (delta.inDays < 30) return '${delta.inDays}d ago';
  if (delta.inDays < 365) return '${(delta.inDays / 30).floor()}mo ago';
  return '${(delta.inDays / 365).floor()}y ago';
}

/// "4:12 PM", for telling the user when a rate limit clears.
String clockTime(DateTime time) {
  final hour24 = time.hour;
  final suffix = hour24 < 12 ? 'AM' : 'PM';
  var hour = hour24 % 12;
  if (hour == 0) hour = 12;
  return '$hour:${time.minute.toString().padLeft(2, '0')} $suffix';
}

/// "about 3 min left" from a byte rate. Null when there is nothing useful to
/// say yet - a wildly wrong estimate is worse than none.
String? estimateRemaining({
  required int bytesDone,
  required int bytesTotal,
  required Duration elapsed,
}) {
  if (bytesDone <= 0 || bytesTotal <= bytesDone) return null;
  if (elapsed.inSeconds < 3) return null;

  final rate = bytesDone / elapsed.inMilliseconds; // bytes per ms
  if (rate <= 0) return null;
  final remainingMs = (bytesTotal - bytesDone) / rate;
  final remaining = Duration(milliseconds: remainingMs.round());

  if (remaining.inSeconds < 45) return 'a few seconds left';
  if (remaining.inMinutes < 60) return 'about ${remaining.inMinutes} min left';
  return 'about ${remaining.inHours}h left';
}
