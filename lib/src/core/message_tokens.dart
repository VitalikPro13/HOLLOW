/// Wire tokens that ride message text, and the parsers for them.
///
/// Core owns the grammar so preview and notification code can read a message
/// without importing the chat widgets that render it.
library;

/// Grammar shared with Rust (`node/emotes.rs::parse_emote_token`):
/// `[e:name:hash]`, name = 2-24 of [a-z0-9_], hash = 64 hex.
final emoteTokenRegex = RegExp(r'\[e:([a-z0-9_]{2,24}):([0-9a-f]{64})\]');

/// Parse a string that is EXACTLY one emote token (reaction strings).
({String name, String hash})? parseEmoteToken(String s) {
  final m = emoteTokenRegex.matchAsPrefix(s);
  if (m == null || m.end != s.length) return null;
  return (name: m.group(1)!, hash: m.group(2)!);
}

/// Grammar shared with Rust (`node/emotes.rs::parse_asset_token`):
/// `[a:kind:hash:w:h]`, kind `s` or `g`, hash 64 hex, w/h 1..=4096. The regex
/// admits up to 9999 and the parser enforces the bound. Keep both in sync.
final assetTokenRegex = RegExp(
    r'\[a:(s|g):([0-9a-f]{64}):([1-9][0-9]{0,3}):([1-9][0-9]{0,3})\]');

/// Parse a string that is EXACTLY one asset token.
({String kind, String hash, int w, int h})? parseAssetToken(String s) {
  final m = assetTokenRegex.matchAsPrefix(s);
  if (m == null || m.end != s.length) return null;
  final w = int.parse(m.group(3)!);
  final h = int.parse(m.group(4)!);
  if (w > 4096 || h > 4096) return null;
  return (kind: m.group(1)!, hash: m.group(2)!, w: w, h: h);
}

/// The sentinel a file-only message carries as its text: `[file:<file id>]`.
/// The id shape is deliberately loose, because it is only ever matched to be
/// hidden from a preview, never resolved from here.
final fileTokenRegex = RegExp(r'\[file:([^\]]+)\]');
