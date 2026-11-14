import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_focus_ring.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// A box the person ticks to agree to the sentence beside it.
///
/// For an agreement that gates one action (a right given up before paying),
/// where a [HollowToggle] would read as a setting. The whole sentence is the
/// target; [footer] sits under it, outside the target, for links that explain
/// it.
class HollowCheckbox extends StatefulWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String label;
  final Widget? footer;

  const HollowCheckbox({
    super.key,
    required this.value,
    required this.onChanged,
    required this.label,
    this.footer,
  });

  @override
  State<HollowCheckbox> createState() => _HollowCheckboxState();
}

class _HollowCheckboxState extends State<HollowCheckbox> {
  static const double _box = 16;
  static const double _touchTarget = 44;

  bool _hovered = false;

  static bool get _isTouch =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final onChanged = widget.onChanged;
    final enabled = onChanged != null;
    void toggle() => onChanged!(!widget.value);

    final textStyle = HollowTypography.body.copyWith(
      color: enabled ? hollow.textSecondary : hollow.textTertiary,
    );
    // Centred on the first line of the sentence, however tall the line is.
    final lineHeight = MediaQuery.textScalerOf(context).scale(textStyle.fontSize!) *
        (textStyle.height ?? 1.2);
    final boxTop = ((lineHeight - _box) / 2).clamp(0.0, double.infinity);

    final box = Container(
      width: _box,
      height: _box,
      decoration: BoxDecoration(
        color: widget.value ? hollow.accent : null,
        borderRadius: BorderRadius.circular(hollow.radiusXs),
        border: widget.value
            ? null
            : Border.all(
                color: _hovered && enabled
                    ? hollow.textSecondary
                    : hollow.textTertiary,
                width: 1.5,
              ),
      ),
      child: widget.value
          ? Icon(LucideIcons.check, size: 14, color: hollow.textOnAccent)
          : null,
    );

    Widget row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(padding: EdgeInsets.only(top: boxTop), child: box),
        const SizedBox(width: HollowSpacing.sm),
        Expanded(child: Text(widget.label, style: textStyle)),
      ],
    );
    if (_isTouch) {
      row = ConstrainedBox(
        constraints: const BoxConstraints(minHeight: _touchTarget),
        child: Align(alignment: AlignmentDirectional.centerStart, child: row),
      );
    }

    final target = Semantics(
      checked: widget.value,
      enabled: enabled,
      label: widget.label,
      onTap: enabled ? toggle : null,
      excludeSemantics: true,
      child: HollowFocusRing(
        enabled: enabled,
        onActivate: enabled ? toggle : null,
        borderRadius: BorderRadius.circular(hollow.radiusXs),
        child: MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: enabled ? toggle : null,
            child: row,
          ),
        ),
      ),
    );

    final footer = widget.footer;
    if (footer == null) return target;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        target,
        Padding(
          padding: const EdgeInsetsDirectional.only(
              start: _box + HollowSpacing.sm, top: HollowSpacing.xs),
          child: Align(alignment: AlignmentDirectional.centerStart, child: footer),
        ),
      ],
    );
  }
}
