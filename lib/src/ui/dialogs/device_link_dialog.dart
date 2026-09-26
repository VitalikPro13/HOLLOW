import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/app_relaunch.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/device_link_sync_provider.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/storage_provider.dart'
    show formatBytes;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/app.dart' show hollowNavigatorKey;
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_progress_bar.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/dialogs/welcome_frame.dart';
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

/// Drawn in Welcome's frame, so the first-run link reads as one flow.
class _ConnectingContent extends StatelessWidget {
  final String message;
  const _ConnectingContent({required this.message});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return WelcomeFrame(
      title: 'Link a device',
      body: _SpinnerLine(
        line: message,
        style: HollowTypography.body.copyWith(color: hollow.textPrimary),
      ),
    );
  }
}

/// A spinner beside one line of text: a wait with nothing to count.
class _SpinnerLine extends StatelessWidget {
  final String line;
  final TextStyle style;
  final bool large;

  const _SpinnerLine({
    required this.line,
    required this.style,
    this.large = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        large ? const HollowSpinner.medium() : const HollowSpinner(),
        const SizedBox(width: HollowSpacing.md),
        Expanded(child: Text(line, style: style)),
      ],
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

class _DeviceLinkContentState extends ConsumerState<_DeviceLinkContent>
    with HollowDialogAction {
  final _codeController = TextEditingController();
  String? _codeError;
  bool _includeFiles = false;
  bool _includeVault = false;
  bool _restartScheduled = false;

  /// Link was pressed before the relay was up; it goes once it is.
  bool _linkWaitsForRelay = false;
  Timer? _restartTimer;
  int _restartIn = 3;

  /// The device whose request is being declined: the decline resets the
  /// provider at once, so the confirm view stays up until the answer is sent.
  String? _decliningPeer;
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
    _restartTimer?.cancel();
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

  String _fmtCountdown(int s) {
    final m = (s ~/ 60).toString();
    final ss = (s % 60).toString().padLeft(2, '0');
    return '$m:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final state = ref.watch(deviceLinkSyncProvider);
    // The empty device is still on its first run, so its steps stay in
    // Welcome's frame; the populated device answers in ordinary dialogs.
    if (widget.mode == DeviceLinkMode.enterCode)
      return _receiver(hollow, state);
    final declining = _decliningPeer;
    if (declining != null) return _confirmPush(hollow, declining);
    return switch (state.phase) {
      LinkPhase.confirmPush => _confirmPush(hollow, state.peerId),
      // Receiving phases belong to the empty device; drawn the same wherever
      // they surface.
      LinkPhase.receiving ||
      LinkPhase.importing ||
      LinkPhase.waiting ||
      LinkPhase.done => _receiver(hollow, state),
      LinkPhase.sending => _sending(hollow),
      LinkPhase.pushDone => _pushDone(),
      LinkPhase.failed => _failed(state),
      LinkPhase.showingCode || LinkPhase.idle => _showCode(hollow, state),
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
      busy: actionRunning,
      error: actionError,
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
        // Read off this screen and typed on another, so it is large and spaced
        // rather than a copy field.
        Text(
          code.split('').join(' '),
          textAlign: TextAlign.center,
          semanticsLabel: 'Link code ${code.split('').join(' ')}',
          style: HollowTypography.display.copyWith(
            color: hollow.textPrimary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: HollowSpacing.xs),
        Text(
          'Expires in ${_fmtCountdown(_countdown)}',
          textAlign: TextAlign.center,
          style: HollowTypography.bodySmall.copyWith(
            color: _countdown < 30 ? hollow.error : hollow.textSecondary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: HollowSpacing.lg),
        const HollowDialogText(
          'Keep this device online until the transfer finishes.',
        ),
      ],
      actions: [
        HollowButton.ghost(onPressed: _close, child: const Text('Cancel')),
      ],
    );
  }

  Widget _receiver(HollowTheme hollow, DeviceLinkState state) {
    return switch (state.phase) {
      LinkPhase.waiting => _wait(
        hollow,
        line: 'Waiting for your other device',
        sub: 'Approve the request there. It asks before it sends anything.',
        cancel: true,
      ),
      LinkPhase.importing => _wait(
        hollow,
        line: 'Setting up this device',
        sub: 'Almost done. Hollow restarts by itself when this finishes.',
        cancel: false,
      ),
      LinkPhase.receiving => _receiving(hollow, state),
      LinkPhase.done => _linked(hollow),
      LinkPhase.failed => _receiveFailed(hollow, state),
      _ => _enterCode(hollow),
    };
  }

  Widget _enterCode(HollowTheme hollow) {
    final online = ref.watch(overallConnectionProvider).isOnline;
    ref.listen(overallConnectionProvider, (_, next) {
      if (next.isOnline && _linkWaitsForRelay) {
        setState(() => _linkWaitsForRelay = false);
        _submitCode();
      }
    });
    final phone = WelcomeFrame.isPhone(context);
    final complete = _codeController.text.length == 6;
    return WelcomeFrame(
      title: 'Link a device',
      onBack: _close,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'On your other device, open Settings, then Devices, then Link a '
            'device. Enter the code it shows.',
            style: HollowTypography.body.copyWith(color: hollow.textSecondary),
          ),
          const SizedBox(height: HollowSpacing.xl),
          Text(
            'Link code',
            style: HollowTypography.label.copyWith(color: hollow.textSecondary),
          ),
          const SizedBox(height: HollowSpacing.sm),
          LinkCodeField(
            controller: _codeController,
            hasError: _codeError != null,
            onChanged: (_) => setState(() => _codeError = null),
            onSubmitted: (_) => _pressLink(online),
          ),
          const SizedBox(height: HollowSpacing.sm),
          Text(
            _codeError ?? 'Letters and digits. Capitals do not matter.',
            style: _codeError == null
                ? HollowTypography.caption.copyWith(color: hollow.textTertiary)
                : HollowTypography.bodySmall.copyWith(color: hollow.error),
          ),
          if (!online) ...[
            const SizedBox(height: HollowSpacing.lg),
            _SpinnerLine(
              line: 'Connecting to the relay. You can type the code meanwhile.',
              style: HollowTypography.bodySmall.copyWith(
                color: hollow.textSecondary,
              ),
            ),
          ],
        ],
      ),
      bottom: WelcomeActions(
        children: [
          HollowButton.filled(
            expand: phone,
            touch: phone,
            loading: _linkWaitsForRelay,
            onPressed: complete ? () => _pressLink(online) : null,
            child: const Text('Link'),
          ),
        ],
      ),
    );
  }

