import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/ui/components/hollow_dialog.dart';
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
  final notifier = ref.read(deviceLabelProvider.notifier);
  final name = await promptForName(
    context: context,
    title: 'Rename device',
    confirmLabel: 'Rename',
    hintText: 'Device name',
    initial: device.label,
    maxLength: 32,
    onSubmit: (name) => notifier.setLabel(device.peerId, name),
  );
  if (name == null || !context.mounted) return;
  HollowToast.show(context, 'Device renamed', type: HollowToastType.success);
}

/// Pulls servers and friends FROM an online sibling onto this device, after a
/// confirm. An offline device is refused before anything is asked.
Future<void> syncFromDeviceFlow(
    BuildContext context, WidgetRef ref, MyDevice device) async {
  final name = deviceTitle(device);
  if (!device.online) {
    HollowToast.show(context, '"$name" is offline. Bring it online first.',
        type: HollowToastType.error);
    return;
  }
  final confirmed = await showHollowConfirm(
    context: context,
    title: 'Sync from "$name"?',
    message: 'Copies any servers and friends "$name" has that this device is '
        'missing. Nothing is removed, and your messages stay as they are.',
    confirmLabel: 'Sync now',
    onConfirm: () => network_api.requestStateSync(sourceDeviceId: device.peerId),
  );
  if (!confirmed || !context.mounted) return;
  HollowToast.show(context, 'Syncing from "$name". New servers and friends '
      'appear as they arrive.',
      type: HollowToastType.info);
}

/// Confirms, then permanently revokes the device.
Future<void> removeDeviceFlow(BuildContext context, MyDevice device) async {
  final name = deviceTitle(device);
  final removed = await showHollowConfirm(
    context: context,
    title: 'Remove "$name"?',
    message: '"$name" leaves your identity for good. It stops getting your '
        'messages and is taken off your servers.',
    confirmLabel: 'Remove device',
    destructive: true,
    onConfirm: () => network_api.revokeDevice(devicePeerId: device.peerId),
  );
  if (!removed || !context.mounted) return;
  HollowToast.show(context, 'Device removed', type: HollowToastType.success);
}

/// Confirms, then drops ALL other linked devices.
Future<void> resetDeviceListsFlow(BuildContext context) async {
  final reset = await showHollowConfirm(
    context: context,
    title: 'Remove every other device?',
    message: 'Every device except this one is signed out and wiped, and your '
        'friends stop seeing them. To use one again, link it fresh.',
    confirmLabel: 'Remove other devices',
    destructive: true,
    onConfirm: network_api.resetDeviceLists,
  );
  if (!reset || !context.mounted) return;
  HollowToast.show(context, 'Every other device was removed.',
      type: HollowToastType.success);
}
