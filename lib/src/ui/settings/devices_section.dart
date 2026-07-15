import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/dialogs/device_link_dialog.dart';
import 'package:hollow/src/ui/settings/device_management_shared.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Devices category — the "Your Devices" list + multi-device link/reset tools.
/// Split out of the old Security tab so device management has its own home.
class DevicesCategoryView extends StatelessWidget {
  const DevicesCategoryView({super.key});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SettingsCard(
            title: 'Your Devices',
            children: [
              DevicesListSection(
                infoStyle: (hollow) => HollowTypography.caption
                    .copyWith(color: hollow.textSecondary),
                rowBuilder: (d) => _DeviceRow(device: d),
              ),
            ],
          ),
          const SizedBox(height: HollowSpacing.lg),
          SettingsCard(
            title: 'Link a Device',
            children: [
              Text(
                'Link another device to this identity. Show a code here, then '
                'enter it on your other (empty) device to copy your messages, '
                'friends and profile across. Keep both devices online during '
                'the transfer.',
                style: HollowTypography.caption
                    .copyWith(color: hollow.textSecondary),
              ),
              const SizedBox(height: HollowSpacing.sm),
              HollowButton.filled(
                onPressed: () => showDeviceLinkDialog(context,
                    mode: DeviceLinkMode.showCode),
                icon: const Icon(LucideIcons.smartphone, size: 16),
                child: const Text('Link a device'),
              ),
            ],
          ),
          const SizedBox(height: HollowSpacing.lg),
          SettingsCard(
            title: 'Maintenance',
            children: [
              Text(
                'If leftover or ghost devices still show as linked, reset the '
                'device list. This permanently removes ALL your other devices '
                '(they get signed out and your friends drop them); only this '
                'device remains. Re-link any device you still want.',
                style: HollowTypography.caption
                    .copyWith(color: hollow.textSecondary),
              ),
              const SizedBox(height: HollowSpacing.sm),
              HollowButton.outline(
                onPressed: () => resetDeviceListsFlow(context),
                icon: const Icon(LucideIcons.refreshCw, size: 16),
                child: const Text('Reset Device List'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Desktop device row — the shared shell plus ghost-button actions.
class _DeviceRow extends ConsumerWidget {
  final MyDevice device;
  const _DeviceRow({required this.device});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    return DeviceRowShell(
      device: device,
      actions: [
        // Sync FROM this device (pull servers + friends). Other devices only.
        if (!device.isThisDevice)
          HollowTooltip(
            message: 'Sync servers & friends from this device',
            child: HollowButton.ghost(
              compact: true,
              onPressed: () => syncFromDeviceFlow(context, ref, device),
              semanticLabel: 'Sync servers & friends from this device',
              icon: Icon(LucideIcons.refreshCw, size: 15,
                  color: device.online ? hollow.accent : hollow.textSecondary),
              child: const SizedBox.shrink(),
            ),
          ),
        // Rename (any device).
        HollowButton.ghost(
          compact: true,
          onPressed: () => renameDeviceFlow(context, ref, device),
          semanticLabel: 'Rename device',
          icon: const Icon(LucideIcons.pencil, size: 15),
          child: const SizedBox.shrink(),
        ),
        // Remove — hidden for the device we're running on (can't revoke self).
        if (!device.isThisDevice)
          HollowButton.ghost(
            compact: true,
            onPressed: () => removeDeviceFlow(context, device),
            semanticLabel: 'Remove device',
            icon: Icon(LucideIcons.trash2, size: 15, color: hollow.error),
            child: const SizedBox.shrink(),
          ),
      ],
    );
  }
}
