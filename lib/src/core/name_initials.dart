/// One or two letter initials for a server or folder with no icon: the first
/// letters of the first two words, else the first two letters.
String initialsFromName(String name) {
  // Runes, not code units, so a leading emoji is not split in half.
  String lead(String word, int n) => String.fromCharCodes(word.runes.take(n));
  final words = name.trim().split(RegExp(r'\s+'));
  if (words.length >= 2 && words[0].isNotEmpty && words[1].isNotEmpty) {
    return '${lead(words[0], 1)}${lead(words[1], 1)}'.toUpperCase(); // design-ignore: initials
  }
  return lead(words[0], 2).toUpperCase(); // design-ignore: initials
}

/// Initials for a person with no avatar: from the display name, else the END
/// of the peer id, since every libp2p id starts with the same "12D3KooW".
String peerInitials(String displayName, String peerId) {
  if (displayName.trim().isNotEmpty) return initialsFromName(displayName);
  if (peerId.length < 2) return '??';
  return peerId.substring(peerId.length - 2).toUpperCase(); // design-ignore: initials
}
