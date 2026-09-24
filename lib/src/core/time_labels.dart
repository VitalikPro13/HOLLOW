const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];
const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// The time beside a conversation in a list: `14:05` today, `Yesterday`,
/// a weekday within the week, then `Sep 17`, then `Sep 17, 2025`.
///
/// Month names, never `9/17`: a numeric date reads as a different day in half
/// the world. An unset time (the epoch or earlier) is empty, never a 1970 date.
String conversationTimeLabel(DateTime at, {DateTime? now}) {
  if (at.millisecondsSinceEpoch <= 0) return '';
  final today = now ?? DateTime.now();
  final day = DateTime(at.year, at.month, at.day);
  final daysAgo = DateTime(today.year, today.month, today.day)
      .difference(day)
      .inDays;
  if (daysAgo <= 0) {
    return '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}';
  }
  if (daysAgo == 1) return 'Yesterday';
  if (daysAgo < 7) return _weekdays[at.weekday - 1];
  final monthDay = '${_months[at.month - 1]} ${at.day}';
  return at.year == today.year ? monthDay : '$monthDay, ${at.year}';
}

/// How long ago [at] was, for a status line: `just now`, `5 minutes ago`,
/// `3 hours ago`, `yesterday`, `4 days ago`, then `on Sep 17`.
String relativeTimeLabel(DateTime at, {DateTime? now}) {
  final current = now ?? DateTime.now();
  final ago = current.difference(at);
  if (ago.inMinutes < 1) return 'just now';
  if (ago.inHours < 1) {
    return ago.inMinutes == 1 ? '1 minute ago' : '${ago.inMinutes} minutes ago';
  }
  if (ago.inDays < 1) {
    return ago.inHours == 1 ? '1 hour ago' : '${ago.inHours} hours ago';
  }
  final days = DateTime(current.year, current.month, current.day)
      .difference(DateTime(at.year, at.month, at.day))
      .inDays;
  if (days <= 1) return 'yesterday';
  if (days < 7) return '$days days ago';
  return 'on ${conversationTimeLabel(at, now: current)}';
}
