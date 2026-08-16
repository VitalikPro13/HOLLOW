import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/security_alerts_provider.dart';
import 'package:hollow/src/core/providers/verified_peers_provider.dart';
import 'package:hollow/src/rust/api/verification.dart' as verification_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Open the Verify Contact screen for [peerId] (a device OR master id — it is
/// resolved to the master, since verification is of a PERSON).
///
/// Desktop gets a dialog; mobile pushes a full route, matching how the profile
/// view already adapts.
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
      content: SizedBox(
        width: 460,
        child: VerifyContactBody(peerId: peerId),
      ),
      actions: [
        HollowButton.ghost(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

/// Mobile shell: the shared body on a full route.
class MobileVerifyContactRoute extends StatelessWidget {
  final String peerId;
  const MobileVerifyContactRoute({super.key, required this.peerId});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Scaffold(
      backgroundColor: hollow.background,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                HollowSpacing.xs, HollowSpacing.sm,
                HollowSpacing.lg, HollowSpacing.sm,
              ),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.arrow_back, color: hollow.textPrimary),
                    tooltip: 'Back',
                  ),
                  Icon(LucideIcons.shieldCheck, size: 18, color: hollow.accent),
                  const SizedBox(width: HollowSpacing.sm),
                  Text(
                    'Verify contact',
                    style: HollowTypography.subheading.copyWith(
                      color: hollow.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(HollowSpacing.lg),
                child: VerifyContactBody(peerId: peerId),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The verification flow itself, shared by desktop and mobile.
///
/// ## What the user is actually doing
///
/// Both people open this screen and see the SAME 60-digit number, because it is
/// derived symmetrically from their two master Ed25519 keys. If the numbers
/// match, the keys each side holds for the other are the real ones and nothing
/// is sitting in the middle. It has to be compared over a channel an attacker
/// on the relay does not control — in person, on a video call, or through an
/// app they already trust.
///
/// ## Why there is no "yours / theirs"
///
/// Signal shows a combined number too, but its inputs churn on reinstall.
/// Hollow's peer_id IS the public key, so this number changes only when the
/// person changes. That stability is why a reinstall does NOT clear the
/// verified flag — the separate device alert covers what actually changed.
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

  /// Set when the number could not be derived — shown instead of a number, so
  /// the screen never presents a plausible-looking value it did not compute.
  String? _error;

  /// Result of the paste-compare: null = nothing entered yet.
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
      setState(() => _error = '$e');
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
        Text(
          'Compare this number with $name over a channel you already trust: '
          'in person, on a video call, or through another app. If it matches on '
          'both screens, your messages reach only each other.',
          style: HollowTypography.body.copyWith(
            color: hollow.textSecondary,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: HollowSpacing.lg),

        if (_error != null)
          _ErrorBox(hollow: hollow, message: _error!)
        else if (_number == null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: HollowSpacing.xl),
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: hollow.accent,
                ),
              ),
            ),
          )
        else ...[
          _NumberBlock(hollow: hollow, number: _number!),
          const SizedBox(height: HollowSpacing.md),
          Row(
            children: [
              HollowButton.outline(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(
                    text: verification_api.formatSafetyNumber(number: _number!),
                  ));
                  if (context.mounted) {
                    HollowToast.show(context, 'Safety number copied');
                  }
                },
                icon: const Icon(LucideIcons.copy),
                compact: true,
                child: const Text('Copy'),
              ),
            ],
          ),
          const SizedBox(height: HollowSpacing.lg),

          // ── Paste-compare ──
          // 60 digits is a lot to check by eye. Let the machine do the
          // comparison so a mismatch can't be missed through fatigue.
          Text(
            'Or paste what they read you',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontSize: 11,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: HollowSpacing.xs),
          HollowTextField(
            controller: _compareController,
            hintText: 'Their number',
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

          // ── Outstanding alerts for this contact ──
          // Surfaced HERE as well as in the conversation: this is the screen
          // where the user decides whether to trust the person, so a pending
          // "a new device appeared" belongs in front of them at that moment.
          if (alerts.isNotEmpty) ...[
            for (final a in alerts)
              Padding(
                padding: const EdgeInsets.only(bottom: HollowSpacing.xs),
                child: _AlertLine(hollow: hollow, kind: a.kind, name: name),
              ),
            const SizedBox(height: HollowSpacing.md),
          ],

          // ── The verified flag ──
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
}

/// The number itself: 12 groups of 5, three rows of four, monospace.
///
/// Selectable so it can be copied by hand, and big enough to read aloud from
/// across a desk without losing your place.
class _NumberBlock extends StatelessWidget {
  final HollowTheme hollow;
  final String number;

  const _NumberBlock({required this.hollow, required this.number});

  @override
  Widget build(BuildContext context) {
    final groups = verification_api
        .formatSafetyNumber(number: number)
        .split(' ');
    final rows = <List<String>>[];
    for (var i = 0; i < groups.length; i += 4) {
      rows.add(groups.sublist(i, (i + 4).clamp(0, groups.length)));
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.md,
        vertical: HollowSpacing.md,
      ),
      decoration: BoxDecoration(
        color: hollow.surface,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(color: hollow.border),
      ),
      child: SelectionArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (final g in row)
                      Text(
                        g,
                        style: HollowTypography.mono.copyWith(
                          color: hollow.textPrimary,
                          fontSize: 17,
                          letterSpacing: 1.5,
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Match / mismatch feedback. Carries an ICON as well as colour, so the result
/// is not conveyed by colour alone.
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
              style: HollowTypography.body.copyWith(color: color, fontSize: 12),
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
    final isNewDevice = kind == SecurityAlertKind.newDevice;
    final color = isNewDevice ? hollow.warning : hollow.textSecondary;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          isNewDevice ? LucideIcons.monitorSmartphone : LucideIcons.rotateCw,
          size: 14,
          color: color,
        ),
        const SizedBox(width: HollowSpacing.sm),
        Expanded(
          child: Text(
            isNewDevice
                ? 'A new device was added to $name since you last talked.'
                : '$name reinstalled or re-keyed a device.',
            style: HollowTypography.body.copyWith(color: color, fontSize: 12),
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
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(HollowSpacing.md),
      decoration: BoxDecoration(
        color: isVerified ? hollow.success.withValues(alpha: 0.08) : null,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(
          color: isVerified ? hollow.success.withValues(alpha: 0.5) : hollow.border,
        ),
      ),
      child: Row(
        children: [
          Icon(
            isVerified ? LucideIcons.shieldCheck : LucideIcons.shield,
            size: 18,
            color: isVerified ? hollow.success : hollow.textSecondary,
          ),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Text(
              isVerified
                  ? 'You verified $name.'
                  : 'Not verified yet.',
              style: HollowTypography.body.copyWith(
                color: hollow.textPrimary,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          if (busy)
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: hollow.accent,
              ),
            )
          else if (isVerified)
            HollowButton.ghost(
              onPressed: () => onChanged(false),
              compact: true,
              child: const Text('Remove'),
            )
          else
            HollowButton.filled(
              onPressed: () => onChanged(true),
              compact: true,
              child: const Text('Mark verified'),
            ),
        ],
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  final HollowTheme hollow;
  final String message;

  const _ErrorBox({required this.hollow, required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(HollowSpacing.md),
      decoration: BoxDecoration(
        color: hollow.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(color: hollow.error.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.circleAlert, size: 16, color: hollow.error),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Text(
              "Couldn't build a safety number for this contact.\n$message",
              style: HollowTypography.body.copyWith(
                color: hollow.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
