import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the right-side member panel is visible.
/// Defaults to true (desktop shows it open).
final memberPanelProvider = StateProvider<bool>((ref) => true);

/// Whether the channel search bar is open.
/// Toggled by Ctrl+K globally or the search icon in the channel header.
final channelSearchOpenProvider = StateProvider<bool>((ref) => false);

/// Whether the main window is currently visible (not hidden to tray).
/// Updated by main.dart window/tray listeners.
final windowVisibleProvider = StateProvider<bool>((ref) => true);

/// Whether the active chat pane is scrolled to the bottom.
/// Updated by ChannelChatPane / ChatPane on scroll position changes.
/// Used by event_provider to decide if new messages count as read.
final chatAtBottomProvider = StateProvider<bool>((ref) => true);
