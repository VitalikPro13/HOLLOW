import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/settings/network_section.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';

/// Settings > network. Hosted by the desktop Settings place and pushed as a phone
/// sub-page under `SettingsDensity(touch: true)`; the host owns the scroll.
class NetworkSettingsPage extends StatelessWidget {
  const NetworkSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: 'Network',
      children: [
        // The desktop copies it from the profile card's footer; a phone has
        // no hover card to hold it.
        if (Platform.isAndroid || Platform.isIOS) const _PeerIdSection(),
        const RelaySettingsSection(),
        const OfflineDeliverySection(),
        const GifsAndPreviewsSection(),
        const NetworkAdvancedSettings(),
      ],
    );
  }
}

class _PeerIdSection extends ConsumerWidget {
  const _PeerIdSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final peerId = ref.watch(identityProvider).peerId ?? '';
    return SettingsSection(
      title: 'Your ID',
      children: [
        SettingsRow(
          title: peerId.isEmpty ? 'Not ready yet' : shortenPeerId(peerId),
          monoTitle: peerId.isNotEmpty,
          subtitle: 'How the network knows you',
          trailing: HollowButton.ghost(
            compact: true,
            semanticLabel: 'Copy your peer ID',
            onPressed: peerId.isEmpty
                ? null
                : () async {
                    await Clipboard.setData(ClipboardData(text: peerId));
                    if (!context.mounted) return;
                    HollowToast.show(context, 'Peer ID copied',
                        type: HollowToastType.success);
                  },
            child: const Text('Copy'),
          ),
        ),
      ],
    );
  }
}
