import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/profile_card_popup.dart';
import 'package:hollow/src/ui/mobile/mobile_profile_sheet.dart';
import 'package:hollow/src/ui/shell/user_context_menu.dart';

/// Opens the user profile card for [peerId] from inside a chat message.
///
/// Chat is wrapped in a [SelectionArea]; per project rules the tap must come
/// from a full widget (GestureDetector + MouseRegion), and the resulting popup
/// must NOT be a raw OverlayEntry on touch platforms. On mobile we use the
/// modal bottom sheet; on desktop the anchored overlay card (same as the
/// member panel), positioned near the tapped widget.
///
/// Pass [serverId] from channel contexts: the sender's server membership
/// (role, labels, nickname, Twitch) is resolved at tap time so the chat popup
/// matches the member panel. DMs pass none — no server, no roles.
void showChatProfile(
  BuildContext context,
  WidgetRef ref, {
  required String peerId,
  String? nickname,
  String? role,
  String? twitchUsername,
  List<crdt_api.LabelFfi>? labels,
  String? serverId,
}) {
  if (serverId != null) {
    final members = ref.read(serverMembersProvider(serverId)).valueOrNull;
    final member =
        members?.where((m) => m.peerId == peerId).firstOrNull;
    if (member != null) {
      role ??= member.role;
      labels ??= member.labels.isNotEmpty ? member.labels : null;
      if (twitchUsername == null || twitchUsername.isEmpty) {
        twitchUsername =
            member.twitchUsername.isNotEmpty ? member.twitchUsername : null;
      }
      if (nickname == null || nickname.isEmpty) {
        nickname = member.nickname.isNotEmpty ? member.nickname : null;
      }
    }
  }
  if (Platform.isAndroid || Platform.isIOS) {
    showMobileProfileSheet(
      context,
      peerId: peerId,
      role: role,
      twitchUsername: twitchUsername,
      labels: labels,
    );
    return;
  }

  final pos = overlayAnchorOf(context);
  // Anchor just below the tapped name/avatar.
  showProfileCardPopup(
    context: context,
    ref: ref,
    peerId: peerId,
    nickname: nickname,
    role: role,
    twitchUsername: twitchUsername,
    labels: labels,
    serverId: serverId,
    anchor: Offset(pos.dx, pos.dy + 24),
  );
}

/// Wraps [child] so tapping it opens the profile card for [peerId].
/// Use for sender avatars and names inside message rows.
class ProfileTapTarget extends ConsumerWidget {
  final String peerId;
  final String? nickname;
  final String? role;
  final String? twitchUsername;
  final List<crdt_api.LabelFfi>? labels;
  final String? serverId;
  final Widget child;

  const ProfileTapTarget({
    super.key,
    required this.peerId,
    required this.child,
    this.nickname,
    this.role,
    this.twitchUsername,
    this.labels,
    this.serverId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = nickname;
    return Semantics(
      button: true,
      label: (name != null && name.isNotEmpty)
          ? "Open $name's profile"
          : 'Open profile',
      // Right-clicking a sender name or avatar opens the user menu (issue
      // #61, phase 3). Desktop only: on touch the profile sheet already
      // carries these actions, and a long press here would fight the message
      // action sheet the row above it owns.
      child: ContextMenuTarget(
        enabled: !Platform.isAndroid && !Platform.isIOS,
        semanticLabel: 'User actions',
        onOpen: (anchor) => showUserContextMenu(
          context: context,
          ref: ref,
          peerId: peerId,
          serverId: serverId,
          nickname: nickname,
          role: role,
          twitchUsername: twitchUsername,
          labels: labels,
          anchor: anchor,
        ),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => showChatProfile(
              context,
              ref,
              peerId: peerId,
              nickname: nickname,
              role: role,
              twitchUsername: twitchUsername,
              labels: labels,
              serverId: serverId,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
