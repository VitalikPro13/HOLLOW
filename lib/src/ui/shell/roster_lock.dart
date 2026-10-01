import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/app_relaunch.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/roster_provider.dart';
import 'package:hollow/src/core/services/destroy_flow.dart';
import 'package:hollow/src/rust/api/roster.dart' as roster_api;
import 'package:hollow/src/rust/api/wipe.dart' as wipe_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/dialogs/recovery_phrase_dialogs.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The full-screen lock for a device our own roster does not admit (design ID-1):
/// one that was removed, or one restored from a backup that waits to be let in.
/// Opaque like the app lock; it lifts when the roster says this device belongs.
Route<void> rosterLockRoute() => PageRouteBuilder<void>(
      opaque: true,
      barrierDismissible: false,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, _, _) => const RosterLockScreen(),
    );

/// A date and time people read, in their locale.
String rosterDateLabel(BuildContext context, DateTime at) {
  final l = MaterialLocalizations.of(context);
  return '${l.formatMediumDate(at)}, ${l.formatTimeOfDay(TimeOfDay.fromDateTime(at))}';
}

class RosterLockScreen extends ConsumerStatefulWidget {
  const RosterLockScreen({super.key});

  @override
  ConsumerState<RosterLockScreen> createState() => _RosterLockScreenState();
}

class _RosterLockScreenState extends ConsumerState<RosterLockScreen> {
  Timer? _deadline;
  bool _erasing = false;

  @override
  void initState() {
    super.initState();
    // A removed device erases itself at its deadline, also when the app was
    // closed through it.
    _deadline = Timer.periodic(const Duration(seconds: 30), (_) => _eraseIfDue());
    WidgetsBinding.instance.addPostFrameCallback((_) => _eraseIfDue());
  }

  @override
  void dispose() {
    _deadline?.cancel();
    super.dispose();
  }

  void _eraseIfDue() {
    final gate = ref.read(rosterGateProvider);
    final at = gate.wipeAt;
    if (gate.kind == RosterGateKind.removed && at != null && !DateTime.now().isBefore(at)) {
      _erase();
    }
  }

  Future<void> _erase() async {
    if (_erasing) return;
    setState(() => _erasing = true);
    try {
      await wipe_api.destroyLocal();
    } catch (e) {
      debugPrint('[HOLLOW] erase after removal failed: $e');
    }
    await clearLocalSecretsAfterDestroy();
    await relaunchApp();
  }

  Future<void> _confirmErase() async {
    final ok = await showHollowConfirm(
      context: context,
      title: 'Erase this device?',
      message: 'Hollow deletes your messages, files and keys on this device, '
          'then restarts at first-time setup.',
      confirmLabel: 'Erase',
      destructive: true,
    );
    if (ok) await _erase();
  }

  Future<void> _usePhrase() async {
    try {
      final status = await roster_api.rosterStatus();
      if (!mounted) return;
      final done = await showRecoverWithPhraseDialog(
        context,
        status: status,
        title: 'Use your recovery phrase',
        body: 'Typing it keeps this device and the ones you pick, and removes '
            'every other device.',
        confirmLabel: 'Keep these devices',
      );
      if (done) await ref.read(rosterGateProvider.notifier).refresh();
    } catch (e) {
      if (mounted) HollowToast.show(context, friendlyError(e), type: HollowToastType.error);
    }
  }

