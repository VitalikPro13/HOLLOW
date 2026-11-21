import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The phone shell's tabs, in nav bar order. The bar's centre (+) adds a
/// server and is no tab, so a tab's [slot] is its place in the bar.
enum MobileTab {
  chats,
  servers,
  friends,
  settings;

  /// Where the tab sits in the five-slot bar.
  int get slot => index < 2 ? index : index + 1;
}

/// Which tab the phone shell shows.
final mobileTabProvider = StateProvider<MobileTab>((ref) => MobileTab.chats);
