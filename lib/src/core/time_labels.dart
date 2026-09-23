const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];
const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// The time beside a conversation in a list: `14:05` today, `Yesterday`,
/// a weekday within the week, then `Sep 17`, then `Sep 17, 2025`.
///
/// Month names, never `9/17`: a numeric date reads as a different day in half
/// the world.
String conversationTimeLabel(DateTime at, {DateTime? now}) {
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
