import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/license_key_provider.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/dialogs/license_key_dialog.dart';

bool _open = false;

/// Why the relay turns our login away while our access key is full (#153), and
/// the way out: another key. Opened from the connection status; one at a time.
void showAccessKeyFull(BuildContext context) {
  if (_open) return;
  _open = true;
  showHollowDialog<void>(
    context: context,
    builder: (_) => const _OpenMark(child: AccessKeyFullDialog()),
  ).whenComplete(() => _open = false);
}

/// Clears the one-at-a-time mark also when the dialog goes without a pop.
class _OpenMark extends StatefulWidget {
  final Widget child;

  const _OpenMark({required this.child});

  @override
  State<_OpenMark> createState() => _OpenMarkState();
}

class _OpenMarkState extends State<_OpenMark> {
  @override
  void dispose() {
    _open = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class AccessKeyFullDialog extends ConsumerWidget {
  const AccessKeyFullDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final domain = ref.watch(relayDomainProvider);
    return HollowDialog(
      title: kAccessKeyFullTitle,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const HollowDialogText(kAccessKeyFullText),
          const SizedBox(height: HollowSpacing.md),
          Text(domain,
              style: HollowTypography.mono.copyWith(color: hollow.textTertiary)),
        ],
      ),
      showClose: true,
      actions: [
        HollowButton.filled(
          onPressed: () {
            // Read before the pop: this dialog's ref dies with it.
            final container = ProviderScope.containerOf(context, listen: false);
            final root = Navigator.of(context, rootNavigator: true);
            Navigator.of(context).pop();
            enterAnotherAccessKey(root.context, container).catchError((_) {});
          },
          child: const Text('Enter another key'),
        ),
      ],
    );
  }
}
