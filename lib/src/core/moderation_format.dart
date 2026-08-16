import 'package:hollow/src/core/models/channel_chat_message.dart';
import 'package:hollow/src/rust/api/crdt.dart';

/// File extensions the chat renders inline (images / GIFs / videos) — the
/// only attachment types a media-only channel accepts. Mirrors the Rust
/// ingest gate (is_image_mime || video mime); GIFs convert to animated WebP.
const kMediaOnlyExtensions = {
  'png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp', // images
  'mp4', 'webm', 'mov', 'mkv', 'avi', 'm4v', // videos
};

/// Human label for a slow-mode interval in seconds ('Off', '30s', '5m', '1h').
String slowModeDurationLabel(int secs) {
  if (secs <= 0) return 'Off';
  if (secs < 60) return '${secs}s';
  if (secs < 3600) return '${secs ~/ 60}m';
  return '${secs ~/ 3600}h';
}

/// Compact remaining-time label for a mute ('3d 4h', '2h 10m', '45m', '30s').
String formatMuteRemaining(Duration d) {
  if (d.inDays >= 1) return '${d.inDays}d ${d.inHours % 24}h';
  if (d.inHours >= 1) return '${d.inHours}h ${d.inMinutes % 60}m';
  if (d.inMinutes >= 1) return '${d.inMinutes}m';
  return '${d.inSeconds}s';
}

/// When the local user may next post in a slow-mode channel, DERIVED from the
/// loaded message list (my newest message's timestamp + the interval) — never
/// from ephemeral widget state, so it survives channel switches and restarts
/// and can't drift from the Rust-side gate. Null = no active cooldown.
DateTime? slowModeReadyAtFrom(List<ChannelChatMessage> messages, int slowSecs) {
  if (slowSecs <= 0) return null;
  DateTime? lastOwn;
  for (final m in messages) {
    if (m.isMe && (lastOwn == null || m.timestamp.isAfter(lastOwn))) {
      lastOwn = m.timestamp;
    }
  }
  if (lastOwn == null) return null;
  final ready = lastOwn.add(Duration(seconds: slowSecs));
  return ready.isAfter(DateTime.now()) ? ready : null;
}

/// Input-bar banner for the local user's mute, or null when not muted
/// (including a stale record whose expiry has already passed).
String? muteBannerText(MutedMemberFfi? mute) {
  if (mute == null) return null;
  if (mute.permanent) return 'You are muted on this server';
  final expires = DateTime.fromMillisecondsSinceEpoch(mute.expiresAtMs);
  final remaining = expires.difference(DateTime.now());
  if (remaining.isNegative) return null;
  return 'You are muted on this server: ${formatMuteRemaining(remaining)} left';
}
