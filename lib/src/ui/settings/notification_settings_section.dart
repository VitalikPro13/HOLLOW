import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:hollow/src/ui/settings/notifications_tab.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Notifications category of Settings, desktop rail and mobile sub-page alike:
/// whether the OS lets Hollow post at all, then every server and every muted
/// conversation in one editable list.
class NotificationSettingsView extends ConsumerWidget {
  const NotificationSettingsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return settingsCardList([
      const _SystemNotificationsCard(),
      if (UnifiedPushController.supported) const _PushDeliveryCard(),
      const _ServersCard(),
      const _MutedDmsCard(),
    ]);
  }
}

/// OS permission status, with the two ways to change it and a real toast to
/// prove the whole chain works.
class _SystemNotificationsCard extends ConsumerStatefulWidget {
  const _SystemNotificationsCard();

  @override
  ConsumerState<_SystemNotificationsCard> createState() =>
      _SystemNotificationsCardState();
}

class _SystemNotificationsCardState
    extends ConsumerState<_SystemNotificationsCard> {
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
        'Could not ask for permission: $e',
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
        'Could not open the system notification settings: $e',
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
        'Could not send the test notification: $e',
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

    final info = _info;
    final state = info?.state ?? NotificationPermissionState.unknown;
    final detail = _loading
        ? 'Checking with your system…'
        : info?.detail ??
            'Hollow could not read the notification permission on this '
                'device.';

    return SettingsCard(
      title: 'System Notifications',
      children: [
        Row(
          children: [
            StatusDot(
              color: switch (state) {
                NotificationPermissionState.granted => hollow.success,
                NotificationPermissionState.denied => hollow.error,
                NotificationPermissionState.unknown => hollow.textTertiary,
              },
              filled: state == NotificationPermissionState.granted,
              semanticLabel: _statusLabel(state),
            ),
            const SizedBox(width: HollowSpacing.sm),
            Text(
              _statusLabel(state),
              style: HollowTypography.body.copyWith(
                color: hollow.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: HollowSpacing.xs),
        Text(
          detail,
          style: HollowTypography.caption.copyWith(
            color: hollow.textTertiary,
            fontSize: 11,
          ),
        ),
        const SizedBox(height: HollowSpacing.md),
        Wrap(
          spacing: HollowSpacing.sm,
          runSpacing: HollowSpacing.sm,
          children: [
            if (info != null &&
                info.canRequest &&
                state != NotificationPermissionState.granted)
              HollowButton.ghost(
                onPressed: _busy != null ? null : _request,
                icon: _spinnerOr(hollow, 'request', LucideIcons.bellRing),
                child: const Text('Request permission'),
              ),
            if (info != null && info.canOpenSettings)
              HollowButton.ghost(
                onPressed: _busy != null ? null : _openSettings,
                icon: _spinnerOr(hollow, 'open', LucideIcons.externalLink),
                child: const Text('Open system settings'),
              ),
            HollowButton.filled(
              onPressed: _busy != null ? null : _sendTest,
              icon: _spinnerOr(hollow, 'test', LucideIcons.send),
              child: const Text('Send a test notification'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _spinnerOr(HollowTheme hollow, String tag, IconData icon) {
    if (_busy == tag) {
      return SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: hollow.textSecondary,
        ),
      );
    }
    return Icon(icon, size: 16);
  }

  static String _statusLabel(NotificationPermissionState state) =>
      switch (state) {
        NotificationPermissionState.granted => 'Allowed',
        NotificationPermissionState.denied => 'Blocked',
        NotificationPermissionState.unknown => 'Unknown',
      };
}

/// Android: which push service wakes the phone, Google's or a UnifiedPush
/// distributor the user installed.
class _PushDeliveryCard extends ConsumerStatefulWidget {
  const _PushDeliveryCard();

  @override
  ConsumerState<_PushDeliveryCard> createState() => _PushDeliveryCardState();
}

class _PushDeliveryCardState extends ConsumerState<_PushDeliveryCard> {
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
        'Could not switch the push service: $e',
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
        return SettingsCard(
          title: 'Push Delivery',
          children: [
            Text(
              'The service that wakes this phone when a message arrives '
              'while Hollow is closed. Messages stay encrypted either way.',
              style: HollowTypography.body.copyWith(
                color: hollow.textSecondary,
              ),
            ),
            const SizedBox(height: HollowSpacing.md),
            Wrap(
              spacing: HollowSpacing.sm,
              runSpacing: HollowSpacing.sm,
              children: [
                NotificationChoiceChip(
                  label: 'Google',
                  icon: LucideIcons.cloud,
                  isSelected: selected == _google,
                  onTap: () => _choose(_google),
                ),
                for (final d in _distributors)
                  NotificationChoiceChip(
                    label: distributorLabel(d),
                    icon: LucideIcons.radioTower,
                    isSelected: selected == d,
                    onTap: () => _choose(d),
                  ),
              ],
            ),
            const SizedBox(height: HollowSpacing.sm),
            Text(
              _busy != null
                  ? 'Switching…'
                  : _statusText(status, _distributors.isEmpty),
              style: HollowTypography.caption.copyWith(
                color: status.phase == UnifiedPushPhase.failed
                    ? hollow.error
                    : hollow.textTertiary,
                fontSize: 11,
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
class _ServersCard extends ConsumerWidget {
  const _ServersCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final servers = ref.watch(serverListProvider).values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return SettingsCard(
      title: 'Servers',
      children: [
        if (servers.isEmpty)
          Text(
            'You have not joined any servers.',
            style: HollowTypography.body.copyWith(color: hollow.textSecondary),
          )
        else
          for (int i = 0; i < servers.length; i++) ...[
            if (i > 0) const SizedBox(height: HollowSpacing.md),
            _ServerNotificationRow(
              key: ValueKey(servers[i].serverId),
              serverId: servers[i].serverId,
              name: servers[i].name,
            ),
          ],
      ],
    );
  }
}

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
        'Could not save the notification level: $e',
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
        'Could not save the channel override: $e',
        type: HollowToastType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final notif = ref.watch(notificationSettingsProvider);
    final level = notif.serverLevels[widget.serverId] ?? NotificationLevel.all;
    final overrides = notif.channelOverrides.keys
        .where((k) => k.startsWith('${widget.serverId}:'))
        .length;

    final chevron = HollowPressable(
      onTap: () => setState(() => _expanded = !_expanded),
      semanticLabel:
          _expanded ? 'Hide channel overrides' : 'Show channel overrides',
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      padding: const EdgeInsets.all(HollowSpacing.xs),
      child: Icon(
        _expanded ? LucideIcons.chevronUp : LucideIcons.chevronDown,
        size: 16,
        color: hollow.textSecondary,
      ),
    );

    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.name,
          style: HollowTypography.body.copyWith(
            color: hollow.textPrimary,
            fontSize: 13,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (overrides > 0)
          Text(
            overrides == 1 ? '1 override' : '$overrides overrides',
            style: HollowTypography.caption.copyWith(
              color: hollow.textTertiary,
              fontSize: 10,
            ),
          ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // The three chips need room for their labels, and that room grows with
        // the OS text size; a card too narrow for them gets the compact
        // segment instead of a squeezed, clipped row.
        final textScale = MediaQuery.textScalerOf(context).scale(12) / 12;
        final wide = constraints.maxWidth >= 380 * textScale;
        final selector = wide
            ? NotificationLevelSelector(value: level, onChanged: _setLevel)
            : TriStateSegment<NotificationLevel>(
                value: level,
                options: const [
                  (NotificationLevel.all, 'All'),
                  (NotificationLevel.mentions, 'Mentions'),
                  (NotificationLevel.nothing, 'Nothing'),
                ],
                onChanged: _setLevel,
              );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (wide)
              Row(
                children: [
                  Expanded(child: title),
                  const SizedBox(width: HollowSpacing.md),
                  selector,
                  const SizedBox(width: HollowSpacing.xs),
                  chevron,
                ],
              )
            else ...[
              Row(
                children: [
                  Expanded(child: title),
                  chevron,
                ],
              ),
              const SizedBox(height: HollowSpacing.sm),
              selector,
            ],
            if (_expanded) ...[
              const SizedBox(height: HollowSpacing.sm),
              _ChannelOverrideList(
                serverId: widget.serverId,
                onChanged: _setOverride,
              ),
            ],
          ],
        );
      },
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
    final hollow = HollowTheme.of(context);
    final notif = ref.watch(notificationSettingsProvider);
    final channels = ref.watch(serverChannelsProvider(serverId));

    Widget note(String text) => Padding(
          padding: const EdgeInsets.only(left: HollowSpacing.lg),
          child: Text(
            text,
            style: HollowTypography.caption.copyWith(
              color: hollow.textTertiary,
              fontSize: 11,
            ),
          ),
        );

    return channels.when(
      loading: () => note('Loading channels…'),
      error: (_, _) => note('Could not load this server\'s channels.'),
      data: (all) {
        // Only channels the local user can see: naming a restricted channel
        // here would leak that it exists.
        final visible = <ChannelInfo>[
          for (final c in all.values)
            if (c.meCanSee) c,
        ];
        if (visible.isEmpty) return note('No channels you can see.');

        return Padding(
          padding: const EdgeInsets.only(left: HollowSpacing.lg),
          child: Column(
            children: [
              for (final channel in visible)
                Padding(
                  padding: const EdgeInsets.only(bottom: HollowSpacing.sm),
                  child: Row(
                    children: [
                      Icon(LucideIcons.hash,
                          size: 14, color: hollow.textSecondary),
                      const SizedBox(width: HollowSpacing.xs),
                      Expanded(
                        child: Text(
                          channel.name,
                          style: HollowTypography.body.copyWith(
                            color: hollow.textSecondary,
                            fontSize: 12,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: HollowSpacing.sm),
                      ChannelOverrideDropdown(
                        value: notif.channelOverrides[
                                '$serverId:${channel.channelId}'] ??
                            ChannelNotificationLevel.inherit,
                        onChanged: (level) =>
                            onChanged(channel.channelId, level),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Conversations that are muted, and the one control that unmutes them.
class _MutedDmsCard extends ConsumerWidget {
  const _MutedDmsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
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

    return SettingsCard(
      title: 'Muted Direct Messages',
      children: [
        if (masters.isEmpty)
          Text(
            'No muted conversations.',
            style: HollowTypography.body.copyWith(color: hollow.textSecondary),
          )
        else
          for (final master in masters)
            _MutedDmRow(
              key: ValueKey(master),
              master: master,
              storedKeys: grouped[master]!,
            ),
      ],
    );
  }
}

class _MutedDmRow extends ConsumerStatefulWidget {
  final String master;
  final List<String> storedKeys;

  const _MutedDmRow({
    super.key,
    required this.master,
    required this.storedKeys,
  });

  @override
  ConsumerState<_MutedDmRow> createState() => _MutedDmRowState();
}

class _MutedDmRowState extends ConsumerState<_MutedDmRow> {
  bool _busy = false;

  Future<void> _unmute() async {
    setState(() => _busy = true);
    try {
      final notifier = ref.read(notificationSettingsProvider.notifier);
      for (final key in widget.storedKeys) {
        await notifier.setDmEnabled(key, true);
      }
    } catch (e) {
      if (!mounted) return;
      HollowToast.show(
        context,
        'Could not unmute this conversation: $e',
        type: HollowToastType.error,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final name = displayNameFor(ref.watch(profileProvider), widget.master);

    return Padding(
      padding: const EdgeInsets.only(bottom: HollowSpacing.sm),
      child: Row(
        children: [
          HollowAvatar(peerId: widget.master, size: 28, semanticLabel: name),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Text(
              name,
              style: HollowTypography.body.copyWith(
                color: hollow.textPrimary,
                fontSize: 13,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          HollowButton.ghost(
            onPressed: _busy ? null : _unmute,
            compact: true,
            icon: _busy
                ? SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: hollow.textSecondary,
                    ),
                  )
                : const Icon(LucideIcons.bell, size: 14),
            child: const Text('Unmute'),
          ),
        ],
      ),
    );
  }
}
