import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the right-side member panel is visible. Defaults to true on desktop.
final memberPanelProvider = StateProvider<bool>((ref) => true);

/// Whether the message search bar is open, in whichever chat is on screen.
///
/// ONE flag for both surfaces: the quick-search shortcut is global and used to
/// flip a CHANNEL-only flag, so it did nothing in a DM (issue #54). Both panes
/// reset it on mount, so it never arrives open where it wasn't opened.
final chatSearchOpenProvider = StateProvider<bool>((ref) => false);

/// Whether the main window is currently visible (not hidden to tray).
final windowVisibleProvider = StateProvider<bool>((ref) => true);

/// Whether the main window has OS focus (desktop). An unfocused window means
/// the user is not really reading the open conversation, so a new message
/// there still raises a native toast. Defaults true.
final windowFocusedProvider = StateProvider<bool>((ref) => true);

/// Whether the active chat pane is scrolled to the bottom. Used by
/// event_provider to decide if new messages count as read.
final chatAtBottomProvider = StateProvider<bool>((ref) => true);
