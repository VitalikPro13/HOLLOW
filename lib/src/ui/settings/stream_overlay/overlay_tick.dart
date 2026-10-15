import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/blocked_users_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/overlay_settings_provider.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The words on the tick, everywhere it shows.
const String kOverlayTickLabel = 'Show on my stream overlay';

/// Whether the tick shows for [peerId], and whether that person is on our
/// overlay. Never for ourselves, a blocked person, or someone whose "Let others
/// show me" is off. [watch] is a `ref.watch` (or `ref.read` for a one-off).
({bool show, bool added}) overlayTickState(
    T Function<T>(ProviderListenable<T>) watch, String peerId) {
  final master = watch(deviceLinkProvider).identityOf(peerId);
  final me = watch(identityProvider).peerId;
  if (master.isEmpty || master == me) return (show: false, added: false);
  if (watch(blockedUsersProvider).contains(master)) {
    return (show: false, added: false);
  }
  if (watch(overlayFieldProvider(master)) == 'off') {
    return (show: false, added: false);
  }
  final people = watch(overlayPeopleProvider).valueOrNull ?? const [];
  return (show: true, added: people.any((p) => p.master == master));
}

/// Adds or removes [peerId]; a person we picked images for is removed only
/// after a confirm, since the picks go with them.
Future<void> toggleOverlayPerson(
  BuildContext context,
  WidgetRef ref, {
  required String peerId,
  required String name,
}) async {
  final master = ref.read(deviceLinkProvider).identityOf(peerId);
  final people = ref.read(overlayPeopleProvider).valueOrNull ?? const [];
  final existing = people.where((p) => p.master == master).firstOrNull;
  final notifier = ref.read(overlayPeopleProvider.notifier);
  if (existing != null && existing.hasOwnPicks) {
    await showHollowConfirm(
      context: context,
      title: 'Remove $name from your overlay?',
      message: 'The images you picked for them are deleted too.',
      confirmLabel: 'Remove',
      destructive: true,
      onConfirm: () => notifier.remove(master),
    );
    return;
  }
  try {
    if (existing != null) {
      await notifier.remove(master);
    } else {
      await notifier.add(master);
      if (context.mounted) {
        HollowToast.show(context, '$name is on your stream overlay',
            type: HollowToastType.success);
      }
    }
  } catch (e) {
    if (!context.mounted) return;
    HollowToast.show(
        context,
        friendlyError(e,
            fallback: existing != null
                ? "Couldn't take them off your overlay. Try again."
                : "Couldn't add them to your overlay. Try again."),
        type: HollowToastType.error);
  }
}

/// The tick as a menu row, or null where it must not show. [menuRef] watches
/// for display; [ref] (the caller's) runs the action after the menu closes.
HollowMenuItem? overlayTickMenuItem({
  required BuildContext context,
  required WidgetRef menuRef,
  required WidgetRef ref,
  required String peerId,
  required String name,
}) {
  final tick = overlayTickState(menuRef.watch, peerId);
  if (!tick.show) return null;
  return HollowMenuItem(
    icon: LucideIcons.cast,
    label: kOverlayTickLabel,
    isChecked: tick.added,
    onTap: () => toggleOverlayPerson(context, ref, peerId: peerId, name: name),
  );
}
