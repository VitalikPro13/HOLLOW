import 'package:flutter/material.dart';
import 'package:hollow/src/ui/settings/accessibility_section.dart';

/// Settings > accessibility. Hosted by the desktop Settings place and pushed as a phone
/// sub-page under `SettingsDensity(touch: true)`; the host owns the scroll.
class AccessibilitySettingsPage extends StatelessWidget {
  const AccessibilitySettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const AccessibilitySettingsView();
  }
}
