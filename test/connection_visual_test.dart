import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/components/connection_visual.dart';

/// Issue #23: the Dock bar coloured its dot from the local node status while
/// the Classic bar synthesised "Connecting…" from "nobody else is online", so
/// the same connection read differently in the two layouts — and opening your
/// own empty server looked like a dropped connection.
///
/// Both bars now render from [connectionVisual]. These lock the mapping: the
/// label/shape follow the REAL node+relay state and nothing else.
void main() {
  final hollow = HollowTheme.dark();

  test('connected is the only solid dot, and reads "Online"', () {
    final v = connectionVisual(hollow, OverallConnection.connected);
    expect(v.label, 'Online');
    expect(v.filled, isTrue);
    expect(v.color, hollow.success);
  });

  test('in-progress states read as a hollow ring', () {
    for (final c in [
      OverallConnection.connecting,
      OverallConnection.reconnecting,
      OverallConnection.loading,
    ]) {
      final v = connectionVisual(hollow, c);
      expect(v.filled, isFalse, reason: '$c must not read as connected');
      expect(v.label, c.label);
    }
  });

  test('offline and error are warning-coloured rings', () {
    for (final c in [OverallConnection.offline, OverallConnection.error]) {
      final v = connectionVisual(hollow, c);
      expect(v.filled, isFalse);
      expect(v.color, hollow.warning);
    }
  });

  test('invisible wins over every connection state', () {
    for (final c in OverallConnection.values) {
      final v = connectionVisual(hollow, c, invisible: true);
      expect(v.label, 'Invisible');
      expect(v.filled, isFalse);
    }
  });

  test('only `connected` is treated as online', () {
    for (final c in OverallConnection.values) {
      expect(c.isOnline, c == OverallConnection.connected);
    }
  });
}
