import 'package:flutter/material.dart';
import 'package:hollow/src/ui/settings/appearance_section.dart';

/// Settings > appearance. Hosted by the desktop Settings place and pushed as a phone
/// sub-page under `SettingsDensity(touch: true)`; the host owns the scroll.
class AppearanceSettingsPage extends StatelessWidget {
  const AppearanceSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppearanceSettingsView();
  }
}