  Future<void> _join() async {
    final done = await showJoinWithPhraseDialog(context);
    if (done) await ref.read(rosterGateProvider.notifier).refresh();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final gate = ref.watch(rosterGateProvider);
    final labels = ref.watch(deviceLabelProvider);
    final removed = gate.kind == RosterGateKind.removed;

    final String title;
    final String body;
    if (removed) {
      // A bare id names nothing a removed device can look up, so only a label is said.
      final label = labels[gate.removedBy];
      final who = label == null || label.isEmpty ? 'Another of your devices' : 'Your device $label';
      final when = gate.wipeAt == null ? 'soon' : 'on ${rosterDateLabel(context, gate.wipeAt!)}';
      title = 'This device was removed';
      body = '$who removed it from your identity, so it gets none of your '
          'messages. Hollow erases it $when unless you type your recovery '
          'phrase.';
    } else {
      final when = gate.joinsAt == null
          ? ''
          : ' If nobody refuses it, it joins on ${rosterDateLabel(context, gate.joinsAt!)}.';
      title = 'Waiting to join your identity';
      body = 'This device was restored from a backup. Approve it on one of your '
          'other devices, or type your recovery phrase.$when';
    }

    return PopScope(
      canPop: false,
      child: ColoredBox(
        color: hollow.opaqueBackground,
        child: DefaultTextStyle(
          style: HollowTypography.body,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.all(HollowSpacing.xl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(removed ? LucideIcons.shieldOff : LucideIcons.hourglass,
                        size: 32, color: hollow.textSecondary),
                    const SizedBox(height: HollowSpacing.lg),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: HollowTypography.subheading.copyWith(color: hollow.textPrimary),
                    ),
                    const SizedBox(height: HollowSpacing.sm),
                    Text(
                      body,
                      textAlign: TextAlign.center,
                      style: HollowTypography.bodySmall.copyWith(color: hollow.textSecondary),
                    ),
                    const SizedBox(height: HollowSpacing.xl),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: HollowSpacing.sm,
                      runSpacing: HollowSpacing.sm,
                      children: [
                        if (removed)
                          HollowButton.outline(
                            danger: true,
                            onPressed: _erasing ? null : _confirmErase,
                            loading: _erasing,
                            child: const Text('Erase now'),
                          ),
                        HollowButton.filled(
                          onPressed: _erasing ? null : (removed ? _usePhrase : _join),
                          child: const Text('Use recovery phrase'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Whether [status] still has [device] waiting to join.
bool rosterStillWaiting(roster_api.RosterStatus status, String device) =>
    status.devices.any((d) => d.devicePeerId == device && d.state == 'pending');

/// Asks this device's person whether a device restored from a backup is theirs.
/// Approve vouches for it; Refuse removes it; Later leaves it waiting. An ask that
/// was settled meanwhile (on another device, or by the phrase) is never shown.
Future<void> showPendingDeviceDialog(BuildContext context, WidgetRef ref, String device) async {
  final asks = ref.read(pendingDeviceAsksProvider.notifier);
  final waiting = await roster_api.rosterStatus().then((s) => rosterStillWaiting(s, device), onError: (_) => true);
  if (!waiting || !context.mounted) return asks.answered(device);
  final labels = ref.read(deviceLabelProvider);
  final name = labels[device]?.isNotEmpty == true ? labels[device]! : shortenPeerId(device);
  await showHollowDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PendingDeviceDialog(device: device, name: name),
  );
  asks.answered(device);
}

class _PendingDeviceDialog extends ConsumerStatefulWidget {
  final String device;
  final String name;
  const _PendingDeviceDialog({required this.device, required this.name});

  @override
  ConsumerState<_PendingDeviceDialog> createState() => _PendingDeviceDialogState();
}

class _PendingDeviceDialogState extends ConsumerState<_PendingDeviceDialog> with HollowDialogAction {
  bool? _approving;

  Future<void> _answer(bool approve) async {
    setState(() => _approving = approve);
    final ok = await runDialogAction(
      () => approve
          ? roster_api.approveDevice(devicePeerId: widget.device)
          : roster_api.refuseDevice(devicePeerId: widget.device),
      fallback: "Hollow couldn't answer for that device. Try again.",
    );
    if (ok && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    // Settled elsewhere while this was open: a Refuse now would remove a member.
    ref.listen(rosterStatusProvider, (_, next) {
      final status = next.valueOrNull;
      if (status != null && !actionRunning && !rosterStillWaiting(status, widget.device)) {
        Navigator.of(context).pop();
      }
    });
    return HollowDialog(
      title: 'A device wants to join',
      width: 420,
      busy: actionRunning,
      error: actionError,
      content: HollowDialogText(
        'Device ${widget.name} was restored from a backup of your identity and '
        "asks to join. If it's yours, approve it. If you don't know it, refuse "
        'it and it never gets your messages. With no answer it joins in seven days.',
      ),
      leadingActions: [
        HollowButton.ghost(
          onPressed: actionRunning ? null : () => Navigator.of(context).pop(),
          child: const Text('Later'),
        ),
      ],
      actions: [
        HollowButton.outline(
          danger: true,
          onPressed: actionRunning ? null : () => _answer(false),
          loading: actionRunning && _approving == false,
          child: const Text('Refuse'),
        ),
        HollowButton.filled(
          onPressed: actionRunning ? null : () => _answer(true),
          loading: actionRunning && _approving == true,
          child: const Text('Approve'),
        ),
      ],
    );
  }
}
