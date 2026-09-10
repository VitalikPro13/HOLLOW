import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/app_relaunch.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';

/// Where an invite waits out the restart a relay switch needs.
const String kPendingInviteAfterSwitchKey = 'pending_invite_after_switch';

/// Reads providers for the relay switch from either a widget or the service
/// layer, so the dialog has exactly one builder.
class RelaySwitch {
  RelaySwitch.ofRef(WidgetRef ref) : _read = ref.read;
  RelaySwitch.ofContainer(ProviderContainer container) : _read = container.read;

  final T Function<T>(ProviderListenable<T>) _read;

  /// True when the invite can be opened on the relay we are on now: either it
  /// names no relay (an old link) or it names ours.
  ///
  /// Otherwise asks, and returns false either way: on confirm the process ends
  /// and the invite is finished after the restart. NEVER switches on its own.
  Future<bool> ensureRelayForInvite(
      BuildContext context, HollowLink link) async {
    final target = link.relay;
    if (target == null) return true;
    final current = _read(relayDomainProvider);
    if (normalizeRelayHost(current) == target) return true;

    final confirmed = await showHollowDialog<bool>(
      context: context,
      builder: (dialogContext) =>
          _RelaySwitchDialog(link: link, target: target, current: current),
    );
    if (confirmed != true) return false;

    await storage_api.saveSetting(
        key: kPendingInviteAfterSwitchKey, value: link.fullUrl);
    await _read(relayDomainProvider.notifier).setDomain(target);
    await _read(savedRelayListProvider.notifier).addRelay(target);
    await exitForRelaySwitch();
    return false;
  }
}

Future<bool> ensureRelayForInvite(
        BuildContext context, WidgetRef ref, HollowLink link) =>
    RelaySwitch.ofRef(ref).ensureRelayForInvite(context, link);

/// Same gate for the paste bars, which hold an id and a relay rather than a
/// link; the canonical link is rebuilt so the hand-off stores one shape.
Future<bool> ensureRelayForInviteId(
  BuildContext context,
  WidgetRef ref, {
  required HollowLinkType type,
  required String id,
  required String? relay,
}) async {
  if (relay == null) return true;
  final built = switch (type) {
    HollowLinkType.conference => webConferenceInviteLink(id, relay: relay),
    HollowLinkType.roomInvite => roomInviteLink(id, relay: relay),
    _ => webServerInviteLink(id, relay: relay),
  };
  final link = classifyHollowLink(built);
  if (link == null) return true;
  return ensureRelayForInvite(context, ref, link);
}

bool get _isMobile => Platform.isAndroid || Platform.isIOS;

String _titleFor(HollowLinkType type) => switch (type) {
      HollowLinkType.roomInvite => 'This room lives on another relay',
      HollowLinkType.conference => 'This meeting lives on another relay',
      _ => 'This server lives on another relay',
    };

class _RelaySwitchDialog extends StatelessWidget {
  const _RelaySwitchDialog({
    required this.link,
    required this.target,
    required this.current,
  });

  final HollowLink link;
  final String target;
  final String current;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final body = HollowTypography.body.copyWith(color: hollow.textSecondary);
    final host = body.copyWith(
        color: hollow.textPrimary, fontWeight: FontWeight.w600);

    return HollowDialog(
      title: _titleFor(link.type),
      content: Padding(
        padding: const EdgeInsets.only(bottom: HollowSpacing.xs),
        child: Text.rich(
          TextSpan(children: [
            const TextSpan(text: 'It is on '),
            TextSpan(text: target, style: host),
            const TextSpan(text: '. You are connected to '),
            TextSpan(text: current, style: host),
            TextSpan(
              text: '. Switching restarts Hollow, and your servers and '
                  'friends there go quiet until you switch back. '
                  '${_isMobile ? 'Reopen Hollow to finish joining.' : 'Hollow '
                      'finishes this join after the restart.'}',
            ),
          ]),
          style: body,
        ),
      ),
      actions: [
        HollowButton.ghost(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(_isMobile ? 'Switch and close app' : 'Switch and restart'),
        ),
      ],
    );
  }
}
