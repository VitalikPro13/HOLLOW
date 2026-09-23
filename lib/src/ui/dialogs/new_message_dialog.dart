import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/dm_navigation.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/components/conversation_row.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/shell/friends_bar.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Pick a friend and open the conversation with them.
void showNewMessageDialog(BuildContext context) {
  showHollowDialog(
    context: context,
    builder: (_) => const _NewMessageDialog(),
  );
}

class _NewMessageDialog extends ConsumerStatefulWidget {
  const _NewMessageDialog();

  @override
  ConsumerState<_NewMessageDialog> createState() => _NewMessageDialogState();
}

class _NewMessageDialogState extends ConsumerState<_NewMessageDialog> {
  String _query = '';

  static const double _listHeight = 320;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final friends = ref.watch(sortedFriendsProvider);
    final profiles = ref.watch(profileProvider);
    final online = ref.watch(onlineIdentitiesProvider);
    final q = _query.trim().toLowerCase();
    final matches = [
      for (final f in friends)
        if (q.isEmpty ||
            displayNameFor(profiles, f.peerId).toLowerCase().contains(q))
          f,
    ];

    return HollowDialog(
      title: 'New message',
      showClose: true,
      width: 420,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HollowTextField(
            autofocus: true,
            isDense: true,
            hintText: 'Search friends',
            prefixIcon: Icon(LucideIcons.search,
                size: 16, color: hollow.textTertiary),
            onChanged: (v) => setState(() => _query = v),
            onSubmitted: (_) {
              if (matches.isNotEmpty) _open(matches.first.peerId);
            },
          ),
          const SizedBox(height: HollowSpacing.sm),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: _listHeight),
            child: matches.isEmpty
                ? HollowEmptyState(
                    title: friends.isEmpty
                        ? 'No friends yet'
                        : 'No friend matches that name',
                    description: friends.isEmpty
                        ? 'Add a friend first, then message them here.'
                        : null,
                  )
                : ListView.builder(
                    // Shrinks to a short friend list instead of leaving a
                    // fixed-height hole under two names.
                    shrinkWrap: true,
                    itemCount: matches.length,
                    itemBuilder: (context, i) {
                      final id = matches[i].peerId;
                      final status = profiles[id]?.status ?? '';
                      final isOnline = online.contains(id);
                      return HollowListRow(
                        key: ValueKey(id),
                        leading: PresenceAvatar(
                          peerId: id,
                          size: 32,
                          online: isOnline,
                          ring: hollow.overlay,
                        ),
                        title: displayNameFor(profiles, id),
                        subtitle: status.isNotEmpty
                            ? status
                            : (isOnline ? 'Online' : 'Offline'),
                        onTap: () => _open(id),
                      );
                    },
                  ),
          ),
        ],
      ),
      leadingActions: [
        HollowButton.ghost(
          onPressed: () {
            final nav = Navigator.of(context);
            final host = nav.context;
            nav.pop();
            showFriendsManager(host, addFriend: true);
          },
          icon: const Icon(LucideIcons.userPlus, size: 16),
          child: const Text('Add a friend'),
        ),
      ],
    );
  }

  void _open(String peerId) {
    openDmConversation(ref, peerId);
    Navigator.of(context).pop();
  }
}
