import 'package:flutter/widgets.dart';
import 'package:hollow/src/core/providers/settings_place_provider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The rail's groups, in order. About stands alone after them.
enum SettingsGroup { account, app, connection }

extension SettingsGroupMeta on SettingsGroup {
  String get label => switch (this) {
        SettingsGroup.account => 'Account',
        SettingsGroup.app => 'App',
        SettingsGroup.connection => 'Connection and data',
      };
}

extension SettingsCategoryMeta on SettingsCategory {
  String get label => switch (this) {
        SettingsCategory.profile => 'Profile',
        SettingsCategory.security => 'Security',
        SettingsCategory.devices => 'Devices',
        SettingsCategory.appearance => 'Appearance',
        SettingsCategory.accessibility => 'Accessibility',
        SettingsCategory.notifications => 'Notifications',
        SettingsCategory.audio => 'Audio & Video',
        SettingsCategory.shortcuts => 'Shortcuts',
        SettingsCategory.network => 'Network',
        SettingsCategory.storage => 'Files & Storage',
        SettingsCategory.about => 'About',
      };

  IconData get icon => switch (this) {
        SettingsCategory.profile => LucideIcons.user,
        SettingsCategory.security => LucideIcons.shield,
        SettingsCategory.devices => LucideIcons.smartphone,
        SettingsCategory.appearance => LucideIcons.palette,
        SettingsCategory.accessibility => LucideIcons.accessibility,
        SettingsCategory.notifications => LucideIcons.bell,
        SettingsCategory.audio => LucideIcons.mic,
        SettingsCategory.shortcuts => LucideIcons.keyboard,
        SettingsCategory.network => LucideIcons.globe,
        SettingsCategory.storage => LucideIcons.hardDrive,
        SettingsCategory.about => LucideIcons.info,
      };

  /// Null for About, which sits apart at the end of the rail.
  SettingsGroup? get group => switch (this) {
        SettingsCategory.profile ||
        SettingsCategory.security ||
        SettingsCategory.devices =>
          SettingsGroup.account,
        SettingsCategory.appearance ||
        SettingsCategory.accessibility ||
        SettingsCategory.notifications ||
        SettingsCategory.audio ||
        SettingsCategory.shortcuts =>
          SettingsGroup.app,
        SettingsCategory.network ||
        SettingsCategory.storage =>
          SettingsGroup.connection,
        SettingsCategory.about => null,
      };
}

/// One findable setting: what the row is called, words people might type for
/// it, and the page it lives on.
class SettingsSearchEntry {
  final String label;
  final String keywords;
  final SettingsCategory category;

  const SettingsSearchEntry(this.label, this.category, [this.keywords = '']);

  bool matches(String query) {
    final q = query.toLowerCase();
    return label.toLowerCase().contains(q) || keywords.contains(q);
  }
}

