import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/changelog.dart';
import 'package:hollow/src/core/providers/channel_navigation.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/dm_navigation.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/home_setup_provider.dart';
import 'package:hollow/src/core/providers/local_nickname_provider.dart';
import 'package:hollow/src/core/providers/news_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/updater_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/connection_visual.dart';
import 'package:hollow/src/ui/components/conversation_row.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_badge.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/components/hollow_text_link.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:hollow/src/ui/dialogs/changelog_dialog.dart';
import 'package:hollow/src/ui/dialogs/news_post_dialog.dart';
import 'package:hollow/src/ui/settings/relay_health_card.dart';
import 'package:hollow/src/ui/shell/voice_room_switch.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Home's side panel: news and what changed, the relay we are on, and who is
/// around.
class HomeRail extends StatelessWidget {
  const HomeRail({super.key});

  @override
  Widget build(BuildContext context) {
    return const SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Inset(child: HomeNewsCard()),
          _Inset(child: HomeRelayCard()),
          _ActiveNow(),
          SizedBox(height: HollowSpacing.xl),
        ],
      ),
    );
  }
}

/// A card in the panel: the raised step on the panel's chrome.
class _RailCard extends StatelessWidget {
  final Widget child;

  /// The whole card as one target, for a phone where a text link is too
  /// small to hit.
  final VoidCallback? onTap;

  const _RailCard({required this.child, this.onTap});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final radius = BorderRadius.circular(hollow.radiusLg);
    return Padding(
      padding: const EdgeInsets.only(bottom: HollowSpacing.lg),
      child: onTap == null
          ? Container(
              padding: const EdgeInsets.all(HollowSpacing.lg),
              decoration: BoxDecoration(
                color: hollow.elevated,
                borderRadius: radius,
              ),
              child: child,
            )
          : HollowPressable(
              onTap: onTap,
              semanticButton: false,
              borderRadius: radius,
              backgroundColor: hollow.elevated,
              hoverColor: hollow.hover,
              padding: const EdgeInsets.all(HollowSpacing.lg),
              child: child,
            ),
    );
  }
}

/// The latest news post, and the changelog of the build that is running; the
/// first launch after an update leads with what changed.
class HomeNewsCard extends ConsumerWidget {
  const HomeNewsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final posts = ref.watch(newsProvider).posts;
    final version = ref.watch(updaterProvider.select((u) => u.currentVersion));
    final setup = ref.watch(homeSetupProvider);
    final releases =
        ref.watch(changelogProvider).valueOrNull ?? const <ChangelogRelease>[];
    final current = releases.indexWhere((r) => r.describes(version));
    final release = current < 0 ? null : releases[current];
    final justUpdated = release != null &&
        setup.loaded &&
        setup.changelogSeen != null &&
        setup.changelogSeen != version;
    if (posts.isEmpty && release == null) return const SizedBox.shrink();

    void openChangelog() {
      ref
          .read(homeSetupProvider.notifier)
          .markChangelogSeen(version)
          .catchError((_) {});
      showChangelogDialog(context, releases, current);
    }

    final post = posts.isEmpty ? null : posts.first;
    return _RailCard(
      onTap: post == null ? null : () => showNewsPostDialog(context, post),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'News',
                  style:
                      HollowTypography.label.copyWith(color: hollow.textPrimary),
                ),
              ),
              if (version.isNotEmpty)
                HollowBadge('v$version', kind: HollowBadgeKind.mono),
            ],
          ),
          if (justUpdated) ...[
            const SizedBox(height: HollowSpacing.md),
            Text(
              'Updated to ${release.version}',
              style: HollowTypography.body.copyWith(
                  color: hollow.textPrimary, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: HollowSpacing.xs),
            for (final item
                in release.sections.expand((s) => s.items).take(3))
              Padding(
                padding: const EdgeInsets.only(bottom: HollowSpacing.xxs),
                child: Text(
                  item,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: HollowTypography.bodySmall
                      .copyWith(color: hollow.textSecondary),
                ),
              ),
            const SizedBox(height: HollowSpacing.xs),
            HollowTextLink("See everything that's new", onTap: openChangelog),
            if (post != null) ...[
              const SizedBox(height: HollowSpacing.md),
              const HollowDivider(),
            ],
          ],
          if (post != null) ...[
            const SizedBox(height: HollowSpacing.md),
            Text(
              post.title,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: HollowTypography.body.copyWith(
                  color: hollow.textPrimary, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: HollowSpacing.xxs),
            Text(
              post.date,
              style: HollowTypography.caption
                  .copyWith(color: hollow.textTertiary),
            ),
            const SizedBox(height: HollowSpacing.sm),
            Text(
              plainNewsExcerpt(post.body),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: HollowTypography.bodySmall
                  .copyWith(color: hollow.textSecondary),
            ),
          ],
          if (release != null && !justUpdated) ...[
            const SizedBox(height: HollowSpacing.md),
            HollowTextLink(
              "What's new in ${release.version}",
              onTap: openChangelog,
            ),
          ],
        ],
      ),
    );
  }
}

