import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_settings_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/server_avatar.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';
import 'package:hollow/src/ui/mobile/mobile_storage_route.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_settings_tab.dart';
import 'package:hollow/src/ui/server_settings/server_settings_catalog.dart';
import 'package:hollow/src/ui/server_settings/server_settings_place.dart'
    show ForeignServerSettingsScope, saveServerDraft;
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Pages whose text fields ride the draft, so their bar carries Reset and Save.
const _draftPages = {
  ServerSettingsPage.overview,
  ServerSettingsPage.access,
  ServerSettingsPage.profile,
};

/// A server's settings on a phone: the list of pages, each pushing the same
/// page widget the desktop rail shows, at touch density.
class MobileServerSettingsRoute extends ConsumerWidget {
  final String serverId;

  const MobileServerSettingsRoute({super.key, required this.serverId});

  void _open(BuildContext context, WidgetRef ref, ServerSettingsPage page) {
    // A phone opens any server's settings from the chat list: its channel
    // list and layout are loaded for it unless it is the selected one.
    final foreign = ref.read(selectedServerProvider) != serverId;
    Navigator.of(context).push(
      hollowMobileRoute(
        builder: (_) => foreign
            ? ForeignServerSettingsScope(
                serverId: serverId, child: _page(page))
            : _page(page),
      ),
    );
  }

  Widget _page(ServerSettingsPage page) => MobileSettingsSubPage(
          title: page.label,
          actions: page == ServerSettingsPage.channels
              ? _LayoutSaveActions(serverId: serverId)
              : _draftPages.contains(page)
                  ? _DraftSaveActions(serverId: serverId)
                  : null,
          child: SettingsDensity(
            touch: true,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(HollowSpacing.lg,
                  HollowSpacing.sm, HollowSpacing.lg, HollowSpacing.xl),
              child: serverSettingsPageFor(page, serverId),
            ),
          ),
        );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final server = ref.watch(serverListProvider)[serverId];
    final access = ref.watch(serverSettingsAccessProvider(serverId));
    final online = ref.watch(onlineMembersProvider(serverId)).length;
    final members =
        ref.watch(serverMembersProvider(serverId)).valueOrNull?.length ??
            server?.memberCount ??
            0;
    final level = ref.watch(notificationSettingsProvider
            .select((s) => s.serverLevels[serverId])) ??
        NotificationLevel.all;

    String? valueFor(ServerSettingsPage page) => switch (page) {
          ServerSettingsPage.members => '$members',
          ServerSettingsPage.notifications => switch (level) {
              NotificationLevel.all => 'All messages',
              NotificationLevel.mentions => 'Mentions only',
              NotificationLevel.nothing => 'Nothing',
            },
          _ => null,
        };

    Widget body;
    if (server == null) {
      body = Center(
        child: Text('This server is gone',
            style: HollowTypography.body.copyWith(color: hollow.textSecondary)),
      );
    } else if (access == null) {
      // Nothing until the permissions load: the wrong pages would flash.
      body = const Center(child: HollowSpinner.medium());
    } else {
      final pages = serverSettingsPagesFor(access.perms);
      Widget row(ServerSettingsPage p) => MobileSettingsNavRow(
            key: ValueKey(p),
            icon: p.icon,
            title: p.label,
            value: valueFor(p),
            onTap: () => _open(context, ref, p),
          );
      body = ListView(
        padding: const EdgeInsets.only(bottom: HollowSpacing.xl),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.lg, vertical: HollowSpacing.md),
            child: Row(
              children: [
                ServerAvatar(
                    serverId: serverId, name: server.name, size: 48, animate: true),
                const SizedBox(width: HollowSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        server.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HollowTypography.subheading
                            .copyWith(color: hollow.textPrimary),
                      ),
                      const SizedBox(height: HollowSpacing.xxs),
                      Text(
                        '$online online · $members '
                        '${members == 1 ? 'member' : 'members'}',
                        style: HollowTypography.bodySmall
                            .copyWith(color: hollow.textSecondary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const MobileSettingsGroupCaption('Server'),
          for (final p in pages)
            if (!p.isYou) row(p),
          const MobileSettingsGroupCaption('You'),
          for (final p in pages)
            if (p.isYou) row(p),
          MobileSettingsNavRow(
            icon: LucideIcons.hardDrive,
            title: 'Storage on this phone',
            onTap: () => Navigator.of(context).push(hollowMobileRoute(
                builder: (_) => MobileStorageRoute(serverId: serverId))),
          ),
        ],
      );
    }

    return MobileSettingsSubPage(title: 'Server settings', child: body);
  }
}

/// The draft's commit on a phone: Reset and Save in the page's bar, where the
/// desktop floats its unsaved bar. The draft outlives the page.
class _DraftSaveActions extends ConsumerWidget {
  final String serverId;
  const _DraftSaveActions({required this.serverId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(serverSettingsDraftProvider(serverId));
    final notifier = ref.read(serverSettingsDraftProvider(serverId).notifier);
    if (!draft.dirty) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        HollowButton.ghost(
          onPressed: draft.saving ? null : notifier.reset,
          child: const Text('Reset'),
        ),
        const SizedBox(width: HollowSpacing.sm),
        HollowButton.ghost(
          loading: draft.saving,
          onPressed: () => saveServerDraft(context, notifier),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _LayoutSaveActions extends ConsumerWidget {
  final String serverId;
  const _LayoutSaveActions({required this.serverId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final channels = ref.watch(channelListProvider);
    final saved = ref.watch(channelLayoutProvider);
    ref.watch(channelLayoutDraftProvider(serverId));
    final layout = ref.read(channelLayoutDraftProvider(serverId).notifier);
    if (!layout.dirty(channels, saved)) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        HollowButton.ghost(
          onPressed: layout.discard,
          child: const Text('Discard'),
        ),
        const SizedBox(width: HollowSpacing.sm),
        HollowButton.ghost(
          onPressed: () {
            layout.save(channels, ref.read(channelLayoutProvider.notifier));
            HollowToast.show(context, 'Channel list saved',
                type: HollowToastType.success);
          },
          child: const Text('Save layout'),
        ),
      ],
    );
  }
}
