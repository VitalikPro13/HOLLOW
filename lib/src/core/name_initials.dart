/// One or two letter initials for a server or folder with no icon: the first
/// letters of the first two words, else the first two letters.
String initialsFromName(String name) {
  final words = name.trim().split(RegExp(r'\s+'));
  if (words.length >= 2 && words[0].isNotEmpty && words[1].isNotEmpty) {
    return '${words[0][0]}${words[1][0]}'.toUpperCase(); // design-ignore: initials
  }
  return name.substring(0, name.length.clamp(0, 2)).toUpperCase(); // design-ignore: initials
}
