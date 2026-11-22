import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/app_relaunch.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
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
  /// (on iOS the person closes it) and the invite is finished on the next
  /// launch. NEVER switches on its own.
  Future<bool> ensureRelayForInvite(
      BuildContext context, HollowLink link) async {
    final target = link.relay;
    if (target == null) return true;
    final current = _read(relayDomainProvider);
    if (normalizeRelayHost(current) == target) return true;

    // The switch runs inside the dialog: it stays open loading, and a failed
    // write shows there instead of vanishing behind a closed dialog.
    await showHollowDialog<void>(
      context: context,
      builder: (dialogContext) => _RelaySwitchDialog(
        target: target,
        current: current,
        title: _titleFor(link.type),
        onSwitch: () async {
          await storage_api.saveSetting(
              key: kPendingInviteAfterSwitchKey, value: link.fullUrl);
          return switchRelay(_read, target);
        },
      ),
    );
    return false;
  }

  /// A server we hold that lives on [target], another relay (HOL-SEC-211): the
  /// same one dialog an invite opens, and nothing to finish after the restart.
  Future<void> switchToServerRelay(
      BuildContext context, String serverId, String target) async {
    final current = _read(relayDomainProvider);
    await showHollowDialog<void>(
      context: context,
      builder: (dialogContext) => _RelaySwitchDialog(
        target: target,
        current: current,
        title: _titleFor(HollowLinkType.serverInvite),
        held: true,
        onSwitch: () => switchRelay(_read, target),
      ),
    );
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
  String? owner,
  String? key,
}) async {
  if (relay == null) return true;
  final built = switch (type) {
    HollowLinkType.conference =>
      webConferenceInviteLink(id, relay: relay, key: key),
    HollowLinkType.roomInvite => roomInviteLink(id, relay: relay),
    _ => webServerInviteLink(id, relay: relay, owner: owner, key: key),
  };
  final link = classifyHollowLink(built);
  if (link == null) return true;
  return ensureRelayForInvite(context, ref, link);
}

/// What iOS asks once a switch is saved: it cannot close the app itself.
String closeByHandText(String relay) =>
    'Close Hollow from the app switcher and open it again to connect to '
    '$relay.';

String _titleFor(HollowLinkType type) => switch (type) {
      HollowLinkType.roomInvite => 'This room lives on another relay',
      HollowLinkType.conference => 'This meeting lives on another relay',
      _ => 'This server lives on another relay',
    };

class _RelaySwitchDialog extends StatefulWidget {
  const _RelaySwitchDialog({
    required this.target,
    required this.current,
    required this.title,
    required this.onSwitch,
    this.held = false,
  });

  final String title;

  /// A server we already hold: nothing to finish after the restart.
  final bool held;
  final String target;
  final String current;

  /// True when the app is ending; false when the person closes it (iOS).
  final Future<bool> Function() onSwitch;

  @override
  State<_RelaySwitchDialog> createState() => _RelaySwitchDialogState();
}

class _RelaySwitchDialogState extends State<_RelaySwitchDialog>
    with HollowDialogAction {
  /// The switch is saved and waits for the person to close the app.
  bool _saved = false;

  Future<void> _switch() async {
    var ending = true;
    if (!await runDialogAction(() async => ending = await widget.onSwitch(),
            fallback: "Couldn't switch relays. Try again.") ||
        !mounted) {
      return;
    }
    // A switch that ends the process never gets here; one that returns anyway
    // (a test, a relaunch that was refused) still closes the dialog.
    if (ending) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        actionRunning = false;
        _saved = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final body = HollowTypography.body.copyWith(color: hollow.textSecondary);
    // Relay names are what the protocol produces: the console voice.
    final host = HollowTypography.mono.copyWith(color: hollow.textPrimary);
    final end = relaySwitchEnd;

    if (_saved) {
      return HollowDialog(
        title: 'Close and reopen Hollow',
        width: 420,
        showClose: true,
        content: Text.rich(
          TextSpan(children: [
            const TextSpan(
                text: 'Close Hollow from the app switcher, then open it '
                    'again. It connects to '),
            TextSpan(text: widget.target, style: host),
            TextSpan(text: widget.held ? '.' : ' and finishes joining.'),
          ]),
          style: body,
        ),
      );
    }

    return HollowDialog(
      title: widget.title,
      width: 420,
      busy: actionRunning,
      error: actionError,
      content: Text.rich(
        TextSpan(children: [
          const TextSpan(text: 'It is on '),
          TextSpan(text: widget.target, style: host),
          const TextSpan(text: '. You are connected to '),
          TextSpan(text: widget.current, style: host),
          TextSpan(
              text: switch (end) {
                RelaySwitchEnd.restart => '. Switching restarts Hollow, and '
                    'your servers and friends on ',
                RelaySwitchEnd.close => '. Switching closes Hollow, and your '
                    'servers and friends on ',
                RelaySwitchEnd.closeByHand => '. Switching takes effect the '
                    'next time Hollow opens, and your servers and friends on ',
              }),
          TextSpan(text: widget.current, style: host),
          TextSpan(
            text: ' go quiet until you switch back.'
                '${widget.held ? '' : switch (end) {
                    RelaySwitchEnd.restart =>
                      ' Hollow finishes this join after the restart.',
                    RelaySwitchEnd.close =>
                      ' Open Hollow again to finish joining.',
                    RelaySwitchEnd.closeByHand => ' Hollow finishes joining '
                        'when it opens again.',
                  }}',
          ),
        ]),
        style: body,
      ),
      actions: [
        HollowButton.ghost(
          onPressed: actionRunning ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          onPressed: _switch,
          loading: actionRunning,
          child: Text(switch (end) {
            RelaySwitchEnd.restart => 'Switch and restart',
            RelaySwitchEnd.close => 'Switch and close app',
            RelaySwitchEnd.closeByHand => 'Switch relay',
          }),
        ),
      ],
    );
  }
}
