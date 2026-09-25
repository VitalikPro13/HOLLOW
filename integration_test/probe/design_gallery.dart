import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/link_health_provider.dart';
import 'package:hollow/src/core/services/link_resilience.dart';
import 'package:hollow/src/ui/call/call_person_tile.dart';
import 'package:hollow/src/ui/call/call_stage_bar.dart';
import 'package:hollow/src/ui/call/call_stage_data.dart';
import 'package:hollow/src/ui/call/share_tile.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_badge.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_card.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_chip_tabs.dart';
import 'package:hollow/src/ui/components/hollow_copy_field.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/components/hollow_duration_picker.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_key_combo.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_progress_bar.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/components/hollow_sheet.dart';
import 'package:hollow/src/ui/components/hollow_skeleton.dart';
import 'package:hollow/src/ui/components/hollow_slider.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/label_visuals.dart';
import 'package:hollow/src/rust/api/crdt.dart' show LabelFfi;
import 'package:hollow/src/ui/components/hollow_toggle.dart';

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
    // Material for the sliders sampled below, which need one above them.
    return Material(
      type: MaterialType.transparency,
      child: SingleChildScrollView(
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
              const _DialogsPassSample(),
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
                    ('Messages', true),
                    ('Vault files', false),
                    ('Imported', false),
                  ]) ...[
                    Expanded(
                      child: HollowChip(
                        label: label,
                        expand: true,
                        selected: sel,
                        onTap: () {},
                      ),
                    ),
                    if (label != 'Imported')
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
              const SizedBox(height: HollowSpacing.sm),
              Text('Loading keeps the width and the colours:',
                  style: HollowTypography.caption
                      .copyWith(color: hollow.textSecondary)),
              Row(
                children: [
                  HollowButton.filled(
                    onPressed: () {},
                    loading: true,
                    child: const Text('Create a server'),
                  ),
                  const SizedBox(width: HollowSpacing.sm),
                  HollowButton.outline(
                    onPressed: () {},
                    loading: true,
                    child: const Text('Join with a link'),
                  ),
                  const SizedBox(width: HollowSpacing.sm),
                  HollowButton.ghost(
                    onPressed: () {},
                    loading: true,
                    child: const Text('Refresh'),
                  ),
                ],
              ),
              const SizedBox(height: HollowSpacing.xl),

              const HollowSectionHeader('Spinner'),
              const Row(
                children: [
                  HollowSpinner(),
                  SizedBox(width: HollowSpacing.lg),
                  HollowSpinner.medium(),
                  SizedBox(width: HollowSpacing.lg),
                  HollowSpinner.large(),
                  SizedBox(width: HollowSpacing.lg),
                  HollowSpinner.medium(value: 0.65),
                ],
              ),
              const SizedBox(height: HollowSpacing.xl),

              const HollowSectionHeader('Progress bar'),
              Row(
                children: [
                  const Expanded(child: HollowProgressBar(value: 0.35)),
                  const SizedBox(width: HollowSpacing.lg),
                  Expanded(
                    child: Builder(
                      builder: (context) => HollowProgressBar(
                          value: 1, color: HollowTheme.of(context).success),
                    ),
                  ),
                  const SizedBox(width: HollowSpacing.lg),
                  const Expanded(child: HollowProgressBar(value: 0)),
                ],
              ),
              const SizedBox(height: HollowSpacing.xl),

              const HollowSectionHeader('Slider and toggle'),
              Row(
                children: [
                  Expanded(child: HollowSlider(value: 0.6, onChanged: (_) {})),
                  const SizedBox(width: HollowSpacing.lg),
                  const Expanded(
                      child: HollowSlider(value: 0.3, onChanged: null)),
                  const SizedBox(width: HollowSpacing.lg),
                  HollowToggle(
                      value: true, semanticLabel: 'On', onChanged: (_) {}),
                  const SizedBox(width: HollowSpacing.sm),
                  HollowToggle(
                      value: false, semanticLabel: 'Off', onChanged: (_) {}),
                  const SizedBox(width: HollowSpacing.sm),
                  const HollowToggle(
                      value: true, semanticLabel: 'Disabled', onChanged: null),
                ],
              ),
              const SizedBox(height: HollowSpacing.xl),

              const HollowSectionHeader('Sheet'),
              Container(
                height: 120,
                decoration: BoxDecoration(
                  color: hollow.overlay,
                  borderRadius: BorderRadius.vertical(
                      top: Radius.circular(hollow.radiusXl)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const HollowSheetHandle(),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: HollowSpacing.lg),
                      child: Text('showHollowSheet: overlay, radiusXl, one handle',
                          style: HollowTypography.body
                              .copyWith(color: hollow.textPrimary)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: HollowSpacing.xl),

              const HollowSectionHeader('Dialog'),
              HollowDialog(
                title: 'Leave server?',
                content: const HollowDialogText(
                    'You will need a new invite to rejoin.'),
                actions: [
                  HollowButton.ghost(
                      onPressed: () {}, child: const Text('Cancel')),
                  HollowButton.danger(
                      onPressed: () {}, child: const Text('Leave server')),
                ],
              ),
              HollowDialog(
                title: 'Set app password',
                width: 420,
                content: const HollowDialogText(
                    'Asked every time Hollow starts.'),
                leadingActions: [
                  HollowButton.ghost(
                      onPressed: () {}, child: const Text('Forgot it?')),
                ],
                actions: [
                  HollowButton.ghost(
                      onPressed: () {}, child: const Text('Cancel')),
                  HollowButton.filled(
                      onPressed: () {}, child: const Text('Set password')),
                ],
              ),
              const HollowDialog(
                title: 'Message proof',
                showClose: true,
                content: HollowDialogText(
                    'Nothing to confirm, so the X closes it.'),
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
              const SizedBox(height: HollowSpacing.lg),
              const HollowSectionHeader('Empty state, dense', dense: true),
              const HollowEmptyState(
                dense: true,
                title: 'No blocked users',
                description: 'People you block from a profile appear here.',
              ),
              const SizedBox(height: HollowSpacing.xl),

              const HollowSectionHeader('Calls'),
              const _CallsSample(),
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


final _galleryQuiet = Provider<bool>((_) => false);
final _galleryTalking = Provider<bool>((_) => true);
final _galleryWeak = Provider<LinkHealthSnapshot?>(
    (_) => const LinkHealthSnapshot(health: LinkHealth.unstable));

/// The call pieces (session 21): person tiles at rest, speaking, muted with a
/// weak link; share tiles as an offer, live, and yours with a watcher; the
/// bar at rest and muted.
class _CallsSample extends StatelessWidget {
  const _CallsSample();

  static const _tileW = 176.0;
  static const _tileH = 99.0;

  @override
  Widget build(BuildContext context) {
    Widget large(Widget child) => Padding(
        padding: const EdgeInsets.only(right: HollowSpacing.lg),
        child: SizedBox(width: _tileW, height: _tileH, child: child));
    Widget strip(Widget child) => Padding(
        padding: const EdgeInsets.only(right: HollowSpacing.sm),
        child: SizedBox(width: 132, height: 76, child: child));
    CallPerson person(String id, String name,
            {bool self = false,
            bool muted = false,
            bool talking = false,
            bool weak = false}) =>
        CallPerson(
          id: id,
          master: id,
          isSelf: self,
          name: name,
          muted: muted,
          speaking: talking ? _galleryTalking : _galleryQuiet,
          link: weak ? _galleryWeak : null,
        );
    CallBarModel bar({bool muted = false}) => CallBarModel(
          startedAt: DateTime.now().subtract(const Duration(minutes: 4)),
          muted: muted,
          deafened: false,
          onMute: () {},
          onDeafen: () {},
          cameraOn: false,
          onCamera: () {},
          sharing: false,
          onShare: () {},
          layout: CallLayoutAction.showEveryone,
          onLayout: () {},
          fullscreen: false,
          onFullscreen: () {},
          watching: false,
          leaveLabel: 'Leave the room',
          onLeave: () {},
        );

    return ProviderScope(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Rows of fixed boxes, not a Wrap: the page sits in an
          // IntrinsicHeight, and a Wrap dry-lays its children, which a tile's
          // LayoutBuilder cannot do.
          Row(
            children: [
              large(CallPersonTile(
                  size: CallTileSize.large,
                  person: person('gallery-you', 'You', self: true))),
              large(CallPersonTile(
                  size: CallTileSize.large,
                  person: person('gallery-mira', 'Mira', talking: true))),
              large(CallPersonTile(
                  size: CallTileSize.large,
                  person: person('gallery-juno', 'Juno',
                      muted: true, weak: true))),
            ],
          ),
          const SizedBox(height: HollowSpacing.lg),
          Row(
            children: [
              large(ShareTile(
                size: CallTileSize.large,
                share: const CallShare(
                  owner: 'gallery-kes',
                  master: 'gallery-kes',
                  isMine: false,
                  name: 'Kestrel',
                  watched: false,
                  quality: '1080p60',
                ),
                onWatch: () {},
              )),
            ],
          ),
          const SizedBox(height: HollowSpacing.lg),
          Row(
            children: [
              SizedBox(
                width: 480,
                height: 270,
                child: ShareTile(
                size: CallTileSize.large,
                share: const CallShare(
                  owner: 'gallery-you',
                  master: 'gallery-you',
                  isMine: true,
                  name: 'You',
                  watched: true,
                  quality: '1080p60',
                  watchers: ['gallery-mira'],
                ),
                onStopSharing: () {},
              )),
            ],
          ),
          const SizedBox(height: HollowSpacing.lg),
          Row(
            children: [
              strip(CallPersonTile(
                  size: CallTileSize.strip,
                  person: person('gallery-mira', 'Mira', talking: true))),
              strip(CallPersonTile(
                  size: CallTileSize.strip,
                  person: person('gallery-juno', 'Juno',
                      muted: true, weak: true))),
              strip(ShareTile(
                size: CallTileSize.strip,
                share: const CallShare(
                  owner: 'gallery-kes',
                  master: 'gallery-kes',
                  isMine: false,
                  name: 'Kestrel',
                  watched: false,
                ),
                onWatch: () {},
              )),
              CallPersonTile(
                  size: CallTileSize.compact,
                  person: person('gallery-mira', 'Mira', talking: true)),
              const SizedBox(width: HollowSpacing.md),
              CallPersonTile(
                  size: CallTileSize.compact,
                  person: person('gallery-juno', 'Juno', muted: true)),
            ],
          ),
          const SizedBox(height: HollowSpacing.lg),
          CallStageBar(model: bar()),
          const SizedBox(height: HollowSpacing.sm),
          CallStageBar(model: bar(muted: true)),
        ],
      ),
    );
  }
}


/// The dialogs-pass primitives: chip tabs, the copy well, labels as chips and
/// badges, the duration picker, and a dialog whose action failed inside it.
/// The pane's width stands in for the screen's, so a pane at phone width
/// shows the compact dialog with its touch-size actions.
class _DialogsPassSample extends StatefulWidget {
  const _DialogsPassSample();

  @override
  State<_DialogsPassSample> createState() => _DialogsPassSampleState();
}

class _DialogsPassSampleState extends State<_DialogsPassSample> {
  int _tab = 1;
  Duration? _duration = const Duration(hours: 1);

  static const _artists =
      LabelFfi(labelId: 'a', name: 'Artists', color: '#EC4899', access: false);
  static const _staff =
      LabelFfi(labelId: 's', name: 'Staff', color: '#3B82F6', access: true);

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    // Each theme pane is half the window; no LayoutBuilder, since the gallery
    // sits in an IntrinsicHeight.
    final mq = MediaQuery.of(context);
    return MediaQuery(
        data: mq.copyWith(size: Size(mq.size.width / 2, mq.size.height)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const HollowSectionHeader('Tabs are chips'),
            HollowChipTabs<int>(
              selected: _tab,
              onSelected: (v) => setState(() => _tab = v),
              tabs: const [
                HollowChipTab(value: 0, label: 'Friends', hint: '12'),
                HollowChipTab(value: 1, label: 'Requests', count: 3),
                HollowChipTab(value: 2, label: 'Add friend'),
              ],
            ),
            const SizedBox(height: HollowSpacing.sm),
            HollowChipTabs<int>(
              selected: _tab,
              expand: true,
              onSelected: (v) => setState(() => _tab = v),
              tabs: const [
                HollowChipTab(value: 0, label: 'Messages'),
                HollowChipTab(value: 1, label: 'Vault files'),
                HollowChipTab(value: 2, label: 'Imported'),
              ],
            ),
            const SizedBox(height: HollowSpacing.xl),
            const HollowSectionHeader('Copy field'),
            const HollowCopyField(
              value: 'https://hollow.chat/join#server=7Hq2kX9mP4vL8wR3',
              name: 'invite link',
            ),
            const SizedBox(height: HollowSpacing.md),
            const HollowCopyField(
                value: 'K7Q-4MX', label: 'Link code', wrap: false),
            const SizedBox(height: HollowSpacing.xl),
            const HollowSectionHeader('Labels'),
            Wrap(
              spacing: HollowSpacing.sm,
              runSpacing: HollowSpacing.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                LabelChip(label: _artists, selected: true, onTap: () {}),
                LabelChip(label: _staff, selected: false, onTap: () {}),
                LabelChip(
                    label: _staff, selected: false, locked: true, onTap: () {}),
                LabelTypeChip(
                    icon: LucideIcons.lock,
                    text: 'Access',
                    selected: true,
                    onTap: () {}),
                const LabelBadge(label: _artists),
                const LabelBadge(label: _staff),
              ],
            ),
            const SizedBox(height: HollowSpacing.xl),
            const HollowSectionHeader('Duration picker'),
            HollowDurationPicker(
              value: _duration,
              onChanged: (d) => setState(() => _duration = d),
            ),
            const SizedBox(height: HollowSpacing.xl),
            const HollowSectionHeader('A confirm that acts'),
            HollowDialog(
              title: 'Leave server',
              content: const HollowDialogText(
                  'You will need a new invite to rejoin.'),
              error: "Hollow can't reach the relay right now. Check your "
                  'connection and try again.',
              actions: [
                HollowButton.ghost(
                    onPressed: () {}, child: const Text('Cancel')),
                HollowButton.danger(
                    onPressed: () {}, child: const Text('Leave server')),
              ],
            ),
            HollowDialog(
              title: 'Rename channel',
              width: 420,
              content: const HollowTextField(
                hintText: 'Channel name',
                maxLength: 32,
                errorText: 'That name is taken.',
              ),
              actions: [
                const HollowButton.ghost(onPressed: null, child: Text('Cancel')),
                HollowButton.filled(
                    onPressed: () {},
                    loading: true,
                    child: const Text('Rename')),
              ],
            ),
            Text(
              'Close on a phone is 44, as are the actions:',
              style: HollowTypography.caption
                  .copyWith(color: hollow.textTertiary),
            ),
            const HollowDialog(
              title: 'Invite link',
              showClose: true,
              content: HollowCopyField(
                  value: 'https://hollow.chat/join#server=7Hq2kX9m',
                  name: 'invite link'),
            ),
          ],
        ),
      );
  }
}
