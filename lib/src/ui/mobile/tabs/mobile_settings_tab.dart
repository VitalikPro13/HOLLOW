import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/node_status.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/node_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:lucide_icons/lucide_icons.dart';

class MobileSettingsTab extends ConsumerWidget {
  const MobileSettingsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final identity = ref.watch(identityProvider);
    final nodeState = ref.watch(nodeProvider);
    final peerId = identity.peerId ?? '';

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: HollowSpacing.lg),
      children: [
        // Profile card
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
          child: Column(
            children: [
              HollowAvatar(peerId: peerId, size: 72),
              const SizedBox(height: HollowSpacing.md),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  StatusDot(
                    color: nodeState.status == NodeStatus.connected
                        ? hollow.success
                        : hollow.warning,
                    size: 8,
                    pulse: nodeState.status == NodeStatus.connected,
                  ),
                  const SizedBox(width: HollowSpacing.sm),
                  Text(
                    nodeState.status == NodeStatus.connected
                        ? 'Online'
                        : 'Connecting...',
                    style: HollowTypography.body.copyWith(
                      color: nodeState.status == NodeStatus.connected
                          ? hollow.success
                          : hollow.warning,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: HollowSpacing.xl),

        // ──────── Peer ID ────────
        _Divider(label: 'Peer ID'),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.lg, vertical: HollowSpacing.sm,
          ),
          child: HollowPressable(
            onTap: () {
              Clipboard.setData(ClipboardData(text: peerId));
              HollowToast.show(context, 'Peer ID copied',
                  type: HollowToastType.success);
            },
            borderRadius: BorderRadius.circular(hollow.radiusMd),
            padding: const EdgeInsets.all(HollowSpacing.md),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(HollowSpacing.md),
              decoration: BoxDecoration(
                color: hollow.surface,
                borderRadius: BorderRadius.circular(hollow.radiusMd),
                border: Border.all(color: hollow.border),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      peerId,
                      style: HollowTypography.mono.copyWith(
                        color: hollow.accent,
                        fontSize: 11,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: HollowSpacing.sm),
                  Icon(LucideIcons.copy, size: 16, color: hollow.textSecondary),
                ],
              ),
            ),
          ),
        ),

        const SizedBox(height: HollowSpacing.lg),

        // ──────── Network ────────
        _Divider(label: 'Network'),
        _InfoRow(
          label: 'Node status',
          value: nodeState.status.name,
        ),
        if (nodeState.error != null)
          _InfoRow(label: 'Error', value: nodeState.error!),

        const SizedBox(height: HollowSpacing.lg),

        // ──────── About ────────
        _Divider(label: 'About'),
        _InfoRow(label: 'Version', value: '0.3.1'),
        _InfoRow(label: 'Platform', value: 'Android (mobile)'),
      ],
    );
  }
}

class _Divider extends StatelessWidget {
  final String label;
  const _Divider({required this.label});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.lg, vertical: HollowSpacing.sm,
      ),
      child: Row(
        children: [
          Expanded(child: Divider(color: hollow.border, height: 1)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.md),
            child: Text(
              label,
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.0,
              ),
            ),
          ),
          Expanded(child: Divider(color: hollow.border, height: 1)),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.lg, vertical: HollowSpacing.sm,
      ),
      child: Row(
        children: [
          Text(label, style: HollowTypography.body.copyWith(
            color: hollow.textSecondary,
          )),
          const Spacer(),
          Text(value, style: HollowTypography.body.copyWith(
            color: hollow.textPrimary,
          )),
        ],
      ),
    );
  }
}
