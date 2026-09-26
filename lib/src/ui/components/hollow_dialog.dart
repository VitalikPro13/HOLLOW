import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/shell/window_chrome_insets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Shows a Hollow-styled dialog: a scale and fade in over the flat [HollowTheme.scrim].
Future<T?> showHollowDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: 'Dismiss',
    barrierColor: HollowTheme.of(context).scrim,
    transitionDuration: HollowDurations.normal,
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      // One duration per route, so the exit runs in the last 60% of the
      // reverse: a dialog leaves in about 150 ms, quicker than it came.
      final curvedAnimation = CurvedAnimation(
        parent: animation,
        curve: HollowCurves.enter,
        reverseCurve: const Interval(0.4, 1, curve: HollowCurves.exit),
      );
      return FadeTransition(
        opacity: curvedAnimation,
        child: ScaleTransition(
          scale: Tween<double>(begin: HollowMotion.popoverScale, end: 1.0)
              .animate(curvedAnimation),
          child: child,
        ),
      );
    },
    pageBuilder: (context, _, _) {
      // Keyboard avoidance for EVERY dialog: pad by the inset so centred
      // content shifts up, and strip viewInsets so a builder cannot double-pad.
      return AnimatedPadding(
        padding: MediaQuery.viewInsetsOf(context),
        duration: HollowDurations.exit,
        curve: Curves.decelerate,
        child: MediaQuery.removeViewInsets(
          context: context,
          removeLeft: true,
          removeTop: true,
          removeRight: true,
          removeBottom: true,
          // Innermost, and the builder below it: a MediaQuery built above
          // would restore the whole window as the dialog's screen.
          child: DialogChromeSlot(child: Builder(builder: builder)),
        ),
      );
    },
  );
}

/// Keeps a dialog out of the Dock header's band: the route's slot starts below
/// it, and MediaQuery's size is that slot, so a dialog that sizes or centres
/// itself from the screen can never reach the pinned friends or the window
/// controls. The scrim still covers the whole window.
class DialogChromeSlot extends StatelessWidget {
  final Widget child;

  const DialogChromeSlot({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    // A dialog pumped without a ProviderScope has no Dock around it.
    if (context.getElementForInheritedWidgetOfExactType<
            UncontrolledProviderScope>() ==
        null) {
      return child;
    }
    return Consumer(
      builder: (context, ref, child) {
        final top = windowChromeTop(ref);
        if (top == 0) return child!;
        final media = MediaQuery.of(context);
        final height = media.size.height - top;
        return Padding(
          padding: EdgeInsets.only(top: top),
          child: MediaQuery(
            data: media.copyWith(
              size: Size(media.size.width, height < 0 ? 0 : height),
            ),
            child: child!,
          ),
        );
      },
      child: child,
    );
  }
}

/// Asks one yes-or-no question: ghost Cancel beside one filled confirm, or a
/// danger confirm when [destructive]. Resolves true only on the confirm.
///
/// With [onConfirm] the dialog runs the action itself: it stays open with the
/// confirm loading, closes and resolves true on success, and on a throw shows
/// [friendlyError] inside the dialog so the person can retry or cancel. Cancel
/// is disabled while the action runs, since closing would hide its outcome.
Future<bool> showHollowConfirm({
  required BuildContext context,
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
  String cancelLabel = 'Cancel',
  Future<void> Function()? onConfirm,
}) async {
  final confirmed = await showHollowDialog<bool>(
    context: context,
    builder: (_) => _HollowConfirmDialog(
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      destructive: destructive,
      onConfirm: onConfirm,
    ),
  );
  return confirmed ?? false;
}

class _HollowConfirmDialog extends StatefulWidget {
  final String title;
  final String message;
  final String confirmLabel;
  final String cancelLabel;
  final bool destructive;
  final Future<void> Function()? onConfirm;

  const _HollowConfirmDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.destructive,
    required this.onConfirm,
  });

  @override
  State<_HollowConfirmDialog> createState() => _HollowConfirmDialogState();
}

