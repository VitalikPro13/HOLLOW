import 'package:flutter/material.dart';
import 'package:hollow/src/ui/settings/about_section.dart';

/// Settings > about, Updates included. Hosted by the desktop Settings place and
/// pushed as a phone sub-page under `SettingsDensity(touch: true)`; the host
/// owns the scroll.
class AboutSettingsPage extends StatelessWidget {
  const AboutSettingsPage({super.key});

  @override
  Widget build(BuildContext context) => const AboutTab();
}
