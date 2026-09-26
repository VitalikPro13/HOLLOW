import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/guest_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/guest/guest_server_sidebar.dart';
import 'package:hollow/src/ui/guest/guest_chat_pane.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
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
                  style: HollowTypography.label
                      .copyWith(color: hollow.accentText),
                ),
              ),
              if (serverMode != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: HollowSpacing.sm,
                    vertical: HollowSpacing.xxs,
                  ),
                  decoration: BoxDecoration(
                    color: hollow.accent.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(hollow.radiusXs),
                  ),
                  child: Text(
                    serverMode.label,
                    style: HollowTypography.caption.copyWith(
                      color: hollow.accentText,
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
                    : const HollowEmptyState(
                        glyph: LucideIcons.hash,
                        title: 'Select a channel to browse',
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
