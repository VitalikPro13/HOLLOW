import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/color_utils.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/models/channel_layout.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/local_nickname_provider.dart';
import 'package:hollow/src/core/providers/name_color_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_badge.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_count_badge.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_skeleton.dart';
import 'package:hollow/src/ui/components/name_text.dart';
import 'package:hollow/src/ui/dialogs/create_channel_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_channel_actions.dart';
import 'package:hollow/src/ui/mobile/mobile_chat_route.dart'
    show mobileChannelGlyph;
import 'package:hollow/src/ui/mobile/server/mobile_server_navigation.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// One line of a server's channel list on the phone.
sealed class MobileChannelEntry {
  const MobileChannelEntry();
}

class MobileCategoryEntry extends MobileChannelEntry {
  final String name;
  const MobileCategoryEntry(this.name);
}

class MobileSeparatorEntry extends MobileChannelEntry {
  const MobileSeparatorEntry();
}

class MobileChannelRowEntry extends MobileChannelEntry {
  final ChannelInfo channel;

  /// The category it sits under, which folds it away.
  final String? category;
  const MobileChannelRowEntry(this.channel, this.category);
}

/// The rows of a channel list: the EFFECTIVE layout over the channels this
/// person may see. `meCanSee` is Rust's whole access predicate; never
/// re-implement the ladder here.
List<MobileChannelEntry> mobileChannelEntries(
    Map<String, ChannelInfo> allChannels, String layoutJson) {
  final channels = <String, ChannelInfo>{
    for (final e in allChannels.entries)
      if (e.value.meCanSee) e.key: e.value,
  };
  // Channels missing from the stored layout come out of this one call, so a
  // channel under a trailing category folds with it (#61).
  final layout = effectiveLayoutFrom(parseLayoutJson(layoutJson), channels);
  final entries = <MobileChannelEntry>[];
  String? category;
  for (final item in layout) {
    switch (item) {
      case CategoryItem(:final name):
        category = name;
        entries.add(MobileCategoryEntry(name));
      case SeparatorItem():
        category = null;
        entries.add(const MobileSeparatorEntry());
      case ChannelItem(:final channelId):
        final ch = channels[channelId];
        if (ch != null) entries.add(MobileChannelRowEntry(ch, category));
    }
  }
  return entries;
}

/// A server's channel list for its phone page, re-read when the channels, the
/// layout, the server or our permissions change.
final mobileServerChannelsProvider = FutureProvider.autoDispose
    .family<List<MobileChannelEntry>, String>((ref, serverId) async {
  ref.watch(serverListProvider.select((s) => s[serverId]));
  ref.watch(channelLayoutProvider);
  ref.watch(myPermissionsProvider(serverId).select((p) => p.valueOrNull));
  ref.watch(myRoleProvider(serverId).select((p) => p.valueOrNull));
  final results = await Future.wait([
    ref.watch(serverChannelsProvider(serverId).future),
    ChannelLayoutNotifier.fetchLayout(serverId),
  ]);
  return mobileChannelEntries(
      results[0] as Map<String, ChannelInfo>, results[1] as String);
});

/// Row height of a channel: a comfortable touch target.
const double _kRowHeight = 44;

/// A row's glyph size; the text after it starts past it.
const double _kGlyph = 20;

/// Where a channel's name starts inside its row.
const double _kTextStart = HollowSpacing.sm + _kGlyph + HollowSpacing.md;

/// Faces shown on a voice room's line before the names take over.
const int _kFaces = 4;
const double _kFace = 22;

/// The channel list of one server, as slivers for the server page.
class MobileServerChannelList extends ConsumerStatefulWidget {
  final String serverId;

  const MobileServerChannelList({super.key, required this.serverId});

  @override
  ConsumerState<MobileServerChannelList> createState() =>
      _MobileServerChannelListState();
}

