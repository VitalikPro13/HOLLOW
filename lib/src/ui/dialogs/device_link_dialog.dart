import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/app_relaunch.dart';
import 'package:hollow/src/core/providers/device_link_sync_provider.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/app.dart' show hollowNavigatorKey;
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Entry mode for the device-link dialog.
enum DeviceLinkMode {
  /// This device HAS the data, so it shows a code for an empty one to enter.
  showCode,

  /// This device is EMPTY, so it takes a code from the populated device or
  /// pulls from an auto-detected online sibling.
  enterCode,
}

/// True while a device-link dialog is mounted anywhere, so the shell's global
/// confirm-push listener does not stack a SECOND dialog on an open one: the
/// open dialog re-renders into the confirm view on the phase change.
bool deviceLinkDialogIsOpen = false;

// Tracks the transient placeholder so it is dismissed exactly once, when the
// real link dialog is ready.
bool _connectingDialogOpen = false;

/// Fills the gap between picking "Link a device" and the node finishing
/// startup, so the screen is not blank. Not dismissible.
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
    return HollowDialogSurface(
      maxWidth: 320,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const HollowSpinner.large(),
          const SizedBox(height: HollowSpacing.lg),
          Text(
            message,
            textAlign: TextAlign.center,
            style: HollowTypography.body.copyWith(color: hollow.textPrimary),
          ),
        ],
      ),
    );
  }
}

