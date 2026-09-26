import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/local_nickname_provider.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Shared pieces of every profile surface: the friend action, the colours of
/// roles and labels, and the nickname prompt. The surfaces themselves are
/// `ProfileIdentityColumn` (profile_identity_column.dart) and the showcase.

/// The primary action for someone who is not a friend yet: Add friend,
/// Accept request, or a quiet Request sent. Friends get Message instead.
class ProfileFriendAction extends ConsumerStatefulWidget {
  final String peerId;
  final bool compact;
  final bool touch;

  const ProfileFriendAction({
    super.key,
    required this.peerId,
    this.compact = false,
    this.touch = false,
  });

  @override
  ConsumerState<ProfileFriendAction> createState() =>
      _ProfileFriendActionState();
}

class _ProfileFriendActionState extends ConsumerState<ProfileFriendAction> {
  bool _busy = false;

  Future<void> _run(
    Future<void> Function() action, {
    required String done,
    required String failed,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        HollowToast.show(
          context,
          friendlyError(e, fallback: failed),
          type: HollowToastType.error,
        );
      }
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    HollowToast.show(context, done, type: HollowToastType.success);
  }

  @override
  Widget build(BuildContext context) {
    final peerId = widget.peerId;
    final friendInfo = ref.watch(friendsProvider)[peerId];
    final notifier = ref.read(friendsProvider.notifier);

    // A `declined` row is a sticky reject tombstone, neither pending nor
    // accepted, so it reads as no row at all and the person can be re-added.
    if (friendInfo == null ||
        (friendInfo.status != 'pending' && friendInfo.status != 'accepted')) {
      return HollowButton.filled(
        onPressed: () => _run(
          () => notifier.sendRequest(peerId),
          done: 'Friend request sent',
          failed: "Couldn't send the request. Try again.",
        ),
        loading: _busy,
        compact: widget.compact,
        touch: widget.touch,
        expand: true,
        icon: const Icon(LucideIcons.userPlus),
        child: const Text('Add friend'),
      );
    }

    if (friendInfo.status == 'pending' && friendInfo.direction == 'incoming') {
      return HollowButton.filled(
        onPressed: () => _run(
          () => notifier.acceptRequest(peerId),
          done: 'Friend request accepted',
          failed: "Couldn't accept the request. Try again.",
        ),
        loading: _busy,
        compact: widget.compact,
        touch: widget.touch,
        expand: true,
        icon: const Icon(LucideIcons.check),
        child: const Text('Accept request'),
      );
    }

    if (friendInfo.status == 'pending') {
      return HollowButton.ghost(
        onPressed: null,
        compact: widget.compact,
        touch: widget.touch,
        expand: true,
        icon: const Icon(LucideIcons.clock),
        child: const Text('Request sent'),
      );
    }

    return const SizedBox.shrink();
  }
}

/// The colour of the dot on a role badge.
Color profileRoleColor(String role, HollowTheme hollow) {
  return switch (role) {
    'owner' => hollow.warning,
    'admin' => const Color(0xFFA78BFA),
    'moderator' =>
      Color.lerp(hollow.warning, hollow.error, 0.5) ?? hollow.warning,
    _ => hollow.textSecondary,
  };
}

/// Sets, edits or clears (an empty name) the nickname only you see for
/// [peerId]. The one nickname dialog: every surface, desktop and phone, calls
/// it.
Future<void> showLocalNicknameDialog(
  BuildContext context,
  WidgetRef ref,
  String peerId, {
  String currentNickname = '',
}) async {
  // Read now: the caller's ref may belong to a menu or sheet that closes
  // before the save runs.
  final nicknames = ref.read(localNicknameProvider.notifier);
  final saved = await promptForName(
    context: context,
    title: 'Set nickname',
    confirmLabel: 'Save',
    description: 'Only you see it.',
    hintText: 'Nickname (leave empty to clear)',
    initial: currentNickname,
    maxLength: 32,
    allowEmpty: true,
    onSubmit: (name) => nicknames.setNickname(peerId, name),
  );
  if (saved == null || !context.mounted) return;
  HollowToast.show(
    context,
    saved.isEmpty ? 'Nickname cleared' : 'Nickname set',
    type: HollowToastType.success,
  );
}
