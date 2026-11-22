import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/app_relaunch.dart';
import 'package:hollow/src/core/providers/license_key_provider.dart';
import 'package:hollow/src/core/providers/node_provider.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;

/// Asks for the access key a SELF-HOSTED relay's owner switched on; the
/// default relay never asks. Resolves to the typed key. The only other way
/// out is back to the default relay, which ends Hollow (on iOS it waits for
/// the person to close it). [linking]: this
/// device is joining an identity whose other device already holds a key, and
/// no system back leaves the prompt. [cancellable]: the person asked to replace a
/// key that still works, so Cancel keeps it. [onKey] runs INSIDE the dialog:
/// Connect loads while it runs, and a throw keeps the dialog open with the error.
Future<String?> showLicenseKeyDialog(
  BuildContext context, {
  String? error,
  bool linking = false,
  bool cancellable = false,
  Future<void> Function(String key)? onKey,
}) {
  return showHollowDialog<String>(
    context: context,
    barrierDismissible: cancellable,
    builder: (dialogContext) => _LicenseKeyContent(
        initialError: error,
        linking: linking,
        cancellable: cancellable,
        onKey: onKey),
  );
}

/// Replaces the relay's access key with one the person types, then restarts the
/// node so the next login carries it. Cancel changes nothing. [container] is read
/// after the caller's dialog is gone.
Future<void> enterAnotherAccessKey(
    BuildContext context, ProviderContainer container) async {
  await showLicenseKeyDialog(context, cancellable: true, onKey: (key) async {
    await container.read(licenseKeyProvider.notifier).setKey(key);
    await network_api.setLicenseKey(key: key);
    final node = container.read(nodeProvider.notifier);
    await node.stop();
    await node.start();
  });
}

class _LicenseKeyContent extends ConsumerStatefulWidget {
  final String? initialError;
  final bool linking;
  final bool cancellable;
  final Future<void> Function(String key)? onKey;
  const _LicenseKeyContent(
      {this.initialError,
      this.linking = false,
      this.cancellable = false,
      this.onKey});

  @override
  ConsumerState<_LicenseKeyContent> createState() => _LicenseKeyContentState();
}