/// The relay this identity lives on: which one, whether we reach it, and how
/// loaded it is, so a slow evening has a visible reason.
class HomeRelayCard extends ConsumerWidget {
  /// False drops the load bars and so their 7 s poll, for a card that is
  /// mounted but not on screen (a phone keeps every tab mounted).
  final bool loadBars;

  const HomeRelayCard({super.key, this.loadBars = true});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final connection = ref.watch(overallConnectionProvider);
    final visual = connectionVisual(hollow, connection);
    final domain = ref.watch(relayDomainProvider);
    return _RailCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Relay',
                  style:
                      HollowTypography.label.copyWith(color: hollow.textPrimary),
                ),
              ),
              StatusDot(
                color: visual.color,
                size: 8,
                filled: visual.filled,
              ),
              const SizedBox(width: HollowSpacing.xs),
              Text(
                connection.label,
                style: HollowTypography.bodySmall
                    .copyWith(color: hollow.textSecondary),
              ),
            ],
          ),
          const SizedBox(height: HollowSpacing.xxs),
          Text(
            domain,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: HollowTypography.monoSmall
                .copyWith(color: hollow.textTertiary),
          ),
          if (loadBars) ...[
            const SizedBox(height: HollowSpacing.md),
            const RelayLoadBars(),
          ],
        ],
      ),
    );
  }
}

/// Insets rail content by a list row's own padding, so the rail's text shares
/// one left edge with the rows' text and only their hover fill bleeds past it.
class _Inset extends StatelessWidget {
  final Widget child;
  const _Inset({required this.child});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.md),
        child: child,
      );
}

