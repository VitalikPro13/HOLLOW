import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/verified_peers_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:hollow/src/ui/dialogs/verify_contact_dialog.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Verified-contacts pieces shared by desktop Settings > Security and the
/// mobile Security tab.
///
/// Listing them is auditability: a verified badge is a claim the app makes on
/// the user's behalf, so they must be able to see every claim in one place and
/// withdraw any of them.

/// One verified-contact row: View opens the safety number, the More menu
/// withdraws the verification.
class VerifiedContactRow extends ConsumerWidget {
  final String id;
  final double avatarSize;
  final String shortId;

  const VerifiedContactRow({
    super.key,
    required this.id,
    required this.avatarSize,
    required this.shortId,
  });

  Future<void> _unverify(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(verifiedPeersProvider.notifier).unverify(id);
    } catch (_) {
      if (context.mounted) {
        HollowToast.show(context, "Couldn't remove verification",
            type: HollowToastType.error);
      }
    }
  }

  void _openMenu(BuildContext buttonContext, WidgetRef ref) {
    final box = buttonContext.findRenderObject() as RenderBox?;
    if (box == null) return;
    showHollowMenu(
      context: buttonContext,
      anchor: overlayAnchorOf(buttonContext,
          localOffset: Offset(box.size.width, box.size.height)),
      alignEnd: true,
      builder: (menuContext, _) => [
        HollowMenuItem(
          label: 'Remove verification',
          isDanger: true,
          onTap: () => _unverify(buttonContext, ref),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final name = displayNameForPeer(ref.watch(profileProvider)[id], id);
    final touch = SettingsDensity.touchOf(context);

    return SettingsRow(
      leading: HollowAvatar(peerId: id, size: avatarSize),
      title: name,
      subtitleWidget: Text(
        shortId,
        style: HollowTypography.monoSmall.copyWith(color: hollow.textSecondary),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          HollowButton.outline(
            compact: true,
            onPressed: () => showVerifyContactDialog(context, peerId: id),
            child: const Text('View'),
          ),
          const SizedBox(width: HollowSpacing.xs),
          Builder(
            builder: (buttonContext) => HollowIconButton(
              icon: LucideIcons.ellipsis,
              label: 'More for $name',
              size: touch ? 44 : 32,
              onPressed: () => _openMenu(buttonContext, ref),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Verified contacts": a count, and the list behind Show.
class VerifiedContactsExpandRow extends ConsumerWidget {
  const VerifiedContactsExpandRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final verified = ref.watch(verifiedPeersProvider).toList()..sort();

    if (verified.isEmpty) {
      return const SettingsRow(
        title: 'Verified contacts',
        subtitle: 'Nobody yet. Verify someone from their profile.',
      );
    }
    final count =
        verified.length == 1 ? '1 person' : '${verified.length} people';
    return SettingsExpandRow(
      title: 'Verified contacts',
      subtitle: '$count, checked by safety number',
      children: [
        for (final id in verified)
          VerifiedContactRow(
            key: ValueKey(id),
            id: id,
            avatarSize: 32,
            shortId: shortenPeerId(id),
          ),
      ],
    );
  }
}
