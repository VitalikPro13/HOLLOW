import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

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
  if (saved == true) {
    await ref
        .read(deviceLabelProvider.notifier)
        .setLabel(device.peerId, controller.text.trim());
  }
}

/// Confirms, then pulls servers and friends FROM an online sibling onto this
/// device.
Future<void> syncFromDeviceFlow(
    BuildContext context, WidgetRef ref, MyDevice device) async {
  final name = deviceTitle(device);
  final confirmed = await showHollowDialog<bool>(
    context: context,
    builder: (ctx) => HollowDialog(
      title: 'Sync from this device?',
      content: Text(
        'Pull servers and friends FROM "$name" onto THIS device. Use this if a '
        'server or friend exists on "$name" but is missing here. It only adds '
        'what\'s missing. Nothing is removed, and your messages are unaffected.\n\n'
        '"$name" must be online.',
        style: HollowTypography.body
            .copyWith(color: HollowTheme.of(ctx).textSecondary),
      ),
      actions: [
        HollowButton.ghost(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Sync now'),
        ),
      ],
    ),
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
  final confirmed = await showHollowDialog<bool>(
    context: context,
    builder: (ctx) => HollowDialog(
      title: 'Remove this device?',
      content: Text(
        'This permanently removes "$name" '
        'from your identity. It will stop receiving your messages and is removed '
        'from your servers. This cannot be undone from the removed device.',
        style: HollowTypography.body
            .copyWith(color: HollowTheme.of(ctx).textSecondary),
      ),
      actions: [
        HollowButton.ghost(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        HollowButton.danger(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Remove device'),
        ),
      ],
    ),
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
  final confirmed = await showHollowDialog<bool>(
    context: context,
    builder: (ctx) => HollowDialog(
      title: 'Reset device list?',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This permanently removes ALL your other linked devices, not just '
            'this one. Each is signed out and wiped, and your friends stop '
            'seeing them. Only this device stays. To use another device again, '
            'link it fresh.\n\nUse this to clean up leftover or ghost devices.',
            style: HollowTypography.body
                .copyWith(color: HollowTheme.of(ctx).textSecondary),
          ),
          const SizedBox(height: HollowSpacing.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              HollowButton.ghost(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: HollowSpacing.sm),
              HollowButton.danger(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Reset'),
              ),
            ],
          ),
        ],
      ),
    ),
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

/// The "This device" badge.
class DeviceBadge extends StatelessWidget {
  final String text;
  final Color color;
  const DeviceBadge({super.key, required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: HollowTypography.caption.copyWith(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Row shell for a device entry, with the surface-specific action buttons
/// appended at the end.
class DeviceRowShell extends StatelessWidget {
  final MyDevice device;
  final List<Widget> actions;

  const DeviceRowShell({
    super.key,
    required this.device,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final title = deviceTitle(device);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.md,
        vertical: HollowSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: hollow.surface,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(color: hollow.border.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.smartphone, size: 18, color: hollow.textSecondary),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        overflow: TextOverflow.ellipsis,
                        style: HollowTypography.body.copyWith(
                            color: hollow.textPrimary,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (device.isThisDevice) ...[
                      const SizedBox(width: HollowSpacing.xs),
                      DeviceBadge(text: 'This device', color: hollow.accent),
                    ],
                  ],
                ),
                Text(
                  '${shortenPeerId(device.peerId)} · ${device.online ? "online" : "offline"}',
                  style: HollowTypography.caption
                      .copyWith(color: hollow.textSecondary),
                ),
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

/// The "Your Devices" list. Stateful for the "Show all" toggle that reveals
/// offline, unlabelled ghost devices.
class DevicesListSection extends ConsumerStatefulWidget {
  final TextStyle Function(HollowTheme hollow) infoStyle;
  final Widget Function(MyDevice device) rowBuilder;

  const DevicesListSection({
    super.key,
    required this.infoStyle,
    required this.rowBuilder,
  });

  @override
  ConsumerState<DevicesListSection> createState() =>
      _DevicesListSectionState();
}

class _DevicesListSectionState extends ConsumerState<DevicesListSection> {
  bool _showAll = false;

  @override
  void initState() {
    super.initState();
    // Re-pull from the running node's resolver on open: the startup warm-up
    // races node readiness and nothing keeps the provider fresh while Settings
    // is closed, so the list renders stale after a restart.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(deviceLinkProvider.notifier).refresh();
      ref.read(deviceLabelProvider.notifier).refresh();
      ref.invalidate(localDevicePeerIdProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final devices = ref.watch(myDevicesProvider);

    if (devices.length <= 1) {
      return Text(
        'Only this device is linked to your identity. Link another below to sync '
        'your messages, friends and profile across devices.',
        style: widget.infoStyle(hollow),
      );
    }

    final ghosts = devices.where((d) => !deviceIsActive(d)).toList();
    final shown =
        _showAll ? devices : devices.where(deviceIsActive).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Devices linked to your identity. Remove a device you no longer use or '
          'have lost. It can no longer read your messages once removed.',
          style: widget.infoStyle(hollow),
        ),
        const SizedBox(height: HollowSpacing.sm),
        for (final d in shown)
          Padding(
            padding: const EdgeInsets.only(bottom: HollowSpacing.sm),
            child: widget.rowBuilder(d),
          ),
        if (ghosts.isNotEmpty)
          HollowButton.ghost(
            compact: true,
            onPressed: () => setState(() => _showAll = !_showAll),
            child: Text(_showAll
                ? 'Hide old devices'
                : 'Show all (${ghosts.length} offline)'),
          ),
      ],
    );
  }
}
