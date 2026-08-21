import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the right-side member panel is visible.
/// Defaults to true (desktop shows it open).
final memberPanelProvider = StateProvider<bool>((ref) => true);

/// Whether the message search bar is open, in whichever chat is on screen.
///
/// One flag for both surfaces on purpose: the quick-search shortcut is global,
/// and it used to flip a CHANNEL-only flag, so pressing it in a DM did nothing
/// at all (issue #54, "or have some sort of search"). Both panes reset it when
/// they mount, so it can never arrive open in a conversation the user did not
/// open it in.
final chatSearchOpenProvider = StateProvider<bool>((ref) => false);

/// Whether the main window is currently visible (not hidden to tray).
/// Updated by main.dart window/tray listeners.
final windowVisibleProvider = StateProvider<bool>((ref) => true);

/// Whether the main window currently has OS focus (desktop). Updated by
/// main.dart's onWindowFocus/onWindowBlur listeners. Used to decide whether a
/// new message should raise a native toast even for the conversation that's
/// open: if the window is unfocused (alt-tabbed away), the user isn't really
/// reading it, so notify. Defaults true.
final windowFocusedProvider = StateProvider<bool>((ref) => true);

/// Whether the active chat pane is scrolled to the bottom.
/// Updated by ChannelChatPane / ChatPane on scroll position changes.
/// Used by event_provider to decide if new messages count as read.
final chatAtBottomProvider = StateProvider<bool>((ref) => true);
