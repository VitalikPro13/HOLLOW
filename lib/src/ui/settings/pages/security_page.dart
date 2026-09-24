import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/settings/blocked_users_shared.dart';
import 'package:hollow/src/ui/settings/duress_section.dart';
import 'package:hollow/src/ui/settings/security_section.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:hollow/src/ui/settings/verified_contacts_shared.dart';
import 'package:hollow/src/ui/settings/verify_proof_section.dart';

/// Settings > Security. Hosted by the desktop Settings place and pushed as a
/// phone sub-page under `SettingsDensity(touch: true)`; the host owns the
/// scroll.
class SecuritySettingsPage extends StatelessWidget {
  const SecuritySettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final desktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    return SettingsPage(
      title: 'Security',
      children: [
        const SecurityAppLockSection(),
        const SecurityRecoverySection(),
        SettingsSection(
          title: 'Privacy',
          children: [
            const AlwaysRelayCallsToggle(),
            if (desktop) const PeerForwardingToggle(),
          ],
        ),
        const SettingsSection(
          title: 'People',
          children: [VerifiedContactsExpandRow(), BlockedUsersExpandRow()],
        ),
        SettingsAdvanced(
          children: [
            SettingsRow(
              title: 'Check a message proof',
              subtitle: 'Paste a proof to confirm who signed a message',
              trailing: HollowButton.outline(
                compact: true,
                onPressed: () => showVerifyProofDialog(context),
                child: const Text('Open'),
              ),
            ),
          ],
        ),
        const SettingsSection(
          title: 'Danger zone',
          children: [AccountDangerZoneCard()],
        ),
      ],
    );
  }
}