class _HollowConfirmDialogState extends State<_HollowConfirmDialog>
    with HollowDialogAction {
  Future<void> _confirm() async {
    final action = widget.onConfirm;
    if (action == null) {
      Navigator.of(context).pop(true);
      return;
    }
    if (await runDialogAction(action) && mounted) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final confirm = widget.destructive
        ? HollowButton.danger(
            onPressed: _confirm,
            loading: actionRunning,
            child: Text(widget.confirmLabel),
          )
        : HollowButton.filled(
            onPressed: _confirm,
            loading: actionRunning,
            child: Text(widget.confirmLabel),
          );
    return HollowDialog(
      title: widget.title,
      content: HollowDialogText(widget.message),
      busy: actionRunning,
      error: actionError,
      actions: [
        HollowButton.ghost(
          onPressed:
              actionRunning ? null : () => Navigator.of(context).pop(false),
          child: Text(widget.cancelLabel),
        ),
        confirm,
      ],
    );
  }
}

/// Runs a dialog's confirm action: [actionRunning] while it runs, and
/// [actionError] (a [friendlyError] sentence) when it throws. For a dialog of
/// its own that acts on its confirm: pass both to [HollowDialog.busy] and
/// [HollowDialog.error], and the confirm takes `loading: actionRunning`.
mixin HollowDialogAction<T extends StatefulWidget> on State<T> {
  bool actionRunning = false;
  String? actionError;

  /// True when [action] finished, and the caller then pops. The running state
  /// stays on after success so the confirm keeps its spinner through the exit.
  Future<bool> runDialogAction(FutureOr<void> Function() action,
      {String? fallback}) async {
    if (actionRunning) return false;
    setState(() {
      actionRunning = true;
      actionError = null;
    });
    try {
      await action();
      return true;
    } catch (e) {
      if (mounted) {
        setState(() {
          actionRunning = false;
          actionError = friendlyError(e, fallback: fallback);
        });
      }
      return false;
    }
  }
}

/// One small "type a name" dialog: the field autofocused, Enter submits, and
/// the dialog owns its controller. Resolves to the trimmed name, or null on
/// Cancel.
///
/// [onSubmit] runs INSIDE the dialog: the confirm loads while it runs, and a
/// throw keeps the dialog open with [friendlyError] on the field and the typed
/// text intact. [validator] returns the field's error for a name that cannot
/// be used, checked on submit. The confirm stays disabled while the field is
/// empty unless [allowEmpty].
Future<String?> promptForName({
  required BuildContext context,
  required String title,
  required String confirmLabel,
  String hintText = '',
  String initial = '',
  String? description,
  int? maxLength,
  String? Function(String name)? validator,
  bool allowEmpty = false,
  FutureOr<void> Function(String name)? onSubmit,
}) {
  return showHollowDialog<String>(
    context: context,
    builder: (_) => _NamePromptDialog(
      title: title,
      confirmLabel: confirmLabel,
      hintText: hintText,
      initial: initial,
      description: description,
      maxLength: maxLength,
      validator: validator,
      allowEmpty: allowEmpty,
      onSubmit: onSubmit,
    ),
  );
}

class _NamePromptDialog extends StatefulWidget {
  final String title;
  final String confirmLabel;
  final String hintText;
  final String initial;
  final String? description;
  final int? maxLength;
  final String? Function(String name)? validator;
  final bool allowEmpty;
  final FutureOr<void> Function(String name)? onSubmit;

  const _NamePromptDialog({
    required this.title,
    required this.confirmLabel,
    required this.hintText,
    required this.initial,
    required this.description,
    required this.maxLength,
    required this.validator,
    required this.allowEmpty,
    required this.onSubmit,
  });

  @override
  State<_NamePromptDialog> createState() => _NamePromptDialogState();
}

