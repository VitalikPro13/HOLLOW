import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/device_link_sync_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/app.dart' show hollowNavigatorKey;
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Entry mode for the device-link dialog.
enum DeviceLinkMode {
  /// This device HAS the data — show a code for an empty device to enter.
  showCode,

  /// This device is EMPTY — enter a code from the populated device, or it will
  /// pull from an auto-detected online sibling.
  enterCode,
}

/// True while a device-link dialog is mounted anywhere. The shell's global
/// confirm-push listener checks this so an inbound request doesn't stack a SECOND
/// dialog on top of one already open (e.g. the Settings show-code dialog) — the
/// already-open dialog re-renders into the confirm view on the phase change.
bool deviceLinkDialogIsOpen = false;

// Tracks the transient "Connecting…" placeholder so it can be dismissed exactly
// once when the real link dialog is ready.
bool _connectingDialogOpen = false;

/// Shows a lightweight non-dismissible "Connecting…" dialog. Used to fill the
/// ~few-second gap between picking "Link a device" on the welcome screen and the
/// node finishing startup, so the screen isn't blank.
void showConnectingDialog(BuildContext context, {required String message}) {
  if (_connectingDialogOpen) return;
  _connectingDialogOpen = true;
  showHollowDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ConnectingContent(message: message),
  );
}

/// Dismisses the "Connecting…" dialog if it's showing.
void dismissConnectingDialog() {
  if (!_connectingDialogOpen) return;
  _connectingDialogOpen = false;
  final nav = hollowNavigatorKey.currentState;
  if (nav != null && nav.canPop()) nav.pop();
}

