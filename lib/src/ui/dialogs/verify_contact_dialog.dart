import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/security_alerts_provider.dart';
import 'package:hollow/src/core/providers/verified_peers_provider.dart';
import 'package:hollow/src/rust/api/verification.dart' as verification_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_copy_field.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_settings_tab.dart'
    show MobileSettingsSubPage;
import 'package:hollow/src/ui/settings/settings_shared.dart'
    show SettingsFieldLabel;
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Opens the Verify Contact screen for [peerId], which may be a device or a
/// master id: it resolves to the master, because verification is of a PERSON.
Future<void> showVerifyContactDialog(
  BuildContext context, {
  required String peerId,
}) {
  if (Platform.isAndroid || Platform.isIOS) {
    return Navigator.of(context, rootNavigator: true).push(
      hollowMobileRoute(builder: (_) => MobileVerifyContactRoute(peerId: peerId)),
    );
  }
  return showHollowDialog(
    context: context,
    builder: (_) => _VerifyContactDialog(peerId: peerId),
  );
}

/// Desktop shell: the shared body inside a HollowDialog.
class _VerifyContactDialog extends StatelessWidget {
  final String peerId;
  const _VerifyContactDialog({required this.peerId});

  @override
  Widget build(BuildContext context) {
    return HollowDialog(
      title: 'Verify contact',
      showClose: true,
      width: 460 + HollowSpacing.xl * 2,
      content: VerifyContactBody(peerId: peerId),
    );
  }
}

/// Mobile shell: the shared body on a full route.
class MobileVerifyContactRoute extends StatelessWidget {
  final String peerId;
  const MobileVerifyContactRoute({super.key, required this.peerId});

  @override
  Widget build(BuildContext context) {
    return MobileSettingsSubPage(
      title: 'Verify contact',
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(HollowSpacing.lg),
        child: VerifyContactBody(peerId: peerId),
      ),
    );
  }
}

/// The verification flow itself, shared by desktop and mobile.
///
/// Both people see the SAME 60-digit number, derived symmetrically from their
/// two master Ed25519 keys, so a match means the keys each side holds for the
/// other are real and nothing sits in the middle. It MUST be compared over a
/// channel an attacker on the relay does not control.
///
/// There is no "yours / theirs" because Hollow's peer_id IS the public key, so
/// the number changes only when the person does. That stability is why a
/// reinstall does not clear the verified flag; the device alert covers what
/// actually changed.
class VerifyContactBody extends ConsumerStatefulWidget {
  final String peerId;
  const VerifyContactBody({super.key, required this.peerId});

  @override
  ConsumerState<VerifyContactBody> createState() => _VerifyContactBodyState();
}

class _VerifyContactBodyState extends ConsumerState<VerifyContactBody> {
  final _compareController = TextEditingController();

  /// The raw 60 digits. `null` while loading.
  String? _number;

  /// Set when the number could not be derived, so the screen never presents a
  /// plausible-looking value it did not compute.
  String? _error;

  /// Result of the paste-compare; null until something is entered.
  bool? _compareMatches;

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _compareController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final n = await verification_api.safetyNumberWith(peerId: widget.peerId);
      if (!mounted) return;
      setState(() => _number = n);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e,
          fallback: "Hollow couldn't work out a safety number for this "
              'contact. Try again later.'));
    }
  }

  void _onCompareChanged(String value) {
    final number = _number;
    if (number == null || value.trim().isEmpty) {
      setState(() => _compareMatches = null);
      return;
    }
    setState(() {
      _compareMatches = verification_api.safetyNumbersMatch(
        expected: number,
        provided: value,
      );
    });
  }

  Future<void> _setVerified(bool verified) async {
    setState(() => _busy = true);
    try {
      final notifier = ref.read(verifiedPeersProvider.notifier);
      if (verified) {
        await notifier.verify(widget.peerId);
      } else {
        await notifier.unverify(widget.peerId);
      }
      if (!mounted) return;
      HollowToast.show(
        context,
        verified ? 'Contact verified' : 'Verification removed',
        type: HollowToastType.success,
      );
    } catch (_) {
      if (!mounted) return;
      HollowToast.show(
        context,
        verified ? "Couldn't save verification" : "Couldn't remove verification",
        type: HollowToastType.error,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final master = ref.watch(deviceLinkProvider).identityOf(widget.peerId);
    final name = displayNameForPeer(
      ref.watch(profileProvider.select((p) => p[master])),
      master,
    );
    final isVerified = ref.watch(isPeerVerifiedProvider(master));
    final alerts = ref.watch(peerSecurityAlertsProvider(master));

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HollowDialogText(
          'Compare this number with $name over a channel you already trust: '
          'in person, on a video call, or through another app. If it matches on '
          'both screens, your messages reach only each other.',
        ),
        const SizedBox(height: HollowSpacing.lg),

        if (_error != null)
          _ErrorLine(hollow: hollow, message: _error!)
        else if (_number == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: HollowSpacing.xl),
            child: Center(
              child: HollowSpinner.medium(),
            ),
          )
        else ...[
          _numberField(_number!),
          const SizedBox(height: HollowSpacing.lg),

          // 60 digits is a lot to check by eye, and the machine cannot miss a
          // mismatch through fatigue.
          const SettingsFieldLabel(label: 'Their number'),
          const SizedBox(height: HollowSpacing.xs),
          HollowTextField(
            controller: _compareController,
            hintText: 'Paste the number they sent you',
            onChanged: _onCompareChanged,
            maxLines: 2,
            minLines: 1,
            showCounter: false,
          ),
          if (_compareMatches != null) ...[
            const SizedBox(height: HollowSpacing.sm),
            _CompareResult(hollow: hollow, matches: _compareMatches!),
          ],
          const SizedBox(height: HollowSpacing.lg),

          // Surfaced here as well as in the conversation: this is where the
          // user decides whether to trust the person, so a pending "a new
          // device appeared" belongs in front of them.
          if (alerts.isNotEmpty) ...[
            for (final a in alerts)
              Padding(
                padding: const EdgeInsets.only(bottom: HollowSpacing.xs),
                child: _AlertLine(hollow: hollow, kind: a.kind, name: name),
              ),
            const SizedBox(height: HollowSpacing.md),
          ],

          _VerifiedRow(
            hollow: hollow,
            name: name,
            isVerified: isVerified,
            busy: _busy,
            onChanged: _setVerified,
          ),
        ],
      ],
    );
  }

  /// Four groups to a line, so a person reading it aloud keeps their place;
  /// the copy is one line.
  Widget _numberField(String number) {
    final formatted = verification_api.formatSafetyNumber(number: number);
    final groups = formatted.split(' ');
    final lines = [
      for (var i = 0; i < groups.length; i += 4)
        groups.sublist(i, (i + 4).clamp(0, groups.length)).join('  '),
    ];
    return HollowCopyField(
      label: 'Safety number',
      value: lines.join('\n'),
      copyValue: formatted,
    );
  }
}

