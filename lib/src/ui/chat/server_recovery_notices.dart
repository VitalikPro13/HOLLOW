import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/device_proof_copy.dart';
import 'package:hollow/src/core/peer_id_label.dart';
import 'package:hollow/src/core/providers/device_proof_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_settings_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/mobile/mobile_server_settings_route.dart';
import 'package:hollow/src/ui/server_settings/server_settings_catalog.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// How a member of [serverId] reads in it: server nickname, then their name.
String serverMemberName(WidgetRef ref, String serverId, String master) =>
    serverMemberKnownName(ref, serverId, master) ?? shortPeerLabel(master);

/// The server nickname or the name we hold for [master], or null when all we
/// have is the id.
String? serverMemberKnownName(WidgetRef ref, String serverId, String master) {
  final profile = ref.watch(profileProvider.select((p) => p[master]));
  final nickname = ref.watch(
          serverNicknamesProvider(serverId).select((n) => n[master])) ??
      '';
  return nickname.isNotEmpty ? nickname : chosenNameForPeer(profile, master);
}

/// Why [serverId]'s composer is closed while its owner restores it, or null:
/// a member removed meanwhile can't post (DEVICE_PROOF_DESIGN 8.8).
String? recoveryComposerBlock(WidgetRef ref, String serverId) =>
    ref.watch(serverRecoveryProvider(serverId)
            .select((r) => r.valueOrNull?.removedBy != null))
        ? kRemovedComposer
        : null;

/// The strips a server's chat shows while a device-proof recovery touches it
/// (DEVICE_PROOF_DESIGN 8.3 and 8.8): a member removed meanwhile, a server its
/// owner is restoring, and the owner's lost-device reviews. Nothing when none
/// applies, so it sits in the chat column unconditionally.
class ServerRecoveryNotices extends ConsumerWidget {
  final String serverId;

  /// Phone sizing; the strip then sits on top of the chat like on desktop.
  final bool touch;

  const ServerRecoveryNotices({
    super.key,
    required this.serverId,
    this.touch = false,
  });

  void _review(BuildContext context, WidgetRef ref) {
    if (touch) {
      MobileServerSettingsRoute(serverId: serverId)
          .openPage(context, ref, ServerSettingsPage.lostDevices);
    } else {
      openServerSettings(ref.read, serverId,
          page: ServerSettingsPage.lostDevices);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final recovery = ref.watch(serverRecoveryProvider(serverId)).valueOrNull;
    final reviews = openRefoldReviews(
        ref.watch(refoldReviewsProvider(serverId)).valueOrNull);
    final server = ref.watch(
            serverListProvider.select((s) => s[serverId]?.name)) ??
        kRestoreServerFallback;

    final strips = <Widget>[];
    final remover = recovery?.removedBy;
    if (remover != null) {
      strips.add(_NoticeStrip(
        key: const ValueKey('shell-banner'),
        icon: LucideIcons.userX,
        color: hollow.warning,
        text: shellBanner(serverMemberName(ref, serverId, remover), server),
        touch: touch,
        action: ({required expand}) => HollowButton.outline(
          danger: true,
          compact: true,
          expand: expand,
          touch: touch,
          onPressed: () => confirmLeaveServer(context, ref, serverId),
          child: Text(
            'Leave ${_buttonName(server)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ));
    } else if (recovery?.steppedBack ?? false) {
      strips.add(_NoticeStrip(
        key: const ValueKey('stepped-back-banner'),
        icon: LucideIcons.history,
        color: hollow.textSecondary,
        text: steppedBackBanner(server),
        touch: touch,
      ));
    }
    if (reviews.isNotEmpty) {
      // One name per member: two members can share a display name.
      final ids = <String>{for (final r in reviews) r.member};
      final members = [for (final m in ids) serverMemberName(ref, serverId, m)];
      strips.add(_NoticeStrip(
        key: const ValueKey('refold-notice'),
        icon: LucideIcons.smartphone,
        color: hollow.textSecondary,
        text: refoldNotice(members, server),
        touch: touch,
        action: ({required expand}) => HollowButton.outline(
          compact: true,
          expand: expand,
          touch: touch,
          onPressed: () => _review(context, ref),
          child: const Text('Review'),
        ),
      ));
    }
    if (strips.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: strips,
    );
  }
}

/// Narrower than this (at text scale 1), the action sits under the words.
const double _stackBelow = 520;

const double _kIcon = 16;

/// A button names the server in at most this many characters.
const int _maxNameInButton = 24;

String _buttonName(String name) => name.length <= _maxNameInButton
    ? name
    : '${name.substring(0, _maxNameInButton - 1)}…';

/// One opaque strip under the chat header, in the status banner's shape.
class _NoticeStrip extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;

  /// The strip's one action, full width when it sits under the words.
  final Widget Function({required bool expand})? action;
  final bool touch;

  const _NoticeStrip({
    super.key,
    required this.icon,
    required this.color,
    required this.text,
    required this.touch,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final style = (touch ? HollowTypography.body : HollowTypography.bodySmall)
        .copyWith(color: hollow.textPrimary);
    final scaler = MediaQuery.textScalerOf(context);
    // The icon sits on the first line, not the middle of a long paragraph.
    final firstLine = scaler.scale(style.fontSize!) * style.height!;
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.lg,
          vertical: HollowSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: hollow.noticeSurface(color),
          border: Border(bottom: BorderSide(color: hollow.border)),
        ),
        child: LayoutBuilder(builder: (context, box) {
          final stacked =
              action != null && box.maxWidth < scaler.scale(_stackBelow);
          final row = Row(
            crossAxisAlignment:
                stacked ? CrossAxisAlignment.start : CrossAxisAlignment.center,
            children: [
              SizedBox(
                height: stacked ? firstLine : null,
                // Scaled with the text, as a button's icon is.
                child: Center(
                    widthFactor: 1,
                    child: Icon(icon, size: scaler.scale(_kIcon), color: color)),
              ),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(child: Text(text, style: style)),
              if (action != null && !stacked) ...[
                const SizedBox(width: HollowSpacing.md),
                action!(expand: false),
              ],
            ],
          );
          if (!stacked) return row;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              row,
              const SizedBox(height: HollowSpacing.sm),
              // Full width under the words, so a long server name still fits.
              action!(expand: true),
            ],
          );
        }),
      ),
    );
  }
}
