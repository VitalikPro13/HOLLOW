import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/app_lock_provider.dart';
import 'package:hollow/src/core/providers/relay_denial_provider.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/core/providers/settings_place_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_settings_tab.dart';

/// Shows, once per refusal, that this relay refuses our account or network, with
/// the two ways out: another relay in Relay settings, or asking this one again.
/// Never switches relays on its own, and never shows above the app lock: a refusal
/// that lands while locked waits for the unlock. [touch] opens the phone's settings.
void listenForRelayLoginDenial(
  WidgetRef ref,
  BuildContext Function() context, {
  bool touch = false,
}) {
  String? shown;
  void sync() {
    final kind = ref.read(relayLoginDenialProvider);
    if (kind == null) {
      shown = null;
      return;
    }
    if (kind == shown || ref.read(appLockedProvider)) return;
    final at = context();
    if (!at.mounted) return;
    shown = kind;
    showRelayLoginDenial(at, kind, touch: touch);
  }

  ref.listenManual<String?>(relayLoginDenialProvider, (_, _) => sync());
  ref.listenManual<bool>(appLockedProvider, (_, _) => sync());
}

bool _denialOpen = false;

/// The refused-login dialog, also opened from the connection status; one at a
/// time, since the phone's status card stays above it.
void showRelayLoginDenial(BuildContext context, String kind,
    {bool touch = false}) {
  if (_denialOpen) return;
  _denialOpen = true;
  showHollowDialog<void>(
    context: context,
    builder: (_) => _OpenMark(child: RelayDeniedDialog(kind: kind, touch: touch)),
  ).whenComplete(() => _denialOpen = false);
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
    _denialOpen = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class RelayDeniedDialog extends ConsumerWidget {
  /// The relay's code: `account_denied` or `network_denied`.
  final String kind;
  final bool touch;

  const RelayDeniedDialog({super.key, required this.kind, this.touch = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final domain = ref.watch(relayDomainProvider);
    return HollowDialog(
      title: kRelayLoginDeniedTitle,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HollowDialogText(
              '${relayLoginDenialText(kind)} $kLoginDeniedStopsText'),
          const SizedBox(height: HollowSpacing.sm),
          const HollowDialogText('$kDeniedKeepsText $kLoginDeniedWorksText'),
          const SizedBox(height: HollowSpacing.md),
          Text(domain,
              style: HollowTypography.mono.copyWith(color: hollow.textTertiary)),
        ],
      ),
      showClose: true,
      leadingActions: [
        HollowButton.ghost(
          onPressed: () {
            // Read before the pop: this dialog's ref dies with it.
            final read = ProviderScope.containerOf(context, listen: false).read;
            final root = Navigator.of(context, rootNavigator: true);
            Navigator.of(context).pop();
            if (touch) {
              openMobileSettingsPage(root.context, SettingsCategory.network);
            } else {
              openSettings(read, category: SettingsCategory.network);
            }
          },
          child: const Text('Relay settings'),
        ),
      ],
      actions: [
        HollowButton.filled(
          onPressed: () {
            // A refusal again shows this again.
            ref.read(relayLoginDenialProvider.notifier).state = null;
            retryRelayDenials();
            Navigator.of(context).pop();
          },
          child: const Text('Try again'),
        ),
      ],
    );
  }
}
