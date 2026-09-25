import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/member_panel_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/services/notification_permission.dart';
import 'package:hollow/src/core/services/unified_push_service.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:hollow/src/ui/components/server_avatar.dart';
import 'package:hollow/src/ui/settings/channel_override_dropdown.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Settings > Notifications, desktop and phone alike: whether the OS lets
/// Hollow post at all, then every server and every muted conversation.
class NotificationSettingsView extends ConsumerWidget {
  const NotificationSettingsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SettingsPage(
      title: 'Notifications',
      children: [
        const SettingsSection(children: [_SystemPermissionRow()]),
        if (UnifiedPushController.supported) const _PushDeliverySection(),
        const _ServersSection(),
        const _MutedConversationsSection(),
      ],
    );
  }
}

bool get _isPhone => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

String get _platformName {
  if (kIsWeb) return 'your browser';
  if (Platform.isWindows) return 'Windows';
  if (Platform.isMacOS) return 'macOS';
  if (Platform.isLinux) return 'Linux';
  if (Platform.isAndroid) return 'Android';
  if (Platform.isIOS) return 'iOS';
  return 'your system';
}

/// OS permission: one quiet line while allowed, the detail and the ways to
/// fix it when not.
class _SystemPermissionRow extends ConsumerStatefulWidget {
  const _SystemPermissionRow();

  @override
  ConsumerState<_SystemPermissionRow> createState() =>
      _SystemPermissionRowState();
}

class _SystemPermissionRowState extends ConsumerState<_SystemPermissionRow> {
  NotificationPermissionInfo? _info;
  bool _loading = true;

