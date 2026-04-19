import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:lucide_icons/lucide_icons.dart';

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
    // Auto-format: uppercase, strip non-alphanumeric, insert dashes.
    final raw = value.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
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

    // Basic format check: XXXX-XXXX-XXXX-XXXX (19 chars with dashes).
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
    final radius = BorderRadius.circular(hollow.radiusLg);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HollowSpacing.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: 440,
            minWidth: 340,
          ),
          child: Material(
            color: Colors.transparent,
            child: Container(
              decoration: BoxDecoration(
                color: hollow.elevated.withValues(alpha: 0.95),
                borderRadius: radius,
                border: Border.all(
                  color: hollow.accent.withValues(alpha: 0.15),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 32,
                  ),
                ],
              ),
              padding: const EdgeInsets.all(HollowSpacing.xl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Icon
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: hollow.accent.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(hollow.radiusMd),
                    ),
                    child: Icon(
                      LucideIcons.keyRound,
                      size: 28,
                      color: hollow.accent,
                    ),
                  ),

                  const SizedBox(height: HollowSpacing.lg),

                  Text(
                    'License Key Required',
                    style: HollowTypography.heading.copyWith(
                      color: hollow.textPrimary,
                    ),
                  ),

                  const SizedBox(height: HollowSpacing.xs),

                  Text(
                    'Enter your alpha access key to continue',
                    style: HollowTypography.body.copyWith(
                      color: hollow.textSecondary,
                    ),
                    textAlign: TextAlign.center,
                  ),

                  const SizedBox(height: HollowSpacing.xl),

                  HollowTextField(
                    controller: _controller,
                    hintText: 'HLLW-XXXX-XXXX-XXXX',
                    onChanged: _onChanged,
                    onSubmitted: (_) => _onSubmit(),
                    autofocus: true,
                    style: HollowTypography.body.copyWith(
                      color: hollow.textPrimary,
                      fontFamily: 'monospace',
                      letterSpacing: 1.5,
                    ),
                  ),

                  if (_error != null) ...[
                    const SizedBox(height: HollowSpacing.sm),
                    Text(
                      _error!,
                      style: HollowTypography.caption.copyWith(
                        color: hollow.error,
                      ),
                    ),
                  ],

                  const SizedBox(height: HollowSpacing.lg),

                  HollowButton.filled(
                    onPressed: _onSubmit,
                    expand: true,
                    child: const Text('Activate'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
