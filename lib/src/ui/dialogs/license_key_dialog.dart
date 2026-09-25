import 'dart:io';

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

/// Asks for the access key a SELF-HOSTED relay's owner switched on; the
/// default relay never asks. Resolves to the typed key. The only other way
/// out is back to the default relay, which restarts Hollow.
Future<String?> showLicenseKeyDialog(
  BuildContext context, {
  String? error,
}) {
  return showHollowDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => _LicenseKeyContent(initialError: error),
  );
}

class _LicenseKeyContent extends ConsumerStatefulWidget {
  final String? initialError;
  const _LicenseKeyContent({this.initialError});

  @override
  ConsumerState<_LicenseKeyContent> createState() => _LicenseKeyContentState();
}

class _LicenseKeyContentState extends ConsumerState<_LicenseKeyContent>
    with HollowDialogAction {
  final _controller = TextEditingController();
  String? _error;

  static final _isMobile = Platform.isAndroid || Platform.isIOS;

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

  void _onSubmit() {
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

    Navigator.of(context).pop(key);
  }

  Future<void> _useDefaultRelay() => runDialogAction(() async {
        await ref
            .read(relayDomainProvider.notifier)
            .setDomain(kDefaultRelayDomain);
        await exitForRelaySwitch();
      }, fallback: "Couldn't switch relays. Try again.");

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final relay = ref.watch(relayDomainProvider);
    final onDefault = relay == kDefaultRelayDomain;

    return HollowDialog(
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
              const TextSpan(
                text: ' only lets people in with an access key, set by '
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
        ],
      ),
      // Ghost first, primary last; in the trailing row, which wraps on a
      // phone where the longer label would not fit beside Connect.
      actions: [
        if (!onDefault)
          HollowButton.ghost(
            onPressed: _useDefaultRelay,
            loading: actionRunning,
            child: Text(_isMobile
                ? 'Use the default relay and close'
                : 'Use the default relay'),
          ),
        HollowButton.filled(
          onPressed: actionRunning ? null : _onSubmit,
          child: const Text('Connect'),
        ),
      ],
    );
  }
}
