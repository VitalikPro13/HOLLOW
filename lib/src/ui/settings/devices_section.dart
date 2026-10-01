import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/roster_provider.dart';
import 'package:hollow/src/rust/api/roster.dart' as roster_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_badge.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:hollow/src/ui/dialogs/device_link_dialog.dart';
import 'package:hollow/src/ui/shell/roster_lock.dart' show rosterDateLabel;
import 'package:hollow/src/ui/settings/device_management_shared.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:hollow/src/ui/settings/sync_check_card.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Settings > Devices: the devices on this identity, linking another, and the
/// sync check and list reset for when devices disagree.
class DevicesCategoryView extends ConsumerStatefulWidget {
  const DevicesCategoryView({super.key});

  @override
  ConsumerState<DevicesCategoryView> createState() =>
      _DevicesCategoryViewState();
}

class _DevicesCategoryViewState extends ConsumerState<DevicesCategoryView> {
  /// Reveals the offline, unlabelled ghosts left by past re-link cycles.
  bool _showAll = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => refreshMyDevices(ref));
  }

  @override
  Widget build(BuildContext context) {
    final devices = ref.watch(myDevicesProvider);
    final ghosts = devices.where((d) => !deviceIsActive(d)).length;
    final shown = _showAll ? devices : devices.where(deviceIsActive).toList();
    final roster = ref.watch(rosterStatusProvider).valueOrNull;
    final waiting = roster?.devices.where((d) => d.state == 'pending').toList() ?? const [];
    final removed = roster?.devices.where((d) => d.state == 'removed').toList() ?? const [];

    return SettingsPage(
      title: 'Devices',
      intro: devices.length <= 1
          ? "Only this device is linked. Link another to sync your messages, "
              "friends and profile."
          : "Every device here reads your messages. Remove one you lost and "
              "it can't any more.",
      children: [
        SettingsSection(
          title: 'Your devices',
          children: [
            for (final d in shown) _DeviceRow(key: ValueKey(d.peerId), device: d),
            if (ghosts > 0)
              Align(
                alignment: Alignment.centerLeft,
                child: HollowButton.ghost(
                  compact: true,
                  onPressed: () => setState(() => _showAll = !_showAll),
                  child: Text(
                      _showAll ? 'Hide old devices' : 'Show all ($ghosts offline)'),
                ),
              ),
            for (final d in waiting) _WaitingDeviceRow(key: ValueKey('waiting-${d.devicePeerId}'), device: d),
            SettingsRow(
              title: 'Link another device',
              subtitle: "Show a code here, type it on the new device. Keep both "
                  "online until it's done.",
              trailing: HollowButton.filled(
                compact: true,
                onPressed: () =>
                    showDeviceLinkDialog(context, mode: DeviceLinkMode.showCode),
                child: const Text('Link a device'),
              ),
            ),
          ],
        ),
        if (removed.isNotEmpty)
          SettingsSection(
            title: 'Removed devices',
            children: [
              for (final d in removed)
                SettingsRow(
                  key: ValueKey('removed-${d.devicePeerId}'),
                  title: _rosterDeviceTitle(ref, d.devicePeerId),
                  subtitle: 'Gets nothing of yours. Only your recovery phrase '
                      'can bring it back.',
                ),
            ],
          ),
        SettingsAdvanced(
          children: [
            const SyncCheckCard(),
            SettingsRow(
              title: 'Reset the device list',
              subtitle: 'Removes every other device. Use it when old '
                  "devices won't go away.",
              trailing: HollowButton.outline(
                danger: true,
                compact: true,
                onPressed: () => resetDeviceListsFlow(context),
                child: const Text('Reset list'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// One device: what it is, its short id and whether it is reachable. Removing
/// a device lives behind More, never a red icon at rest.
class _DeviceRow extends ConsumerWidget {
  final MyDevice device;
  const _DeviceRow({super.key, required this.device});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final buttonSize = SettingsDensity.touchOf(context) ? 44.0 : 32.0;
    return SettingsRow(
      title: deviceTitle(device),
      titleTrailing:
          device.isThisDevice ? const HollowBadge('This device') : null,
      leading: _DeviceKindTile(device: device),
      subtitleWidget: Text.rich(
        TextSpan(children: [
          // An unnamed device is titled by its id already.
          if (device.label.isNotEmpty) ...[
            TextSpan(
              text: shortenPeerId(device.peerId),
              style: HollowTypography.monoSmall
                  .copyWith(color: hollow.textSecondary),
            ),
            const TextSpan(text: ' · '),
          ],
          TextSpan(
            text: device.online ? 'online' : 'offline',
            style: device.online ? TextStyle(color: hollow.success) : null,
          ),
        ]),
      ),
      trailing: device.isThisDevice
          ? HollowIconButton(
              icon: LucideIcons.pencil,
              label: 'Rename this device',
              size: buttonSize,
              onPressed: () => renameDeviceFlow(context, ref, device),
            )
          : Builder(
              builder: (buttonContext) => HollowIconButton(
                icon: LucideIcons.ellipsis,
                label: 'More options for ${deviceTitle(device)}',
                tooltip: 'More',
                size: buttonSize,
                onPressed: () => showHollowMenu(
                  context: buttonContext,
                  anchor: overlayAnchorOf(
                    buttonContext,
                    localOffset: Offset(buttonContext.size?.width ?? 0,
                        (buttonContext.size?.height ?? 0) + HollowSpacing.xs),
                  ),
                  alignEnd: true,
                  builder: (_, _) => [
                    // Pulls FROM that device, which is why ours has no such row.
                    HollowMenuItem(
                      icon: LucideIcons.refreshCw,
                      label: 'Sync servers and friends from this device',
                      enabled: device.online,
                      onTap: () => syncFromDeviceFlow(context, ref, device),
                    ),
                    HollowMenuItem(
                      icon: LucideIcons.pencil,
                      label: 'Rename',
                      onTap: () => renameDeviceFlow(context, ref, device),
                    ),
                    const HollowMenuDivider(),
                    HollowMenuItem(
                      icon: LucideIcons.trash2,
                      label: 'Remove device',
                      isDanger: true,
                      onTap: () => removeDeviceFlow(context, device),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

String _rosterDeviceTitle(WidgetRef ref, String id) {
  final label = ref.watch(deviceLabelProvider)[id];
  return label != null && label.isNotEmpty ? label : shortenPeerId(id);
}

/// A device restored from a backup that asks to join. It joins on its own once
/// seven days pass with nobody refusing it.
class _WaitingDeviceRow extends ConsumerStatefulWidget {
  final roster_api.RosterDevice device;
  const _WaitingDeviceRow({super.key, required this.device});

  @override
  ConsumerState<_WaitingDeviceRow> createState() => _WaitingDeviceRowState();
}

class _WaitingDeviceRowState extends ConsumerState<_WaitingDeviceRow> {
  bool? _approving;

  Future<void> _answer(bool approve) async {
    setState(() => _approving = approve);
    try {
      final id = widget.device.devicePeerId;
      await (approve
          ? roster_api.approveDevice(devicePeerId: id)
          : roster_api.refuseDevice(devicePeerId: id));
      ref.read(pendingDeviceAsksProvider.notifier).answered(id);
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, friendlyError(e), type: HollowToastType.error);
      }
    } finally {
      if (mounted) setState(() => _approving = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final seen = widget.device.firstSeenMs;
    final joins = seen == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(seen.toInt()).add(const Duration(days: 7));
    return SettingsRow(
      title: _rosterDeviceTitle(ref, widget.device.devicePeerId),
      titleTrailing: const HollowBadge('Waiting'),
      leading: const _KindTile(LucideIcons.monitorSmartphone),
      subtitle: joins == null
          ? 'Restored from a backup. It asks to join your identity.'
          : 'Restored from a backup. It joins on ${rosterDateLabel(context, joins)} '
              'unless you refuse it.',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          HollowButton.ghost(
            compact: true,
            onPressed: _approving != null ? null : () => _answer(false),
            loading: _approving == false,
            child: const Text('Refuse'),
          ),
          const SizedBox(width: HollowSpacing.sm),
          HollowButton.outline(
            compact: true,
            onPressed: _approving != null ? null : () => _answer(true),
            loading: _approving == true,
            child: const Text('Approve'),
          ),
        ],
      ),
    );
  }
}

/// The device-kind tile. Only the running device knows its own kind; a
/// sibling's is not carried in the device list, so it takes the generic mark.
class _DeviceKindTile extends StatelessWidget {
  final MyDevice device;
  const _DeviceKindTile({required this.device});

  @override
  Widget build(BuildContext context) {
    final IconData icon;
    if (!device.isThisDevice) {
      icon = LucideIcons.monitorSmartphone;
    } else if (Platform.isAndroid || Platform.isIOS) {
      icon = LucideIcons.smartphone;
    } else {
      icon = LucideIcons.monitor;
    }
    return _KindTile(icon);
  }
}

class _KindTile extends StatelessWidget {
  final IconData icon;
  const _KindTile(this.icon);

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: hollow.elevated,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
      ),
      child: Icon(icon, size: 16, color: hollow.textSecondary),
    );
  }
}
