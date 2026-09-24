import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_draft_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/settings_place_provider.dart';
import 'package:hollow/src/core/providers/storage_provider.dart';
import 'package:hollow/src/core/shop_availability.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/guides/help_panel.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';
import 'package:hollow/src/ui/settings/settings_catalog.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:hollow/src/ui/settings/settings_pages.dart';
import 'package:hollow/src/ui/shell/home_rail.dart';
import 'package:hollow/src/ui/shell/mobile_nav.dart';
import 'package:hollow/src/ui/shell/system_status_banner.dart';
import 'package:hollow/src/ui/shop/shop_dashboard.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Settings > Profile on its own page, from outside the Settings tab.
void openMobileProfileSettings(BuildContext context) =>
    _openCategory(context, SettingsCategory.profile);

/// Pushes the shared page for [category], the same widget the desktop rail
/// shows, at touch density.
void _openCategory(BuildContext context, SettingsCategory category) {
  if (category == SettingsCategory.storage) {
    // Read during the push, so the page lands with its figures.
    warmStorageBreakdown(ProviderScope.containerOf(context, listen: false));
  }
  Navigator.of(context).push(
    hollowMobileRoute(
      builder: (_) => MobileSettingsSubPage(
        title: category.label,
        actions: category == SettingsCategory.profile
            ? const _ProfileSaveActions()
            : null,
        child: SettingsDensity(
          touch: true,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(HollowSpacing.lg,
                HollowSpacing.sm, HollowSpacing.lg, HollowSpacing.xl),
            child: settingsPageFor(category),
          ),
        ),
      ),
    ),
  );
}

void _pushPage(BuildContext context, String title, Widget child) {
  Navigator.of(context).push(
    hollowMobileRoute(
      builder: (_) => MobileSettingsSubPage(title: title, child: child),
    ),
  );
}

/// The phone has no keyboard shortcuts to set.
bool _onPhone(SettingsCategory c) => c != SettingsCategory.shortcuts;

class MobileSettingsTab extends ConsumerWidget {
  const MobileSettingsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    Widget row(SettingsCategory c) => MobileSettingsNavRow(
          icon: c.icon,
          title: c.label,
          onTap: () => _openCategory(context, c),
        );

    return ListView(
      padding: const EdgeInsets.only(top: HollowSpacing.lg, bottom: HollowSpacing.xl),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
          child: Text(
            'Settings',
            style: HollowTypography.heading.copyWith(color: hollow.textPrimary),
          ),
        ),
        const SizedBox(height: HollowSpacing.md),
        const _IdentityRow(),
        for (final g in SettingsGroup.values) ...[
          MobileSettingsGroupCaption(g.label),
          for (final c in SettingsCategory.values)
            if (c.group == g && _onPhone(c)) row(c),
        ],
        const SizedBox(height: HollowSpacing.lg),
        for (final c in SettingsCategory.values)
          if (c.group == null) row(c),
        const SizedBox(height: HollowSpacing.lg),
        MobileSettingsNavRow(
          icon: LucideIcons.circleHelp,
          title: 'Help',
          onTap: () => _pushPage(context, 'Help', const HelpResourceCenter()),
        ),
        // Absent entirely on store builds (Apple 3.1.1 / Play): no gallery,
        // no prices, no import, no redeem.
        if (ref.watch(shopAvailableProvider))
          MobileSettingsNavRow(
            icon: LucideIcons.store,
            title: 'Hollow Shop',
            onTap: () => _pushPage(
                context, 'Hollow Shop', const ShopDashboard(embedded: true)),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
              HollowSpacing.lg, HollowSpacing.xl, HollowSpacing.lg, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Mobile's pull surface for status; the mobile banner only
              // pushes problems.
              const HomeStatusCard(),
              const SizedBox(height: HollowSpacing.lg),
              const HomeNewsCard(),
              // All four mobile tabs stay mounted, so the load bars (and their
              // poll) run only while this one shows.
              HomeRelayCard(loadBars: ref.watch(mobileTabProvider) == 3),
            ],
          ),
        ),
      ],
    );
  }
}

