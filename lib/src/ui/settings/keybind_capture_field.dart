import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/services/hotkeys/hotkey_binding.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';

/// Press-to-set keybind field (issue #38): shows the current binding as key
/// badges; tap to arm capture — the next non-modifier key (with live
/// modifiers) becomes the binding. Esc or focus loss cancels. While armed,
/// [keybindCaptureActiveProvider] suspends the live hotkey controller so
/// the captured combo never fires an action.
class KeybindCaptureField extends ConsumerStatefulWidget {
  final String serialized;
  final ValueChanged<String> onChanged;
  final String semanticLabel;

  const KeybindCaptureField({
    super.key,
    required this.serialized,
    required this.onChanged,
    required this.semanticLabel,
  });

  @override
  ConsumerState<KeybindCaptureField> createState() =>
      _KeybindCaptureFieldState();
}

class _KeybindCaptureFieldState extends ConsumerState<KeybindCaptureField> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'keybind-capture');
  bool _capturing = false;

  @override
  void dispose() {
    if (_capturing) {
      // Post-frame: provider writes during teardown are illegal.
      final container = ProviderScope.containerOf(context, listen: false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        container.read(keybindCaptureActiveProvider.notifier).state = false;
      });
    }
    _focusNode.dispose();
    super.dispose();
  }

  void _arm() {
    setState(() => _capturing = true);
    ref.read(keybindCaptureActiveProvider.notifier).state = true;
    _focusNode.requestFocus();
  }

  void _disarm() {
    if (!_capturing) return;
    setState(() => _capturing = false);
    ref.read(keybindCaptureActiveProvider.notifier).state = false;
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (!_capturing) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _disarm();
      return KeyEventResult.handled;
    }
    final binding = bindingFromCapture(event, HardwareKeyboard.instance);
    if (binding != null) {
      widget.onChanged(binding.serialize());
      _disarm();
    }
    // Swallow everything while armed (modifier presses stay pending).
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final binding = HotkeyBinding.parse(widget.serialized);

    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _onKeyEvent,
      onFocusChange: (focused) {
        if (!focused) _disarm();
      },
      child: HollowPressable(
        onTap: _capturing ? _disarm : _arm,
        semanticLabel: widget.semanticLabel,
        borderRadius: BorderRadius.circular(hollow.radiusSm),
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.sm,
          vertical: HollowSpacing.xs,
        ),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.xs,
            vertical: 2,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            // Never lerp from transparent (goes via black) — idle shows the
            // normal field border instead.
            border: Border.all(
              color: _capturing ? hollow.accent : hollow.border,
            ),
          ),
          child: _capturing
              ? Text(
                  'Press a key combo (Esc cancels)',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.accentText,
                    fontSize: 11,
                  ),
                )
              : _BindingBadges(
                  display: binding?.display() ?? 'Not set',
                ),
        ),
      ),
    );
  }
}

/// Key badges matching the Shortcuts page style.
class _BindingBadges extends StatelessWidget {
  final String display;

  const _BindingBadges({required this.display});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final keys = display.split(' + ');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < keys.length; i++) ...[
          if (i > 0)
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: HollowSpacing.xxs),
              child: Text(
                '+',
                style: HollowTypography.caption.copyWith(
                  color: hollow.textSecondary.withValues(alpha: 0.4),
                  fontSize: 9,
                ),
              ),
            ),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.xs + 2,
              vertical: HollowSpacing.xxs,
            ),
            decoration: BoxDecoration(
              color: hollow.surface,
              borderRadius: BorderRadius.circular(hollow.radiusSm - 2),
              border: Border.all(color: hollow.border),
            ),
            child: Text(
              keys[i],
              style: HollowTypography.mono.copyWith(
                color: hollow.textSecondary,
                fontSize: 10,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
