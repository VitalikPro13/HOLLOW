import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/core/models/node_status.dart';
import 'package:haven/src/core/providers/identity_provider.dart';
import 'package:haven/src/core/providers/node_provider.dart';
import 'package:haven/src/core/providers/theme_provider.dart';
import 'package:haven/src/theme/haven_spacing.dart';
import 'package:haven/src/theme/haven_theme.dart';
import 'package:haven/src/theme/haven_typography.dart';
import 'package:haven/src/ui/components/haven_avatar.dart';
import 'package:haven/src/ui/components/haven_pressable.dart';
import 'package:haven/src/ui/components/haven_toast.dart';
import 'package:haven/src/ui/components/haven_tooltip.dart';
import 'package:haven/src/ui/components/status_dot.dart';
import 'package:haven/src/ui/dialogs/mnemonic_dialog.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Bottom bar in the channel sidebar showing the local user's identity and status.
/// Mirrors Discord's bottom-left user panel.
class UserBar extends ConsumerWidget {
  const UserBar({super.key});

  Color _statusColor(HavenTheme haven, NodeStatus status) {
    return switch (status) {
      NodeStatus.connected => haven.success,
      NodeStatus.starting => haven.warning,
      NodeStatus.loading => haven.textSecondary,
      NodeStatus.error => haven.error,
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final haven = HavenTheme.of(context);
    final identity = ref.watch(identityProvider);
    final nodeState = ref.watch(nodeProvider);

    final localPeerId = identity.peerId;
    final shortPeerId = localPeerId != null && localPeerId.length > 8
        ? '${localPeerId.substring(0, 8)}...'
        : localPeerId ?? '---';

    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: HavenSpacing.sm + 2),
      decoration: BoxDecoration(
        color: haven.background,
        border: Border(
          top: BorderSide(color: haven.border),
        ),
      ),
      child: Row(
        children: [
          // Avatar
          if (localPeerId != null)
            HavenAvatar(peerId: localPeerId, size: 32)
          else
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: haven.elevated,
                borderRadius: BorderRadius.circular(haven.radiusMd),
              ),
            ),

          const SizedBox(width: HavenSpacing.sm),

          // Peer ID + status
          Expanded(
            child: HavenTooltip(
              message: localPeerId ?? 'Loading...',
              child: HavenPressable(
                borderRadius: BorderRadius.circular(haven.radiusSm),
                onTap: () {
                  if (localPeerId != null) {
                    Clipboard.setData(ClipboardData(text: localPeerId));
                    HavenToast.show(
                      context,
                      'Peer ID copied',
                      type: HavenToastType.success,
                      duration: const Duration(seconds: 1),
                    );
                  }
                },
                padding: const EdgeInsets.symmetric(
                  vertical: HavenSpacing.xs,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      shortPeerId,
                      style: HavenTypography.mono.copyWith(
                        color: haven.textPrimary,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        StatusDot(
                          color: _statusColor(haven, nodeState.status),
                          size: 7,
                        ),
                        const SizedBox(width: HavenSpacing.xs),
                        Text(
                          _statusText(nodeState.status),
                          style: HavenTypography.caption.copyWith(
                            color: haven.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Error indicator
          if (nodeState.error != null)
            HavenTooltip(
              message: nodeState.error!,
              child: Padding(
                padding: const EdgeInsets.only(right: HavenSpacing.xs),
                child: Icon(
                  LucideIcons.alertTriangle,
                  size: 16,
                  color: haven.error,
                ),
              ),
            ),

          // Theme toggle
          HavenTooltip(
            message: ref.watch(themeModeProvider) == ThemeMode.dark
                ? 'Switch to light mode'
                : 'Switch to dark mode',
            child: HavenPressable(
              onTap: () {
                final current = ref.read(themeModeProvider);
                ref.read(themeModeProvider.notifier).state =
                    current == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
              },
              borderRadius: BorderRadius.circular(haven.radiusSm),
              padding: const EdgeInsets.all(HavenSpacing.xs),
              child: Icon(
                ref.watch(themeModeProvider) == ThemeMode.dark
                    ? LucideIcons.sun
                    : LucideIcons.moon,
                size: 16,
                color: haven.textSecondary,
              ),
            ),
          ),

          // Recovery key button
          if (identity.mnemonic != null)
            HavenTooltip(
              message: 'Recovery phrase',
              child: HavenPressable(
                onTap: () =>
                    showMnemonicDialog(context, identity.mnemonic!),
                borderRadius: BorderRadius.circular(haven.radiusSm),
                padding: const EdgeInsets.all(HavenSpacing.xs),
                child: Icon(LucideIcons.keyRound, size: 16, color: haven.textSecondary),
              ),
            ),
        ],
      ),
    );
  }

  String _statusText(NodeStatus status) {
    return switch (status) {
      NodeStatus.connected => 'Online',
      NodeStatus.starting => 'Connecting...',
      NodeStatus.loading => 'Loading...',
      NodeStatus.error => 'Error',
    };
  }
}
