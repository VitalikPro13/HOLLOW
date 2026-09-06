import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/security_alerts_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/dialogs/verify_contact_dialog.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Persistent warning strip for a conversation whose contact's identity changed
/// (Issue 1-C).
///
/// Deliberately NOT a toast, which fires once and may do so while the window is
/// unfocused. This stays pinned above the message list until the user acts on
/// it, and survives restarts because the alert is DB-backed.
///
/// Renders nothing when nothing is outstanding, so it is safe to place
/// unconditionally in the chat column.
class SecurityAlertBanner extends ConsumerWidget {
  /// The conversation partner — device or master id, resolved internally.
  final String peerId;

  const SecurityAlertBanner({super.key, required this.peerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final master = ref.watch(deviceLinkProvider).identityOf(peerId);
    final alerts = ref.watch(peerSecurityAlertsProvider(master));
    if (alerts.isEmpty) return const SizedBox.shrink();

    final hollow = HollowTheme.of(context);
    final name = displayNameForPeer(
      ref.watch(profileProvider.select((p) => p[master])),
      master,
    );

    // A new device carries the attack shape and a re-key is informational, so
    // with both outstanding the stronger one leads.
    final hasNewDevice =
        alerts.any((a) => a.kind == SecurityAlertKind.newDevice);
    final color = hasNewDevice ? hollow.warning : hollow.textSecondary;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.md,
        vertical: HollowSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        border: Border(bottom: BorderSide(color: color.withValues(alpha: 0.35))),
      ),
      child: Row(
        children: [
          Icon(
            hasNewDevice
                ? LucideIcons.monitorSmartphone
                : LucideIcons.rotateCw,
            size: 16,
            color: color,
          ),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Text(
              _message(hasNewDevice, name, alerts.length),
              style: HollowTypography.body.copyWith(
                color: hollow.textPrimary,
                fontSize: 12,
              ),
              // Bounded so a large text scale cannot grow the banner into the
              // message area; the Verify screen repeats the full wording.
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          HollowButton.outline(
            onPressed: () => showVerifyContactDialog(context, peerId: master),
            compact: true,
            child: const Text('Verify'),
          ),
          const SizedBox(width: HollowSpacing.xs),
          HollowButton.ghost(
            onPressed: () => _dismiss(context, ref, master),
            compact: true,
            child: const Text('Dismiss'),
          ),
        ],
      ),
    );
  }

  String _message(bool hasNewDevice, String name, int count) {
    if (!hasNewDevice) {
      return '$name reinstalled or re-keyed a device. Their messages are still '
          'end-to-end encrypted.';
    }
    final devices = count == 1 ? 'A new device was' : '$count new devices were';
    return '$devices added to $name. If they did not just set up a new phone or '
        'computer, verify them before sharing anything sensitive.';
  }

  Future<void> _dismiss(BuildContext context, WidgetRef ref, String master) async {
    try {
      await ref.read(securityAlertsProvider.notifier).acknowledgeForPeer(master);
    } catch (_) {
      if (context.mounted) {
        HollowToast.show(context, "Couldn't dismiss the warning",
            type: HollowToastType.error);
      }
    }
  }
}
