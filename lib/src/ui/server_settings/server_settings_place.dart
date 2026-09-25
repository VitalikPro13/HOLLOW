import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_settings_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/server_avatar.dart';
import 'package:hollow/src/ui/server_settings/server_settings_catalog.dart';
import 'package:hollow/src/ui/settings/settings_place_frame.dart';

/// A server's settings as a place: the rail takes the channel list's spot and
/// the page takes the chat's, while the dock, header and a call stay. Escape,
/// the X or the gear return to the channel it covered.
class ServerSettingsPlace extends ConsumerStatefulWidget {
  const ServerSettingsPlace({super.key});

  @override
  ConsumerState<ServerSettingsPlace> createState() =>
      _ServerSettingsPlaceState();
}

class _ServerSettingsPlaceState extends ConsumerState<ServerSettingsPlace> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _go(ServerSettingsPage page) {
    ref.read(serverSettingsPageProvider.notifier).state = page;
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final sid = ref.watch(serverSettingsTargetProvider);
    final server = sid == null ? null : ref.watch(serverListProvider)[sid];
    final access = sid == null ? null : ref.watch(serverSettingsAccessProvider(sid));
    // Nothing until the permissions load: the wrong pages would flash.
    if (sid == null || server == null || access == null) {
      if (sid != null && server == null) {
        // Deleted or left from elsewhere while open.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) closeServerSettings(ref.read);
        });
      }
      return ColoredBox(color: hollow.background);
    }

    final pages = serverSettingsPagesFor(access.perms);
    final wanted = ref.watch(serverSettingsPageProvider);
    final page = wanted != null && pages.contains(wanted)
        ? wanted
        : defaultServerSettingsPage(access.perms);

    Widget item(ServerSettingsPage p) => SettingsRailItem(
          icon: p.icon,
          label: p.label,
          selected: p == page,
          onTap: () => _go(p),
        );

    return SettingsPlaceFrame(
      rail: SettingsRail(
        header: Padding(
          padding: const EdgeInsets.fromLTRB(HollowSpacing.lg, HollowSpacing.lg,
              HollowSpacing.lg, HollowSpacing.sm),
          child: Row(
            children: [
              ServerAvatar(serverId: sid, name: server.name, size: 32),
              const SizedBox(width: HollowSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      server.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HollowTypography.subheading
                          .copyWith(color: hollow.textPrimary),
                    ),
                    Text(
                      'Server settings',
                      style: HollowTypography.bodySmall
                          .copyWith(color: hollow.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        children: [
          const SettingsRailGroupLabel('Server'),
          for (final p in pages)
            if (!p.isYou) item(p),
          const SettingsRailGroupLabel('You'),
          for (final p in pages)
            if (p.isYou) item(p),
        ],
      ),
      page: KeyedSubtree(
        key: ValueKey((sid, page)),
        child: serverSettingsPageFor(page, sid),
      ),
      sliverPage: page.slivers,
      scroll: _scroll,
      closeLabel: 'Close server settings',
      closeTooltip: 'Close server settings (Esc)',
      onClose: () => closeServerSettings(ref.read),
      bottomBar: ServerSettingsUnsavedBar(
          serverId: sid, onChannels: page == ServerSettingsPage.channels),
    );
  }
}

/// The one bar for unsaved server edits: the staged channel list while on
/// Channels, else the text fields of any page.
class ServerSettingsUnsavedBar extends ConsumerWidget {
  final String serverId;
  final bool onChannels;

  const ServerSettingsUnsavedBar(
      {super.key, required this.serverId, required this.onChannels});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final channels = ref.watch(channelListProvider);
    final saved = ref.watch(channelLayoutProvider);
    ref.watch(channelLayoutDraftProvider(serverId));
    final layout = ref.read(channelLayoutDraftProvider(serverId).notifier);
    if (onChannels && layout.dirty(channels, saved)) {
      return SettingsUnsavedBar(
        message: 'You changed the channel list',
        resetLabel: 'Discard',
        saveLabel: 'Save layout',
        onReset: layout.discard,
        onSave: () {
          layout.save(
              channels, ref.read(channelLayoutProvider.notifier));
          HollowToast.show(context, 'Channel list saved',
              type: HollowToastType.success);
        },
      );
    }

    final draft = ref.watch(serverSettingsDraftProvider(serverId));
    if (!draft.dirty) return const SizedBox.shrink();
    final notifier = ref.read(serverSettingsDraftProvider(serverId).notifier);
    return SettingsUnsavedBar(
      message: 'You have unsaved server changes',
      saving: draft.saving,
      onReset: notifier.reset,
      onSave: () => saveServerDraft(context, notifier),
    );
  }
}

/// Saves the draft and says how it went.
Future<void> saveServerDraft(
    BuildContext context, ServerSettingsDraftNotifier notifier) async {
  try {
    await notifier.save();
    if (context.mounted) {
      HollowToast.show(context, 'Server settings saved',
          type: HollowToastType.success);
    }
  } on ServerDraftError catch (e) {
    if (context.mounted) {
      HollowToast.show(context, e.message, type: HollowToastType.error);
    }
  } catch (e) {
    if (context.mounted) {
      HollowToast.show(
          context,
          friendlyError(e, fallback: "Couldn't save. Try again."),
          type: HollowToastType.error);
    }
  }
}

/// Settings for a server that is not the selected one (a split's right pane):
/// its own channel list and layout, so the pages never edit the left pane's.
class ForeignServerSettingsScope extends StatelessWidget {
  final String serverId;
  final Widget child;

  const ForeignServerSettingsScope(
      {super.key, required this.serverId, required this.child});

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      key: ValueKey('server-settings-$serverId'),
      overrides: [
        selectedServerProvider.overrideWith((_) => serverId),
        channelListProvider.overrideWith(ChannelListNotifier.new),
        channelLayoutProvider.overrideWith(ChannelLayoutNotifier.new),
      ],
      child: _ForeignLoader(serverId: serverId, child: child),
    );
  }
}

class _ForeignLoader extends ConsumerStatefulWidget {
  final String serverId;
  final Widget child;
  const _ForeignLoader({required this.serverId, required this.child});

  @override
  ConsumerState<_ForeignLoader> createState() => _ForeignLoaderState();
}

class _ForeignLoaderState extends ConsumerState<_ForeignLoader> {
  @override
  void initState() {
    super.initState();
    ref.read(channelListProvider.notifier).loadForServer(widget.serverId);
    ref.read(channelLayoutProvider.notifier).loadForServer(widget.serverId);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
