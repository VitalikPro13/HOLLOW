/// The words of the device-proof screens (DEVICE_PROOF_DESIGN appendix A):
/// the owner's review of a member's lost device, the restore chooser and the
/// banners of a server being restored. Names arrive resolved, so every line is
/// testable without a node.
library;

import 'package:hollow/src/rust/api/device_proof.dart' as dp;

/// "A", "A and B", "A, B and 1 other", "A, B and 3 others": the first two names
/// and a count of the rest.
String namesLine(List<String> names) {
  if (names.isEmpty) return '';
  if (names.length == 1) return names.first;
  if (names.length == 2) return '${names[0]} and ${names[1]}';
  final rest = names.length - 2;
  return '${names[0]}, ${names[1]} and $rest ${rest == 1 ? 'other' : 'others'}';
}

/// A name that opens a sentence: only our own fallbacks are ours to capitalize.
String _lead(String name) => name == kRestoreServerFallback ||
        name.startsWith(_memberFallbackStart) ||
        name == _channelFallback
    ? _cap(name)
    : name;

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1); // design-ignore: sentence start, not a label

const _memberFallbackStart = 'a member (';
const _channelFallback = 'a channel';

/// A held name, or null when it is empty.
String? _named(String? name) => name == null || name.isEmpty ? null : name;

/// A member we hold no name for: never a bare id, which reads as an error.
String memberFallback(String shortId) => '$_memberFallbackStart$shortId)';

/// The names one review line needs. [person], [channel] and [label] answer
/// null when nothing here knows the name; the names the item's op held come
/// next.
class RefoldNames {
  final String server;
  final String member;
  final String? Function(String master) person;
  final String Function(String master) unnamedPerson;
  final String? Function(String channelId) channel;
  final String? Function(String labelId) label;
  final String Function(String role) role;

  const RefoldNames({
    required this.server,
    required this.member,
    required this.person,
    required this.unnamedPerson,
    required this.channel,
    required this.label,
    required this.role,
  });
}

/// The heading of each group, in appendix A order.
String refoldGroupHeading(dp.RefoldGroup g) => switch (g) {
      dp.RefoldGroup.removed => 'Members removed or banned',
      dp.RefoldGroup.letIn => 'People it let in',
      dp.RefoldGroup.roles => 'Roles',
      dp.RefoldGroup.mutes => 'Mutes',
      dp.RefoldGroup.seeOrPost => 'Who can see or post',
      dp.RefoldGroup.joining => 'Joining the server',
      dp.RefoldGroup.things => 'Channels, labels, emotes and stickers',
      dp.RefoldGroup.other => 'Other changes',
    };

const kAlreadyUndoneHeading = 'Already undone';

/// A role above member, the only kind an undo names.
bool _aboveMember(String? role) =>
    role != null && role.isNotEmpty && role != 'member';

/// A role as a sentence's object: "a member", else the role's name.
String _roleNoun(String role, RefoldNames n) =>
    role == 'member' ? 'a member' : n.role(role);

