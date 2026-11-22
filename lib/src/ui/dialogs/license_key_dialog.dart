import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/app_relaunch.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/dialogs/relay_switch_dialog.dart';

/// Asks for the access key a SELF-HOSTED relay's owner switched on; the
/// default relay never asks. Resolves to the typed key. The only other way
/// out is back to the default relay, which ends Hollow (on iOS it waits for
/// the person to close it). [linking]: this
/// device is joining an identity whose other device already holds a key, and
/// no system back leaves the prompt.
Future<String?> showLicenseKeyDialog(
  BuildContext context, {
  String? error,
  bool linking = false,
}) {
  return showHollowDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) =>
        _LicenseKeyContent(initialError: error, linking: linking),
  );
}

class _LicenseKeyContent extends ConsumerStatefulWidget {
  final String? initialError;
  final bool linking;
  const _LicenseKeyContent({this.initialError, this.linking = false});

  @override
  ConsumerState<_LicenseKeyContent> createState() => _LicenseKeyContentState();
}

class _LicenseKeyContentState extends ConsumerState<_LicenseKeyContent>
    with HollowDialogAction {
  final _controller = TextEditingController();
  String? _error;

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

    // A key for this relay takes back a switch waiting for the next launch.
    if (ref.read(pendingRelayProvider) != null) {
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
    Navigator.of(context).pop(key);
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
      setState(() => actionRunning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final relay = ref.watch(relayDomainProvider);
    final onDefault = relay == kDefaultRelayDomain;
    final pending = ref.watch(pendingRelayProvider);
    final end = relaySwitchEnd;
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
            Text(closeByHandText(pending),
                style: HollowTypography.body
                    .copyWith(color: hollow.textSecondary)),
          ],
        ],
      ),
      // Ghost first, primary last; in the trailing row, which wraps on a
      // phone where the longer label would not fit beside Connect.
      actions: [
        if (!onDefault && pending == null)
          HollowButton.ghost(
            onPressed: _useDefaultRelay,
            loading: actionRunning,
            child: Text(closes
                ? 'Use the default relay and close'
                : 'Use the default relay'),
          ),
        HollowButton.filled(
          onPressed: actionRunning ? null : _onSubmit,
          child: const Text('Connect'),
        ),
      ],
    ));
  }
}
