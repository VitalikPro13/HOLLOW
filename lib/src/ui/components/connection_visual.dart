import 'package:flutter/widgets.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/theme/hollow_theme.dart';

/// How an [OverallConnection] renders in a user panel: dot colour, dot shape
/// and the word beside it.
///
/// Both user panels render from this ONE helper, so the indicator cannot
/// disagree between layouts. Neither may read the local node status (green the
/// instant the node boots, internet or not) or who else is online.
class ConnectionVisual {
  final String label;
  final Color color;

  /// Shape is the non-colour cue: only a settled "connected" is filled.
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
    // A pulsing ring: something is happening, not settled yet.
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
