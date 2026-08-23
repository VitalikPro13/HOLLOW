import 'package:flutter/widgets.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/theme/hollow_theme.dart';

/// How an [OverallConnection] renders in a user panel: dot color, dot shape,
/// and the word beside it.
///
/// Both user panels render from this ONE helper so the indicator can never
/// disagree between layouts again. Before: the Dock bar coloured its dot from
/// the LOCAL node status (green the instant the node booted, internet or not)
/// while the Classic bar synthesised "Connecting…" whenever no other member of
/// the selected server happened to be online — so switching layouts, or just
/// opening your own server, appeared to change your connection state.
class ConnectionVisual {
  final String label;
  final Color color;

  /// Solid disc vs hollow ring. Shape is the non-color cue (a11y): only a
  /// settled "connected" is filled.
  final bool filled;

  const ConnectionVisual({
    required this.label,
    required this.color,
    required this.filled,
  });
}

/// Maps the combined node+relay connection state onto dot + label.
ConnectionVisual connectionVisual(
  HollowTheme hollow,
  OverallConnection connection, {
  bool invisible = false,
}) {
  if (invisible) {
    return ConnectionVisual(
      label: 'Invisible',
      color: hollow.textSecondary,
      filled: false,
    );
  }
  return switch (connection) {
    OverallConnection.connected => ConnectionVisual(
        label: 'Online',
        color: hollow.success,
        filled: true,
      ),
    // In progress — pulsing ring: something is happening, not settled yet.
    OverallConnection.connecting ||
    OverallConnection.reconnecting ||
    OverallConnection.loading =>
      ConnectionVisual(
        label: connection.label,
        color: hollow.textSecondary,
        filled: false,
      ),
    OverallConnection.offline || OverallConnection.error => ConnectionVisual(
        label: connection.label,
        color: hollow.warning,
        filled: false,
      ),
  };
}