/// Match feedback. Carries an ICON as well as colour, so the result is not
/// conveyed by colour alone.
class _CompareResult extends StatelessWidget {
  final HollowTheme hollow;
  final bool matches;

  const _CompareResult({required this.hollow, required this.matches});

  @override
  Widget build(BuildContext context) {
    final color = matches ? hollow.success : hollow.error;
    return Semantics(
      liveRegion: true,
      child: Row(
        children: [
          Icon(
            matches ? LucideIcons.circleCheck : LucideIcons.circleAlert,
            size: 16,
            color: color,
          ),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Text(
              matches
                  ? 'Numbers match.'
                  : "Numbers don't match. Do not treat this contact as verified. "
                      'Check you both read the whole number, then try again.',
              style: HollowTypography.bodySmall.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// One outstanding alert, phrased for a person rather than a protocol.
class _AlertLine extends StatelessWidget {
  final HollowTheme hollow;
  final String kind;
  final String name;

  const _AlertLine({
    required this.hollow,
    required this.kind,
    required this.name,
  });

  @override
  Widget build(BuildContext context) {
    final isReappeared = kind == SecurityAlertKind.identityReappeared;
    final isNewDevice = kind == SecurityAlertKind.newDevice;
    final color = isReappeared
        ? hollow.error
        : isNewDevice
            ? hollow.warning
            : hollow.textSecondary;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          isReappeared
              ? LucideIcons.shieldX
              : isNewDevice
                  ? LucideIcons.monitorSmartphone
                  : LucideIcons.rotateCw,
          size: 14,
          color: color,
        ),
        const SizedBox(width: HollowSpacing.sm),
        Expanded(
          child: Text(
            isReappeared
                ? 'This identity was destroyed and has come back. Verify the '
                    'safety number before trusting it.'
                : isNewDevice
                    ? 'A new device was added to $name since you last talked.'
                    : '$name reinstalled or re-keyed a device.',
            style: HollowTypography.bodySmall.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

/// The verified state and the action that changes it.
class _VerifiedRow extends StatelessWidget {
  final HollowTheme hollow;
  final String name;
  final bool isVerified;
  final bool busy;
  final ValueChanged<bool> onChanged;

  const _VerifiedRow({
    required this.hollow,
    required this.name,
    required this.isVerified,
    required this.busy,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          isVerified ? LucideIcons.shieldCheck : LucideIcons.shield,
          size: 16,
          color: isVerified ? hollow.success : hollow.textSecondary,
        ),
        const SizedBox(width: HollowSpacing.sm),
        Expanded(
          child: Text(
            isVerified
                ? 'You verified $name.'
                : 'Not verified yet.',
            style: HollowTypography.label.copyWith(
              color: hollow.textPrimary,
            ),
          ),
        ),
        const SizedBox(width: HollowSpacing.sm),
        // The row exists for this one action, so it is a compact outline;
        // removing trust is cautionary, hence the danger tint.
        if (isVerified)
          HollowButton.outline(
            onPressed: () => onChanged(false),
            compact: true,
            danger: true,
            loading: busy,
            child: const Text('Remove verification'),
          )
        else
          HollowButton.outline(
            onPressed: () => onChanged(true),
            compact: true,
            loading: busy,
            child: const Text('Mark verified'),
          ),
      ],
    );
  }
}

/// The number could not be derived: say so, and show nothing that looks like
/// a number.
class _ErrorLine extends StatelessWidget {
  final HollowTheme hollow;
  final String message;

  const _ErrorLine({required this.hollow, required this.message});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.circleAlert, size: 16, color: hollow.error),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(child: HollowDialogText(message)),
        ],
      ),
    );
  }
}
