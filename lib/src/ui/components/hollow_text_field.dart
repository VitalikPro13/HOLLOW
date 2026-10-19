import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';

/// The caret every Hollow input draws: as tall as the glyphs (not the line
/// box), with the last glyph's own side bearing as a gap before it.
abstract final class HollowCaret {
  static const double width = 2;
  static const Radius radius = Radius.circular(width / 2);

  /// The painted caret height for text in [style]: ascender to descender.
  static double height(TextStyle style, TextScaler scaler) =>
      scaler.scale(style.fontSize ?? HollowTypography.body.fontSize!) * 1.2;

  /// What to pass as `cursorHeight` so the painted caret is [height] tall:
  /// the render object draws an Apple caret 2 px taller than asked.
  static double fieldHeight(TextStyle style, TextScaler scaler) =>
      height(style, scaler) - (_apple ? 2 : 0);

  /// The blink: a fade on iOS, as the system does, a plain blink elsewhere.
  static bool get opacityAnimates =>
      defaultTargetPlatform == TargetPlatform.iOS;

  static bool get _apple =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;
}

/// Puts a Material [TextField] on the Hollow caret's horizontal position.
/// On Apple platforms the field shifts its caret 2 physical px left, into the
/// last glyph, keyed off `Theme.platform` with no parameter to undo it. So the
/// field alone sees the nearest non-Apple platform that keeps the same IME
/// length rule and selection handling (iOS as fuchsia, macOS as linux), and
/// whatever it hosts gets the real theme back through `restore`. Its menu
/// comes from the field's own selection controls, which ignore the platform.
class HollowCaretScope extends StatelessWidget {
  const HollowCaretScope({super.key, required this.builder});

  /// Builds the field; `restore` wraps what it hosts (prefix, suffix).
  final Widget Function(Widget Function(Widget) restore) builder;

  static TargetPlatform? _standIn(TargetPlatform platform) =>
      switch (platform) {
        TargetPlatform.iOS => TargetPlatform.fuchsia,
        TargetPlatform.macOS => TargetPlatform.linux,
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final real = Theme.of(context);
    Widget restore(Widget child) => Theme(data: real, child: child);
    final field = builder(restore);
    final standIn = _standIn(real.platform);
    if (standIn == null) return field;
    return Theme(data: real.copyWith(platform: standIn), child: field);
  }
}

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

  /// A control inside the field's trailing edge (the composer's emoji
  /// button), laid out at its own size.
  final Widget? trailing;

  /// Focus keeps the resting hairline instead of the accent border, for a
  /// field that holds focus all the time (the chat composer). The caret still
  /// marks it.
  final bool quietFocus;

  final TextInputAction? textInputAction;
  final TapRegionCallback? onTapOutside;

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
    this.trailing,
    this.quietFocus = false,
    this.textInputAction,
    this.onTapOutside,
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
  int _charCount = 0;

  AnimationController? _shakeController;
  Animation<double>? _shakeAnimation;

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _charCount = widget.controller?.text.length ?? 0;
    widget.controller?.addListener(_onTextChanged);
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
    // The error text still appears; only the shake is motion.
    if (HollowDurations.animationsDisabled) return;
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
    final focusBorderColor = hasError
        ? hollow.error
        : (widget.quietFocus ? hollow.border : hollow.accent);

    final style = widget.style ??
        HollowTypography.body.copyWith(color: hollow.textPrimary);
    final scaler = MediaQuery.textScalerOf(context);

    Widget field = HollowCaretScope(builder: (restore) => TextField(
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
      textInputAction: widget.textInputAction,
      onTapOutside: widget.onTapOutside,
      cursorColor: hollow.accent,
      cursorWidth: HollowCaret.width,
      cursorHeight: HollowCaret.fieldHeight(style, scaler),
      cursorRadius: HollowCaret.radius,
      cursorOpacityAnimates: HollowCaret.opacityAnimates,
      style: style,
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
            ? restore(IconTheme(
                data: IconThemeData(
                  color: hollow.textSecondary,
                  size: 18,
                ),
                child: widget.prefixIcon!,
              ))
            : null,
        prefixIconConstraints: widget.prefixIcon != null
            ? const BoxConstraints(minWidth: 40, minHeight: 0)
            : null,
        suffixIcon: widget.trailing == null ? null : restore(widget.trailing!),
        suffixIconConstraints: widget.trailing != null
            ? const BoxConstraints(minWidth: 0, minHeight: 0)
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
    ));

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

    if ((widget.maxLength != null && widget.showCounter) || hasError) {
      final nearLimit = widget.maxLength != null &&
          _charCount >= widget.maxLength! * 0.8;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          field,
          Padding(
            padding: const EdgeInsets.only(top: HollowSpacing.xs),
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
