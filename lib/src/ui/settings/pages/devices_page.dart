import 'package:flutter/material.dart';
import 'package:hollow/src/ui/settings/devices_section.dart';

/// Settings > devices. Hosted by the desktop Settings place and pushed as a phone
/// sub-page under `SettingsDensity(touch: true)`; the host owns the scroll.
class DevicesSettingsPage extends StatelessWidget {
  const DevicesSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const DevicesCategoryView();
  }
}