class _MobileServerChannelListState
    extends ConsumerState<MobileServerChannelList> {
  /// Folded categories by their place in the list: names are not unique.
  final _folded = <int>{};

  void _reload() =>
      ref.invalidate(mobileServerChannelsProvider(widget.serverId));

  @override
  Widget build(BuildContext context) {
    final serverId = widget.serverId;
    final perms = ref.watch(myPermissionsProvider(serverId)).valueOrNull ?? 0;
    final canManage = (perms & Permission.manageChannels) != 0;
    final listed = ref.watch(mobileServerChannelsProvider(serverId));

    return listed.when(
      skipLoadingOnReload: true,
      loading: () => const _SkeletonRows(),
      error: (_, _) => SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(HollowSpacing.lg),
          child: HollowEmptyState(
            title: "Channels didn't load",
            action: HollowButton.ghost(
              touch: true,
              onPressed: _reload,
              child: const Text('Try again'),
            ),
          ),
        ),
      ),
      data: (entries) => _buildRows(context, entries, canManage),
    );
  }

  Widget _buildRows(
      BuildContext context, List<MobileChannelEntry> entries, bool canManage) {
    final serverId = widget.serverId;
    final hasChannels = entries.any((e) => e is MobileChannelRowEntry);
    if (!hasChannels && !canManage) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(HollowSpacing.lg),
          child: HollowEmptyState(title: 'No channels'),
        ),
      );
    }
    final current =
        ref.watch(mobileLastChannelProvider.select((m) => m[serverId]));
    final rows = <Widget>[];
    // The category a channel sits under, by its place in [entries].
    int? under;
    for (final (index, entry) in entries.indexed) {
      switch (entry) {
        case MobileCategoryEntry(:final name):
          under = index;
          final folded = _folded.contains(index);
          rows.add(_CategoryRow(
            key: ValueKey('cat:$index'),
            name: name,
            folded: folded,
            onToggle: () => setState(() {
              if (!_folded.remove(index)) _folded.add(index);
            }),
          ));
        case MobileSeparatorEntry():
          under = null;
          rows.add(const SizedBox(height: HollowSpacing.md));
        case MobileChannelRowEntry(:final channel, :final category):
          if (category != null && under != null && _folded.contains(under)) {
            break;
          }
          rows.add(_ChannelRow(
            key: ValueKey('ch:${channel.channelId}'),
            serverId: serverId,
            channel: channel,
            current: channel.channelId == current,
            canManage: canManage,
            onChanged: _reload,
          ));
      }
    }
    if (canManage) {
      rows.add(_CreateChannelRow(
        onTap: () => showCreateChannelDialog(context, serverId,
            onCreated: (_) => _reload()),
      ));
    }
    return SliverPadding(
      padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.sm, vertical: HollowSpacing.sm),
      sliver: SliverList.list(children: rows),
    );
  }
}

class _SkeletonRows extends StatelessWidget {
  const _SkeletonRows();

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.all(HollowSpacing.sm),
      sliver: SliverList.list(children: [
        for (final width in const [140.0, 96.0, 180.0, 120.0, 150.0])
          SizedBox(
            height: _kRowHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.sm),
              child: Row(children: [
                const HollowSkeleton(width: 20, height: 20),
                const SizedBox(width: HollowSpacing.md),
                HollowSkeleton(width: width, height: 14),
              ]),
            ),
          ),
      ]),
    );
  }
}

class _CategoryRow extends StatelessWidget {
  final String name;
  final bool folded;
  final VoidCallback onToggle;

