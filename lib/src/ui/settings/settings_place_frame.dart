import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hollow/src/theme/hollow_shadows.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The rail's width, a navigation sidebar's (design language 5.2).
const double kSettingsRailWidth = 240;

/// The page column's widest, set by the prose in its rows.
const double kSettingsPageMaxWidth = 720;

/// Where the rail's visible edge starts: its header and the item fills all
/// line up on it.
const double _railEdgeInset = HollowSpacing.md;

const _pagePadding = EdgeInsets.fromLTRB(
  HollowSpacing.xxl,
  HollowSpacing.xl,
  HollowSpacing.xxxl,
  HollowSpacing.xxxl + HollowSpacing.xxxl,
);

/// The frame of a settings place (Settings, a server's settings): a rail on
/// chrome beside a page column, a close button and one floating bar.
///
/// On a wide window the rail and its page centre as a PAIR, the rail's chrome
/// running out to the left edge; below that width the pair hugs the left edge.
/// Either way every region touches an edge of the window.
class SettingsPlaceFrame extends StatelessWidget {
  final Widget rail;

  /// The page on screen; keyed by the caller so a switch resets its state.
  final Widget page;
  final ScrollController? scroll;
  final String closeLabel;
  final String closeTooltip;
  final VoidCallback onClose;

  /// Escape leaves the innermost layer first; returns false when nothing
  /// inside took it, and the place closes.
  final bool Function()? onEscape;

  /// The unsaved-changes bar, floating over the page's foot.
  final Widget? bottomBar;

  const SettingsPlaceFrame({
    super.key,
    required this.rail,
    required this.page,
    required this.closeLabel,
    required this.closeTooltip,
    required this.onClose,
    this.scroll,
    this.onEscape,
    this.bottomBar,
  });

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    if (!(onEscape?.call() ?? false)) onClose();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: LayoutBuilder(builder: (context, constraints) {
        // Centre what the eye reads as the block: from the rail's left edge
        // to the page column's end, so the gaps either side measure the same.
        const visible = kSettingsRailWidth -
            _railEdgeInset +
            HollowSpacing.xxl +
            kSettingsPageMaxWidth;
        final bleed = ((constraints.maxWidth - visible) / 2 - _railEdgeInset)
            .clamp(0.0, double.infinity)
            .floorToDouble();
        return ColoredBox(
          color: hollow.background,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (bleed > 0)
                SizedBox(width: bleed, child: ColoredBox(color: hollow.surface)),
              rail,
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: FocusTraversalGroup(
                        policy: ReadingOrderTraversalPolicy(),
                        child: SingleChildScrollView(
                          controller: scroll,
                          padding: _pagePadding,
                          child: Align(
                            alignment: Alignment.topLeft,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                  maxWidth: kSettingsPageMaxWidth),
                              child: page,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      top: HollowSpacing.lg,
                      right: HollowSpacing.lg,
                      child: HollowIconButton(
                        icon: LucideIcons.x,
                        label: closeLabel,
                        tooltip: closeTooltip,
                        onPressed: onClose,
                      ),
                    ),
                    if (bottomBar != null)
                      Positioned(
                        left: HollowSpacing.xxl,
                        right: HollowSpacing.xxxl,
                        bottom: HollowSpacing.lg,
                        child: Align(
                          alignment: Alignment.bottomLeft,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                                maxWidth: kSettingsPageMaxWidth),
                            child: bottomBar,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      }),
    );
  }
}

/// A settings rail: [header] above a scrolling list of groups and items.
class SettingsRail extends StatelessWidget {
  final Widget header;
  final List<Widget> children;

  const SettingsRail({super.key, required this.header, required this.children});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Container(
      width: kSettingsRailWidth,
      decoration: BoxDecoration(
        color: hollow.surface,
        border: Border(right: BorderSide(color: hollow.border)),
      ),
      child: FocusTraversalGroup(
        policy: ReadingOrderTraversalPolicy(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                    HollowSpacing.md, 0, HollowSpacing.md, HollowSpacing.lg),
                children: children,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The caption over a group of rail items, standing over the icons it names.
class SettingsRailGroupLabel extends StatelessWidget {
  final String label;
  const SettingsRailGroupLabel(this.label, {super.key});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          HollowSpacing.md, HollowSpacing.md, HollowSpacing.md, HollowSpacing.xs),
      child: Text(
        label,
        style: HollowTypography.caption.copyWith(color: hollow.textTertiary),
      ),
    );
  }
}

/// One entry in a settings rail: a grey icon and the page's name. The page on
/// screen takes a surface fill and brighter text, nothing else.
class SettingsRailItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const SettingsRailItem({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: HollowSpacing.xxs),
      child: Semantics(
        selected: selected,
        child: HollowPressable(
          onTap: onTap,
          subtle: true,
          backgroundColor: selected ? hollow.elevated : null,
          hoverColor: hollow.elevated,
          borderRadius: BorderRadius.circular(hollow.radiusMd),
          // 32 tall: the whole rail fits a 768 px laptop screen unscrolled.
          padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.md,
              vertical: HollowSpacing.xs + HollowSpacing.xxs),
          child: Row(
            children: [
              Icon(icon, size: 16, color: hollow.textSecondary),
              const SizedBox(width: HollowSpacing.md),
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: HollowTypography.label.copyWith(
                    color: selected ? hollow.textPrimary : hollow.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The one reminder that a place holds unsaved edits: what is pending, a ghost
/// Reset and the filled Save.
class SettingsUnsavedBar extends StatelessWidget {
  final String message;
  final String resetLabel;
  final String saveLabel;
  final bool saving;
  final VoidCallback onReset;
  final VoidCallback onSave;

  const SettingsUnsavedBar({
    super.key,
    required this.message,
    required this.onReset,
    required this.onSave,
    this.resetLabel = 'Reset',
    this.saveLabel = 'Save',
    this.saving = false,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(
          HollowSpacing.lg, HollowSpacing.sm, HollowSpacing.sm, HollowSpacing.sm),
      decoration: BoxDecoration(
        color: hollow.overlay,
        borderRadius: BorderRadius.circular(hollow.radiusLg),
        border: Border.all(color: hollow.border),
        boxShadow: HollowShadows.float,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: HollowTypography.body.copyWith(color: hollow.textPrimary),
            ),
          ),
          HollowButton.ghost(
            onPressed: saving ? null : onReset,
            child: Text(resetLabel),
          ),
          const SizedBox(width: HollowSpacing.sm),
          HollowButton.filled(
            loading: saving,
            onPressed: onSave,
            child: Text(saveLabel),
          ),
        ],
      ),
    );
  }
}