/// Returns true only when the user cancelled the enter-code flow and wants to
/// go BACK, which the first-run path uses to re-show the Welcome dialog.
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
      // Only mint a fresh code when actually idle: a dialog opened BECAUSE an
      // inbound request arrived is already past that phase, and claiming a new
      // code there spawns a second code on the other device.
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
    // Pops true so the first-run link flow re-shows the Welcome dialog; other
    // callers ignore the result.
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
    return switch (state.phase) {
      LinkPhase.confirmPush => _confirmPush(hollow, state),
      LinkPhase.receiving ||
      LinkPhase.importing ||
      LinkPhase.waiting =>
        _progress(hollow, state),
      LinkPhase.sending => _sending(hollow),
      LinkPhase.pushDone => _pushDone(),
      LinkPhase.done => _done(hollow),
      LinkPhase.failed => _failed(state),
      LinkPhase.showingCode => _showCode(hollow, state),
      LinkPhase.idle => widget.mode == DeviceLinkMode.enterCode
          ? _enterCode(hollow)
          : _showCode(hollow, state),
    };
  }

  /// Every phase is one dialog: its title, one line of prose, then extras.
  Widget _phase({
    required String title,
    required String subtitle,
    List<Widget> children = const [],
    List<Widget> actions = const [],
  }) {
    return HollowDialog(
      title: title,
      width: 420,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HollowDialogText(subtitle),
          if (children.isNotEmpty) const SizedBox(height: HollowSpacing.lg),
          ...children,
        ],
      ),
      actions: actions,
    );
  }

  Widget _showCode(HollowTheme hollow, DeviceLinkState state) {
    final code = state.code ?? '······';
    return _phase(
      title: 'Link a device',
      subtitle:
          'On your other (empty) device, choose "Link a device" and enter this code.',
      children: [
        Container(
          padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.lg, vertical: HollowSpacing.md),
          decoration: BoxDecoration(
            color: hollow.elevated,
            borderRadius: BorderRadius.circular(hollow.radiusMd),
          ),
          child: Text(
            code.split('').join(' '),
            textAlign: TextAlign.center,
            style: HollowTypography.display.copyWith(
              color: hollow.textPrimary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        const SizedBox(height: HollowSpacing.sm),
        Text(
          'Expires in ${_fmtCountdown(_countdown)}',
          textAlign: TextAlign.center,
          style: HollowTypography.bodySmall.copyWith(
            color: _countdown < 30 ? hollow.error : hollow.textSecondary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: HollowSpacing.md),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(LucideIcons.info, size: 14, color: hollow.textSecondary),
            const SizedBox(width: HollowSpacing.xs),
            Flexible(
              child: Text(
                'Keep this device online until the transfer finishes.',
                style: HollowTypography.caption
                    .copyWith(color: hollow.textSecondary),
              ),
            ),
          ],
        ),
      ],
      actions: [
        HollowButton.ghost(onPressed: _close, child: const Text('Cancel')),
      ],
    );
  }

  Widget _enterCode(HollowTheme hollow) {
    final online = ref.watch(overallConnectionProvider).isOnline;
    return _phase(
      title: 'Link this device',
      subtitle:
          'Enter the 6-character code shown on your other device to pull all your data.',
      children: [
        HollowTextField(
          controller: _codeController,
          hintText: 'ABC123',
          autofocus: true,
          inputFormatters: [
            UpperCaseTextFormatter(),
            LengthLimitingTextInputFormatter(6),
          ],
          style: HollowTypography.heading.copyWith(color: hollow.textPrimary),
        ),
        const SizedBox(height: HollowSpacing.sm),
        // No scope toggles here: the POPULATED device chooses scope when it
        // confirms the push, because it is the one building the snapshot.
        Text(
          'Your messages, friends and profile transfer automatically.',
          style: HollowTypography.caption.copyWith(color: hollow.textSecondary),
        ),
        if (!online) ...[
          const SizedBox(height: HollowSpacing.sm),
          Text(
            'Hollow is not connected to the relay yet.',
            style:
                HollowTypography.caption.copyWith(color: hollow.textSecondary),
          ),
        ],
      ],
      actions: [
        HollowButton.ghost(onPressed: _close, child: const Text('Cancel')),
        HollowButton.filled(
          onPressed: !online
              ? null
              : () {
                  final code = _codeController.text.trim();
                  if (code.length == 6) {
                    // Scope is decided by the populated device.
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
    );
  }

  Widget _scopeToggles(HollowTheme hollow) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const HollowSectionHeader('Transfer options', dense: true),
        _toggleRow(hollow, 'Include downloaded files', _includeFiles,
            (v) => setState(() => _includeFiles = v)),
        const SizedBox(height: HollowSpacing.xs),
        _toggleRow(hollow, 'Include vault shard data', _includeVault,
            (v) => setState(() => _includeVault = v)),
        const SizedBox(height: HollowSpacing.xs),
        Text(
          'Messages, friends and profile always transfer. Files re-sync automatically if left off.',
          style: HollowTypography.caption.copyWith(color: hollow.textSecondary),
        ),
      ],
    );
  }

  Widget _toggleRow(HollowTheme hollow, String label, bool value,
      ValueChanged<bool> onChanged) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: HollowTypography.label.copyWith(color: hollow.textPrimary),
          ),
        ),
        const SizedBox(width: HollowSpacing.sm),
        HollowToggle(value: value, onChanged: onChanged, semanticLabel: label),
      ],
    );
  }

  Widget _confirmPush(HollowTheme hollow, DeviceLinkState state) {
    return _phase(
      title: 'Send your data?',
      subtitle:
          'Your other device is asking to sync. This sends your full history and identity to it.',
      children: [_scopeToggles(hollow)],
      actions: [
        HollowButton.ghost(
          onPressed: () {
            if (state.peerId != null) {
              ref
                  .read(deviceLinkSyncProvider.notifier)
                  .declinePush(state.peerId!);
            }
            Navigator.of(context).maybePop();
          },
          child: const Text('Decline'),
        ),
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
          icon: const Icon(LucideIcons.send, size: 14),
          child: const Text('Send data'),
        ),
      ],
    );
  }

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

    return _phase(
      title: 'Linking this device',
      subtitle: label,
      children: [
        // The ONE real progress bar: actual bytes, never a fabricated ramp.
        ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: LinearProgressIndicator(
            value: receiving && state.totalBytes > 0 ? state.progress : null,
            minHeight: 8,
            backgroundColor: hollow.elevated,
            valueColor: AlwaysStoppedAnimation(hollow.accent),
          ),
        ),
        if (receiving && state.totalBytes > 0) ...[
          const SizedBox(height: HollowSpacing.sm),
          Text(
            '${_fmtBytes(state.bytesReceived)} / ${_fmtBytes(state.totalBytes)}',
            style: HollowTypography.bodySmall.copyWith(
              color: hollow.textSecondary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
        if (waiting) ...[
          const SizedBox(height: HollowSpacing.sm),
          Text(
            'Your other device must be online to send your data.',
            style:
                HollowTypography.caption.copyWith(color: hollow.textSecondary),
          ),
        ],
      ],
      actions: [
        HollowButton.ghost(onPressed: _close, child: const Text('Cancel')),
      ],
    );
  }

  // The sender streams chunks with no per-byte feedback, so this is a spinner
  // rather than a bar. It stays up until the RECEIVER acks, so "Data sent"
  // means the other device has everything, not that our bytes left.
  Widget _sending(HollowTheme hollow) {
    return _phase(
      title: 'Sending your data',
      subtitle:
          'Copying your messages, friends and profile to your other device…',
      children: [
        const Center(child: HollowSpinner.medium()),
        const SizedBox(height: HollowSpacing.lg),
        Text(
          'Keep both devices online until this finishes.',
          textAlign: TextAlign.center,
          style: HollowTypography.caption.copyWith(color: hollow.textSecondary),
        ),
      ],
    );
  }

  Widget _pushDone() {
    // A button rather than the close X: leaving must also reset the link.
    return _phase(
      title: 'Data sent',
      subtitle:
          'Your other device received everything and will restart to finish.',
      actions: [
        HollowButton.filled(
          onPressed: () {
            ref.read(deviceLinkSyncProvider.notifier).reset();
            Navigator.of(context).maybePop();
          },
          child: const Text('Done'),
        ),
      ],
    );
  }

  // The snapshot replaced the identity and the database, and this process still
  // holds the throwaway identity it started with, so it CANNOT read the imported
  // DB. Hence the automatic restart; counts would read 0 until it happens.
  Widget _done(HollowTheme hollow) {
    // Once only, shortly after the done view appears.
    if (!_restartScheduled) {
      _restartScheduled = true;
      Future.delayed(const Duration(milliseconds: 1500), _restartApp);
    }
    return _phase(
      title: 'Device linked',
      subtitle: 'Your data was copied across. Restarting Hollow to finish…',
      children: [
        const Center(child: HollowSpinner.medium()),
        const SizedBox(height: HollowSpacing.lg),
        Text(
          'Servers and their history were copied too. New messages reach both '
          'devices from now on.',
          textAlign: TextAlign.center,
          style: HollowTypography.caption.copyWith(color: hollow.textSecondary),
        ),
      ],
      actions: [
        HollowButton.filled(
          onPressed: _restartApp,
          icon: const Icon(LucideIcons.power, size: 14),
          child: const Text('Restart now'),
        ),
      ],
    );
  }

  Future<void> _restartApp() async {
    // Only via the shared waiter: a directly-spawned copy dies against the
    // native single-instance forwarder while this one is still shutting down.
    await relaunchApp();
  }

  Widget _failed(DeviceLinkState state) {
    // A wrong or expired code is recoverable, so "Try again" resets to idle and
    // re-renders the enter-code view in place. "Back" still goes to Welcome,
    // where the shell discards the throwaway identity and relaunches.
    final isEnterCode = widget.mode == DeviceLinkMode.enterCode;
    return _phase(
      title: 'Link failed',
      subtitle: state.error ?? 'Something went wrong.',
      actions: isEnterCode
          ? [
              HollowButton.ghost(onPressed: _close, child: const Text('Back')),
              HollowButton.filled(
                onPressed: () {
                  // Back to the enter-code view in place.
                  _codeController.clear();
                  ref.read(deviceLinkSyncProvider.notifier).reset();
                },
                child: const Text('Try again'),
              ),
            ]
          : [
              // A button rather than the close X: leaving must also reset.
              HollowButton.ghost(
                onPressed: () {
                  ref.read(deviceLinkSyncProvider.notifier).reset();
                  Navigator.of(context).maybePop();
                },
                child: const Text('Close'),
              ),
            ],
    );
  }
}

/// Uppercases typed link-code input as it is entered.
class UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    return TextEditingValue(
      text: newValue.text.toUpperCase(), // design-ignore: the typed link code, data
      selection: newValue.selection,
    );
  }
}
