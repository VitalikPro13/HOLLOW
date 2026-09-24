import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';

/// Multi-device management shared by the desktop Devices category and the
/// mobile Settings tab. The two surfaces differ only in text styling and row
/// action buttons, which are passed in.

/// Whether a device is worth showing by default: online, ourselves, or
/// labelled. Ghosts from past re-link cycles are offline and unlabelled, and
/// fold behind "Show all".
bool deviceIsActive(MyDevice d) =>
    d.online || d.isThisDevice || d.label.isNotEmpty;

/// The device's label, or its shortened peer id when it has none.
String deviceTitle(MyDevice d) =>
    d.label.isNotEmpty ? d.label : shortenPeerId(d.peerId);

/// Re-pulls the device list from the running node. Call on open: the startup
/// warm-up races node readiness and nothing keeps the list fresh while
/// Settings is closed, so it renders stale after a restart.
void refreshMyDevices(WidgetRef ref) {
  ref.read(deviceLinkProvider.notifier).refresh();
  ref.read(deviceLabelProvider.notifier).refresh();
  ref.invalidate(localDevicePeerIdProvider);
}

/// Label edit dialog, persisted through [deviceLabelProvider].
Future<void> renameDeviceFlow(
    BuildContext context, WidgetRef ref, MyDevice device) async {
  final controller = TextEditingController(text: device.label);
  final saved = await showHollowDialog<bool>(
    context: context,
    builder: (ctx) => HollowDialog(
      title: 'Rename device',
      content: HollowTextField(
        controller: controller,
        hintText: "e.g. My Pixel",
        autofocus: true,
      ),
      actions: [
        HollowButton.ghost(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  if (saved != true) return;
  try {
    await ref
        .read(deviceLabelProvider.notifier)
        .setLabel(device.peerId, controller.text.trim());
  } catch (e) {
    if (context.mounted) {
      HollowToast.show(context, 'Could not rename the device: $e',
          type: HollowToastType.error);
    }
  }
}

/// Confirms, then pulls servers and friends FROM an online sibling onto this
/// device.
Future<void> syncFromDeviceFlow(
    BuildContext context, WidgetRef ref, MyDevice device) async {
  final name = deviceTitle(device);
  final confirmed = await showHollowConfirm(
    context: context,
    title: 'Sync from this device?',
    message:
        'Pull servers and friends FROM "$name" onto THIS device. Use this if a '
        'server or friend exists on "$name" but is missing here. It only adds '
        'what\'s missing. Nothing is removed, and your messages are unaffected.\n\n'
        '"$name" must be online.',
    confirmLabel: 'Sync now',
  );
  if (confirmed != true) return;
  if (!device.online) {
    if (context.mounted) {
      HollowToast.show(context, '"$name" is offline. Bring it online first',
          type: HollowToastType.error);
    }
    return;
  }
  try {
    await network_api.requestStateSync(sourceDeviceId: device.peerId);
    if (context.mounted) {
      HollowToast.show(context, 'Syncing from "$name"…',
          type: HollowToastType.info);
    }
  } catch (e) {
    if (context.mounted) {
      HollowToast.show(context, 'Sync failed: $e', type: HollowToastType.error);
    }
  }
}

/// Confirms, then permanently revokes the device.
Future<void> removeDeviceFlow(BuildContext context, MyDevice device) async {
  final name = deviceTitle(device);
  final confirmed = await showHollowConfirm(
    context: context,
    title: 'Remove this device?',
    message: 'This permanently removes "$name" '
        'from your identity. It will stop receiving your messages and is removed '
        'from your servers. This cannot be undone from the removed device.',
    confirmLabel: 'Remove device',
    destructive: true,
  );
  if (confirmed != true) return;
  try {
    await network_api.revokeDevice(devicePeerId: device.peerId);
    if (context.mounted) {
      HollowToast.show(context, 'Device removed', type: HollowToastType.success);
    }
  } catch (e) {
    if (context.mounted) {
      HollowToast.show(context, 'Failed to remove: $e',
          type: HollowToastType.error);
    }
  }
}

/// Confirms, then drops ALL other linked devices.
Future<void> resetDeviceListsFlow(BuildContext context) async {
  final confirmed = await showHollowConfirm(
    context: context,
    title: 'Reset device list?',
    message:
        'This permanently removes ALL your other linked devices, not just '
        'this one. Each is signed out and wiped, and your friends stop '
        'seeing them. Only this device stays. To use another device again, '
        'link it fresh.\n\nUse this to clean up leftover or ghost devices.',
    confirmLabel: 'Reset',
    destructive: true,
  );
  if (confirmed != true) return;
  try {
    await network_api.resetDeviceLists();
    if (context.mounted) {
      HollowToast.show(
        context,
        'Device list reset. All other devices were removed.',
        type: HollowToastType.success,
      );
    }
  } catch (e) {
    if (context.mounted) {
      HollowToast.show(context, 'Reset failed: $e',
          type: HollowToastType.error);
    }
  }
}
