import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/blocked_users_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';

/// Blocked-users pieces shared by desktop Settings > Security and the mobile
/// Blocked users tab. The list is master-keyed and purely local: Rust drops
/// their DMs, requests and calls at ingest.

/// One blocked-user row. Avatar size and id formatting differ per surface, so
/// they are passed in.
class BlockedUserRow extends ConsumerStatefulWidget {
  final String id;
  final double avatarSize;
  final String shortId;

  const BlockedUserRow({
    super.key,
    required this.id,
    required this.avatarSize,
    required this.shortId,
  });

  @override
  ConsumerState<BlockedUserRow> createState() => _BlockedUserRowState();
}

class _BlockedUserRowState extends ConsumerState<BlockedUserRow> {
  bool _busy = false;

  Future<void> _unblock(String name) async {
    // The row leaves the list once the unblock lands, so the toast rides the
    // overlay rather than this row's context.
    final overlay = Overlay.of(context);
    setState(() => _busy = true);
    try {
      await ref.read(blockedUsersProvider.notifier).unblock(widget.id);
      if (!overlay.mounted) return;
      HollowToast.show(overlay.context, 'Unblocked $name',
          type: HollowToastType.success, overlayState: overlay);
    } catch (_) {
      if (!mounted) return;
      HollowToast.show(context, 'Failed to unblock',
          type: HollowToastType.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final name = displayNameForPeer(ref.watch(profileProvider)[widget.id], widget.id);

    return SettingsRow(
      leading: HollowAvatar(peerId: widget.id, size: widget.avatarSize),
      title: name,
      subtitleWidget: Text(
        widget.shortId,
        style: HollowTypography.monoSmall.copyWith(color: hollow.textSecondary),
      ),
      trailing: HollowButton.outline(
        compact: true,
        onPressed: _busy ? null : () => _unblock(name),
        loading: _busy,
        child: const Text('Unblock'),
      ),
    );
  }
}

/// "Blocked users": a count, and the list behind Manage.
class BlockedUsersExpandRow extends ConsumerWidget {
  const BlockedUsersExpandRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blocked = ref.watch(blockedUsersProvider).toList()..sort();

    if (blocked.isEmpty) {
      return const SettingsRow(title: 'Blocked users', subtitle: 'Nobody');
    }
    final count = blocked.length == 1 ? '1 person' : '${blocked.length} people';
    return SettingsExpandRow(
      title: 'Blocked users',
      subtitle: "$count can't message, call or friend you",
      showLabel: 'Manage',
      children: [
        for (final id in blocked)
          BlockedUserRow(
            key: ValueKey(id),
            id: id,
            avatarSize: 32,
            shortId: shortenPeerId(id),
          ),
      ],
    );
  }
}
