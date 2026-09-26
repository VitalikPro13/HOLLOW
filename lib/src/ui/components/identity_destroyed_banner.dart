import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/duress_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Pinned notice for a contact who announced their identity destroyed.
///
/// Not dismissible and not an alert: it is a standing fact about the
/// conversation, and it clears by itself when that identity comes back.
class IdentityDestroyedBanner extends ConsumerWidget {
  /// The conversation partner, device or master id.
  final String peerId;

  const IdentityDestroyedBanner({super.key, required this.peerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final master = ref.watch(deviceLinkProvider).identityOf(peerId);
    final destroyed =
        ref.watch(identityDestroyedProvider(master)).valueOrNull ?? false;
    if (!destroyed) return const SizedBox.shrink();

    final hollow = HollowTheme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.md,
        vertical: HollowSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: hollow.error.withValues(alpha: 0.10),
        border: Border(
          bottom: BorderSide(color: hollow.error.withValues(alpha: 0.35)),
        ),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.shieldX, size: 16, color: hollow.error),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Text(
              'This identity was destroyed. The keys and messages behind it '
              'are gone.',
              style: HollowTypography.bodySmall
                  .copyWith(color: hollow.textPrimary),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