/// The first paragraph of a markdown post as plain text, for a teaser.
String plainNewsExcerpt(String markdown) {
  final paragraph = markdown
      .split(RegExp(r'\n\s*\n'))
      .map((p) => p.trim())
      .firstWhere(
        (p) => p.isNotEmpty && !p.startsWith('#'),
        orElse: () => '',
      );
  return paragraph
      .replaceAllMapped(RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m.group(1)!)
      .replaceAll(RegExp(r'[*_`>#]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

class HomeVoiceRoom {
  final String serverId;
  final String channelId;
  final String serverName;
  final String channelName;
  final List<String> people;
  final bool mine;

  const HomeVoiceRoom({
    required this.serverId,
    required this.channelId,
    required this.serverName,
    required this.channelName,
    required this.people,
    required this.mine,
  });
}

/// Voice rooms with someone in them, across every server we are in.
List<HomeVoiceRoom> homeVoiceRooms(WidgetRef ref) {
  final voice = ref.watch(voiceChannelProvider);
  final servers = ref.watch(serverListProvider);
  final links = ref.watch(deviceLinkProvider);
  final rooms = <HomeVoiceRoom>[];
  for (final MapEntry(key: serverId, value: channels)
      in voice.participants.entries) {
    // Conferences are virtual servers with their own surface.
    if (serverId.startsWith('conf:')) continue;
    final server = servers[serverId];
    if (server == null) continue;
    for (final MapEntry(key: channelId, value: devices) in channels.entries) {
      if (devices.isEmpty) continue;
      final people = {for (final d in devices) links.identityOf(d)}.toList();
      final name = ref
              .watch(serverChannelsProvider(serverId))
              .valueOrNull?[channelId]
              ?.name ??
          '';
      rooms.add(HomeVoiceRoom(
        serverId: serverId,
        channelId: channelId,
        serverName: server.name,
        channelName: name,
        people: people,
        mine: voice.currentServerId == serverId &&
            voice.currentChannelId == channelId,
      ));
    }
  }
  rooms.sort((a, b) => b.people.length.compareTo(a.people.length));
  return rooms;
}

class _ActiveNow extends ConsumerWidget {
  const _ActiveNow();

  /// More than this in one list and the rail turns into a roster.
  static const _onlineCap = 8;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final rooms = homeVoiceRooms(ref);
    final online = ref.watch(onlineIdentitiesProvider);
    final profiles = ref.watch(profileProvider);
    // displayNameFor reads the nickname cache, so a rename must rebuild.
    ref.watch(localNicknameProvider);
    final onlineFriends = [
      for (final f in ref.watch(sortedFriendsProvider))
        if (online.contains(f.peerId)) f.peerId,
    ];
    final inVoice = <String, String>{
      for (final r in rooms)
        for (final p in r.people) p: r.serverName,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Inset(child: HollowSectionHeader('Active Now')),
        if (rooms.isEmpty && onlineFriends.isEmpty)
          const _Inset(
            child: HollowEmptyState(
              dense: true,
              title: 'Nobody is around right now',
              description: 'Friends who are online, and voice rooms they are '
                  'in, show up here.',
            ),
          ),
        for (final room in rooms) ...[
          _Inset(child: HomeVoiceRoomTile(room: room)),
          const SizedBox(height: HollowSpacing.xs),
        ],
        if (onlineFriends.isNotEmpty) ...[
          if (rooms.isNotEmpty) const SizedBox(height: HollowSpacing.md),
          _Inset(
            child: HollowSectionHeader('Online',
                dense: true, count: '${onlineFriends.length}'),
          ),
          for (final id in onlineFriends.take(_onlineCap))
            HollowListRow(
              key: ValueKey(id),
              leading: PresenceAvatar(
                peerId: id,
                size: 28,
                online: true,
                ring: hollow.surface,
              ),
              title: displayNameFor(profiles, id),
              subtitle: _statusLine(profiles[id]?.status, inVoice[id]),
              onTap: () => openDmConversation(ref, id),
            ),
          if (onlineFriends.length > _onlineCap)
            Padding(
              padding: const EdgeInsets.only(
                  left: HollowSpacing.md, top: HollowSpacing.xs),
              child: Text(
                'and ${onlineFriends.length - _onlineCap} more',
                style: HollowTypography.bodySmall
                    .copyWith(color: hollow.textTertiary),
              ),
            ),
        ],
      ],
    );
  }

  String _statusLine(String? status, String? voiceServer) {
    if (status != null && status.isNotEmpty) return status;
    if (voiceServer != null) return 'In voice, $voiceServer';
    return 'Online';
  }

}

/// A voice room with people in it and one action, Join (or Open when we are
/// already in it).
class HomeVoiceRoomTile extends ConsumerStatefulWidget {
  final HomeVoiceRoom room;

  /// Replaces the desktop join-and-open, for a shell with its own voice route.
  final Future<void> Function(HomeVoiceRoom room)? onOpen;

  /// Full-size button, for a finger.
  final bool touch;

  const HomeVoiceRoomTile({
    super.key,
    required this.room,
    this.onOpen,
    this.touch = false,
  });

  @override
  ConsumerState<HomeVoiceRoomTile> createState() => _HomeVoiceRoomTileState();
}

class _HomeVoiceRoomTileState extends ConsumerState<HomeVoiceRoomTile> {
  bool _busy = false;

  static const _faces = 3;
  static const double _face = 20;

  Future<void> _go() async {
    final room = widget.room;
    final container = ProviderScope.containerOf(context, listen: false);
    setState(() => _busy = true);
    try {
      final onOpen = widget.onOpen;
      if (onOpen != null) {
        await onOpen(room);
        return;
      }
      if (!room.mine) {
        if (!await confirmVoiceRoomSwitch(context, ref,
                serverId: room.serverId,
                channelId: room.channelId,
                channelName: room.channelName) ||
            !mounted) {
          return;
        }
        await ref
            .read(voiceChannelProvider.notifier)
            .joinChannel(room.serverId, room.channelId);
      }
      await openServerChannel(container, room.serverId, room.channelId);
    } catch (_) {
      if (mounted) {
        HollowToast.show(context, "Couldn't join the voice room",
            type: HollowToastType.error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final profiles = ref.watch(profileProvider);
    ref.watch(localNicknameProvider);
    final room = widget.room;
    final names = room.people.map((p) => displayNameFor(profiles, p)).toList();
    final who = switch (names.length) {
      1 => names.first,
      2 => '${names[0]} and ${names[1]}',
      3 => '${names[0]}, ${names[1]} and ${names[2]}',
      _ => '${names[0]}, ${names[1]} and ${names.length - 2} more',
    };
    final title = room.channelName.isEmpty
        ? room.serverName
        : '${room.channelName} · ${room.serverName}';

    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.md, vertical: HollowSpacing.sm),
      decoration: BoxDecoration(
        color: hollow.elevated,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(LucideIcons.headphones,
                        size: 14, color: hollow.success),
                    const SizedBox(width: HollowSpacing.xs),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HollowTypography.label
                            .copyWith(color: hollow.textPrimary),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: HollowSpacing.xs),
                Row(
                  children: [
                    SizedBox(
                      width: _face +
                          (room.people.take(_faces).length - 1) *
                              (_face - HollowSpacing.xs),
                      height: _face,
                      child: Stack(
                        children: [
                          for (var i = 0;
                              i < room.people.take(_faces).length;
                              i++)
                            Positioned(
                              left: i * (_face - HollowSpacing.xs),
                              child: HollowAvatar(
                                  peerId: room.people[i], size: _face),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: HollowSpacing.sm),
                    Expanded(
                      child: Text(
                        who,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HollowTypography.bodySmall
                            .copyWith(color: hollow.textSecondary),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          HollowButton.outline(
            compact: !widget.touch,
            loading: _busy,
            onPressed: _go,
            child: Text(room.mine ? 'Open' : 'Join'),
          ),
        ],
      ),
    );
  }
}
