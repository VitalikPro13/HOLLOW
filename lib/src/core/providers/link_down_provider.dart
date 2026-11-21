import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/relay_denial_provider.dart';

/// Why OUR relay link is down, as the "you're offline" family of copy names it:
/// a relay that refuses us is no reconnect away, so it never reads as offline.
enum LinkDown { offline, refusedAccount, refusedNetwork, keyFull }

/// What a down link means right now; surfaces still decide for themselves
/// whether it is down.
final linkDownProvider = Provider<LinkDown>((ref) {
  final link = ref.watch(overallConnectionProvider);
  // Every seat of our access key is taken (#153): the status says so, and so does
  // every line about the link.
  if (link == OverallConnection.keyFull) return LinkDown.keyFull;
  if (link != OverallConnection.refused) return LinkDown.offline;
  return ref.watch(relayLoginDenialProvider) == 'network_denied'
      ? LinkDown.refusedNetwork
      : LinkDown.refusedAccount;
});

/// Where a line about a down link shows.
enum LinkNote {
  /// An empty state's title.
  title,

  /// Under a member list.
  presence,

  /// Above Home's Active now.
  around,

  /// Home's Active now with nobody in it.
  friendsAround,

  /// The phone's Friends list.
  friendsOnline,

  /// The nickname claim.
  nickname,

  /// A meeting's waiting room.
  lobby,

  /// A pasted share link that cannot be fetched.
  pasteLink,

  /// Before destroying the whole identity: the order cannot leave.
  destroyEverywhere,

  /// Before destroying and unlinking this device: the order cannot leave.
  destroyUnlink,
}

/// The one wording of a down link for [note]. Refused copy names the relay
/// and never promises a reconnect will help.
String linkDownNote(LinkDown down, LinkNote note) {
  if (down == LinkDown.offline) {
    return switch (note) {
      LinkNote.title => "You're offline",
      LinkNote.presence =>
        "You're offline, so who's online may be out of date.",
      LinkNote.around => "You're offline, so who's around may be out of date.",
      LinkNote.friendsAround =>
        "Friends who are online show up here once you're back.",
      LinkNote.friendsOnline => "Who's online shows up once you're back.",
      LinkNote.nickname => "Claim a nickname once you're back.",
      LinkNote.lobby => "You're offline. You'll knock again when you're back.",
      LinkNote.pasteLink => "You're offline. Reconnect to fetch this file.",
      LinkNote.destroyEverywhere || LinkNote.destroyUnlink =>
        "You're offline, so the order can't reach your other devices from "
            'here.',
    };
  }
  if (down == LinkDown.keyFull) {
    const full = 'Your access key is full';
    return switch (note) {
      LinkNote.title => full,
      LinkNote.presence => "$full, so who's online may be out of date.",
      LinkNote.around => "$full, so who's around may be out of date.",
      LinkNote.friendsAround =>
        'Friends who are online show up here once the relay lets you in.',
      LinkNote.friendsOnline =>
        "Who's online shows up once the relay lets you in.",
      LinkNote.nickname => 'Claim a nickname once the relay lets you in.',
      LinkNote.lobby =>
        "$full. You'll knock again once the relay lets you in.",
      LinkNote.pasteLink =>
        '$full. Fetch this file once the relay lets you in.',
      LinkNote.destroyEverywhere || LinkNote.destroyUnlink =>
        "$full, so the order can't reach your other devices from here.",
    };
  }
  final refused = down == LinkDown.refusedNetwork
      ? 'This relay blocks your network'
      : 'This relay refused your account';
  return switch (note) {
    LinkNote.title => refused,
    LinkNote.presence => "$refused, so who's online may be out of date.",
    LinkNote.around => "$refused, so who's around may be out of date.",
    LinkNote.friendsAround =>
      'Friends who are online show up here once it lets you in.',
    LinkNote.friendsOnline => "Who's online shows up once it lets you in.",
    LinkNote.nickname => 'Claim a nickname once it lets you in.',
    LinkNote.lobby => "$refused. You'll knock again once it lets you in.",
    LinkNote.pasteLink => '$refused. Switch relays to fetch this file.',
    LinkNote.destroyEverywhere =>
      "$refused, so the order can't reach your other devices from here. "
          'Switch relays first, or use your recovery phrase on another device.',
    LinkNote.destroyUnlink =>
      "$refused, so the order can't reach your other devices from here. "
          'Switch relays first, or remove this device from another one.',
  };
}
