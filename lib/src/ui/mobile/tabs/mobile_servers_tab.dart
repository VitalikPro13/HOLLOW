import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/pending_join_provider.dart';
import 'package:hollow/src/core/providers/relay_denial_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_strip_layout_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_count_badge.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/components/pending_join_ui.dart';
import 'package:hollow/src/ui/components/server_avatar.dart';
import 'package:hollow/src/ui/components/server_name_text.dart';
import 'package:hollow/src/ui/dialogs/create_server_dialog.dart';
import 'package:hollow/src/ui/mobile/server/mobile_server_navigation.dart';
import 'package:hollow/src/ui/mobile/server/mobile_server_order.dart';
import 'package:hollow/src/ui/mobile/server/mobile_server_switcher.dart'
    show mobileServerSubline, mobileServerVoiceRoom;
import 'package:hollow/src/ui/shell/mobile_nav.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

const double _kAvatar = 48;

const kAgeHoldNoticeText =
    'Age-restricted servers appear once Hollow connects.';

/// Adds a server from the phone: the dialog opens over the Servers tab, where
/// the new server shows up (it no longer appears in Chats).
void showMobileAddServer(BuildContext context) {
  ProviderScope.containerOf(context, listen: false)
      .read(mobileTabProvider.notifier)
      .state = MobileTab.servers;
  showCreateServerDialog(context);
}

/// The phone's server list. A row opens its server's page; long press is the
/// server's actions sheet.
///
/// Brief (design language 5.1). Job: get into a server. Focal point: the list.
/// Primary action: none here (a row is the action); the nav bar's centre +
/// adds a server, so the header carries no second one.
class MobileServersTab extends ConsumerWidget {
  const MobileServersTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final entries = mobileServersEntries(
      layout: ref.watch(serverStripLayoutProvider),
      listed: mobileListedServers(ref),
      pending: ref.watch(pendingJoinsProvider).keys,
    );
    final load = ref.watch(serverListLoadStateProvider);
    final held = ref.watch(ageHoldHidesServersProvider);

    final Widget body;
    if (entries.isEmpty && !load.loaded) {
      // Still reading the servers: nothing, never "none yet".
      body = load.error == null
          ? const SizedBox.shrink()
          : HollowEmptyState(
              title: "Your servers didn't load",
              description: friendlyError(load.error!),
              action: HollowButton.ghost(
                touch: true,
                onPressed: () =>
                    ref.read(serverListProvider.notifier).loadFromDb(),
                child: const Text('Try again'),
              ),
            );
    } else if (entries.isEmpty && held) {
      // The person has servers, just not on screen yet.
      body = const Align(
        alignment: Alignment.topLeft,
        child: AgeHoldNotice(),
      );
    } else if (entries.isEmpty) {
      body = HollowEmptyState(
        glyph: LucideIcons.layoutGrid,
        title: 'No servers yet',
        description: 'Start your own, or join one with an invite link.',
        action: HollowButton.ghost(
          touch: true,
          onPressed: () => showMobileAddServer(context),
          child: const Text('Add a server'),
        ),
      );
    } else {
      body = ListView.builder(
        padding: const EdgeInsets.only(bottom: HollowSpacing.xl),
        itemCount: entries.length + (held ? 1 : 0),
        // Keyed by server: rows hold per-server state and the dock order can
        // change under them.
        findChildIndexCallback: (key) {
          final i = entries.indexWhere((e) => _keyOf(e) == key);
          return i < 0 ? null : i;
        },
        itemBuilder: (context, i) {
          if (i == entries.length) return const AgeHoldNotice();
          final entry = entries[i];
          return KeyedSubtree(
            key: _keyOf(entry),
            child: switch (entry) {
              MobileServersFolder(:final name) => Padding(
                  padding: EdgeInsets.fromLTRB(
                    HollowSpacing.lg,
                    i == 0 ? HollowSpacing.sm : HollowSpacing.lg,
                    HollowSpacing.lg,
                    0,
                  ),
                  child: HollowSectionHeader(name, dense: true),
                ),
              MobileServersFolderEnd() => const Padding(
                  padding: EdgeInsets.symmetric(vertical: HollowSpacing.sm),
                  child: HollowDivider(
                    indent: HollowSpacing.lg,
                    endIndent: HollowSpacing.lg,
                  ),
                ),
              MobileServersServer(:final serverId) =>
                _ServerRow(serverId: serverId),
              MobileServersPending(:final serverId) =>
                _PendingJoinRow(serverId: serverId),
            },
          );
        },
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            HollowSpacing.lg,
            HollowSpacing.sm,
            HollowSpacing.lg,
            HollowSpacing.sm,
          ),
          // As tall as the Chats header's touch actions, so the title stays
          // put when the tabs switch.
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Semantics(
                header: true,
                child: Text(
                  'Servers',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HollowTypography.heading
                      .copyWith(color: hollow.textPrimary),
                ),
              ),
            ),
          ),
        ),
        Expanded(child: body),
      ],
    );
  }

  static Key _keyOf(MobileServersEntry e) => switch (e) {
        MobileServersFolder(:final folderId) => ValueKey('folder-$folderId'),
        MobileServersFolderEnd(:final folderId) => ValueKey('end-$folderId'),
        MobileServersServer(:final serverId) => ValueKey('srv-$serverId'),
        MobileServersPending(:final serverId) => ValueKey('pending-$serverId'),
      };
}