/// Every setting search can find. Each entry names the row as the page shows
/// it; a renamed row renames its entry here.
const List<SettingsSearchEntry> kSettingsSearchIndex = [
  SettingsSearchEntry('Display name', SettingsCategory.profile, 'name nickname'),
  SettingsSearchEntry('Status', SettingsCategory.profile, 'status what are you up to'),
  SettingsSearchEntry('About me', SettingsCategory.profile, 'bio description'),
  SettingsSearchEntry('Avatar', SettingsCategory.profile, 'picture photo image gif'),
  SettingsSearchEntry('Banner', SettingsCategory.profile, 'header image'),
  SettingsSearchEntry('Frame', SettingsCategory.profile, 'avatar frame border'),
  SettingsSearchEntry('Appear invisible', SettingsCategory.profile, 'offline hidden presence'),
  SettingsSearchEntry('Twitch', SettingsCategory.profile, 'connection stream verified'),
  SettingsSearchEntry('Your art', SettingsCategory.profile, 'shop pack wear hollowpack'),
  SettingsSearchEntry('Support marks', SettingsCategory.profile, 'mark redeem code receipt'),
  SettingsSearchEntry('Password', SettingsCategory.security, 'app lock password encrypt'),
  SettingsSearchEntry('Lock after', SettingsCategory.security, 'idle lock now timeout'),
  SettingsSearchEntry('Duress code', SettingsCategory.security, 'wipe panic'),
  SettingsSearchEntry('Recovery phrase', SettingsCategory.security, 'mnemonic 24 words seed'),
  SettingsSearchEntry('Backup file', SettingsCategory.security, 'export backup'),
  SettingsSearchEntry('Always relay calls', SettingsCategory.security, 'ip address privacy turn'),
  SettingsSearchEntry('Help carry screen shares', SettingsCategory.security, 'peer media forwarding upload'),
  SettingsSearchEntry('Verified contacts', SettingsCategory.security, 'safety number verify'),
  SettingsSearchEntry('Blocked users', SettingsCategory.security, 'block unblock'),
  SettingsSearchEntry('Check a message proof', SettingsCategory.security, 'proof signature verify'),
  SettingsSearchEntry('Destroy my identity everywhere', SettingsCategory.security, 'delete wipe danger'),
  SettingsSearchEntry('Your devices', SettingsCategory.devices, 'phone laptop device revoke remove'),
  SettingsSearchEntry('Link another device', SettingsCategory.devices, 'link a device code sync new'),
  SettingsSearchEntry('Reset the device list', SettingsCategory.devices, 'ghost devices sign out'),
  SettingsSearchEntry('Sync check', SettingsCategory.devices, 'counts compare'),
  SettingsSearchEntry('Theme', SettingsCategory.appearance, 'dark light mode'),
  SettingsSearchEntry('Accent color', SettingsCategory.appearance, 'colour hue'),
  SettingsSearchEntry('Background image', SettingsCategory.appearance, 'wallpaper'),
  SettingsSearchEntry('Darken', SettingsCategory.appearance, 'background image dim'),
  SettingsSearchEntry('Ambient light', SettingsCategory.appearance, 'ambient background glow'),
  SettingsSearchEntry('Window layout', SettingsCategory.appearance, 'dock classic'),
  SettingsSearchEntry('Messages', SettingsCategory.appearance, 'cozy compact density display'),
  SettingsSearchEntry('Keep running when closed', SettingsCategory.appearance, 'tray minimize'),
  SettingsSearchEntry('Open full profiles', SettingsCategory.appearance, 'profile card expanded'),
  SettingsSearchEntry('Interface', SettingsCategory.accessibility, 'zoom scale size bigger'),
  SettingsSearchEntry('Chat text', SettingsCategory.accessibility, 'font text size bigger'),
  SettingsSearchEntry('Side panels', SettingsCategory.accessibility, 'panel size'),
  SettingsSearchEntry('Reduce motion', SettingsCategory.accessibility, 'animation'),
  SettingsSearchEntry('Reduce transparency', SettingsCategory.accessibility, 'blur glass'),
  SettingsSearchEntry('Desktop notifications', SettingsCategory.notifications, 'toast permission test'),
  SettingsSearchEntry('Servers', SettingsCategory.notifications, 'server mentions mute channel'),
  SettingsSearchEntry('Wake-up service', SettingsCategory.notifications, 'push delivery unifiedpush fcm google ntfy'),
  SettingsSearchEntry('Muted conversations', SettingsCategory.notifications, 'unmute dm'),
  SettingsSearchEntry('Microphone', SettingsCategory.audio, 'mic input device'),
  SettingsSearchEntry('Hear yourself', SettingsCategory.audio, 'test microphone mic record'),
  SettingsSearchEntry('Noise suppression', SettingsCategory.audio, 'rnnoise deepfilter background'),
  SettingsSearchEntry('Voice enhancement', SettingsCategory.audio, 'eq compressor loud'),
  SettingsSearchEntry('Automatic level', SettingsCategory.audio, 'dynamic mode loudness'),
  SettingsSearchEntry('Gain', SettingsCategory.audio, 'mic volume loud'),
  SettingsSearchEntry('Speaker', SettingsCategory.audio, 'output headphones'),
  SettingsSearchEntry('Camera', SettingsCategory.audio, 'webcam video'),
  SettingsSearchEntry('Call quality', SettingsCategory.audio, 'bitrate music hi-fi stereo'),
  SettingsSearchEntry('Send my voice', SettingsCategory.audio, 'push to talk ptt voice activity'),
  SettingsSearchEntry('Push-to-talk key', SettingsCategory.audio, 'ptt hotkey keybind'),
  SettingsSearchEntry('Ringtone', SettingsCategory.audio, 'call sound'),
  SettingsSearchEntry('Sound effects', SettingsCategory.audio, 'sounds volume'),
  SettingsSearchEntry('Keyboard shortcuts', SettingsCategory.shortcuts, 'keys hotkeys keybind'),
  SettingsSearchEntry('Relay', SettingsCategory.network, 'server domain self-host switch'),
  SettingsSearchEntry('Relay health', SettingsCategory.network, 'load bandwidth ram status'),
  SettingsSearchEntry('Hold my messages', SettingsCategory.network, 'offline delivery inbox'),
  SettingsSearchEntry('GIF rating', SettingsCategory.network, 'nsfw klipy content'),
  SettingsSearchEntry('Play GIFs automatically', SettingsCategory.network, 'animate data'),
  SettingsSearchEntry('Previews for links I send', SettingsCategory.network, 'link preview embed card'),
  SettingsSearchEntry('Storage used', SettingsCategory.storage, 'space disk clean clear'),
  SettingsSearchEntry('Download automatically', SettingsCategory.storage, 'auto download threshold'),
  SettingsSearchEntry('Image quality', SettingsCategory.storage, 'webp compression lossless'),
  SettingsSearchEntry('Data folder', SettingsCategory.storage, 'location path'),
  SettingsSearchEntry('Profiles', SettingsCategory.storage, 'switch identity folder'),
  SettingsSearchEntry('Updates', SettingsCategory.about, 'version update install check'),
  SettingsSearchEntry("What's new", SettingsCategory.about, 'changelog release notes'),
  SettingsSearchEntry('Earlier versions', SettingsCategory.about, 'downgrade older build rollback'),
  SettingsSearchEntry('Feedback', SettingsCategory.about, 'contact email support bug'),
  SettingsSearchEntry('Legal', SettingsCategory.about, 'privacy terms licenses'),
];
