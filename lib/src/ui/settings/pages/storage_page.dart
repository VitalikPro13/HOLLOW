import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hollow/src/ui/settings/profile_locations_card.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:hollow/src/ui/settings/storage_section.dart';
import 'package:hollow/src/ui/settings/storage_settings_cards.dart';

/// Settings > storage. Hosted by the desktop Settings place and pushed as a phone
/// sub-page under `SettingsDensity(touch: true)`; the host owns the scroll.
class StorageSettingsPage extends StatelessWidget {
  const StorageSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    // Data folders and profiles are desktop things: a phone's data root is
    // sandboxed and fixed.
    final desktop = !Platform.isAndroid && !Platform.isIOS;
    return SettingsPage(
      title: 'Files & storage',
      children: [
        const StorageBreakdownView(),
        const StorageDownloadsSection(),
        if (desktop)
          const SettingsSection(
            title: 'On this computer',
            children: [DataFolderRow(), ProfileLocationsCard()],
          ),
        const StorageAdvancedSettings(),
      ],
    );
  }
}
