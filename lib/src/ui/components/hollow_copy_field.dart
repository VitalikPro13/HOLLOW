import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// A value to read and copy (an invite link, a code, an id): the one
/// legitimate well, the value in `textPrimary` on `elevated`, with a copy
/// button that toasts "Copied". Never a card, and never the accent: the value
/// is content, not an action.
class HollowCopyField extends StatelessWidget {
  final String value;

  /// A [SettingsFieldLabel] above the well, and the name the copy button
  /// announces ("Copy invite link").
  final String? label;

  /// The copy button's name when there is no visible [label].
  final String? name;

  /// The console voice for ids, codes and links; false for prose-like values.
  final bool mono;

  /// Wraps a long value over lines; false keeps one line with an ellipsis.
  final bool wrap;

  /// What lands on the clipboard, when it differs from what is shown.
  final String? copyValue;

  const HollowCopyField({
    super.key,
    required this.value,
    this.label,
    this.name,
    this.mono = true,
    this.wrap = true,
    this.copyValue,
  });

  void _copy(BuildContext context) {
    Clipboard.setData(ClipboardData(text: copyValue ?? value));
    HollowToast.show(context, 'Copied', type: HollowToastType.success);
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final style = (mono ? HollowTypography.mono : HollowTypography.body)
        .copyWith(color: hollow.textPrimary);
    final what = label ?? name;
    final well = Container(
      padding: const EdgeInsets.only(
        left: HollowSpacing.md,
        top: HollowSpacing.xs,
        bottom: HollowSpacing.xs,
        right: HollowSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: hollow.elevated,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
      ),
      child: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: HollowSpacing.xs),
              child: wrap
                  ? SelectableText(value, style: style)
                  : Text(
                      value,
                      style: style,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          HollowIconButton(
            icon: LucideIcons.copy,
            label: what == null ? 'Copy' : 'Copy ${_inSentence(what)}',
            tooltip: 'Copy',
            onPressed: () => _copy(context),
          ),
        ],
      ),
    );
    if (label == null) return well;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsFieldLabel(label: label!),
        const SizedBox(height: HollowSpacing.xs),
        well,
      ],
    );
  }
}

/// "Invite link" reads "invite link" mid-sentence; "ID" stays "ID".
String _inSentence(String label) {
  if (label.isEmpty || RegExp(r'^[A-Z]{2}').hasMatch(label)) return label;
  return label[0].toLowerCase() + label.substring(1);
}