/// Where the phone's hold keeps flagged servers off the list, so a failed or
/// slow connection never reads as "you have no such servers".
class AgeHoldNotice extends StatelessWidget {
  const AgeHoldNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.lg,
        vertical: HollowSpacing.md,
      ),
      child: Text(
        kAgeHoldNoticeText,
        style: HollowTypography.bodySmall.copyWith(color: hollow.textSecondary),
      ),
    );
  }
}

/// One server: its face, its name, and one line of what is true now (the
/// switcher sheet's line, so the two never disagree).
class _ServerRow extends ConsumerWidget {
  final String serverId;

  const _ServerRow({required this.serverId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final server =
        ref.watch(serverListProvider.select((m) => m[serverId]));
    final name = server?.name ?? '';
    final muted = ref.watch(notificationSettingsProvider
        .select((n) => n.isServerMuted(serverId)));
    // A muted server counts nothing, as on the dock.
    final unread = muted
        ? 0
        : ref.watch(unreadProvider.select((u) => u.serverUnreadCount(serverId)));
    final mentions = muted
        ? 0
        : ref.watch(
            unreadProvider.select((u) => u.serverMentionCount(serverId)));
    final hot = unread > 0 || mentions > 0;
    // Admitted after a parked join, still waiting for a member to finish the
    // MLS setup.
    final awaitingSetup = ref.watch(
        awaitingSetupProvider.select((s) => s.contains(serverId)));

    final line = mobileServerSubline(ref, serverId);
    final voice = mobileServerVoiceRoom(ref, serverId);
    final inVoice = !muted && voice != null && voice.room.isNotEmpty;
    final lineStyle = HollowTypography.body.copyWith(
      color: muted ? hollow.textTertiary : hollow.textSecondary,
    );

    return HollowPressable(
      onTap: () => openMobileServer(context, ref, serverId),
      onLongPress: () => showMobileServerSheet(context, ref, serverId),
      subtle: true,
      semanticLabel: [
        name,
        if (mentions > 0)
          mentions == 1 ? '1 mention' : '$mentions mentions'
        else if (unread > 0)
          '$unread unread',
        if (awaitingSetup) kAwaitingSetupTooltip,
        line,
      ].join(', '),
      borderRadius: BorderRadius.zero,
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.lg,
        vertical: HollowSpacing.md,
      ),
      child: Row(
        children: [
          ServerAvatar(serverId: serverId, name: name, size: _kAvatar),
          const SizedBox(width: HollowSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                ServerNameText(
                  name,
                  isNsfw: server?.isNsfw ?? false,
                  style: HollowTypography.subheading.copyWith(
                    fontWeight: hot ? FontWeight.w600 : FontWeight.w500,
                    color: muted ? hollow.textTertiary : hollow.textPrimary,
                  ),
                ),
                Row(
                  children: [
                    if (inVoice) ...[
                      Icon(LucideIcons.volume2,
                          size: 14, color: hollow.success),
                      const SizedBox(width: HollowSpacing.xs),
                    ],
                    Flexible(
                      child: Text(
                        line,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: lineStyle.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (awaitingSetup) ...[
            const SizedBox(width: HollowSpacing.sm),
            const AwaitingSetupBadge(),
          ],
          if (hot) ...[
            const SizedBox(width: HollowSpacing.md),
            HollowCountBadge(
              count: mentions > 0 ? mentions : unread,
              mention: mentions > 0,
            ),
          ],
        ],
      ),
    );
  }
}

/// A join we asked for that nobody has answered yet.
///
/// Greyed on purpose: there is nothing to open, and all we know about the
/// server is the id from the invite link. No spinner either, because the wait
/// is for another person to open their app. Tap and long press open the same
/// sheet: a tap that did nothing would read as broken.
class _PendingJoinRow extends ConsumerWidget {
  final String serverId;

  const _PendingJoinRow({required this.serverId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final info = ref.watch(pendingJoinsProvider)[serverId];
    final rejected = info?.isRejected ?? false;
    final denied = ref.watch(serverRelayDeniedProvider(serverId));
    void openSheet() =>
        showPendingJoinSheet(context: context, ref: ref, serverId: serverId);

    return HollowPressable(
      onTap: openSheet,
      onLongPress: openSheet,
      semanticLabel:
          '${pendingJoinTitle(rejected: rejected, denied: denied)}, show actions',
      subtle: true,
      borderRadius: BorderRadius.zero,
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.lg,
        vertical: HollowSpacing.md,
      ),
      child: Row(
        children: [
          Container(
            width: _kAvatar,
            height: _kAvatar,
            decoration: BoxDecoration(
              color: hollow.elevated,
              borderRadius: BorderRadius.circular(hollow.radiusMd),
            ),
            alignment: Alignment.center,
            child: Icon(
              rejected || denied ? LucideIcons.ban : LucideIcons.clock,
              size: 20,
              color: hollow.textTertiary,
            ),
          ),
          const SizedBox(width: HollowSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  pendingJoinTitle(rejected: rejected, denied: denied),
                  style: HollowTypography.subheading.copyWith(
                    color: hollow.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  pendingJoinSubtitle(
                    rejected: rejected,
                    reason: info?.reason ?? '',
                    denied: denied,
                  ),
                  style: HollowTypography.body
                      .copyWith(color: hollow.textTertiary),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