  /// Which button is mid-flight, so the others disable with it.
  String? _busy;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final info = await checkNotificationPermission();
      if (!mounted) return;
      setState(() {
        _info = info;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _info = null;
        _loading = false;
      });
    }
  }

  Future<void> _request() async {
    setState(() => _busy = 'request');
    try {
      final info = await requestNotificationPermission();
      if (!mounted) return;
      setState(() => _info = info);
      final granted = info.state == NotificationPermissionState.granted;
      HollowToast.show(
        context,
        granted
            ? 'Notifications are allowed.'
            : 'Your system did not allow notifications. Open the system '
                'settings to turn them on.',
        type: granted ? HollowToastType.success : HollowToastType.info,
      );
    } catch (e) {
      if (!mounted) return;
      HollowToast.show(
        context,
        friendlyError(e,
            fallback: "Couldn't ask for permission. Try again."),
        type: HollowToastType.error,
      );
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _openSettings() async {
    setState(() => _busy = 'open');
    try {
      final opened = await openSystemNotificationSettings();
      if (!mounted) return;
      if (!opened) {
        HollowToast.show(
          context,
          'Could not open the system notification settings on this device.',
          type: HollowToastType.error,
        );
      }
    } catch (e) {
      if (!mounted) return;
      HollowToast.show(
        context,
        friendlyError(e,
            fallback: "Couldn't open the system notification settings."),
        type: HollowToastType.error,
      );
    } finally {
      if (mounted) setState(() => _busy = null);
      await _refresh();
    }
  }

  Future<void> _sendTest() async {
    setState(() => _busy = 'test');
    try {
      await sendTestNotification();
      if (!mounted) return;
      HollowToast.show(
        context,
        'Test notification sent.',
        type: HollowToastType.success,
      );
    } catch (e) {
      if (!mounted) return;
      HollowToast.show(
        context,
        friendlyError(e,
            fallback: "Couldn't send the test notification. Try again."),
        type: HollowToastType.error,
      );
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    // Permission can change while Settings is open, in the system app the
    // "Open system settings" button just launched.
    ref.listen<bool>(windowFocusedProvider, (prev, next) {
      if (next && prev != true) _refresh();
    });

    final title = _isPhone ? 'Notifications' : 'Desktop notifications';
    final info = _info;
    if (_loading) {
      return SettingsRow(title: title, subtitle: 'Checking with your system…');
    }
    final state = info?.state ?? NotificationPermissionState.unknown;

    if (state == NotificationPermissionState.granted) {
      return SettingsRow(
        title: title,
        subtitleWidget: Text.rich(TextSpan(children: [
          TextSpan(text: 'Allowed', style: TextStyle(color: hollow.success)),
          TextSpan(text: ' by $_platformName'),
        ])),
        trailing: HollowButton.ghost(
          compact: true,
          onPressed: _busy != null ? null : _sendTest,
          loading: _busy == 'test',
          child: const Text('Send a test'),
        ),
      );
    }

    final blocked = state == NotificationPermissionState.denied;
    final detail = info?.detail ??
        'Hollow could not read the notification permission on this device.';
    final canRequest = info != null && info.canRequest;
    final canOpen = info != null && info.canOpenSettings;
    return SettingsRow(
      title: title,
      subtitleWidget: Text.rich(TextSpan(children: [
        TextSpan(
          text: blocked ? 'Blocked' : 'Unknown',
          style: TextStyle(color: blocked ? hollow.error : hollow.warning),
        ),
        TextSpan(text: '. $detail'),
      ])),
      wideTrailing: true,
      trailing: !canRequest && !canOpen
          ? null
          : Wrap(
              spacing: HollowSpacing.sm,
              runSpacing: HollowSpacing.sm,
              children: [
                if (canRequest)
                  HollowButton.filled(
                    compact: true,
                    onPressed: _busy != null ? null : _request,
                    loading: _busy == 'request',
                    child: const Text('Request permission'),
                  ),
                if (canOpen)
                  HollowButton.ghost(
                    compact: true,
                    onPressed: _busy != null ? null : _openSettings,
                    loading: _busy == 'open',
                    child: const Text('Open system settings'),
                  ),
              ],
            ),
    );
  }
}

/// Android: which push service wakes the phone, Google's or a UnifiedPush
/// distributor the user installed.
class _PushDeliverySection extends ConsumerStatefulWidget {
  const _PushDeliverySection();

  @override
  ConsumerState<_PushDeliverySection> createState() =>
      _PushDeliverySectionState();
}

class _PushDeliverySectionState extends ConsumerState<_PushDeliverySection> {
  static const _google = '';

  List<String> _distributors = const [];

  /// The choice mid-switch, so every chip waits for it.
  String? _busy;

  UnifiedPushController get _controller => UnifiedPushController.instance;

  @override
  void initState() {
    super.initState();
    _loadDistributors();
  }

  Future<void> _loadDistributors() async {
    try {
      final found = await _controller.distributors();
      if (mounted) setState(() => _distributors = found);
    } catch (_) {}
  }

  Future<void> _choose(String choice) async {
    if (_busy != null) return;
    setState(() => _busy = choice);
    try {
      if (choice == _google) {
        await _controller.useFirebase();
      } else {
        await _controller.use(choice);
      }
    } catch (e) {
      if (!mounted) return;
      HollowToast.show(
        context,
        friendlyError(e,
            fallback: "Couldn't switch the push service. Try again."),
        type: HollowToastType.error,
      );
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    // Someone installs ntfy in another app and comes back.
    ref.listen<bool>(windowFocusedProvider, (prev, next) {
      if (next && prev != true) _loadDistributors();
    });

    return ValueListenableBuilder<UnifiedPushStatus>(
      valueListenable: _controller.status,
      builder: (context, status, _) {
        final selected = status.phase == UnifiedPushPhase.off
            ? _google
            : status.distributor ?? _google;
        final failed = status.phase == UnifiedPushPhase.failed;
        return SettingsSection(
          title: 'Push delivery',
          subtitle: 'Wakes this phone for messages while Hollow is closed. '
              'Messages stay encrypted either way.',
          children: [
            SettingsRow(
              title: 'Wake-up service',
              subtitleWidget: Text(
                _busy != null
                    ? 'Switching…'
                    : _statusText(status, _distributors.isEmpty),
                style: failed ? TextStyle(color: hollow.error) : null,
              ),
              wideTrailing: true,
              trailing: Wrap(
                spacing: HollowSpacing.sm,
                runSpacing: HollowSpacing.sm,
                children: [
                  HollowChip(
                    label: 'Google',
                    selected: selected == _google,
                    onTap: () => _choose(_google),
                  ),
                  for (final d in _distributors)
                    HollowChip(
                      label: distributorLabel(d),
                      selected: selected == d,
                      onTap: () => _choose(d),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  static String _statusText(UnifiedPushStatus status, bool noneInstalled) {
    final name = distributorLabel(status.distributor ?? '');
    return switch (status.phase) {
      UnifiedPushPhase.off => noneInstalled
          ? 'Wake-ups come through Google. To use another service, install '
              'a UnifiedPush app such as ntfy, then pick it here.'
          : 'Wake-ups come through Google.',
      UnifiedPushPhase.registering => 'Connecting to $name…',
      UnifiedPushPhase.active => 'Wake-ups come through $name.',
      UnifiedPushPhase.failed => switch (status.failure) {
          FailedReason.network =>
            '$name could not connect. Google wakes the phone until it does. '
                'Pick it again once it is online.',
          FailedReason.actionRequired =>
            '$name needs you to open it first. Google wakes the phone until '
                'then.',
          FailedReason.vapidRequired =>
            '$name asks for a server key Hollow does not send yet. Google '
                'wakes the phone instead.',
          _ => '$name did not work with Hollow. Google wakes the phone '
              'instead.',
        },
    };
  }
}

/// Every joined server with its level, each expandable to its channels.
class _ServersSection extends ConsumerWidget {
  const _ServersSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final servers = ref.watch(serverListProvider).values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return SettingsSection(
      title: 'Servers',
      children: [
        if (servers.isEmpty)
          const HollowEmptyState(
              dense: true, title: "You haven't joined a server yet")
        else
          for (final server in servers)
            _ServerNotificationRow(
              key: ValueKey(server.serverId),
              serverId: server.serverId,
              name: server.name,
            ),
      ],
    );
  }
}

const _levelLabels = {
  NotificationLevel.all: 'All messages',
  NotificationLevel.mentions: 'Mentions only',
  NotificationLevel.nothing: 'Nothing',
};

class _ServerNotificationRow extends ConsumerStatefulWidget {
  final String serverId;
  final String name;

  const _ServerNotificationRow({
    super.key,
    required this.serverId,
    required this.name,
  });

  @override
  ConsumerState<_ServerNotificationRow> createState() =>
      _ServerNotificationRowState();
}

class _ServerNotificationRowState
    extends ConsumerState<_ServerNotificationRow> {
  bool _expanded = false;

  Future<void> _setLevel(NotificationLevel level) async {
    try {
      await ref
          .read(notificationSettingsProvider.notifier)
          .setServerLevel(widget.serverId, level);
    } catch (e) {
      if (!mounted) return;
      HollowToast.show(
        context,
        friendlyError(e,
            fallback: "Couldn't save the notification level. Try again."),
        type: HollowToastType.error,
      );
    }
  }

  Future<void> _setOverride(
      String channelId, ChannelNotificationLevel level) async {
    try {
      await ref
          .read(notificationSettingsProvider.notifier)
          .setChannelOverride(widget.serverId, channelId, level);
    } catch (e) {
      if (!mounted) return;
      HollowToast.show(
        context,
        friendlyError(e,
            fallback: "Couldn't save the channel setting. Try again."),
        type: HollowToastType.error,
      );
    }
  }

  void _openLevelMenu(BuildContext chipContext, NotificationLevel level) {
    showHollowMenu(
      context: chipContext,
      // The chip sits at the row's trailing edge, so the menu opens
      // right-aligned under it rather than over the next panel.
      alignEnd: true,
      anchor: overlayAnchorOf(chipContext,
          localOffset: Offset(chipContext.size?.width ?? 0,
              (chipContext.size?.height ?? 0) + HollowSpacing.xs)),
      builder: (_, _) => [
        for (final entry in _levelLabels.entries)
          HollowMenuItem(
            label: entry.value,
            isChecked: entry.key == level,
            onTap: () => _setLevel(entry.key),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final touch = SettingsDensity.touchOf(context);
    final notif = ref.watch(notificationSettingsProvider);
    final level = notif.serverLevels[widget.serverId] ?? NotificationLevel.all;
    final levelLabel = _levelLabels[level]!;
    final overrides = notif.channelOverrides.keys
        .where((k) => k.startsWith('${widget.serverId}:'))
        .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SettingsRow(
          leading: ServerAvatar(
              serverId: widget.serverId, name: widget.name, size: 32),
          title: widget.name,
          subtitle: switch (overrides) {
            0 => null,
            1 => '1 channel set differently',
            _ => '$overrides channels set differently',
          },
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Builder(
                builder: (chipContext) => HollowChip(
                  label: levelLabel,
                  trailingIcon: LucideIcons.chevronDown,
                  semanticLabel:
                      'Notifications for ${widget.name}, $levelLabel',
                  onTap: () => _openLevelMenu(chipContext, level),
                ),
              ),
              const SizedBox(width: HollowSpacing.xs),
              HollowIconButton(
                icon: _expanded
                    ? LucideIcons.chevronUp
                    : LucideIcons.chevronDown,
                label: 'Channels in ${widget.name}',
                size: touch ? 44 : 32,
                selected: _expanded,
                onPressed: () => setState(() => _expanded = !_expanded),
              ),
            ],
          ),
        ),
        // Opening a list is switching what the region shows: instant.
        if (_expanded)
          Padding(
            // Under the name, past the server's avatar.
            padding: const EdgeInsets.only(
                left: HollowSpacing.xxl + HollowSpacing.md,
                bottom: HollowSpacing.sm),
            child: _ChannelOverrideList(
              serverId: widget.serverId,
              onChanged: _setOverride,
            ),
          ),
      ],
    );
  }
}

/// The expanded half of a server row. Its own widget so the channel query is
/// only subscribed while the row is open.
class _ChannelOverrideList extends ConsumerWidget {
  final String serverId;
  final void Function(String channelId, ChannelNotificationLevel level)
      onChanged;

  const _ChannelOverrideList({
    required this.serverId,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notif = ref.watch(notificationSettingsProvider);
    final channels = ref.watch(serverChannelsProvider(serverId));

    return channels.when(
      loading: () => const SettingsNote('Loading channels…'),
      error: (_, _) =>
          const SettingsNote("Could not load this server's channels."),
      data: (all) {
        // Only channels the local user can see: naming a restricted channel
        // here would leak that it exists.
        final visible = <ChannelInfo>[
          for (final c in all.values)
            if (c.meCanSee) c,
        ];
        if (visible.isEmpty) {
          return const HollowEmptyState(
              dense: true, title: 'No channels you can see');
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final channel in visible)
              SettingsRow(
                title: channel.name,
                trailing: ChannelOverrideDropdown(
                  value: notif.channelOverrides[
                          '$serverId:${channel.channelId}'] ??
                      ChannelNotificationLevel.inherit,
                  onChanged: (level) => onChanged(channel.channelId, level),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Conversations that are muted, and the one control that unmutes them.
class _MutedConversationsSection extends ConsumerWidget {
  const _MutedConversationsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notif = ref.watch(notificationSettingsProvider);
    final links = ref.watch(deviceLinkProvider);
    final profiles = ref.watch(profileProvider);

    // Mutes are written under a device id by one call site and a master id by
    // another, so collapse to the master for display and remember every raw
    // key: unmuting has to clear all of them or the row comes back.
    final grouped = <String, List<String>>{};
    for (final entry in notif.dmEnabled.entries) {
      if (entry.value) continue;
      final master = links.identityOf(entry.key);
      grouped.putIfAbsent(master, () => <String>[]).add(entry.key);
    }
    for (final entry in grouped.entries) {
      if (!entry.value.contains(entry.key)) entry.value.add(entry.key);
    }

    final masters = grouped.keys.toList()
      ..sort((a, b) => displayNameFor(profiles, a)
          .toLowerCase()
          .compareTo(displayNameFor(profiles, b).toLowerCase()));

    return SettingsSection(
      title: 'Muted conversations',
      children: [
        if (masters.isEmpty)
          const HollowEmptyState(dense: true, title: 'No muted conversations')
        else
          for (final master in masters)
            _MutedConversationRow(
              key: ValueKey(master),
              master: master,
              storedKeys: grouped[master]!,
            ),
      ],
    );
  }
}

class _MutedConversationRow extends ConsumerStatefulWidget {
  final String master;
  final List<String> storedKeys;

  const _MutedConversationRow({
    super.key,
    required this.master,
    required this.storedKeys,
  });

  @override
  ConsumerState<_MutedConversationRow> createState() =>
      _MutedConversationRowState();
}

class _MutedConversationRowState extends ConsumerState<_MutedConversationRow> {
  bool _busy = false;

  Future<void> _unmute(String name) async {
    // The row leaves the list as soon as the mute clears, so the success
    // toast cannot count on it still being mounted.
    final overlay = Overlay.maybeOf(context);
    setState(() => _busy = true);
    try {
      final notifier = ref.read(notificationSettingsProvider.notifier);
      for (final key in widget.storedKeys) {
        await notifier.setDmEnabled(key, true);
      }
      if (overlay != null && overlay.mounted) {
        HollowToast.show(overlay.context, 'Unmuted $name.',
            type: HollowToastType.success, overlayState: overlay);
      }
    } catch (e) {
      if (!mounted) return;
      HollowToast.show(
        context,
        friendlyError(e,
            fallback: "Couldn't unmute this conversation. Try again."),
        type: HollowToastType.error,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = displayNameFor(ref.watch(profileProvider), widget.master);
    return SettingsRow(
      leading: HollowAvatar(peerId: widget.master, size: 32, semanticLabel: name),
      title: name,
      trailing: HollowButton.outline(
        compact: true,
        loading: _busy,
        onPressed: () => _unmute(name),
        child: const Text('Unmute'),
      ),
    );
  }
}
