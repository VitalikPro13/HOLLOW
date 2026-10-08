import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/roster_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/roster.dart' as roster_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';

/// Multi-device management shared by the desktop Devices category and the
/// mobile Settings tab. The two surfaces differ only in text styling and row
/// action buttons, which are passed in.

/// Whether a device is worth showing by default: online, ourselves, or
/// labelled. Ghosts from past re-link cycles are offline and unlabelled, and
/// fold behind "Show all".
bool deviceIsActive(MyDevice d) =>
    d.online || d.isThisDevice || d.label.isNotEmpty;

/// The device's label, else "Desktop" or "Phone", else its shortened peer id.
String deviceTitle(MyDevice d) => d.label.isNotEmpty
    ? d.label
    : deviceKindName(d.kind) ?? shortenPeerId(d.peerId);

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

String _removalMessage(String name) =>
    '"$name" stops getting your messages at once and is taken off your '
    'servers. It locks, and erases itself in three days unless your recovery '
    'phrase is typed on it.';

/// Confirms, then removes the device from our roster. The devices it added stay
/// unless the person removes them too (C-IDENTITY-09), so the dialog lists them.
Future<void> removeDeviceFlow(
    BuildContext context, WidgetRef ref, MyDevice device) async {
  final name = deviceTitle(device);
  roster_api.RosterStatus? roster;
  try {
    roster = await ref.read(rosterStatusProvider.future);
  } catch (_) {
    // Unread, the plain confirm still removes the device and keeps its own.
  }
  if (!context.mounted) return;
  final self = roster?.devices.where((d) => d.thisDevice).firstOrNull;
  final added = <String>[
    for (final d in roster?.devices ?? const <roster_api.RosterDevice>[])
      if (d.devicePeerId == device.peerId) ...d.added,
  ].where((id) => id != self?.devicePeerId).toList();
  if (added.isEmpty) {
    final removed = await showHollowConfirm(
      context: context,
      title: 'Remove "$name"?',
      message: _removalMessage(name),
      confirmLabel: 'Remove device',
      destructive: true,
      onConfirm: () => network_api.revokeDevice(devicePeerId: device.peerId),
    );
    if (!removed || !context.mounted) return;
    HollowToast.show(context, 'Device removed', type: HollowToastType.success);
    return;
  }
  final count = await showHollowDialog<int>(
    context: context,
    builder: (_) => RemoveDeviceDialog(
        name: name, devicePeerId: device.peerId, added: added),
  );
  if (count == null || !context.mounted) return;
  HollowToast.show(
      context, count == 1 ? 'Device removed' : '$count devices removed',
      type: HollowToastType.success);
}

/// Removing a device that added others: they are listed, and they stay unless
/// the person turns on removing them too. Resolves to how many were removed.
class RemoveDeviceDialog extends ConsumerStatefulWidget {
  final String name;
  final String devicePeerId;

  /// The members this device added, this device left out.
  final List<String> added;

  const RemoveDeviceDialog({
    super.key,
    required this.name,
    required this.devicePeerId,
    required this.added,
  });

  @override
  ConsumerState<RemoveDeviceDialog> createState() => _RemoveDeviceDialogState();
}

class _RemoveDeviceDialogState extends ConsumerState<RemoveDeviceDialog>
    with HollowDialogAction {
  bool _removeAdded = false;

  Future<void> _remove() async {
    final also = _removeAdded ? widget.added : const <String>[];
    final ok = await runDialogAction(() async {
      await network_api.revokeDevice(devicePeerId: widget.devicePeerId);
      for (final id in also) {
        await network_api.revokeDevice(devicePeerId: id);
      }
    });
    if (ok && mounted) Navigator.of(context).pop(1 + also.length);
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final labels = ref.watch(deviceLabelProvider);
    final kinds = ref.watch(deviceKindProvider);
    final touch = HollowDialogSurface.isCompact(context);
    final total = 1 + (_removeAdded ? widget.added.length : 0);
    final one = widget.added.length == 1;
    final toggleLabel = one ? 'Remove it too' : 'Remove them too';
    final String note;
    if (_removeAdded) {
      note = one
          ? "It's removed too and locks the same way."
          : "They're removed too and lock the same way.";
    } else {
      note = one
          ? 'It stays and keeps getting your messages.'
          : 'They stay and keep getting your messages.';
    }
    return HollowDialog(
      title: 'Remove "${widget.name}"?',
      width: 420,
      busy: actionRunning,
      error: actionError,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HollowDialogText(_removalMessage(widget.name)),
          const SizedBox(height: HollowSpacing.lg),
          SettingsFieldLabel(
              label: one ? 'It added this device' : 'It added these devices'),
          const SizedBox(height: HollowSpacing.xs),
          for (final id in widget.added)
            HollowListRow(
              key: ValueKey('added-$id'),
              touch: touch,
              title: deviceGivenName(id, labels: labels, kinds: kinds) ??
                  shortenPeerId(id),
              subtitle: shortenPeerId(id),
            ),
          const SizedBox(height: HollowSpacing.md),
          Row(
            children: [
              Expanded(
                child: Text(
                  toggleLabel,
                  style: HollowTypography.label
                      .copyWith(color: hollow.textPrimary),
                ),
              ),
              const SizedBox(width: HollowSpacing.sm),
              HollowToggle(
                value: _removeAdded,
                semanticLabel: toggleLabel,
                onChanged: actionRunning
                    ? null
                    : (v) => setState(() => _removeAdded = v),
              ),
            ],
          ),
          const SizedBox(height: HollowSpacing.xs),
          Text(
            note,
            style:
                HollowTypography.bodySmall.copyWith(color: hollow.textSecondary),
          ),
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: actionRunning ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        HollowButton.danger(
          onPressed: _remove,
          loading: actionRunning,
          child: Text(total == 1 ? 'Remove device' : 'Remove $total devices'),
        ),
      ],
    );
  }
}

/// Confirms, then removes every other device from our roster.
Future<void> resetDeviceListsFlow(BuildContext context) async {
  final reset = await showHollowConfirm(
    context: context,
    title: 'Remove every other device?',
    message: 'Every device except this one stops getting your messages, '
        'locks, and erases itself in three days. To use one again, link it '
        'fresh.',
    confirmLabel: 'Remove other devices',
    destructive: true,
    onConfirm: network_api.resetDeviceLists,
  );
  if (!reset || !context.mounted) return;
  HollowToast.show(context, 'Every other device was removed.',
      type: HollowToastType.success);
}