class _ConnectingContent extends StatelessWidget {
  final String message;
  const _ConnectingContent({required this.message});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 320),
          padding: const EdgeInsets.all(HollowSpacing.xl),
          decoration: BoxDecoration(
            color: hollow.elevated.withValues(alpha: 0.97),
            borderRadius: BorderRadius.circular(hollow.radiusLg),
            border: Border.all(color: hollow.accent.withValues(alpha: 0.15)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(strokeWidth: 2.5, color: hollow.accent),
              ),
              const SizedBox(height: HollowSpacing.lg),
              Text(
                message,
                textAlign: TextAlign.center,
                style: HollowTypography.body.copyWith(color: hollow.textPrimary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Returns `true` if the user cancelled the enter-code flow and wants to go BACK
/// (used by the first-run "Link a device" path to re-show the Welcome dialog).
/// Returns `false`/`null` in every other case (completed, declined, closed).
Future<bool?> showDeviceLinkDialog(
  BuildContext context, {
  required DeviceLinkMode mode,
}) {
  return showHollowDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _DeviceLinkContent(mode: mode),
  );
}

class _DeviceLinkContent extends ConsumerStatefulWidget {
  final DeviceLinkMode mode;
  const _DeviceLinkContent({required this.mode});

  @override
  ConsumerState<_DeviceLinkContent> createState() => _DeviceLinkContentState();
}

class _DeviceLinkContentState extends ConsumerState<_DeviceLinkContent> {
  final _codeController = TextEditingController();
  bool _includeFiles = false;
  bool _includeVault = false;
  bool _restartScheduled = false;
  Timer? _countdownTimer;
  int _countdown = 300;

  @override
  void initState() {
    super.initState();
    deviceLinkDialogIsOpen = true;
    // Defer provider mutation until after the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Only mint a fresh code when we're actually idle. If the dialog was opened
      // BECAUSE an inbound link request arrived (phase already confirmPush — the
      // global listener in the shell pops us in showCode mode to render the
      // confirm), do NOT claim a new code: that's the "entering the code spawns a
      // new code on the other device" bug.
      if (widget.mode == DeviceLinkMode.showCode &&
          ref.read(deviceLinkSyncProvider).phase == LinkPhase.idle) {
        ref.read(deviceLinkSyncProvider.notifier).startShowingCode();
        _startCountdown();
      }
    });
  }

  void _startCountdown() {
    _countdown = 300;
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _countdown--);
      if (_countdown <= 0) {
        t.cancel();
        ref.read(deviceLinkSyncProvider.notifier).cancelShowingCode();
      }
    });
  }

  @override
  void dispose() {
    deviceLinkDialogIsOpen = false;
    _countdownTimer?.cancel();
    _codeController.dispose();
    super.dispose();
  }

  void _close() {
    final notifier = ref.read(deviceLinkSyncProvider.notifier);
    final phase = ref.read(deviceLinkSyncProvider).phase;
    if (phase == LinkPhase.showingCode) notifier.cancelShowingCode();
    notifier.reset();
    // Pop with `true` so the first-run link flow re-shows the Welcome dialog
    // ("Cancel goes back"). Other callers (Settings) ignore the result.
    Navigator.of(context).maybePop(true);
  }

  String _fmtBytes(int b) {
    if (b >= 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    if (b >= 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    return '$b B';
  }

  String _fmtCountdown(int s) {
    final m = (s ~/ 60).toString();
    final ss = (s % 60).toString().padLeft(2, '0');
    return '$m:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final state = ref.watch(deviceLinkSyncProvider);
    final radius = BorderRadius.circular(hollow.radiusLg);
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isCompact = screenWidth < 600;
    final minWidth =
        isCompact ? (screenWidth - HollowSpacing.xl * 2).clamp(0.0, 480.0) : 360.0;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HollowSpacing.xl),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 460, minWidth: minWidth),
          child: Material(
            color: Colors.transparent,
            child: Container(
              decoration: BoxDecoration(
                color: hollow.elevated.withValues(alpha: 0.97),
                borderRadius: radius,
                border: Border.all(color: hollow.accent.withValues(alpha: 0.15)),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 32),
                ],
              ),
              padding: const EdgeInsets.all(HollowSpacing.xl),
              child: SingleChildScrollView(child: _body(hollow, state)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(HollowTheme hollow, DeviceLinkState state) {
    switch (state.phase) {
      case LinkPhase.confirmPush:
        return _confirmPush(hollow, state);
      case LinkPhase.receiving:
      case LinkPhase.importing:
      case LinkPhase.waiting:
        return _progress(hollow, state);
      case LinkPhase.sending:
        return _sending(hollow);
      case LinkPhase.pushDone:
        return _pushDone(hollow, state);
      case LinkPhase.done:
        return _done(hollow, state);
      case LinkPhase.failed:
        return _failed(hollow, state);
      case LinkPhase.showingCode:
        return _showCode(hollow, state);
      case LinkPhase.idle:
        return widget.mode == DeviceLinkMode.enterCode
            ? _enterCode(hollow)
            : _showCode(hollow, state);
    }
  }

  Widget _header(HollowTheme hollow, IconData icon, String title, String subtitle) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: hollow.accent.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(hollow.radiusMd),
          ),
          child: Icon(icon, size: 26, color: hollow.accent),
        ),
        const SizedBox(height: HollowSpacing.md),
        Text(title, style: HollowTypography.heading.copyWith(color: hollow.textPrimary)),
        const SizedBox(height: HollowSpacing.xs),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: HollowTypography.body.copyWith(color: hollow.textSecondary, fontSize: 13),
        ),
      ],
    );
  }

  // ── Show code (populated device) ───────────────────────────────────────────
  Widget _showCode(HollowTheme hollow, DeviceLinkState state) {
    final code = state.code ?? '······';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _header(hollow, LucideIcons.smartphone, 'Link a device',
            'On your other (empty) device, choose "Link a device" and enter this code.'),
        const SizedBox(height: HollowSpacing.xl),
        // Big code.
        Container(
          padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.lg, vertical: HollowSpacing.md),
          decoration: BoxDecoration(
            color: hollow.surface.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(hollow.radiusMd),
            border: Border.all(color: hollow.accent.withValues(alpha: 0.25)),
          ),
          child: Text(
            code.split('').join(' '),
            style: HollowTypography.heading.copyWith(
              color: hollow.textPrimary,
              fontFamily: 'monospace',
              fontSize: 30,
              letterSpacing: 2,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: HollowSpacing.sm),
        Text(
          'Expires in ${_fmtCountdown(_countdown)}',
          style: HollowTypography.caption.copyWith(
            color: _countdown < 30 ? hollow.error : hollow.textSecondary,
            fontSize: 12,
          ),
        ),
        const SizedBox(height: HollowSpacing.md),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(LucideIcons.info, size: 13, color: hollow.textSecondary),
            const SizedBox(width: HollowSpacing.xs),
            Flexible(
              child: Text(
                'Keep this device online until the transfer finishes.',
                style: HollowTypography.caption
                    .copyWith(color: hollow.textSecondary, fontSize: 11),
              ),
            ),
          ],
        ),
        const SizedBox(height: HollowSpacing.lg),
        HollowButton.ghost(onPressed: _close, expand: true, child: const Text('Cancel')),
      ],
    );
  }

  // ── Enter code (empty device) ──────────────────────────────────────────────
  Widget _enterCode(HollowTheme hollow) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(hollow, LucideIcons.download, 'Link this device',
            'Enter the 6-character code shown on your other device to pull all your data.'),
        const SizedBox(height: HollowSpacing.xl),
        HollowTextField(
          controller: _codeController,
          hintText: 'ABC123',
          autofocus: true,
          inputFormatters: [
            UpperCaseTextFormatter(),
            LengthLimitingTextInputFormatter(6),
          ],
          style: HollowTypography.heading.copyWith(
            color: hollow.textPrimary,
            fontFamily: 'monospace',
            letterSpacing: 6,
            fontSize: 22,
          ),
        ),
        const SizedBox(height: HollowSpacing.sm),
        // NOTE: no files/vault toggles here — the POPULATED device chooses scope
        // when it confirms the push (it's the one building the snapshot). Showing
        // them here too was duplicated + misleading.
        Text(
          'Your messages, friends and profile transfer automatically.',
          style: HollowTypography.caption.copyWith(color: hollow.textSecondary, fontSize: 11),
        ),
        const SizedBox(height: HollowSpacing.lg),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            HollowButton.ghost(onPressed: _close, child: const Text('Cancel')),
            const SizedBox(width: HollowSpacing.sm),
            HollowButton.filled(
              onPressed: () {
                final code = _codeController.text.trim();
                if (code.length == 6) {
                  // Scope is decided by the populated device; pass false here.
                  ref.read(deviceLinkSyncProvider.notifier).enterCode(
                        code,
                        includeVault: false,
                        includeFiles: false,
                      );
                }
              },
              child: const Text('Link'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _scopeToggles(HollowTheme hollow) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('TRANSFER OPTIONS',
            style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary, fontSize: 10, letterSpacing: 1)),
        const SizedBox(height: HollowSpacing.sm),
        _checkRow(hollow, 'Include downloaded files', _includeFiles,
            () => setState(() => _includeFiles = !_includeFiles)),
        const SizedBox(height: HollowSpacing.xs),
        _checkRow(hollow, 'Include vault shard data', _includeVault,
            () => setState(() => _includeVault = !_includeVault)),
        const SizedBox(height: HollowSpacing.xs),
        Text(
          'Messages, friends and profile always transfer. Files re-sync automatically if left off.',
          style: HollowTypography.caption
              .copyWith(color: hollow.textSecondary, fontSize: 10),
        ),
      ],
    );
  }

  Widget _checkRow(HollowTheme hollow, String label, bool value, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Row(
        children: [
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: value ? hollow.accent : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: value ? hollow.accent : hollow.border, width: 1.5),
            ),
            child: value ? const Icon(LucideIcons.check, size: 12, color: Colors.white) : null,
          ),
          const SizedBox(width: HollowSpacing.sm),
          Text(label,
              style: HollowTypography.body.copyWith(color: hollow.textPrimary, fontSize: 13)),
        ],
      ),
    );
  }

  // ── Confirm push (populated device got a request) ──────────────────────────
  Widget _confirmPush(HollowTheme hollow, DeviceLinkState state) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(hollow, LucideIcons.shieldCheck, 'Send your data?',
            'Your other device is asking to sync. This sends your full history and identity to it.'),
        const SizedBox(height: HollowSpacing.lg),
        _scopeToggles(hollow),
        const SizedBox(height: HollowSpacing.lg),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            HollowButton.ghost(
              onPressed: () {
                if (state.peerId != null) {
                  ref.read(deviceLinkSyncProvider.notifier).declinePush(state.peerId!);
                }
                Navigator.of(context).maybePop();
              },
              child: const Text('Decline'),
            ),
            const SizedBox(width: HollowSpacing.sm),
            HollowButton.filled(
              onPressed: () {
                if (state.peerId != null) {
                  ref.read(deviceLinkSyncProvider.notifier).acceptPush(
                        state.peerId!,
                        includeVault: _includeVault,
                        includeFiles: _includeFiles,
                      );
                }
              },
              icon: const Icon(LucideIcons.send, size: 15),
              child: const Text('Send data'),
            ),
          ],
        ),
      ],
    );
  }

  // ── Progress (waiting / receiving / importing) ─────────────────────────────
  Widget _progress(HollowTheme hollow, DeviceLinkState state) {
    final waiting = state.phase == LinkPhase.waiting;
    final receiving = state.phase == LinkPhase.receiving;
    String label;
    if (waiting) {
      label = 'Waiting for your other device…';
    } else if (receiving) {
      label = 'Receiving data';
    } else {
      label = 'Importing…';
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(hollow, LucideIcons.refreshCw, 'Linking this device', label),
        const SizedBox(height: HollowSpacing.xl),
        // The ONE real progress bar — actual bytes, no fabrication.
        ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: LinearProgressIndicator(
            value: receiving && state.totalBytes > 0 ? state.progress : null,
            minHeight: 8,
            backgroundColor: hollow.surface,
            valueColor: AlwaysStoppedAnimation(hollow.accent),
          ),
        ),
        const SizedBox(height: HollowSpacing.sm),
        if (receiving && state.totalBytes > 0)
          Text(
            '${_fmtBytes(state.bytesReceived)} / ${_fmtBytes(state.totalBytes)}',
            style: HollowTypography.caption.copyWith(color: hollow.textSecondary, fontSize: 12),
          ),
        if (waiting) ...[
          const SizedBox(height: HollowSpacing.sm),
          Text(
            'Your other device must be online to send your data.',
            textAlign: TextAlign.center,
            style: HollowTypography.caption.copyWith(color: hollow.textSecondary, fontSize: 11),
          ),
        ],
        const SizedBox(height: HollowSpacing.lg),
        HollowButton.ghost(onPressed: _close, expand: true, child: const Text('Cancel')),
      ],
    );
  }

  // ── Sending (populated device pushing) ─────────────────────────────────────
  // The sender pushes fire-and-forget (chunks queued into the WS channel), so there
  // is no honest per-byte progress to show — an indeterminate spinner, not a bar.
  Widget _sending(HollowTheme hollow) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(hollow, LucideIcons.send, 'Sending your data',
            'Copying your messages, friends and profile to your other device…'),
        const SizedBox(height: HollowSpacing.xl),
        Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5, color: hollow.accent),
          ),
        ),
        const SizedBox(height: HollowSpacing.lg),
        Text(
          'Keep both devices online until this finishes.',
          textAlign: TextAlign.center,
          style: HollowTypography.caption.copyWith(color: hollow.textSecondary, fontSize: 11),
        ),
      ],
    );
  }

  // ── Push done (populated device, sender-only — no restart) ─────────────────
  Widget _pushDone(HollowTheme hollow, DeviceLinkState state) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(hollow, LucideIcons.checkCheck, 'Data sent',
            'Your other device received everything and will restart to finish.'),
        const SizedBox(height: HollowSpacing.lg),
        HollowButton.filled(
          onPressed: () {
            ref.read(deviceLinkSyncProvider.notifier).reset();
            Navigator.of(context).maybePop();
          },
          expand: true,
          child: const Text('Done'),
        ),
      ],
    );
  }

  // ── Done ───────────────────────────────────────────────────────────────────
  // The snapshot replaced identity.key + messages.db, and the import already closed
  // the live (throwaway) DB connection. The running process loaded the throwaway
  // identity at startup, so it CANNOT read the imported DB (real passphrase). We
  // therefore restart automatically — the relaunched process loads the real identity
  // and opens the real DB with the real data. Counts aren't shown here (they'd be 0
  // pre-restart); the populated UI appears after the relaunch.
  Widget _done(HollowTheme hollow, DeviceLinkState state) {
    // Auto-restart once, shortly after the done view appears.
    if (!_restartScheduled) {
      _restartScheduled = true;
      Future.delayed(const Duration(milliseconds: 1500), _restartApp);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(hollow, LucideIcons.checkCheck, 'Device linked',
            'Your data was copied across. Restarting Hollow to finish…'),
        const SizedBox(height: HollowSpacing.lg),
        Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5, color: hollow.accent),
          ),
        ),
        const SizedBox(height: HollowSpacing.lg),
        Text(
          'Servers & their history were copied too. New server messages will appear '
          'once multi-device servers ship.',
          textAlign: TextAlign.center,
          style: HollowTypography.caption.copyWith(color: hollow.textSecondary, fontSize: 10),
        ),
        const SizedBox(height: HollowSpacing.md),
        HollowButton.filled(
          onPressed: _restartApp,
          icon: const Icon(LucideIcons.power, size: 15),
          expand: true,
          child: const Text('Restart now'),
        ),
      ],
    );
  }

  Future<void> _restartApp() async {
    // Mirror the existing "Apply & Restart" self-relaunch (user_settings_dialog):
    // tell the node to shut down, spawn a fresh copy of ourselves, then exit. On
    // mobile resolvedExecutable can't relaunch the app, so we just exit and the
    // user re-opens it.
    try {
      await network_api.notifyShutdown();
      await Future.delayed(const Duration(milliseconds: 200));
    } catch (_) {}
    try {
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        await Process.start(Platform.resolvedExecutable, const [],
            mode: ProcessStartMode.detached);
        await Future.delayed(const Duration(milliseconds: 100));
      }
    } catch (_) {}
    exit(0);
  }

  // ── Failed ─────────────────────────────────────────────────────────────────
  Widget _failed(HollowTheme hollow, DeviceLinkState state) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(hollow, LucideIcons.alertTriangle, 'Link failed',
            state.error ?? 'Something went wrong.'),
        const SizedBox(height: HollowSpacing.lg),
        HollowButton.ghost(
          onPressed: () {
            ref.read(deviceLinkSyncProvider.notifier).reset();
            Navigator.of(context).maybePop();
          },
          expand: true,
          child: const Text('Close'),
        ),
      ],
    );
  }
}

/// Uppercases typed link-code input as it's entered.
class UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    return TextEditingValue(
      text: newValue.text.toUpperCase(),
      selection: newValue.selection,
    );
  }
}