  void _pressLink(bool online) {
    final code = _codeController.text;
    if (code.length != 6) {
      setState(
        () => _codeError = code.isEmpty
            ? 'Enter the code shown on your other device.'
            : 'The code has 6 characters. Check it on your other device.',
      );
      return;
    }
    if (online) {
      _submitCode();
    } else {
      setState(() => _linkWaitsForRelay = true);
    }
  }

  void _submitCode() {
    // Scope is decided by the populated device when it confirms the push,
    // because it is the one building the snapshot. A failure arrives as the
    // provider's failed phase.
    ref
        .read(deviceLinkSyncProvider.notifier)
        .enterCode(
          _codeController.text,
          includeVault: false,
          includeFiles: false,
        )
        .catchError((_) {});
  }

  Widget _wait(
    HollowTheme hollow, {
    required String line,
    required String sub,
    required bool cancel,
  }) {
    final phone = WelcomeFrame.isPhone(context);
    return WelcomeFrame(
      title: 'Linking this device',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SpinnerLine(
            line: line,
            large: true,
            style: HollowTypography.body.copyWith(color: hollow.textPrimary),
          ),
          const SizedBox(height: HollowSpacing.sm),
          Text(
            sub,
            style: HollowTypography.bodySmall.copyWith(
              color: hollow.textSecondary,
            ),
          ),
        ],
      ),
      bottom: cancel
          ? WelcomeActions(
              children: [
                HollowButton.ghost(
                  expand: phone,
                  touch: phone,
                  onPressed: _close,
                  child: const Text('Cancel'),
                ),
              ],
            )
          : null,
    );
  }

  Widget _receiving(HollowTheme hollow, DeviceLinkState state) {
    final phone = WelcomeFrame.isPhone(context);
    final counted = state.totalBytes > 0;
    return WelcomeFrame(
      title: 'Linking this device',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Receiving your data',
            style: HollowTypography.body.copyWith(color: hollow.textPrimary),
          ),
          const SizedBox(height: HollowSpacing.lg),
          // The ONE real progress bar: actual bytes, never a fabricated ramp.
          if (counted)
            HollowProgressBar(
              value: state.progress,
              semanticLabel: 'Link progress',
            )
          else
            const Align(
              alignment: Alignment.centerLeft,
              child: HollowSpinner.medium(),
            ),
          const SizedBox(height: HollowSpacing.sm),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Keep both devices online.',
                  style: HollowTypography.bodySmall.copyWith(
                    color: hollow.textSecondary,
                  ),
                ),
              ),
              if (counted)
                Text(
                  '${formatBytes(state.bytesReceived)} of '
                  '${formatBytes(state.totalBytes)}',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textTertiary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
            ],
          ),
        ],
      ),
      bottom: WelcomeActions(
        children: [
          HollowButton.ghost(
            expand: phone,
            touch: phone,
            onPressed: _close,
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  // The snapshot replaced the identity and the database, and this process still
  // holds the throwaway identity it started with, so it CANNOT read the imported
  // DB. Hence the automatic restart; counts would read 0 until it happens.
  Widget _linked(HollowTheme hollow) {
    if (!_restartScheduled) {
      _restartScheduled = true;
      _restartTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) return t.cancel();
        if (_restartIn <= 1) {
          t.cancel();
          _restartApp();
          return;
        }
        setState(() => _restartIn--);
      });
    }
    final phone = WelcomeFrame.isPhone(context);
    return WelcomeFrame(
      title: 'Linked',
      body: Text(
        'Hollow restarts to finish. Your servers and history came across.',
        style: HollowTypography.body.copyWith(color: hollow.textSecondary),
      ),
      bottom: WelcomeActions(
        lead: Text(
          _restartIn == 1
              ? 'Restarting in 1 second'
              : 'Restarting in $_restartIn seconds',
          style: HollowTypography.caption.copyWith(
            color: hollow.textTertiary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        children: [
          HollowButton.filled(
            expand: phone,
            touch: phone,
            onPressed: _restartApp,
            child: const Text('Restart now'),
          ),
        ],
      ),
    );
  }

  // A wrong or expired code is recoverable, so "Try again" resets to idle and
  // re-renders the enter-code view in place. "Back" still goes to Welcome,
  // where the shell discards the throwaway identity and relaunches.
  Widget _receiveFailed(HollowTheme hollow, DeviceLinkState state) {
    final phone = WelcomeFrame.isPhone(context);
    return WelcomeFrame(
      title: 'Link failed',
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: HollowSpacing.xxs),
            child: Icon(LucideIcons.circleAlert, size: 16, color: hollow.error),
          ),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Text(
              state.error ?? kGenericErrorSentence,
              style: HollowTypography.body.copyWith(color: hollow.error),
            ),
          ),
        ],
      ),
      bottom: WelcomeActions(
        children: [
          HollowButton.ghost(
            expand: phone,
            touch: phone,
            onPressed: _close,
            child: const Text('Back'),
          ),
          HollowButton.filled(
            expand: phone,
            touch: phone,
            onPressed: () {
              _codeController.clear();
              ref.read(deviceLinkSyncProvider.notifier).reset();
            },
            child: const Text('Try again'),
          ),
        ],
      ),
    );
  }

  Widget _scopeToggles(HollowTheme hollow) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const HollowSectionHeader('Transfer options', dense: true),
        _toggleRow(
          hollow,
          'Include downloaded files',
          _includeFiles,
          (v) => setState(() => _includeFiles = v),
        ),
        const SizedBox(height: HollowSpacing.xs),
        _toggleRow(
          hollow,
          'Include files you keep for your servers',
          _includeVault,
          (v) => setState(() => _includeVault = v),
        ),
        const SizedBox(height: HollowSpacing.xs),
        Text(
          'Messages, friends and profile always transfer. Files download '
          'again on their own if you leave these off.',
          style: HollowTypography.bodySmall.copyWith(
            color: hollow.textSecondary,
          ),
        ),
      ],
    );
  }

  Widget _toggleRow(
    HollowTheme hollow,
    String label,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
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

  Widget _confirmPush(HollowTheme hollow, String? peerId) {
    final declining = _decliningPeer != null;
    return _phase(
      title: 'Send your data?',
      subtitle:
          'Your other device is asking to sync. This sends your full history and identity to it.',
      children: [_scopeToggles(hollow)],
      actions: [
        HollowButton.ghost(
          onPressed: peerId == null ? null : () => _decline(peerId),
          loading: declining && actionRunning,
          child: const Text('Decline'),
        ),
        HollowButton.filled(
          onPressed: peerId == null || actionRunning
              ? null
              : () => _accept(peerId),
          icon: const Icon(LucideIcons.send, size: 14),
          child: const Text('Send data'),
        ),
      ],
    );
  }

  Future<void> _decline(String peerId) async {
    setState(() => _decliningPeer = peerId);
    final done = await runDialogAction(
      () => ref.read(deviceLinkSyncProvider.notifier).declinePush(peerId),
      fallback: "Hollow couldn't answer your other device. Try again.",
    );
    if (done && mounted) Navigator.of(context).maybePop();
  }

  // The provider moves to Sending before the call, so a throw has to move it
  // on to Failed, or the dialog would sit on "Sending your data" for good.
  Future<void> _accept(String peerId) async {
    final notifier = ref.read(deviceLinkSyncProvider.notifier);
    setState(() {
      _decliningPeer = null;
      actionError = null;
    });
    try {
      await notifier.acceptPush(
        peerId,
        includeVault: _includeVault,
        includeFiles: _includeFiles,
      );
    } catch (e) {
      if (!mounted) return;
      notifier.onLinkFailed(
        friendlyError(
          e,
          fallback:
              "Hollow couldn't send your data. Check that both devices "
              'are online and try again.',
        ),
      );
    }
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
        const HollowDialogText('Keep both devices online until this finishes.'),
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

  Future<void> _restartApp() async {
    // Only via the shared waiter: a directly-spawned copy dies against the
    // native single-instance forwarder while this one is still shutting down.
    await relaunchApp();
  }

  Widget _failed(DeviceLinkState state) {
    return _phase(
      title: 'Link failed',
      subtitle: state.error ?? kGenericErrorSentence,
      actions: [
        // A button rather than the close X: leaving must also reset.
        HollowButton.filled(
          onPressed: () {
            ref.read(deviceLinkSyncProvider.notifier).reset();
            Navigator.of(context).maybePop();
          },
          child: const Text('Got it'),
        ),
      ],
    );
  }
}

/// Uppercases typed link-code input as it is entered.
class UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return TextEditingValue(
      text: newValue.text
          .toUpperCase(), // design-ignore: the typed link code, data
      selection: newValue.selection,
    );
  }
}