class _LicenseKeyContentState extends ConsumerState<_LicenseKeyContent>
    with HollowDialogAction {
  final _controller = TextEditingController();
  String? _error;
  // Connect's own run, so the default-relay button's run never spins it.
  bool _connecting = false;

  /// This prompt saved the waiting switch (iOS), so a typed key takes it back.
  /// One saved on another screen stays: the key is for the relay running now.
  bool _switchedHere = false;

  @override
  void initState() {
    super.initState();
    _error = widget.initialError;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    // Uppercased and re-dashed as the user types.
    final raw = value.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), ''); // design-ignore: normalises a typed key
    final limited = raw.length > 16 ? raw.substring(0, 16) : raw;

    final buffer = StringBuffer();
    for (var i = 0; i < limited.length; i++) {
      if (i > 0 && i % 4 == 0) buffer.write('-');
      buffer.write(limited[i]);
    }
    final formatted = buffer.toString();

    if (formatted != _controller.text) {
      _controller.value = TextEditingValue(
        text: formatted,
        selection: TextSelection.collapsed(offset: formatted.length),
      );
    }

    if (_error != null) {
      setState(() => _error = null);
    }
  }

  Future<void> _onSubmit() async {
    if (actionRunning) return;
    final key = _controller.text.trim();
    if (key.isEmpty) {
      setState(() => _error = 'Enter the access key you were given.');
      return;
    }

    // Shape check only; the relay is the authority on validity.
    final parts = key.split('-');
    if (parts.length != 4 || parts.any((p) => p.length != 4)) {
      setState(() => _error =
          'An access key is 16 letters and numbers, like XXXX-XXXX-XXXX-XXXX.');
      return;
    }

    if (_switchedHere && ref.read(pendingRelayProvider) != null) {
      final relay = ref.read(relayDomainProvider);
      if (!await runDialogAction(
              () => ref
                  .read(relayDomainProvider.notifier)
                  .saveForNextLaunch(relay),
              fallback: "Couldn't keep this relay. Try again.") ||
          !mounted) {
        return;
      }
    }
    final onKey = widget.onKey;
    if (onKey != null) {
      setState(() => _connecting = true);
      final done = await runDialogAction(() => onKey(key),
          fallback: "Couldn't reconnect with this key. Try again.");
      if (!done) {
        if (mounted) setState(() => _connecting = false);
        return;
      }
    }
    if (mounted) Navigator.of(context).pop(key);
  }

  Future<void> _useDefaultRelay() async {
    var ending = true;
    if (await runDialogAction(
            () async => ending = await switchRelay(
                ref.read, kDefaultRelayDomain,
                endProcess: widget.linking),
            fallback: "Couldn't switch relays. Try again.") &&
        !ending &&
        mounted) {
      setState(() {
        actionRunning = false;
        _switchedHere = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final relay = ref.watch(relayDomainProvider);
    final onDefault = relay == kDefaultRelayDomain;
    final pending = ref.watch(pendingRelayProvider);
    final end = relaySwitchEnd;
    // Relay names are what the protocol produces: the console voice.
    final host = HollowTypography.mono.copyWith(color: hollow.textPrimary);
    // A linking device ends its process on every platform.
    final closes = end == RelaySwitchEnd.close ||
        (widget.linking && end == RelaySwitchEnd.closeByHand);

    // Linking: a system back would leave the shell on the throwaway (#123).
    return PopScope(canPop: !widget.linking, child: HollowDialog(
      title: 'This relay needs an access key',
      width: 420,
      busy: actionRunning,
      error: actionError,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text.rich(
            TextSpan(children: [
              TextSpan(
                text: relay,
                style: HollowTypography.mono
                    .copyWith(color: hollow.textPrimary),
              ),
              TextSpan(
                text: widget.linking
                    ? ' only lets people in with an access key. Enter the one '
                        'your other device uses.'
                    : ' only lets people in with an access key, set by '
                        'whoever runs it. Ask them for one and enter it here.',
              ),
            ]),
            style: HollowTypography.body.copyWith(color: hollow.textSecondary),
          ),
          const SizedBox(height: HollowSpacing.lg),
          HollowTextField(
            controller: _controller,
            hintText: 'XXXX-XXXX-XXXX-XXXX',
            onChanged: _onChanged,
            onSubmitted: (_) => _onSubmit(),
            autofocus: true,
            errorText: _error,
            style: HollowTypography.mono.copyWith(color: hollow.textPrimary),
          ),
          if (pending != null) ...[
            const SizedBox(height: HollowSpacing.md),
            Text.rich(
              TextSpan(
                  children: _switchedHere
                      ? [
                          const TextSpan(
                              text: 'Close Hollow from the app switcher and '
                                  'open it again to connect to '),
                          TextSpan(text: pending, style: host),
                          const TextSpan(text: '.'),
                        ]
                      : [
                          const TextSpan(text: 'Hollow connects to '),
                          TextSpan(text: pending, style: host),
                          const TextSpan(
                              text: ' after you close it from the app '
                                  'switcher and open it again. A key you '
                                  'enter here is for '),
                          TextSpan(text: relay, style: host),
                          const TextSpan(text: ', and Hollow stays on '),
                          TextSpan(text: relay, style: host),
                          const TextSpan(text: ' until then.'),
                        ]),
              style:
                  HollowTypography.body.copyWith(color: hollow.textSecondary),
            ),
          ],
        ],
      ),
      // Ghost first, primary last; in the trailing row, which wraps on a
      // phone where the longer label would not fit beside Connect.
      actions: [
        if (widget.cancellable)
          HollowButton.ghost(
            onPressed: actionRunning ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        if (!onDefault && !widget.cancellable && pending == null)
          HollowButton.ghost(
            onPressed: _useDefaultRelay,
            loading: actionRunning,
            child: Text(closes
                ? 'Use the default relay and close'
                : 'Use the default relay'),
          ),
        HollowButton.filled(
          onPressed: actionRunning ? null : _onSubmit,
          loading: _connecting,
          child: const Text('Connect'),
        ),
      ],
    ));
  }
}