/// One item's sentence: [what] happened, [line] adds what undoing it does, and
/// [opens] says what its undo opens.
({String what, String line, String? opens}) refoldItemText(
    dp.RefoldItem item, RefoldNames n) {
  final target = item.target;
  final who = target == null
      ? n.member
      : n.person(target) ?? _named(item.targetName) ?? n.unnamedPerson(target);
  final chId = item.channelId;
  final chName = chId == null ? null : n.channel(chId) ?? item.channelName;
  final ch = chName == null || chName.isEmpty ? _channelFallback : '#$chName';
  final labId = item.labelId;
  final labName = labId == null ? null : n.label(labId) ?? item.labelName;
  final theLabel = labName == null || labName.isEmpty
      ? 'A label'
      : 'The $labName label';
  // `role` is what an undo gives back; for a role change `oldRole` is the role
  // the lost device gave.
  final role = item.role == null ? null : _roleNoun(item.role!, n);
  final readable =
      'Anyone, including people outside ${n.server}, can then read new posts there.';
  ({String what, String line, String? opens}) t(String what, String undo,
          [String? opens]) =>
      (what: what, line: '$what. $undo', opens: opens);
  final w = _lead(who);
  return switch (item.kind) {
    dp.RefoldItemKind.banned => t(
        '$w was banned',
        _aboveMember(item.role)
            ? 'Undoing lifts the ban and brings $who back as $role.'
            : 'Undoing lifts the ban and brings $who back.'),
    dp.RefoldItemKind.removed => t(
        '$w was removed',
        _aboveMember(item.role)
            ? 'Undoing brings $who back as $role.'
            : 'Undoing brings $who back.'),
    dp.RefoldItemKind.muted => t('$w was muted', 'Undoing lifts the mute.'),
    dp.RefoldItemKind.joined => t('$w joined',
        'Undoing removes $who from ${n.server}. To keep someone out, ban them.'),
    dp.RefoldItemKind.left =>
      t('$w left ${n.server}', 'Undoing brings $who back.'),
    dp.RefoldItemKind.roleChanged => t(
        '$w became ${item.oldRole == null ? 'another role' : _roleNoun(item.oldRole!, n)}',
        'Undoing makes $who ${role ?? 'what they were'} again.'),
    dp.RefoldItemKind.rolePermissions => t(
        'What ${role ?? 'a role'} can do was changed',
        'Undoing puts back what ${role ?? 'it'} could do before.'),
    dp.RefoldItemKind.nickname => t(
        "$w's nickname was changed", 'Undoing puts back the earlier one.'),
    dp.RefoldItemKind.stoppedPublic => t('${_lead(ch)} stopped being public',
        'Undoing makes it public again.', readable),
    dp.RefoldItemKind.madePublic => t(
        '${_lead(ch)} was made public',
        'Undoing makes it not public, so people outside ${n.server} '
            "can't read it. Members still can."),
    dp.RefoldItemKind.accessRules => t(
        'Who can see or post in $ch was changed',
        'Undoing puts back the earlier rules.',
        item.opens ? 'More people can then see $ch.' : null),
    dp.RefoldItemKind.accessLost => t(
        '$w lost access to $ch', 'Undoing gives $who access again.'),
    dp.RefoldItemKind.accessGiven =>
      t('$w was given access to $ch', 'Undoing takes it back.'),
    dp.RefoldItemKind.joinRules => t(
        '${_lead(n.server)} was made private, or its member limit or Twitch '
            'rules changed',
        'Undoing puts back the earlier rules.',
        item.opens ? 'More people can then join ${n.server}.' : null),
    dp.RefoldItemKind.channelDeleted => t(
        '${_lead(ch)} was deleted',
        'Undoing brings $ch back for admins only. You can open it to others '
            'again afterwards.'),
    dp.RefoldItemKind.channelCreated =>
      t('${_lead(ch)} was created', 'Undoing deletes $ch.'),
    dp.RefoldItemKind.labelChanged =>
      t('$theLabel was changed', 'Undoing puts it back as it was.'),
    dp.RefoldItemKind.labelDeleted => t(
        '$theLabel was deleted',
        'Undoing brings it back. When it controls access, nobody has it until '
            'you give it again.'),
    dp.RefoldItemKind.other => t(
        'The lost device made another change',
        'Undoing puts it back as it was.',
        item.opens ? 'More people can then see, post or join.' : null),
  };
}

/// An answered change that stays because someone changed it after the lost
/// device did.
String refoldChangedSince(String what) =>
    '$what. Someone changed this since, so it stays.';

/// A put back that stays undone because someone changed the channel since.
String putBackChangedSince(String channel) =>
    "${_lead(channel)} wasn't put back. Someone changed it since, so it stays "
    'as it is.';

/// A channel the re-fold already closed ("Already undone").
String unpublishedText(String channel, String server) =>
    "${_lead(channel)} was made public. Hollow made it not public again, so people "
    "outside $server can't read it. Members still can.";

/// What a Put back that is on opens.
String putBackOpens(String server) =>
    'Anyone, including people outside $server, can then read new posts there.';

String refoldTitle(String member) => "Changes from $member's lost device";

String refoldIntro(String member) =>
    'Hollow already undid what $member can still change on their own. These '
    "changes need you, because $member can't make them now or because they "
    'change who can see, post or join. Nothing else changes until you choose.';

String refoldClosedChannels(String member, String server) =>
    'Channels the lost device made public after $member last had it are '
    'already closed to people outside $server.';

const kRefoldTimeoutNote =
    "If you don't answer within 30 days, these changes stay.";

String refoldMoreItems(int count) => count == 1
    ? '1 more change comes up after you answer these.'
    : '$count more changes come up after you answer these.';

String refoldMoreReports(int count) => count == 1
    ? '1 more member reported a lost device. Their changes come up after you '
        'answer these.'
    : '$count more members reported lost devices. Their changes come up after '
        'you answer these.';

String refoldAnsweredOn(String device) => 'Answered on $device.';

const kRefoldTimedOut = 'Closed after 30 days. These changes stayed.';

