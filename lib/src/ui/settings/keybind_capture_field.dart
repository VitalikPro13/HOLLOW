import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/services/hotkeys/hotkey_binding.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_key_combo.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';

/// Press-to-set keybind field (issue #38). Tap arms capture and the next
/// non-modifier key becomes the binding; Esc or focus loss cancels. While armed,
/// [keybindCaptureActiveProvider] suspends the live hotkey controller so the
/// captured combo never fires an action.
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
      // Provider writes during teardown are illegal.
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
    // Swallow everything while armed; modifier presses stay pending.
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
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.sm,
          vertical: HollowSpacing.xs,
        ),
        child: AnimatedContainer(
          duration: HollowDurations.fast,
          padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.xs,
            vertical: HollowSpacing.xxs,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(hollow.radiusMd),
            // Never lerp from transparent, which goes via black: idle shows the
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
                  ),
                )
              : HollowKeyCombo(binding?.display() ?? 'Not set'),
        ),
      ),
    );
  }
}
