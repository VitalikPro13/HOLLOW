import 'package:flutter/foundation.dart' show debugPrint, protected;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/shell_tab.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// The optional places the desktop shell lists beside the servers (#141).
///
/// Home is not one of them: it is the way back to everything, so it can never
/// be hidden. The order here is the order they show in.
enum SidebarItem {
  publicChannels('public_channels', ShellTab.guest),
  share('share', ShellTab.share),
  archive('archive', ShellTab.archive),
  conferences('conferences', ShellTab.conference),
  shop('shop', ShellTab.shop);

  /// The persisted name. Never rename one: a saved choice would come back.
  final String key;
  final ShellTab tab;

  const SidebarItem(this.key, this.tab);

  static SidebarItem? fromKey(String raw) {
    for (final item in values) {
      if (item.key == raw) return item;
    }
    return null;
  }
}

/// Places that exist in this build at all: the Shop is absent on store
/// builds (Apple 3.1.1, Play), so it is neither shown nor offered there.
List<SidebarItem> sidebarItemsAvailable({required bool shopAvailable}) => [
      for (final item in SidebarItem.values)
        if (item != SidebarItem.shop || shopAvailable) item,
    ];

/// Whether the rail or dock draws [item]: every place not hidden, and a
/// hidden one while it is the [open] tab, so where you are keeps its mark.
bool sidebarItemShows(
  SidebarItem item,
  Set<SidebarItem> hidden, {
  ShellTab? open,
}) =>
    !hidden.contains(item) || item.tab == open;

/// The places the rail or dock draws.
List<SidebarItem> sidebarItemsShown(
  Set<SidebarItem> hidden, {
  required bool shopAvailable,
  ShellTab? open,
}) =>
    [
      for (final item in sidebarItemsAvailable(shopAvailable: shopAvailable))
        if (sidebarItemShows(item, hidden, open: open)) item,
    ];

/// The places the Home menu offers instead, so a hidden place stays one
/// click from Home. Together with [sidebarItemsShown] (same [open]) it covers
/// every available place exactly once.
List<SidebarItem> sidebarItemsHidden(
  Set<SidebarItem> hidden, {
  required bool shopAvailable,
  ShellTab? open,
}) =>
    [
      for (final item in sidebarItemsAvailable(shopAvailable: shopAvailable))
        if (!sidebarItemShows(item, hidden, open: open)) item,
    ];

const _kSettingKey = 'sidebar_hidden_items';

/// The places this device has hidden from the server rail and the dock.
/// Local to the device; empty (everything shown) until the person hides one.
///
/// A plain [Notifier] loaded from `_bootstrap` like the other layout prefs:
/// the rail reads it on the first frame.
final hiddenSidebarItemsProvider =
    NotifierProvider<HiddenSidebarItemsNotifier, Set<SidebarItem>>(
        HiddenSidebarItemsNotifier.new);

class HiddenSidebarItemsNotifier extends Notifier<Set<SidebarItem>> {
  /// True once the saved value has been read: a save before that would write
  /// an empty base over what the person chose.
  bool _loaded = false;

  /// Names a newer build saved, kept and written back unchanged.
  List<String> _unknown = const [];

  /// Every read and write runs in order on this chain, so fast toggles land
  /// in the order they were made.
  Future<void> _chain = Future<void>.value();

  @override
  Set<SidebarItem> build() => const <SidebarItem>{};

  /// Parses the saved value; names this build does not know are skipped.
  static Set<SidebarItem> decode(String? raw) {
    if (raw == null || raw.isEmpty) return const <SidebarItem>{};
    return {
      for (final part in raw.split('\n')) ?SidebarItem.fromKey(part.trim()),
    };
  }

  /// The saved names this build does not know, in their saved order.
  static List<String> unknownNames(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    return [
      for (final part in raw.split('\n'))
        if (part.trim().isNotEmpty && SidebarItem.fromKey(part.trim()) == null)
          part.trim(),
    ];
  }

  static String encode(
    Set<SidebarItem> hidden, {
    List<String> unknown = const [],
  }) =>
      [
        for (final item in SidebarItem.values)
          if (hidden.contains(item)) item.key,
        ...unknown,
      ].join('\n');

  /// The stored value; tests override the pair to stand in for the store.
  @protected
  Future<String?> readSaved() => storage_api.loadSetting(key: _kSettingKey);

  @protected
  Future<void> writeSaved(String value) =>
      storage_api.saveSetting(key: _kSettingKey, value: value);

  Future<void> _enqueue(Future<void> Function() op) {
    final run = _chain.then((_) => op());
    _chain = run.catchError((Object _) {});
    return run;
  }

  void _apply(String? raw) {
    state = decode(raw);
    _unknown = unknownNames(raw);
    _loaded = true;
  }

  Future<void> load() => _enqueue(() async {
        try {
          _apply(await readSaved());
        } catch (e) {
          debugPrint('[HOLLOW] hiddenSidebarItems.load() failed: $e');
        }
      });

  /// Shows or hides [item] at once and saves it after any earlier change.
  /// Throws when the save fails, or when the saved value cannot be read
  /// first; the caller tells the person.
  Future<void> setShown(SidebarItem item, bool shown) {
    if (!_loaded) {
      return _enqueue(() async {
        if (!_loaded) _apply(await readSaved());
        final value = _change(item, shown);
        if (value != null) await writeSaved(value);
      });
    }
    final value = _change(item, shown);
    if (value == null) return _chain;
    return _enqueue(() => writeSaved(value));
  }

  /// The value to save, or null when [item] is already as asked.
  String? _change(SidebarItem item, bool shown) {
    if (shown != state.contains(item)) return null;
    final next = Set<SidebarItem>.from(state);
    if (shown) {
      next.remove(item);
    } else {
      next.add(item);
    }
    state = next;
    return encode(next, unknown: _unknown);
  }
}
