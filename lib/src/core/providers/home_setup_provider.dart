import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// What Home needs that no other provider knows: whether the recovery phrase
/// was confirmed saved, whether the first-run checklist was hidden, and which
/// version's changelog was last opened. All live in the settings KV.
class HomeSetupState {
  final bool loaded;
  final bool phraseSaved;
  final bool hidden;

  /// The version whose changelog was last opened, or first seen on a fresh
  /// install; null until loaded.
  final String? changelogSeen;

  const HomeSetupState({
    this.loaded = false,
    this.phraseSaved = false,
    this.hidden = false,
    this.changelogSeen,
  });

  HomeSetupState copyWith({
    bool? phraseSaved,
    bool? hidden,
    String? changelogSeen,
  }) =>
      HomeSetupState(
        loaded: true,
        phraseSaved: phraseSaved ?? this.phraseSaved,
        hidden: hidden ?? this.hidden,
        changelogSeen: changelogSeen ?? this.changelogSeen,
      );
}

class HomeSetupNotifier extends Notifier<HomeSetupState> {
  static const _phraseKey = 'recovery_phrase_saved';
  static const _hiddenKey = 'home_setup_hidden';
  static const _changelogKey = 'changelog_seen_version';

  @override
  HomeSetupState build() => const HomeSetupState();

  /// Called from the shell's `_bootstrap`, after the store opens: a read from
  /// `build()` races the open and silently comes back empty.
  ///
  /// A fresh install has seen nothing, and would be greeted as if it had just
  /// updated; stamping [appVersion] as seen makes "Updated to" mean an update.
  Future<void> load(String appVersion) async {
    try {
      final phrase = await storage_api.loadSetting(key: _phraseKey);
      final hidden = await storage_api.loadSetting(key: _hiddenKey);
      var seen = await storage_api.loadSetting(key: _changelogKey);
      if (seen == null || seen.isEmpty) {
        seen = appVersion;
        await storage_api.saveSetting(key: _changelogKey, value: appVersion);
      }
      state = state.copyWith(
        phraseSaved: state.phraseSaved || phrase == '1',
        hidden: state.hidden || hidden == '1',
        changelogSeen: seen,
      );
    } catch (_) {
      // Unreadable: leave Home's extras unloaded (hidden) rather than guess.
    }
  }

  /// Called when the person confirms "I've saved it" on the phrase dialog.
  Future<void> markPhraseSaved() async {
    state = state.copyWith(phraseSaved: true);
    await storage_api.saveSetting(key: _phraseKey, value: '1');
  }

  Future<void> hide() async {
    state = state.copyWith(hidden: true);
    await storage_api.saveSetting(key: _hiddenKey, value: '1');
  }

  Future<void> markChangelogSeen(String version) async {
    state = state.copyWith(changelogSeen: version);
    await storage_api.saveSetting(key: _changelogKey, value: version);
  }
}

final homeSetupProvider =
    NotifierProvider<HomeSetupNotifier, HomeSetupState>(HomeSetupNotifier.new);
