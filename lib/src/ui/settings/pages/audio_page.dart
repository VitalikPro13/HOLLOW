import 'package:flutter/material.dart';
import 'package:hollow/src/ui/settings/audio_section.dart';

/// Settings > audio. Hosted by the desktop Settings place and pushed as a phone
/// sub-page under `SettingsDensity(touch: true)`; the host owns the scroll.
class AudioSettingsPage extends StatelessWidget {
  const AudioSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const AudioVideoSettingsView();
  }
}
