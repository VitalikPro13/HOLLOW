import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/ui/components/profile_card_popup.dart';
import 'package:hollow/src/ui/mobile/mobile_profile_sheet.dart';

/// Opens the user profile card for [peerId] from inside a chat message.
///
/// Chat is wrapped in a [SelectionArea]; per project rules the tap must come
/// from a full widget (GestureDetector + MouseRegion), and the resulting popup
/// must NOT be a raw OverlayEntry on touch platforms. On mobile we use the
/// modal bottom sheet; on desktop the anchored overlay card (same as the
/// member panel), positioned near the tapped widget.
void showChatProfile(
  BuildContext context,
  WidgetRef ref, {
  required String peerId,
  String? nickname,
  String? role,
  String? twitchUsername,
  List<crdt_api.LabelFfi>? labels,
}) {
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

  final box = context.findRenderObject() as RenderBox?;
  final pos = box?.localToGlobal(Offset.zero) ?? Offset.zero;
  // Anchor just below the tapped name/avatar.
  showProfileCardPopup(
    context: context,
    ref: ref,
    peerId: peerId,
    nickname: nickname,
    role: role,
    twitchUsername: twitchUsername,
    labels: labels,
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
  final Widget child;

  const ProfileTapTarget({
    super.key,
    required this.peerId,
    required this.child,
    this.nickname,
    this.role,
    this.twitchUsername,
    this.labels,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = nickname;
    return Semantics(
      button: true,
      label: (name != null && name.isNotEmpty)
          ? "Open $name's profile"
          : 'Open profile',
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
          ),
          child: child,
        ),
      ),
    );
  }
}
