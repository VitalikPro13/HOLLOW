import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
/// Custom Hollow text field: flat, with no Material floating label.
class HollowTextField extends StatefulWidget {
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
  final int? maxLines;
  final int? minLines;
  final FocusNode? focusNode;
  final double? borderRadius;
  final int? maxLength;
  final bool showCounter;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;

  const HollowTextField({
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
    this.minLines,
    this.focusNode,
    this.borderRadius,
    this.maxLength,
    this.showCounter = true,
    this.keyboardType,
    this.inputFormatters,
  });

  @override
  State<HollowTextField> createState() => _HollowTextFieldState();
}

/// ONE stable instance for every field, never constructed in `build`. A fresh
/// one changes the controls IDENTITY on every keystroke, which makes
/// EditableText recreate its TextSelectionOverlay entries mid-build; inside a
/// raw OverlayEntry the recreated entry is re-inserted after dispose and the
/// app crashes on the second keystroke.
final TextSelectionControls _selectionControls = MaterialTextSelectionControls();

class _HollowTextFieldState extends State<HollowTextField>
    with SingleTickerProviderStateMixin {
  late final FocusNode _focusNode;
  bool _isFocused = false;
  int _charCount = 0;

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
  void didUpdateWidget(HollowTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
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
    final hollow = HollowTheme.of(context);
    final hasError = widget.errorText != null;
    final radius = widget.borderRadius ?? hollow.radiusMd;

    // Precedence: error, then focused, then default.
    final borderColor = hasError ? hollow.error : hollow.border;
    final focusBorderColor = hasError ? hollow.error : hollow.accent;

    Widget field = TextField(
      controller: widget.controller,
      focusNode: _focusNode,
      autofocus: widget.autofocus,
      obscureText: widget.obscureText,
      maxLines: widget.maxLines,
      minLines: widget.minLines,
      maxLength: widget.maxLength,
      keyboardType: widget.keyboardType,
      inputFormatters: widget.inputFormatters,
      onSubmitted: widget.onSubmitted,
      onChanged: widget.onChanged,
      cursorColor: hollow.accent,
      cursorWidth: 2,
      style: widget.style ??
          HollowTypography.body.copyWith(
            color: hollow.textPrimary,
          ),
      buildCounter: (context,
              {required currentLength,
              required isFocused,
              required maxLength}) =>
          null,
      selectionControls: _selectionControls,
      decoration: InputDecoration(
        hintText: widget.hintText,
        hintStyle: (widget.style ?? HollowTypography.body).copyWith(
          color: hollow.textSecondary,
        ),
        prefixIcon: widget.prefixIcon != null
            ? IconTheme(
                data: IconThemeData(
                  color: hollow.textSecondary,
                  size: 18,
                ),
                child: widget.prefixIcon!,
              )
            : null,
        prefixIconConstraints: widget.prefixIcon != null
            ? const BoxConstraints(minWidth: 40, minHeight: 0)
            : null,
        filled: true,
        fillColor: hollow.elevated,
        contentPadding: EdgeInsets.symmetric(
          horizontal: HollowSpacing.md,
          vertical: widget.isDense ? HollowSpacing.sm : HollowSpacing.md,
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

    final glowColor = hasError ? hollow.error : hollow.accent;
    field = AnimatedContainer(
      duration: HollowDurations.fast,
      curve: HollowCurves.subtle,
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

    if ((widget.maxLength != null && widget.showCounter) || hasError) {
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
                      style: HollowTypography.caption.copyWith(
                        color: hollow.error,
                      ),
                    ),
                  )
                else
                  const Spacer(),
                if (widget.maxLength != null)
                  Text(
                    '$_charCount/${widget.maxLength}',
                    style: HollowTypography.caption.copyWith(
                      color: nearLimit ? hollow.warning : hollow.textTertiary,
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
