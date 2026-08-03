import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/hotkey_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/services/hotkeys/hotkey_binding.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// What the mic button should show, PTT-aware (issue #38 follow-up: the
/// gate must be VISIBLE — mic reads gated while PTT idles, live while the
/// key is held). Manual mute always wins and stays the red crossed mic.
({IconData icon, Color color, String tooltip}) micButtonVisual(
  WidgetRef ref, {
  required bool isMuted,
  required HollowTheme hollow,
  required Color idleColor,
}) {
  if (isMuted) {
    return (icon: LucideIcons.micOff, color: hollow.error, tooltip: 'Unmute');
  }
  final ptt = ref.watch(pttStateProvider);
  if (ptt.enabled) {
    if (ptt.transmitting) {
      return (
        icon: LucideIcons.mic,
        color: hollow.accent,
        tooltip: 'Transmitting — push to talk',
      );
    }
    final raw =
        ref.watch(pttKeybindProvider).valueOrNull ?? 'ctrl+space';
    final key = HotkeyBinding.parse(raw)?.display() ?? 'the PTT key';
    return (
      icon: LucideIcons.micOff,
      color: hollow.textTertiary,
      tooltip: 'Push to talk — hold $key',
    );
  }
  return (icon: LucideIcons.mic, color: idleColor, tooltip: 'Mute');
}