/// What the owner's checkpoint did with an answer: [undone] changes (put-back
/// channels count) and [kept] ones.
String refoldOutcome({required int undone, required int kept}) {
  String changes(int n) => n == 1 ? '1 change' : '$n changes';
  if (undone == 0) return 'These changes stayed.';
  if (kept == 0) return 'Hollow undid ${changes(undone)}.';
  return 'Hollow undid ${changes(undone)}. $kept stayed.';
}

String refoldApplied(String server) =>
    'Your answer is saved. ${_lead(server)} applies it next.';

/// The confirm before Keep all drops what the owner picked.
const kKeepAllTitle = 'Keep every change?';

String keepAllMessage({required int total, required int picked}) {
  const later = "You can't change this answer later.";
  if (total == 1) return 'The change stays, even though you picked it to undo. $later';
  final which = picked >= total ? 'the ones' : 'the $picked';
  return 'All $total changes stay, including $which you picked to undo. $later';
}

String refoldKept(String server) =>
    'These changes stay in $server. Channels Hollow closed stay closed.';

/// The owner's notice in the server, for one member or several.
String refoldNotice(List<String> members, String server) {
  if (members.length <= 1) {
    final m = members.isEmpty ? 'A member' : members.first;
    return '$m reported a lost device. Some changes it made in $server need '
        'your decision.';
  }
  final others = members.length - 1;
  return '${members.first} and $others ${others == 1 ? 'other' : 'others'} '
      'reported lost devices. Some changes those devices made in $server need '
      'your decision.';
}

String steppedBackBanner(String server) =>
    'The owner of $server is restoring it after losing a device. Some channels '
    'and roles may be missing until then. Nothing is deleted.';

String shellBanner(String remover, String server) =>
    "$remover removed you from $server while the owner is restoring it. You can't "
    'chat here for now. When the owner finishes, this is either undone or final.';

/// In place of the composer, for the member [shellBanner] speaks to.
const kRemovedComposer =
    "You can't chat here while the owner restores this server";

// The restore chooser (section 8.4).

const kRestoreTitle = 'Restore your servers';

String restoreChecking(String server) => 'Checking with members of $server';

String restoreWaiting(String server) =>
    'Waiting a little longer for more members of $server to answer';

String restorePick(String server, String date, List<String> names) =>
    '${_lead(server)} can be restored as it was on $date. Confirmed by ${namesLine(names)}.';

String restorePickBeforeUpdate(String server, List<String> names) =>
    '${_lead(server)} can be restored as it was before the 0.14 update. '
    'Confirmed by ${namesLine(names)}.';

const kRestorePickNote = "If you don't know these people, choose another point.";

String restorePoints(String server) =>
    'Choose how to restore $server. Members remember it at these points. Pick '
    'the one you recognize.';

/// One point's title: its date, or before the 0.14 update.
String restorePointTitle(String? date) => date ?? 'Before the 0.14 update';

String restorePointNamedBy(List<String> names) => 'Named by ${namesLine(names)}';

const kRestoreDontKnow = "I don't know";

const kRestoreDontKnowNote =
    'Hollow goes back to the last state your kept devices saved. Changes made '
    'after that may be lost.';

String restoreOnlyOne(String name, String server) =>
    'Only $name could confirm how $server looked. Pick it if you recognize it.';

String restoreNobody(String server) =>
    'No members of $server are online. Hollow will ask again when they are.';

/// Members answered and none remembers a point: the server waits for one that does.
String restoreWaitingForMember(String server) =>
    'None of the members of $server who answered remember how it looked. Hollow '
    'keeps asking as members come online.';

/// The Home row for a server [restoreWaitingForMember] speaks of.
String restoreWaitTitle(String server) => "${_lead(server)} can't be restored yet";

const kRestoreWaitBody =
    'None of its members who answered remember how it looked. Hollow keeps '
    'asking as members come online.';

/// The Home row and the Classic strip for a server waiting on the person's
/// pick (stages pick, points and only one).
String restorePickTitle(String server) =>
    '${_lead(server)} is waiting for you to pick how it looked';

/// The Classic strip when several servers wait on a pick.
String restorePickManyTitle(int count) =>
    '$count servers are waiting for you to pick how they looked';

const kRestorePickBody =
    'Voice and restricted channels come back after you pick.';

const kRestorePickAction = 'Choose';

String restoreDone(String server) => '${_lead(server)} is restored.';

const kRestoreNothing = 'No server is waiting to be restored.';

String restoreFailed(String server) => "Hollow couldn't restore $server. Try again.";

const kRestoreUnknownServers =
    "Hollow doesn't know your servers yet. Ask someone in a server you own or "
    'joined for an invite link, or add your friends again. Hollow then checks '
    'with the members how each server looked before you lost your devices.';

const kRestoreServerFallback = 'your server';
