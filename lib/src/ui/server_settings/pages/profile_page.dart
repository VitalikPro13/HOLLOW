import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_settings_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/label_visuals.dart';
import 'package:hollow/src/ui/server_settings/pages/labels_page.dart'
    show LabelDot;
import 'package:hollow/src/ui/server_settings/server_settings_catalog.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// How you show up in one server: a nickname, the labels you wear, and
/// leaving. The nickname waits for the unsaved bar; labels apply at once.
class ServerProfilePage extends ConsumerStatefulWidget {
  final String serverId;
  const ServerProfilePage({super.key, required this.serverId});

  @override
  ConsumerState<ServerProfilePage> createState() => _ServerProfilePageState();
}

class _ServerProfilePageState extends ConsumerState<ServerProfilePage> {
  /// What you wear, seeded ONCE: a re-read right after a queued write returns
  /// the previous set and would undo the tap on screen.
  Set<String>? _wearing;

  String get _sid => widget.serverId;

  Future<void> _toggle(crdt_api.LabelFfi label) async {
    final me = ref.read(identityProvider).peerId ?? '';
    final wearing = _wearing ?? {};
    if (me.isEmpty) return;
    final on = !wearing.contains(label.labelId);
    setState(() => on ? wearing.add(label.labelId) : wearing.remove(label.labelId));
    try {
      if (on) {
        await crdt_api.assignLabel(
            serverId: _sid, labelId: label.labelId, peerId: me);
      } else {
        await crdt_api.unassignLabel(
            serverId: _sid, labelId: label.labelId, peerId: me);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => on ? wearing.remove(label.labelId) : wearing.add(label.labelId));
      HollowToast.show(
          context,
          friendlyError(e, fallback: "Couldn't change that. Try again."),
          type: HollowToastType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final me = ref.watch(identityProvider).peerId ?? '';
    final profiles = ref.watch(profileProvider);
    final myName = displayNameFor(profiles, me);
    final serverName = ref.watch(serverListProvider)[_sid]?.name ?? 'this server';
    final isOwner = ref.watch(myRoleProvider(_sid)).valueOrNull == 'owner';
    final draft = ref.read(serverSettingsDraftProvider(_sid).notifier);
    final labels = ref.watch(serverLabelsProvider(_sid)).valueOrNull;
    final members = ref.watch(serverMembersProvider(_sid)).valueOrNull;
    if (_wearing == null && members != null) {
      _wearing = members
              .where((m) => m.peerId == me)
              .firstOrNull
              ?.labels
              .map((l) => l.labelId)
              .toSet() ??
          <String>{};
    }
    final wearing = _wearing ?? const <String>{};

    return SettingsPage(
      title: 'Profile',
      intro: 'How you show up in $serverName. Everywhere else you stay '
          '$myName.',
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const SettingsFieldLabel(label: 'Nickname'),
            const SizedBox(height: HollowSpacing.xs),
            HollowTextField(
              controller: draft.nickname,
              hintText: myName,
              maxLength: 32,
            ),
            const SizedBox(height: HollowSpacing.md),
            // A message as others will see it, live from the field.
            ListenableBuilder(
              listenable: draft.nickname,
              builder: (context, _) {
                final shown = draft.nickname.text.trim();
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    HollowAvatar(peerId: me, size: 32),
                    const SizedBox(width: HollowSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(shown.isEmpty ? myName : shown,
                              style: HollowTypography.label
                                  .copyWith(color: hollow.accentText)),
                          Text('Anyone up for a patch swap tonight?',
                              style: HollowTypography.body
                                  .copyWith(color: hollow.textPrimary)),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
        SettingsSection(
          title: 'Your labels',
          subtitle: '${SettingsDensity.touchOf(context) ? 'Tap' : 'Click'} one '
              'to wear it or take it off. Access labels come from staff.',
          children: [
            if (labels == null)
              const SizedBox.shrink()
            else if (labels.isEmpty)
              const HollowEmptyState(
                dense: true,
                title: 'This server has no labels yet',
              )
            else
              Wrap(
                spacing: HollowSpacing.sm,
                runSpacing: HollowSpacing.sm,
                children: [
                  for (final l in labels)
                    HollowChip(
                      label: l.name,
                      leading: LabelDot(color: parseLabelColor(l.color)),
                      selected: wearing.contains(l.labelId),
                      trailingIcon: l.access ? LucideIcons.lock : null,
                      semanticLabel: l.access
                          ? '${l.name}, an access label staff hand out'
                          : l.name,
                      onTap: l.access
                          ? () => HollowToast.show(
                              context, 'Access labels come from staff')
                          : () => _toggle(l),
                    ),
                ],
              ),
          ],
        ),
        if (!isOwner)
          SettingsSection(
            title: 'Danger zone',
            children: [
              SettingsRow(
                title: 'Leave $serverName',
                subtitle: "You'll need a new invite to come back",
                trailing: HollowButton.outline(
                  danger: true,
                  compact: true,
                  onPressed: () => confirmLeaveServer(context, ref, _sid),
                  child: const Text('Leave server'),
                ),
              ),
            ],
          ),
      ],
    );
  }
}
