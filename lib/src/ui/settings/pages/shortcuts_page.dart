import 'package:flutter/material.dart';
import 'package:hollow/src/ui/settings/shortcuts_section.dart';

/// Settings > shortcuts. Hosted by the desktop Settings place and pushed as a phone
/// sub-page under `SettingsDensity(touch: true)`; the host owns the scroll.
class ShortcutsSettingsPage extends StatelessWidget {
  const ShortcutsSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const ShortcutsSettingsView();
  }
}
