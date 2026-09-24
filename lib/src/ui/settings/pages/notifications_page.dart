import 'package:flutter/material.dart';
import 'package:hollow/src/ui/settings/notification_settings_section.dart';

/// Settings > notifications. Hosted by the desktop Settings place and pushed as a phone
/// sub-page under `SettingsDensity(touch: true)`; the host owns the scroll.
class NotificationsSettingsPage extends StatelessWidget {
  const NotificationsSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const NotificationSettingsView();
  }
}