class _NamePromptDialogState extends State<_NamePromptDialog>
    with HollowDialogAction {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);
  final FocusNode _focus = FocusNode();
  String? _fieldError;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      widget.allowEmpty || _controller.text.trim().isNotEmpty;

  Future<void> _submit() async {
    if (actionRunning || !_canSubmit) return;
    final name = _controller.text.trim();
    final invalid = widget.validator?.call(name);
    if (invalid != null) {
      setState(() => _fieldError = invalid);
      _focus.requestFocus();
      return;
    }
    final onSubmit = widget.onSubmit;
    if (onSubmit != null && !await runDialogAction(() => onSubmit(name))) {
      // On the field, so the error sits where the text went wrong.
      if (mounted) {
        setState(() => _fieldError = actionError);
        _focus.requestFocus();
      }
      return;
    }
    if (mounted) Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return HollowDialog(
      title: widget.title,
      width: 420,
      busy: actionRunning,
      content: Padding(
        padding: const EdgeInsets.only(top: HollowSpacing.xs),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.description != null) ...[
              HollowDialogText(widget.description!),
              const SizedBox(height: HollowSpacing.md),
            ],
            HollowTextField(
              controller: _controller,
              focusNode: _focus,
              hintText: widget.hintText,
              autofocus: true,
              maxLength: widget.maxLength,
              errorText: _fieldError,
              onChanged: (_) => setState(() => _fieldError = null),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        HollowButton.ghost(
          onPressed: actionRunning ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          onPressed: _canSubmit ? _submit : null,
          loading: actionRunning,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// The body prose of a dialog: `body` in `textSecondary`.
class HollowDialogText extends StatelessWidget {
  final String text;

  const HollowDialogText(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: HollowTypography.body
          .copyWith(color: HollowTheme.of(context).textSecondary),
    );
  }
}

/// The one dialog frame: overlay surface, radius, hairline and shadow, centred
/// with its margin and width policy. [HollowDialog] is built on it; a dialog
/// whose layout is its own (a hero, a crop canvas, a two-pane window) uses it
/// directly and never draws a frame of its own.
class HollowDialogSurface extends StatelessWidget {
  final Widget child;

  /// A fixed desktop width. Phones always span the screen minus the margin.
  final double? width;

  /// Without [width], the dialog shrink-wraps between [minWidth] and this.
  final double maxWidth;
  final double minWidth;

  /// A height cap below the screen's; the screen's always applies.
  final double? maxHeight;

  /// False for content that runs to the frame's edge (a hero image, a crop
  /// canvas, a pane layout); the child is clipped to the radius instead.
  final bool padded;

  const HollowDialogSurface({
    super.key,
    required this.child,
    this.width,
    this.maxWidth = 600,
    this.minWidth = 300,
    this.maxHeight,
    this.padded = true,
  });

  /// Below this width a dialog spans the screen and takes the sheet radius.
  static const compactBreakpoint = 600.0;

  /// A phone-width dialog: full width, the sheet radius, touch-size controls.
  static bool isCompact(BuildContext context) =>
      MediaQuery.sizeOf(context).width < compactBreakpoint;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final screenSize = MediaQuery.sizeOf(context);
    final isCompact = screenSize.width < compactBreakpoint;
    final radius =
        BorderRadius.circular(isCompact ? hollow.radiusXl : hollow.radiusLg);
    final available =
        (screenSize.width - HollowSpacing.xl * 2).clamp(0.0, double.infinity);

    final double min;
    final double max;
    if (isCompact) {
      min = available.clamp(0.0, maxWidth);
      max = min;
    } else if (width != null) {
      min = width!.clamp(0.0, available);
      max = min;
    } else {
      max = maxWidth.clamp(0.0, available);
      min = minWidth.clamp(0.0, max);
    }
    // Capped to the screen so a Flexible scroll region inside clamps and a
    // sticky action row is never pushed off a short display.
    final screenMaxHeight =
        (screenSize.height - HollowSpacing.xl * 2).clamp(0.0, double.infinity);
    final effectiveMaxHeight = maxHeight == null
        ? screenMaxHeight
        : maxHeight!.clamp(0.0, screenMaxHeight);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HollowSpacing.xl),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: min,
            maxWidth: max,
            maxHeight: effectiveMaxHeight,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: hollow.overlay,
                borderRadius: radius,
                border: Border.all(color: hollow.border),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 12,
                  ),
                ],
              ),
              child: padded
                  ? Padding(
                      padding: const EdgeInsets.all(HollowSpacing.xl),
                      child: HollowFlushRows(child: child),
                    )
                  : ClipRRect(borderRadius: radius, child: child),
            ),
          ),
        ),
      ),
    );
  }
}

