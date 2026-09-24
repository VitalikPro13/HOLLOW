import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';

/// The last software keyboard height seen this run, so a panel opened in a
/// fresh chat already matches it.
double? _lastKeyboardHeight;

@visibleForTesting
void debugForgetKeyboardHeight() => _lastKeyboardHeight = null;

/// Share of the screen a panel takes before any keyboard has been seen.
const double _kDefaultPanelShare = 0.4;

/// While the panel's own search field has the keyboard up, the panel keeps at
/// most this share of the space above the keyboard.
const double _kSearchPanelShare = 0.45;

/// How long a closing panel waits for the keyboard to cover it. A hardware
/// keyboard never raises one, so the panel must give up on its own.
const Duration _kYieldTimeout = Duration(milliseconds: 700);

/// The space under a phone composer: the software keyboard's inset, or a panel
/// that takes the keyboard's place (the emoji, GIF and sticker picker).
///
/// The host Scaffold must set `resizeToAvoidBottomInset: false` and its
/// SafeArea `bottom: false`; this widget accounts for both, so the composer
/// stays put while the keyboard and the panel swap under it. A panel that
/// closes while [keyboardFocus] has focus stays up until the rising keyboard
/// covers it.
class MobileKeyboardPanelDock extends StatefulWidget {
  const MobileKeyboardPanelDock({
    super.key,
    required this.open,
    required this.keyboardFocus,
    required this.panelBuilder,
  });

  final bool open;
  final FocusNode keyboardFocus;
  final WidgetBuilder panelBuilder;

  @override
  State<MobileKeyboardPanelDock> createState() =>
      _MobileKeyboardPanelDockState();
}

class _MobileKeyboardPanelDockState extends State<MobileKeyboardPanelDock> {
  final FocusScopeNode _panelScope =
      FocusScopeNode(debugLabel: 'Keyboard panel');
  double _sessionPeak = 0;
  double? _yieldHeight;
  Timer? _yieldTimer;
  double _panelHeight = 0;

  @override
  void didUpdateWidget(MobileKeyboardPanelDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.open && !widget.open && widget.keyboardFocus.hasFocus) {
      _yieldHeight = _panelHeight;
      _yieldTimer?.cancel();
      _yieldTimer = Timer(_kYieldTimeout, _endYield);
    } else if (widget.open) {
      // Rebuilding already: drop the yield without asking for another build.
      _yieldTimer?.cancel();
      _yieldTimer = null;
      _yieldHeight = null;
    }
  }

  @override
  void dispose() {
    _yieldTimer?.cancel();
    _panelScope.dispose();
    super.dispose();
  }

  void _endYield() {
    _yieldTimer?.cancel();
    _yieldTimer = null;
    if (_yieldHeight == null || !mounted) return;
    setState(() => _yieldHeight = null);
  }

  void _trackKeyboard(double inset) {
    if (inset <= 0) {
      _sessionPeak = 0;
      return;
    }
    if (inset > _sessionPeak) {
      _sessionPeak = inset;
      _lastKeyboardHeight = inset;
    }
  }

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final homeIndicator = MediaQuery.viewPaddingOf(context).bottom;
    final screenHeight = MediaQuery.sizeOf(context).height;
    _trackKeyboard(inset);

    final stored =
        _lastKeyboardHeight ?? screenHeight * _kDefaultPanelShare;
    double? panel;
    var spacer = 0.0;
    var padHome = true;
    final yieldHeight = _yieldHeight;
    if (widget.open && _panelScope.hasFocus && inset > 0) {
      // The panel's own search raised the keyboard: sit above it, smaller.
      panel = math.min(stored, (screenHeight - inset) * _kSearchPanelShare);
      spacer = inset;
      padHome = false;
    } else if (widget.open) {
      panel = math.max(stored, inset);
    } else if (yieldHeight != null) {
      panel = math.max(yieldHeight, inset + safeBottom);
      if (inset >= yieldHeight - 1) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _endYield());
      }
    } else {
      spacer = inset + safeBottom;
    }
    if (panel != null) _panelHeight = panel;

    final hollow = HollowTheme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (panel != null)
          SizedBox(
            height: panel,
            // On the composer's own surface, with no scrim: it replaces the
            // keyboard rather than floating over the chat.
            child: ColoredBox(
              color: hollow.surface,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const HollowDivider(),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(
                        bottom: padHome ? homeIndicator : 0,
                      ),
                      child: FocusScope(
                        node: _panelScope,
                        child: Builder(builder: widget.panelBuilder),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        SizedBox(height: spacer),
      ],
    );
  }
}
