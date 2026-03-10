import 'package:flutter/material.dart';
import 'package:haven/src/theme/haven_spacing.dart';
import 'package:haven/src/theme/haven_theme.dart';
import 'package:haven/src/theme/haven_typography.dart';
import 'package:haven/src/ui/animations/haven_curves.dart';
/// Custom Haven text field — flat design, no Material floating label.
///
/// Focus: border transitions to accent color over 150ms.
/// Error: border turns red, optional shake animation.
/// Optional prefix icon. Cursor in accent color.
class HavenTextField extends StatefulWidget {
  final TextEditingController? controller;
  final String? hintText;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final bool isDense;
  final TextStyle? style;
  final Widget? prefixIcon;
  final bool autofocus;
  final String? errorText;
  final bool obscureText;
  final int maxLines;
  final FocusNode? focusNode;
  final double? borderRadius;
  final int? maxLength;

  const HavenTextField({
    super.key,
    this.controller,
    this.hintText,
    this.onSubmitted,
    this.onChanged,
    this.isDense = false,
    this.style,
    this.prefixIcon,
    this.autofocus = false,
    this.errorText,
    this.obscureText = false,
    this.maxLines = 1,
    this.focusNode,
    this.borderRadius,
    this.maxLength,
  });

  @override
  State<HavenTextField> createState() => _HavenTextFieldState();
}

class _HavenTextFieldState extends State<HavenTextField>
    with SingleTickerProviderStateMixin {
  late final FocusNode _focusNode;
  bool _isFocused = false;
  int _charCount = 0;

  // Shake animation for error state.
  AnimationController? _shakeController;
  Animation<double>? _shakeAnimation;

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _focusNode.addListener(_onFocusChange);
    _charCount = widget.controller?.text.length ?? 0;
    widget.controller?.addListener(_onTextChanged);
  }

  void _onFocusChange() {
    setState(() => _isFocused = _focusNode.hasFocus);
  }

  void _onTextChanged() {
    final len = widget.controller?.text.length ?? 0;
    if (len != _charCount) setState(() => _charCount = len);
  }

  @override
  void didUpdateWidget(HavenTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Trigger shake when error appears.
    if (widget.errorText != null && oldWidget.errorText == null) {
      _triggerShake();
    }
  }

  void _triggerShake() {
    _shakeController ??= AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _shakeAnimation ??= TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0, end: 3), weight: 25),
      TweenSequenceItem(tween: Tween(begin: 3, end: -3), weight: 25),
      TweenSequenceItem(tween: Tween(begin: -3, end: 2), weight: 25),
      TweenSequenceItem(tween: Tween(begin: 2, end: 0), weight: 25),
    ]).animate(CurvedAnimation(
      parent: _shakeController!,
      curve: Curves.easeInOut,
    ));
    _shakeController!.forward(from: 0);
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_onTextChanged);
    _focusNode.removeListener(_onFocusChange);
    if (widget.focusNode == null) _focusNode.dispose();
    _shakeController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final haven = HavenTheme.of(context);
    final hasError = widget.errorText != null;
    final radius = widget.borderRadius ?? haven.radiusMd;

    // Border color: error > focused > default.
    final borderColor = hasError ? haven.error : haven.border;
    final focusBorderColor = hasError ? haven.error : haven.accent;

    Widget field = TextField(
      controller: widget.controller,
      focusNode: _focusNode,
      autofocus: widget.autofocus,
      obscureText: widget.obscureText,
      maxLines: widget.maxLines,
      maxLength: widget.maxLength,
      onSubmitted: widget.onSubmitted,
      onChanged: widget.onChanged,
      cursorColor: haven.accent,
      cursorWidth: 2,
      style: widget.style ??
          HavenTypography.body.copyWith(
            color: haven.textPrimary,
          ),
      buildCounter: (context,
              {required currentLength,
              required isFocused,
              required maxLength}) =>
          null,
      selectionControls: MaterialTextSelectionControls(),
      decoration: InputDecoration(
        hintText: widget.hintText,
        hintStyle: (widget.style ?? HavenTypography.body).copyWith(
          color: haven.textSecondary,
        ),
        prefixIcon: widget.prefixIcon != null
            ? IconTheme(
                data: IconThemeData(
                  color: haven.textSecondary,
                  size: 18,
                ),
                child: widget.prefixIcon!,
              )
            : null,
        prefixIconConstraints: widget.prefixIcon != null
            ? const BoxConstraints(minWidth: 40, minHeight: 0)
            : null,
        filled: true,
        fillColor: haven.elevated,
        contentPadding: EdgeInsets.symmetric(
          horizontal: HavenSpacing.md,
          vertical: widget.isDense ? HavenSpacing.sm : HavenSpacing.md,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: borderColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: borderColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: focusBorderColor),
        ),
        isDense: widget.isDense,
      ),
    );

    // Wrap with shake animation if available.
    if (_shakeAnimation != null) {
      field = AnimatedBuilder(
        animation: _shakeController!,
        builder: (context, child) {
          return Transform.translate(
            offset: Offset(_shakeAnimation!.value, 0),
            child: child,
          );
        },
        child: field,
      );
    }

    // Wrap with focus glow.
    final glowColor = hasError ? haven.error : haven.accent;
    field = AnimatedContainer(
      duration: HavenDurations.fast,
      curve: HavenCurves.subtle,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: _isFocused
            ? [
                BoxShadow(
                  color: glowColor.withValues(alpha: 0.15),
                  blurRadius: 6,
                  spreadRadius: 1,
                ),
              ]
            : [],
      ),
      child: field,
    );

    // Counter / error row below field.
    if (widget.maxLength != null || hasError) {
      final nearLimit = widget.maxLength != null &&
          _charCount >= widget.maxLength! * 0.8;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          field,
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Row(
              children: [
                if (hasError)
                  Expanded(
                    child: Text(
                      widget.errorText!,
                      style: HavenTypography.caption.copyWith(
                        color: haven.error,
                      ),
                    ),
                  )
                else
                  const Spacer(),
                if (widget.maxLength != null)
                  Text(
                    '$_charCount/${widget.maxLength}',
                    style: HavenTypography.caption.copyWith(
                      color: nearLimit
                          ? haven.warning
                          : haven.textSecondary.withValues(alpha: 0.4),
                      fontSize: 10,
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    }

    return field;
  }
}