/// The standard dialog: title, scrolling content and the action row. Use it
/// with [showHollowDialog], which owns the entrance and exit.
///
/// Actions: ghost Cancel, then ONE filled confirm (danger only when it
/// destroys something), primary last. A dialog with nothing to confirm has no
/// Cancel; it takes [showClose] instead. On a phone the actions and the close
/// button grow to touch size on their own.
class HollowDialog extends StatelessWidget {
  final String title;
  final Widget content;
  final List<Widget> actions;

  /// Ghost actions at the leading edge of the action row, away from the
  /// confirm (a "Forgot password" link, a "Reset" beside Save).
  final List<Widget> leadingActions;

  /// A close button at the title's trailing edge.
  final bool showClose;

  final double? width;
  final double maxWidth;

  /// False for content that scrolls itself (a long changelog with its own
  /// scroll view): it gets the height left under the title, unwrapped. A
  /// scroll view nested in the default one never scrolls.
  final bool scrollable;

  /// An action is running: the scrim, Escape and the close button stop
  /// dismissing, so the outcome cannot be hidden mid-flight.
  final bool busy;

  /// Why the last action failed, one line above the actions. A failure that
  /// belongs to one field goes on that field's `errorText` instead.
  final String? error;

  const HollowDialog({
    super.key,
    required this.title,
    required this.content,
    this.actions = const [],
    this.leadingActions = const [],
    this.showClose = false,
    this.width,
    this.maxWidth = 600,
    this.scrollable = true,
    this.busy = false,
    this.error,
  });

  /// The widest [HollowListRow] bleed, a touch row's.
  static const _rowBleed = HollowSpacing.lg;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final compact = HollowDialogSurface.isCompact(context);

    Widget dialog = HollowDialogSurface(
      width: width,
      maxWidth: maxWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title.isNotEmpty || showClose) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: HollowTypography.heading
                        .copyWith(color: hollow.textPrimary),
                  ),
                ),
                if (showClose) ...[
                  const SizedBox(width: HollowSpacing.sm),
                  const HollowDialogCloseButton(),
                ],
              ],
            ),
            const SizedBox(height: HollowSpacing.lg),
          ],
          Flexible(
            // Widened into the frame's padding so a flush row's hover is not
            // clipped at the text edge.
            child: scrollable
                ? HollowBleed(
                    horizontal: _rowBleed,
                    child: SingleChildScrollView(
                      padding:
                          const EdgeInsets.symmetric(horizontal: _rowBleed),
                      child: content,
                    ),
                  )
                : content,
          ),
          if (error != null) ...[
            const SizedBox(height: HollowSpacing.lg),
            Semantics(
              liveRegion: true,
              child: Text(
                error!,
                style: HollowTypography.bodySmall.copyWith(color: hollow.error),
              ),
            ),
          ],
          if (actions.isNotEmpty || leadingActions.isNotEmpty) ...[
            SizedBox(height: error != null ? HollowSpacing.md : HollowSpacing.xl),
            HollowButtonTouchScope(
              touch: compact,
              child: Row(
                children: [
                  for (var i = 0; i < leadingActions.length; i++) ...[
                    if (i > 0) const SizedBox(width: HollowSpacing.sm),
                    leadingActions[i],
                  ],
                  if (leadingActions.isNotEmpty)
                    const SizedBox(width: HollowSpacing.sm),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Wrap(
                        alignment: WrapAlignment.end,
                        spacing: HollowSpacing.sm,
                        runSpacing: HollowSpacing.sm,
                        children: actions,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
    if (busy) dialog = PopScope(canPop: false, child: dialog);
    return dialog;
  }
}

/// The dialog close button: a ghost X that pops the route, 44 on a phone. Only
/// on a dialog with nothing to confirm; a dialog with a Cancel never also
/// shows it.
class HollowDialogCloseButton extends StatelessWidget {
  final VoidCallback? onPressed;

  const HollowDialogCloseButton({super.key, this.onPressed});

  @override
  Widget build(BuildContext context) {
    return HollowIconButton(
      icon: LucideIcons.x,
      label: 'Close',
      size: HollowDialogSurface.isCompact(context) ? 44 : 32,
      onPressed: onPressed ?? () => Navigator.of(context).maybePop(),
    );
  }
}