  const _CategoryRow({
    super.key,
    required this.name,
    required this.folded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: HollowSpacing.md),
      child: HollowPressable(
        onTap: onToggle,
        subtle: true,
        semanticLabel: '${folded ? 'Expand' : 'Collapse'} $name',
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.sm, vertical: HollowSpacing.sm),
        child: Row(
          children: [
            Expanded(
              child: Text(
                // The name as typed: never re-cased.
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HollowTypography.label
                    .copyWith(color: hollow.textSecondary),
              ),
            ),
            AnimatedRotation(
              turns: folded ? -0.25 : 0,
              duration: HollowDurations.fast,
              curve: HollowCurves.enter,
              child: Icon(LucideIcons.chevronDown,
                  size: 14, color: hollow.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChannelRow extends ConsumerWidget {
  final String serverId;
  final ChannelInfo channel;
  final bool current;
  final bool canManage;
  final VoidCallback onChanged;

  const _ChannelRow({
    super.key,
    required this.serverId,
    required this.channel,
    required this.current,
    required this.canManage,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final id = channel.channelId;
    final isVoice = channel.channelType == ChannelType.voice;
    final unread = ref.watch(
        unreadProvider.select((u) => u.channelUnreadCount(serverId, id)));
    final mentions = ref.watch(
        unreadProvider.select((u) => u.channelMentions(serverId, id)));
    final muted = ref.watch(notificationSettingsProvider
        .select((s) => s.isChannelMuted(serverId, id)));
    final devices = isVoice
        ? ref.watch(voiceChannelProvider
            .select((s) => s.participants[serverId]?[id]))
        : null;
    final links = ref.watch(deviceLinkProvider);
    final people = devices == null
        ? const <String>[]
        : {for (final d in devices) links.identityOf(d)}.toList();
    final live = people.isNotEmpty;

    final hot = !isVoice && (unread > 0 || mentions > 0);
    final nameColor = current || hot || live
        ? hollow.textPrimary
        : muted
            ? hollow.textTertiary
            : hollow.textSecondary;
    final glyph = mobileChannelGlyph(channel, live: live);
    final glyphColor = live
        ? hollow.success
        : muted
            ? hollow.textTertiary
            : hollow.textSecondary;

    final trailing = <Widget>[
      if (channel.isPublic)
        Semantics(
          label: 'Public channel',
          child: Icon(LucideIcons.globe, size: 16, color: hollow.textTertiary),
        ),
      if (muted)
        Semantics(
          label: 'Muted',
          child:
              Icon(LucideIcons.bellOff, size: 16, color: hollow.textTertiary),
        ),
      if (live)
        HollowBadge('${people.length} here', kind: HollowBadgeKind.success)
      else if (mentions > 0)
        HollowCountBadge(count: mentions, mention: true)
      else if (unread > 0 && !isVoice)
        HollowCountBadge(count: unread),
    ];

    final row = HollowPressable(
      onTap: () => isVoice
          ? openMobileVoiceChannel(context, ref, serverId, channel)
          : openMobileChannel(context, ref,
              serverId: serverId, channelId: id, channelName: channel.name),
      onLongPress: () => showMobileChannelActions(
        context: context,
        serverId: serverId,
        channel: channel,
        canManage: canManage,
        onChanged: onChanged,
      ),
      backgroundColor: current ? hollow.elevated : null,
      borderRadius: BorderRadius.circular(hollow.radiusMd),
      padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.sm),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: _kRowHeight),
        child: Row(
          children: [
            Icon(glyph, size: _kGlyph, color: glyphColor),
            const SizedBox(width: HollowSpacing.md),
            Expanded(
              child: Text(
                channel.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HollowTypography.bodyTouch.copyWith(color: nameColor),
              ),
            ),
            for (final w in trailing) ...[
              const SizedBox(width: HollowSpacing.sm),
              w,
            ],
          ],
        ),
      ),
    );
    if (!live) return row;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [row, _VoicePeople(people: people)],
    );
  }
}

/// Who is in a voice room: a few faces and their names.
class _VoicePeople extends ConsumerWidget {
  final List<String> people;

  const _VoicePeople({required this.people});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final profiles = ref.watch(profileProvider);
    // displayNameFor reads the nickname cache, so a rename must rebuild.
    ref.watch(localNicknameProvider);
    final neutral = NamePaint([hollow.textSecondary]);
    (String, NamePaint) named(String p) => (
          displayNameFor(profiles, p),
          ref.chosenNamePaintOf(p, hollow) ?? neutral,
        );
    final style =
        HollowTypography.bodySmall.copyWith(color: hollow.textSecondary);
    final Widget names = switch (people.length) {
      1 => NameLine(
          name: named(people[0]).$1,
          paint: named(people[0]).$2,
          rest: '',
          style: style),
      2 => NameLine.several(
          names: [named(people[0]), named(people[1])],
          joins: const [' and '],
          rest: '',
          style: style),
      3 => NameLine.several(
          names: [named(people[0]), named(people[1]), named(people[2])],
          joins: const [', ', ' and '],
          rest: '',
          style: style),
      _ => NameLine.several(
          names: [named(people[0]), named(people[1])],
          joins: const [', '],
          rest: ' and ${people.length - 2} more',
          style: style),
    };
    final faces = people.take(_kFaces).toList();
    const step = _kFace - HollowSpacing.xs;
    return Padding(
      // Under the room's name, past its glyph.
      padding: const EdgeInsetsDirectional.fromSTEB(
          _kTextStart, 0, HollowSpacing.sm, HollowSpacing.sm),
      child: Row(
        children: [
          ExcludeSemantics(
            child: SizedBox(
              width: _kFace + (faces.length - 1) * step,
              height: _kFace,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  for (var i = 0; i < faces.length; i++)
                    PositionedDirectional(
                      start: i * step,
                      child: HollowAvatar(peerId: faces[i], size: _kFace),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(child: names),
        ],
      ),
    );
  }
}

class _CreateChannelRow extends StatelessWidget {
  final VoidCallback onTap;

  const _CreateChannelRow({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: HollowSpacing.sm),
      child: HollowPressable(
        onTap: onTap,
        subtle: true,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.sm),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: _kRowHeight),
          child: Row(
            children: [
              Icon(LucideIcons.plus, size: 20, color: hollow.textSecondary),
              const SizedBox(width: HollowSpacing.md),
              Text(
                'Create channel',
                style:
                    HollowTypography.label.copyWith(color: hollow.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
