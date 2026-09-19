import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';

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

class _LicenseKeyContent extends StatefulWidget {
  final String? initialError;
  const _LicenseKeyContent({this.initialError});

  @override
  State<_LicenseKeyContent> createState() => _LicenseKeyContentState();
}

class _LicenseKeyContentState extends State<_LicenseKeyContent> {
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

  void _onSubmit() {
    final key = _controller.text.trim();
    if (key.isEmpty) {
      setState(() => _error = 'Please enter a license key');
      return;
    }

    // Shape check only; the relay is the authority on validity.
    final parts = key.split('-');
    if (parts.length != 4 || parts.any((p) => p.length != 4)) {
      setState(() => _error = 'Invalid key format (expected XXXX-XXXX-XXXX-XXXX)');
      return;
    }

    Navigator.of(context).pop(key);
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return HollowDialog(
      title: 'License key required',
      width: 420,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const HollowDialogText('Enter your beta access key to continue.'),
          const SizedBox(height: HollowSpacing.lg),
          HollowTextField(
            controller: _controller,
            hintText: 'HLLW-XXXX-XXXX-XXXX',
            onChanged: _onChanged,
            onSubmitted: (_) => _onSubmit(),
            autofocus: true,
            style: HollowTypography.mono.copyWith(color: hollow.textPrimary),
          ),
          if (_error != null) ...[
            const SizedBox(height: HollowSpacing.sm),
            Text(
              _error!,
              style: HollowTypography.caption.copyWith(color: hollow.error),
            ),
          ],
        ],
      ),
      actions: [
        HollowButton.filled(
          onPressed: _onSubmit,
          child: const Text('Activate'),
        ),
      ],
    );
  }
}
