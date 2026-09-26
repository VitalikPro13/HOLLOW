import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/layout_prefs_provider.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/components/panel_resize_handle.dart';

/// Narrowest the stage gets while the panel beside it grows. The call bar
/// scales down to fit, but the tiles stop being readable below this.
const double kCallStageMinWidth = 360;

/// A call stage with its one side panel (a DM call's or a voice room's chat, a
/// meeting's chat or people), sized by the seam on the panel's left edge.
class CallStageWithPanel extends ConsumerWidget {
  final Widget stage;

  /// Null shows the stage alone.
  final Widget? panel;

  const CallStageWithPanel({super.key, required this.stage, this.panel});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final panel = this.panel;
    if (panel == null) return stage;
    final hollow = HollowTheme.of(context);
    final saved = ref.watch(callSidePanelWidthProvider);
    return LayoutBuilder(builder: (context, constraints) {
      // The saved width yields to the stage on a small window rather than
      // squeezing the tiles; it is kept, and comes back when the window grows.
      final roomy = constraints.maxWidth - kCallStageMinWidth - kPanelSeamWidth;
      final maxWidth = math.max(kCallSidePanelWidthMin, roomy);
      final width = math.min(saved, maxWidth);
      final notifier = ref.read(callSidePanelWidthProvider.notifier);
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: stage),
          PanelResizeHandle(
            label: 'Resize the side panel',
            panelOnRight: true,
            width: width,
            // Clamped to what fits, so a drag past the edge never banks width
            // the next drag back has to unwind first.
            onResize: (w) => notifier.setWidth(math.min(w, maxWidth)),
            onReset: notifier.reset,
          ),
          // The seam paints the divider on this edge.
          SizedBox(
            width: width,
            child: ColoredBox(color: hollow.surface, child: panel),
          ),
        ],
      );
    });
  }
}