/// You, at the top of the list: opens Profile.
class _IdentityRow extends ConsumerWidget {
  const _IdentityRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final myPeerId = ref.watch(identityProvider).peerId ?? '';
    final myName = myPeerId.isEmpty
        ? ''
        : displayNameFor(ref.watch(profileProvider), myPeerId);
    return HollowPressable(
      onTap: () => openMobileProfileSettings(context),
      subtle: true,
      semanticButton: false,
      padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.lg, vertical: HollowSpacing.md),
      child: Row(
        children: [
          HollowAvatar(peerId: myPeerId, size: 48),
          const SizedBox(width: HollowSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  myName.isEmpty ? 'Profile' : myName,
                  style: HollowTypography.subheading
                      .copyWith(color: hollow.textPrimary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: HollowSpacing.xxs),
                Text(
                  'Name, status, avatar and banner',
                  style: HollowTypography.bodySmall
                      .copyWith(color: hollow.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Icon(LucideIcons.chevronRight, size: 16, color: hollow.textSecondary),
        ],
      ),
    );
  }
}

class MobileSettingsGroupCaption extends StatelessWidget {
  final String label;
  const MobileSettingsGroupCaption(this.label, {super.key});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          HollowSpacing.lg, HollowSpacing.lg, HollowSpacing.lg, HollowSpacing.xs),
      child: Text(
        label,
        style: HollowTypography.caption.copyWith(color: hollow.textTertiary),
      ),
    );
  }
}

/// One page in the list: its icon, its name and a chevron, edge to edge.
class MobileSettingsNavRow extends StatelessWidget {
  final IconData icon;
  final String title;

  /// The page's current state, quiet before the chevron ("Mentions only").
  final String? value;
  final VoidCallback onTap;

  const MobileSettingsNavRow({
    super.key,
    required this.icon,
    required this.title,
    this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowPressable(
      onTap: onTap,
      subtle: true,
      semanticButton: false,
      padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Row(
          children: [
            Icon(icon, size: 20, color: hollow.textSecondary),
            const SizedBox(width: HollowSpacing.lg),
            Expanded(
              child: Text(
                title,
                style:
                    HollowTypography.bodyTouch.copyWith(color: hollow.textPrimary),
              ),
            ),
            if (value != null) ...[
              const SizedBox(width: HollowSpacing.sm),
              Text(
                value!,
                style: HollowTypography.bodySmall
                    .copyWith(color: hollow.textSecondary),
              ),
              const SizedBox(width: HollowSpacing.sm),
            ],
            Icon(LucideIcons.chevronRight,
                size: 16, color: hollow.textSecondary),
          ],
        ),
      ),
    );
  }
}

/// A full-screen pushed settings page: back, its title, and [actions] on the
/// bar's trailing edge. Settings and a server's settings share it.
class MobileSettingsSubPage extends StatelessWidget {
  final String title;
  final Widget? actions;
  final Widget child;

  const MobileSettingsSubPage({
    super.key,
    required this.title,
    this.actions,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Scaffold(
      backgroundColor: hollow.background,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.sm,
                vertical: HollowSpacing.xs,
              ),
              child: Row(
                children: [
                  HollowPressable(
                    onTap: () => Navigator.pop(context),
                    semanticLabel: 'Back',
                    borderRadius: BorderRadius.circular(hollow.radiusMd),
                    padding: const EdgeInsets.all(HollowSpacing.sm),
                    child: Icon(LucideIcons.arrowLeft,
                        size: 20, color: hollow.textPrimary),
                  ),
                  const SizedBox(width: HollowSpacing.sm),
                  Expanded(
                    child: Text(
                      title,
                      style: HollowTypography.heading
                          .copyWith(color: hollow.textPrimary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (actions != null) ...[
                    const SizedBox(width: HollowSpacing.sm),
                    actions!,
                  ],
                ],
              ),
            ),
            const HollowDivider(),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

/// Profile's commit on the phone: the desktop shows it as the unsaved bar, the
/// phone as Reset and Save in the page's own bar. The draft outlives the page.
class _ProfileSaveActions extends ConsumerWidget {
  const _ProfileSaveActions();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(profileDraftProvider);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (draft.dirty) ...[
          HollowButton.ghost(
            onPressed: draft.saving
                ? null
                : () => ref.read(profileDraftProvider.notifier).reset(),
            child: const Text('Reset'),
          ),
          const SizedBox(width: HollowSpacing.sm),
        ],
        HollowButton.ghost(
          loading: draft.saving,
          onPressed: draft.dirty
              ? () async {
                  try {
                    await ref.read(profileDraftProvider.notifier).save();
                    if (context.mounted) {
                      HollowToast.show(context, 'Profile saved',
                          type: HollowToastType.success);
                    }
                  } catch (e) {
                    if (context.mounted) {
                      HollowToast.show(
                          context, 'Could not save your profile: $e',
                          type: HollowToastType.error);
                    }
                  }
                }
              : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
