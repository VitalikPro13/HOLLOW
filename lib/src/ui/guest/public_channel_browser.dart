import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/guest_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/guest/guest_server_sidebar.dart';
import 'package:hollow/src/ui/guest/guest_chat_pane.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

class PublicChannelBrowser extends ConsumerWidget {
  const PublicChannelBrowser({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final selectedServer = ref.watch(guestSelectedServerProvider);
    final selectedChannel = ref.watch(guestSelectedChannelProvider);
    final savedServers = ref.watch(savedGuestServersProvider).valueOrNull ?? [];
    final serverName = selectedServer != null
        ? savedServers
            .where((s) => s.serverId == selectedServer)
            .firstOrNull
            ?.serverName
        : null;
    final serverMode = selectedServer != null
        ? savedServers
            .where((s) => s.serverId == selectedServer)
            .firstOrNull
            ?.fetchMode
        : null;

    return Column(
      children: [
        // Accent-tinted CHROME, not a wash of accent: a low-alpha fill lets a
        // wallpaper straight through and stops reading as part of the app
        // (issue #54).
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.lg,
            vertical: HollowSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: hollow.noticeSurface(hollow.accent),
            border: Border(bottom: BorderSide(color: hollow.border)),
          ),
          child: Row(
            children: [
              Icon(LucideIcons.globe, size: 16, color: hollow.accent),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: Text(
                  serverName != null && serverName.isNotEmpty
                      ? 'Viewing $serverName as guest'
                      : 'Public Channel Browser',
                  style: TextStyle(
                    color: hollow.accentText,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (serverMode != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: HollowSpacing.sm,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: hollow.accent.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(hollow.radiusSm),
                  ),
                  child: Text(
                    serverMode.label,
                    style: TextStyle(
                      color: hollow.accentText,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
            ],
          ),
        ),

        Expanded(
          child: Row(
            children: [
              const SizedBox(
                width: 240,
                child: GuestServerSidebar(),
              ),
              Expanded(
                child: selectedServer != null && selectedChannel != null
                    ? GuestChatPane(
                        key: ValueKey('guest:$selectedServer:$selectedChannel'),
                        serverId: selectedServer,
                        channelId: selectedChannel,
                      )
                    : Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              LucideIcons.hash,
                              size: 48,
                              color: hollow.textSecondary.withValues(alpha: 0.3),
                            ),
                            const SizedBox(height: HollowSpacing.md),
                            Text(
                              'Select a channel to browse',
                              style: TextStyle(
                                color: hollow.textSecondary,
                                fontSize: 15,
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
