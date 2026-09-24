import 'package:flutter/widgets.dart';
import 'package:hollow/src/core/providers/settings_place_provider.dart';
import 'package:hollow/src/ui/settings/pages/profile_page.dart';
import 'package:hollow/src/ui/settings/pages/security_page.dart';
import 'package:hollow/src/ui/settings/pages/devices_page.dart';
import 'package:hollow/src/ui/settings/pages/appearance_page.dart';
import 'package:hollow/src/ui/settings/pages/accessibility_page.dart';
import 'package:hollow/src/ui/settings/pages/notifications_page.dart';
import 'package:hollow/src/ui/settings/pages/audio_page.dart';
import 'package:hollow/src/ui/settings/pages/shortcuts_page.dart';
import 'package:hollow/src/ui/settings/pages/network_page.dart';
import 'package:hollow/src/ui/settings/pages/storage_page.dart';
import 'package:hollow/src/ui/settings/pages/about_page.dart';

/// The page for [category]: the same widget on desktop and phone.
Widget settingsPageFor(SettingsCategory category) => switch (category) {
      SettingsCategory.profile => const ProfileSettingsPage(),
      SettingsCategory.security => const SecuritySettingsPage(),
      SettingsCategory.devices => const DevicesSettingsPage(),
      SettingsCategory.appearance => const AppearanceSettingsPage(),
      SettingsCategory.accessibility => const AccessibilitySettingsPage(),
      SettingsCategory.notifications => const NotificationsSettingsPage(),
      SettingsCategory.audio => const AudioSettingsPage(),
      SettingsCategory.shortcuts => const ShortcutsSettingsPage(),
      SettingsCategory.network => const NetworkSettingsPage(),
      SettingsCategory.storage => const StorageSettingsPage(),
      SettingsCategory.about => const AboutSettingsPage(),
    };
