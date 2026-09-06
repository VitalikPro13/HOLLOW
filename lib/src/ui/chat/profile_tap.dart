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
/// Chat sits inside a [SelectionArea], so the tap comes from a full widget and
/// the popup is never a raw OverlayEntry on touch: mobile gets the modal sheet,
/// desktop the anchored card.
///
/// [serverId] resolves the sender's membership (role, labels, nickname) at tap
/// time, so the chat popup matches the member panel; DMs pass none. The Twitch
/// chip draws from the subject's own verified credential wherever the card is
/// opened from.
void showChatProfile(
  BuildContext context,
  WidgetRef ref, {
  required String peerId,
  String? nickname,
  String? role,
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
      labels: labels,
    );
    return;
  }

  // A closure, not a point: the card re-reads it on a window resize so it stays
  // on the name it belongs to (issue #54).
  Offset anchorOf() {
    final pos = overlayAnchorOf(context);
    return Offset(pos.dx, pos.dy + 24);
  }

  showProfileCardPopup(
    context: context,
    ref: ref,
    peerId: peerId,
    nickname: nickname,
    role: role,
    labels: labels,
    serverId: serverId,
    anchorOf: anchorOf,
  );
}

/// Wraps [child] so tapping it opens the profile card for [peerId].
class ProfileTapTarget extends ConsumerWidget {
  final String peerId;
  final String? nickname;
  final String? role;
  final List<crdt_api.LabelFfi>? labels;
  final String? serverId;
  final Widget child;

  const ProfileTapTarget({
    super.key,
    required this.peerId,
    required this.child,
    this.nickname,
    this.role,
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
      // Desktop only (issue #61): on touch the profile sheet already carries
      // these actions, and a long press would fight the message action sheet.
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
