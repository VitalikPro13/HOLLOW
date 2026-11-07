/// Data for the device-proof screens (lost-device review, restore chooser,
/// recovery banners) while track C1's FFI bodies still answer empty.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/device_proof_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/api/device_proof.dart' as dp;

import 'test_data.dart';

const kMira = 'master_mira_000000000000000001';
const kTomas = 'master_tomas_00000000000000002';
const kIlse = 'master_ilse_000000000000000003';
const kOskar = 'master_oskar_00000000000000004';
const kOwnDesktop = 'device_own_desktop_00000000001';
const kGoneChannel = 'channel_gone_0001';

crdt_api.MemberFfi _member(String id, String nick, String role) =>
    crdt_api.MemberFfi(
      peerId: id,
      displayName: nick,
      role: role,
      nickname: nick,
      twitchUsername: '',
      labels: const [],
    );

final fixtureMembers = [
  _member(kLocalPeerId, 'Vitalii', 'owner'),
  _member(kMira, 'Mira', 'admin'),
  _member(kTomas, 'Tomas', 'moderator'),
  _member(kIlse, 'Ilse', 'member'),
  _member(kOskar, 'Oskar', 'member'),
];

dp.RefoldItem _item(String key, dp.RefoldGroup g, dp.RefoldItemKind k,
        {String? target,
        String? channel,
        String? role,
        String? oldRole,
        bool opens = false}) =>
    dp.RefoldItem(
      key: key,
      group: g,
      kind: k,
      target: target,
      channelId: channel,
      role: role,
      oldRole: oldRole,
      opens: opens,
    );

/// Mira's lost phone: one change in every group, one channel already closed.
final fixtureOpenReview = dp.RefoldReview(
  member: kMira,
  device: 'device_mira_phone_000000000001',
  dr: 'dr01',
  below: null,
  listed: true,
  openedMs: 1762300000000,
  unpublished: const [kChannelId1],
  items: [
    _item('k-ban', dp.RefoldGroup.removed, dp.RefoldItemKind.banned,
        target: kTomas, role: 'moderator', opens: true),
    _item('k-join', dp.RefoldGroup.letIn, dp.RefoldItemKind.joined,
        target: kOskar),
    _item('k-role', dp.RefoldGroup.roles, dp.RefoldItemKind.roleChanged,
        target: kIlse, role: 'member', oldRole: 'admin'),
    _item('k-mute', dp.RefoldGroup.mutes, dp.RefoldItemKind.muted,
        target: kIlse),
    _item('k-public', dp.RefoldGroup.seeOrPost, dp.RefoldItemKind.stoppedPublic,
        channel: kChannelId2, opens: true),
    _item('k-joinrules', dp.RefoldGroup.joining, dp.RefoldItemKind.joinRules,
        opens: true),
    _item('k-deleted', dp.RefoldGroup.things, dp.RefoldItemKind.channelDeleted,
        channel: kGoneChannel, opens: true),
  ],
  moreItems: 3,
  answered: null,
);

const fixtureAnsweredReview = dp.RefoldReview(
  member: kTomas,
  device: 'device_tomas_desk_000000000001',
  dr: 'dr02',
  listed: true,
  unpublished: [],
  items: [],
  moreItems: 0,
  answered: dp.RefoldAnswered(
      byDevice: kOwnDesktop,
      timeout: false,
      undone: ['k-a', 'k-b'],
      kept: ['k-c']),
);

const fixtureTimedOutReview = dp.RefoldReview(
  member: kIlse,
  device: 'device_ilse_phone_000000000001',
  dr: 'dr03',
  listed: true,
  unpublished: [],
  items: [],
  moreItems: 0,
  answered: dp.RefoldAnswered(
      byDevice: kOwnDesktop, timeout: true, undone: [], kept: []),
);

final fixtureReviews = dp.RefoldReviews(
  reviews: [fixtureOpenReview, fixtureAnsweredReview, fixtureTimedOutReview],
  moreReports: 1,
);

const _day = 86400000;
const _now = 1762300000000;

dp.RestorePoint _point(String cp, int? daysAgo, List<String> by) =>
    dp.RestorePoint(
        cp: cp,
        dateMs: daysAgo == null ? null : _now - daysAgo * _day,
        namedBy: by,
        namedByNames: List<String?>.filled(by.length, null));

/// One server in each stage of the restore chooser.
dp.Restores fixtureRestores(List<dp.RestoreStage> stages) => dp.Restores(
      serversKnown: true,
      servers: [
        for (final (i, s) in stages.indexed)
          dp.RestoreChoices(
            serverId: s == dp.RestoreStage.points || i.isOdd
                ? kServerId2
                : kServerId1,
            stage: s,
            pick: s == dp.RestoreStage.pick
                ? _point('cp-pick', 2, [kMira, kTomas, kIlse])
                : null,
            points: switch (s) {
              dp.RestoreStage.points => [
                  _point('cp-a', 2, [kMira, kTomas, kIlse, kOskar]),
                  _point('cp-b', 9, [kOskar]),
                  _point('cp-old', null, [kTomas]),
                ],
              dp.RestoreStage.onlyOne => [_point('cp-one', 5, [kIlse])],
              _ => const [],
            },
          ),
      ],
    );

class _Servers extends ServerListNotifier {
  final Map<String, ServerInfo> servers;
  _Servers(this.servers);

  @override
  Map<String, ServerInfo> build() => servers;
}

class _Kinds extends DeviceKindNotifier {
  @override
  Map<String, String> build() => const {kOwnDesktop: 'desktop'};
}

/// `answer_refold_review`'s result for [chosen] and [putBack], in order: each
/// one in [changedSince] stays, the rest apply.
dp.RefoldApplied refoldAppliedFor(List<String> chosen, List<String> putBack,
    {Set<String> changedSince = const {}}) {
  dp.RefoldItemOutcome o(String key) => dp.RefoldItemOutcome(
      key: key,
      outcome: changedSince.contains(key)
          ? dp.RefoldOutcome.changedSince
          : dp.RefoldOutcome.applied);
  return dp.RefoldApplied(
      items: [for (final k in chosen) o(k)],
      putBack: [for (final c in putBack) o(c)]);
}

/// The overrides every device-proof screen reads, with [reviews],
/// [recovery] and [restores] as the FFI would answer, and [servers] held here.
List<Override> deviceProofOverrides({
  dp.RefoldReviews? reviews,
  dp.ServerRecovery recovery = const dp.ServerRecovery(steppedBack: false),
  dp.Restores? restores,
  Map<String, ServerInfo>? servers,
}) =>
    [
      refoldReviewsProvider(kServerId1).overrideWith((_) async =>
          reviews ?? const dp.RefoldReviews(reviews: [], moreReports: 0)),
      serverRecoveryProvider(kServerId1).overrideWith((_) async => recovery),
      restoreChoicesProvider.overrideWith((_) async =>
          restores ?? const dp.Restores(serversKnown: false, servers: [])),
      serverMembersProvider(kServerId1).overrideWith((_) async => fixtureMembers),
      serverMembersProvider(kServerId2).overrideWith((_) async => fixtureMembers),
      serverChannelsProvider(kServerId1).overrideWith((_) async => testChannels),
      serverLabelsProvider(kServerId1)
          .overrideWith((_) async => const <crdt_api.LabelFfi>[]),
      deviceKindProvider.overrideWith(_Kinds.new),
      serverListProvider.overrideWith(() => _Servers(servers ?? testServers)),
    ];
