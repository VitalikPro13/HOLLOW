import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/shell_tab.dart';

/// The Settings pages, in rail order.
enum SettingsCategory {
  profile,
  security,
  devices,
  appearance,
  accessibility,
  notifications,
  audio,
  shortcuts,
  network,
  storage,
  about,
}

/// Whether Settings covers the centre. Written ONLY by [setShellTab]; open and
/// close it through [openSettings] / [toggleSettings].
final settingsTabOpenProvider = StateProvider<bool>((_) => false);

/// The page Settings shows. It outlives a close, so Settings reopens where it
/// was left.
final settingsCategoryProvider =
    StateProvider<SettingsCategory>((_) => SettingsCategory.profile);

/// Opens Settings, on [category] when given. Unlike the other places it keeps
/// the selection underneath, so closing it returns to the conversation it
/// covered.
void openSettings(ProviderRead read, {SettingsCategory? category}) {
  if (category != null) {
    read(settingsCategoryProvider.notifier).state = category;
  }
  setShellTab(read, ShellTab.settings);
}

/// The gear and Ctrl+, : open Settings, or close it when it is open.
void toggleSettings(ProviderRead read) {
  if (read(settingsTabOpenProvider)) {
    setShellTab(read, null);
  } else {
    openSettings(read);
  }
}
