import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/overlay_runtime_provider.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';

/// What the OBS section and the toast say when the overlay had to move.
const String kOverlayPortMovedText =
    'The overlay moved to a new port because the old one was busy. Copy the '
    'new link into OBS.';

/// Toasts once when the overlay server had to take a new port, wherever the
/// app is: OBS shows nothing until the new link is pasted. Call from a
/// long-lived widget's build.
void listenOverlayPortChanged(WidgetRef ref, BuildContext context) {
  ref.listen<int?>(overlayPortChangedProvider, (before, port) {
    if (port == null || port == before || !context.mounted) return;
    HollowToast.show(context, kOverlayPortMovedText,
        type: HollowToastType.info);
  });
}