/// The link code as six slots over one real text field, so typing, pasting,
/// Enter and assistive tech all go through a normal field while each
/// character sits in its own box.
class LinkCodeField extends StatefulWidget {
  final TextEditingController controller;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool hasError;

  const LinkCodeField({
    super.key,
    required this.controller,
    this.onChanged,
    this.onSubmitted,
    this.hasError = false,
  });

  static const int length = 6;

  @override
  State<LinkCodeField> createState() => _LinkCodeFieldState();
}

class _LinkCodeFieldState extends State<LinkCodeField> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_redraw);
    widget.controller.addListener(_redraw);
  }

  @override
  void didUpdateWidget(LinkCodeField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_redraw);
      widget.controller.addListener(_redraw);
    }
  }

  void _redraw() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_redraw);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final text = widget.controller.text;
    final height = WelcomeFrame.isPhone(context) ? 56.0 : 48.0;
    final caretAt = _focus.hasFocus && text.length < LinkCodeField.length
        ? text.length
        : -1;

    Widget slot(int i) {
      final border = widget.hasError
          ? hollow.error
          : (i == caretAt ? hollow.accent : hollow.border);
      return DecoratedBox(
        decoration: BoxDecoration(
          color: hollow.elevated,
          borderRadius: BorderRadius.circular(hollow.radiusMd),
          border: Border.all(color: border),
        ),
        child: Center(
          child: i < text.length
              ? Text(
                  text[i],
                  style: HollowTypography.display.copyWith(
                    color: hollow.textPrimary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                )
              : i == caretAt
              ? SizedBox(
                  width: HollowSpacing.xxs,
                  height: HollowSpacing.xl,
                  child: ColoredBox(color: hollow.accent),
                )
              : null,
        ),
      );
    }

    return SizedBox(
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ExcludeSemantics(
            child: Row(
              children: [
                for (var i = 0; i < LinkCodeField.length; i++) ...[
                  if (i > 0) const SizedBox(width: HollowSpacing.sm),
                  Expanded(child: slot(i)),
                ],
              ],
            ),
          ),
          // The real field: invisible, on top, so a tap anywhere focuses it.
          TextSelectionTheme(
            data: const TextSelectionThemeData(
              selectionColor: Colors.transparent,
            ),
            child: TextField(
              controller: widget.controller,
              focusNode: _focus,
              autofocus: true,
              showCursor: false,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.characters,
              keyboardType: TextInputType.visiblePassword,
              onChanged: widget.onChanged,
              onSubmitted: widget.onSubmitted,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]')),
                UpperCaseTextFormatter(),
                LengthLimitingTextInputFormatter(LinkCodeField.length),
              ],
              style: const TextStyle(color: Colors.transparent),
              // Every border and fill off: the app's field theme would
              // otherwise paint a box over the slots.
              decoration: const InputDecoration(
                // Addressed by the fleet probes; never visible.
                hintText: 'ABC123',
                hintStyle: TextStyle(color: Colors.transparent),
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                errorBorder: InputBorder.none,
                focusedErrorBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                isCollapsed: true,
                contentPadding: EdgeInsets.zero,
                semanticCounterText: '',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
