import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/verified_peers_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/dialogs/verify_contact_dialog.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Verified-contacts pieces shared by the desktop Security category and the
/// mobile Security tab.
///
/// Listing them is auditability: a verified badge is a claim the app makes on
/// the user's behalf, so they must be able to see every claim in one place and
/// withdraw any of them.

/// Explainer shown above the list on both surfaces.
Widget verifiedContactsIntro(HollowTheme hollow) {
  return Text(
    'You confirmed these contacts by comparing safety numbers in person or '
    'over another trusted channel. Their number stays the same if they '
    'reinstall or add a device. You are warned about new devices separately.',
    style: HollowTypography.caption.copyWith(color: hollow.textSecondary),
  );
}

/// One verified-contact row.
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final profiles = ref.watch(profileProvider);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.md,
        vertical: HollowSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: hollow.surface,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(color: hollow.border),
      ),
      child: Row(
        children: [
          HollowAvatar(peerId: id, size: avatarSize),
          const SizedBox(width: HollowSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(LucideIcons.shieldCheck,
                        size: 13, color: hollow.success),
                    const SizedBox(width: HollowSpacing.xxs),
                    Flexible(
                      child: Text(
                        displayNameForPeer(profiles[id], id),
                        style: HollowTypography.body.copyWith(
                          color: hollow.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  shortId,
                  style: HollowTypography.mono.copyWith(
                    color: hollow.textSecondary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          HollowButton.ghost(
            compact: true,
            onPressed: () => showVerifyContactDialog(context, peerId: id),
            child: const Text('View'),
          ),
          HollowButton.ghost(
            compact: true,
            onPressed: () async {
              try {
                await ref.read(verifiedPeersProvider.notifier).unverify(id);
              } catch (_) {
                if (context.mounted) {
                  HollowToast.show(context, "Couldn't remove verification",
                      type: HollowToastType.error);
                }
              }
            },
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }
}

/// The verified list inside a [SettingsCard], for desktop Security.
class VerifiedContactsCard extends ConsumerWidget {
  const VerifiedContactsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final verified = ref.watch(verifiedPeersProvider).toList()..sort();

    return SettingsCard(
      title: 'Verified Contacts',
      children: [
        if (verified.isEmpty)
          Text(
            'No verified contacts yet. Open a contact\'s profile and choose '
            '"Verify contact" to compare safety numbers.',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
            ),
          )
        else ...[
          verifiedContactsIntro(hollow),
          const SizedBox(height: HollowSpacing.sm),
          for (final id in verified)
            Padding(
              padding: const EdgeInsets.only(bottom: HollowSpacing.sm),
              child: VerifiedContactRow(
                id: id,
                avatarSize: 32,
                shortId: shortenPeerId(id),
              ),
            ),
        ],
      ],
    );
  }
}
