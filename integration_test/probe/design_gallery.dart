import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_badge.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_card.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_key_combo.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/components/hollow_skeleton.dart';

/// Every design-language primitive in every state, dark beside light, in one
/// screenshot.
///
/// It lives here rather than in `lib/` so it cannot ship, and the probe pumps
/// it in place of `HollowApp` when `UI_PROBE_WIDGET=design-gallery`. This is
/// the phase-0 design sheet, arrived at from the other end: instead of a route
/// carrying typeface and surface toggles, the tokens are edited in
/// `lib/src/theme/` and this page is re-shot. Every screen in the app follows
/// the same tokens, so a candidate that reads well here reads well everywhere.
class DesignGallery extends StatelessWidget {
  const DesignGallery({super.key});

  @override
  Widget build(BuildContext context) {
    // ONE scroll view around both panes, not one each: the probe's `scroll` op
    // resolves to the first match, so two scrollables would drift apart and
    // the shot would compare different rows of the two themes.
    return SingleChildScrollView(
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Theme(
                data: HollowThemeData.dark(),
                child: const _GalleryPane(caption: 'Dark'),
              ),
            ),
            Expanded(
              child: Theme(
                data: HollowThemeData.light(),
                child: const _GalleryPane(caption: 'Light'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GalleryPane extends StatelessWidget {
  final String caption;

  const _GalleryPane({required this.caption});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return Container(
      color: hollow.background,
      padding: const EdgeInsets.all(HollowSpacing.lg),
      child: Align(
        alignment: Alignment.topLeft,
        child: DefaultTextStyle(
          style: HollowTypography.body.copyWith(color: hollow.textPrimary),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                caption,
                style:
                    HollowTypography.heading.copyWith(color: hollow.textPrimary),
              ),
              const SizedBox(height: HollowSpacing.xl),

              Row(
                children: [
                  for (final w in [
                    FontWeight.w400,
                    FontWeight.w500,
                    FontWeight.w600,
                  ]) ...[
                    Text('Weight ${w.value}',
                        style: HollowTypography.subheading.copyWith(
                            color: hollow.textPrimary, fontWeight: w)),
                    const SizedBox(width: HollowSpacing.md),
                  ],
                ],
              ),
              const SizedBox(height: HollowSpacing.lg),
              const HollowSectionHeader('Surface ladder'),
              Row(
                children: [
                  for (final (name, color) in [
                    ('chrome', hollow.surface),
                    ('canvas', hollow.background),
                    ('raised', hollow.elevated),
                    ('overlay', hollow.overlay),
                    ('hover', hollow.hover),
                  ])
                    Expanded(
                      child: Container(
                        height: 56,
                        color: color,
                        alignment: Alignment.bottomLeft,
                        padding: const EdgeInsets.all(HollowSpacing.xs),
                        child: Text(name,
                            style: HollowTypography.monoSmall
                                .copyWith(color: hollow.textSecondary)),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: HollowSpacing.xl),

              const HollowSectionHeader('A message'),
              _MessageSample(),
              const SizedBox(height: HollowSpacing.xl),

              const HollowSectionHeader('A row that exists for one action'),
              HollowListRow(
                title: 'Aurora frame',
                subtitle: 'Animated, from the Starter pack',
                leading: _Dot(color: hollow.accent),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    HollowButton.ghost(
                      compact: true,
                      semanticLabel: 'More',
                      onPressed: () {},
                      child: const Icon(LucideIcons.ellipsis),
                    ),
                    const SizedBox(width: HollowSpacing.sm),
                    HollowButton.outline(
                      compact: true,
                      onPressed: () {},
                      child: const Text('Wear'),
                    ),
                  ],
                ),
                onTap: () {},
              ),
              const SizedBox(height: HollowSpacing.xl),

              const HollowSectionHeader('Card: fill only, then fill + hairline'),
              Row(
                children: [
                  Expanded(
                    child: HollowCard(
                      child: Text('Fill only',
                          style: HollowTypography.label
                              .copyWith(color: hollow.textPrimary)),
                    ),
                  ),
                  const SizedBox(width: HollowSpacing.sm),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(HollowSpacing.lg),
                      decoration: BoxDecoration(
                        color: hollow.elevated,
                        borderRadius: BorderRadius.circular(hollow.radiusMd),
                        border: Border.all(color: hollow.border),
                      ),
                      child: Text('Fill + hairline',
                          style: HollowTypography.label
                              .copyWith(color: hollow.textPrimary)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: HollowSpacing.xl),

              const HollowSectionHeader('Picker tabs, lists as one dropdown'),
              Wrap(
                spacing: HollowSpacing.sm,
                runSpacing: HollowSpacing.sm,
                children: [
                  HollowChip(label: 'Emoji', onTap: () {}),
                  HollowChip(label: 'GIFs', selected: true, onTap: () {}),
                  HollowChip(label: 'Stickers', onTap: () {}),
                  HollowChip(
                      label: 'All lists',
                      trailingIcon: LucideIcons.chevronDown,
                      onTap: () {}),
                ],
              ),
              const SizedBox(height: HollowSpacing.xl),

              const HollowSectionHeader('Badges', count: '6'),
              const Wrap(
                spacing: HollowSpacing.sm,
                runSpacing: HollowSpacing.sm,
                children: [
                  HollowBadge('Neutral'),
                  HollowBadge('Accent', kind: HollowBadgeKind.accent),
                  HollowBadge('Owned', kind: HollowBadgeKind.success),
                  HollowBadge('Expiring', kind: HollowBadgeKind.warning),
                  HollowBadge('Failed', kind: HollowBadgeKind.error),
                  HollowBadge('a1b2c3d4', kind: HollowBadgeKind.mono),
                  HollowBadge('12'),
                  HollowBadge('NSFW',
                      kind: HollowBadgeKind.warning, icon: LucideIcons.eyeOff),
                ],
              ),
              const SizedBox(height: HollowSpacing.xl),

              const HollowSectionHeader('Chips'),
              Wrap(
                spacing: HollowSpacing.sm,
                runSpacing: HollowSpacing.sm,
                children: [
                  HollowChip(label: 'All', selected: true, onTap: () {}),
                  HollowChip(label: 'Emotes', onTap: () {}),
                  HollowChip(label: 'Stickers', onTap: () {}),
                  HollowChip(
                      label: 'Frames',
                      icon: LucideIcons.square,
                      onTap: () {}),
                  HollowChip(
                      label: 'Removable', onTap: () {}, onRemove: () {}),
                  HollowChip(
                      label: 'RNNoise',
                      hint: 'light, instant',
                      selected: true,
                      onTap: () {}),
                  HollowChip(
                      label: 'Mod+',
                      icon: LucideIcons.eye,
                      trailingIcon: LucideIcons.chevronDown,
                      onTap: () {}),
                  HollowChip(
                      label: 'Steam',
                      trailingIcon: LucideIcons.arrowUpRight,
                      onTap: () {}),
                ],
              ),
              const SizedBox(height: HollowSpacing.sm),
              const HollowKeyCombo('Ctrl + Shift + M'),
              const SizedBox(height: HollowSpacing.sm),
              Text(
                'expand: true, for a row of equal-width sub-tabs',
                style: HollowTypography.caption
                    .copyWith(color: hollow.textTertiary),
              ),
              const SizedBox(height: HollowSpacing.xs),
              Row(
                children: [
                  for (final (label, sel) in [
                    ('DMs', true),
                    ('Channels', false),
                    ('Vault Files', false),
                  ]) ...[
                    Expanded(
                      child: HollowChip(
                        label: label,
                        expand: true,
                        selected: sel,
                        onTap: () {},
                      ),
                    ),
                    if (label != 'Vault Files')
                      const SizedBox(width: HollowSpacing.sm),
                  ],
                ],
              ),
              const SizedBox(height: HollowSpacing.xl),

              const HollowSectionHeader('Section header'),
              const HollowSectionHeader('With a count', count: '128'),
              HollowSectionHeader(
                'With one action',
                action: HollowButton.ghost(
                  onPressed: () {},
                  child: const Text('Manage'),
                ),
              ),
              HollowSectionHeader(
                'With a subtitle and a tall action',
                subtitle: 'The action centres on both lines',
                action: HollowButton.outline(
                  onPressed: () {},
                  child: const Text('Import'),
                ),
              ),
              const HollowSectionHeader('A dense sub-group', dense: true),
              const SizedBox(height: HollowSpacing.xl),

              const HollowSectionHeader('List rows'),
              HollowListRow(
                title: 'Vitalik',
                subtitle: 'Online',
                leading: _Dot(color: hollow.success),
                trailing: const HollowBadge('3', kind: HollowBadgeKind.accent),
                onTap: () {},
              ),
              const HollowDivider(),
              HollowListRow(
                title: 'A selected row',
                subtitle: 'Selection is a tint, never a filled button',
                leading: _Dot(color: hollow.textTertiary),
                selected: true,
                onTap: () {},
              ),
              const HollowDivider(),
              HollowListRow(
                title: 'A row with no subtitle',
                trailing: const HollowBadge('relay', kind: HollowBadgeKind.mono),
                onTap: () {},
              ),
              const SizedBox(height: HollowSpacing.xl),

              const HollowSectionHeader('Buttons'),
              Row(
                children: [
                  HollowButton.filled(
                    onPressed: () {},
                    child: const Text('Create a server'),
                  ),
                  const SizedBox(width: HollowSpacing.sm),
                  HollowButton.outline(
                    onPressed: () {},
                    child: const Text('Join with a link'),
                  ),
                  const SizedBox(width: HollowSpacing.sm),
                  HollowButton.ghost(
                    onPressed: () {},
                    child: const Text('Cancel'),
                  ),
                ],
              ),
              const SizedBox(height: HollowSpacing.sm),
              Text(
                'A toolbar has no primary, so every button in it is ghost:',
                style: HollowTypography.caption
                    .copyWith(color: hollow.textTertiary),
              ),
              const SizedBox(height: HollowSpacing.xs),
              Row(
                children: [
                  HollowButton.ghost(
                      onPressed: () {}, child: const Text('Import')),
                  const SizedBox(width: HollowSpacing.sm),
                  HollowButton.ghost(
                      onPressed: () {}, child: const Text('Export')),
                  const SizedBox(width: HollowSpacing.sm),
                  HollowButton.ghost(
                      onPressed: () {}, child: const Text('Refresh')),
                ],
              ),
              const SizedBox(height: HollowSpacing.sm),
              HollowButton.danger(
                onPressed: () {},
                child: const Text('Delete this server'),
              ),
              const SizedBox(height: HollowSpacing.xl),

              const HollowSectionHeader('Skeleton'),
              const Row(
                children: [
                  HollowSkeleton.circle(32),
                  SizedBox(width: HollowSpacing.md),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      HollowSkeleton(width: 140, height: 12),
                      SizedBox(height: HollowSpacing.xs),
                      HollowSkeleton(width: 90, height: 10),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: HollowSpacing.xl),

              const HollowSectionHeader('Empty state'),
              SizedBox(
                height: 200,
                child: HollowEmptyState(
                  glyph: LucideIcons.inbox,
                  title: 'No saved messages yet',
                  description:
                      'Anything you save to yourself shows up here.',
                  action: HollowButton.ghost(
                    onPressed: () {},
                    child: const Text('Learn how'),
                  ),
                ),
              ),
              const SizedBox(height: HollowSpacing.xl),

              const HollowSectionHeader('Type roles'),
              _TypeRow('display 28/600', HollowTypography.display),
              _TypeRow('heading 20/600', HollowTypography.heading),
              _TypeRow('subheading 16/600', HollowTypography.subheading),
              _TypeRow('body 14/400', HollowTypography.body),
              _TypeRow('label 13/500', HollowTypography.label),
              _TypeRow('bodySmall 12/400', HollowTypography.bodySmall),
              _TypeRow('caption 11/400', HollowTypography.caption),
              _TypeRow('micro 10/500', HollowTypography.micro),
              _TypeRow('mono 13/400', HollowTypography.mono),
              _TypeRow('monoSmall 11/400', HollowTypography.monoSmall),
              const SizedBox(height: HollowSpacing.sm),
              _TypeRow('Кириллица: Съешь же ещё этих мягких булок',
                  HollowTypography.body),
              _TypeRow('Weights 400, 500, 600 · 0123456789',
                  HollowTypography.body),
              _TypeRow('Medium 500 label', HollowTypography.label),
              _TypeRow('Semibold 600 heading', HollowTypography.subheading),
              _TypeRow('a1b2 c3d4 e5f6 · 1.14.2 · relay.anonlisten.com',
                  HollowTypography.mono),
              const SizedBox(height: HollowSpacing.xxl),
            ],
          ),
        ),
      ),
    );
  }
}

class _TypeRow extends StatelessWidget {
  final String label;
  final TextStyle style;

  const _TypeRow(this.label, this.style);

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: HollowSpacing.xs),
      child: Text(label, style: style.copyWith(color: hollow.textPrimary)),
    );
  }
}

class _Dot extends StatelessWidget {
  final Color color;

  const _Dot({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _MessageSample extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: hollow.accentMuted,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: HollowSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('Dr Faust',
                      style: HollowTypography.label
                          .copyWith(color: hollow.textPrimary)),
                  const SizedBox(width: HollowSpacing.sm),
                  Text('14:02',
                      style: HollowTypography.monoSmall
                          .copyWith(color: hollow.textTertiary)),
                ],
              ),
              const SizedBox(height: HollowSpacing.xxs),
              Text(
                'Pushed the relay fix. Can you try joining the server again '
                'and tell me if the invite still hangs?',
                style: HollowTypography.body.copyWith(color: hollow.textPrimary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
