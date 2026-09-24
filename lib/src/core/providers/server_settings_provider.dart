import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/models/channel_layout.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/shell_tab.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;

/// The pages of a server's settings, in rail order.
enum ServerSettingsPage {
  overview,
  access,
  channels,
  roles,
  labels,
  emotes,
  members,
  profile,
  notifications,
}

/// The server whose settings are open. Set by [openServerSettings]; null
/// falls back to the selected server.
final serverSettingsServerIdProvider = StateProvider<String?>((_) => null);

/// The page on screen; null is the default for the viewer's permissions.
final serverSettingsPageProvider =
    StateProvider<ServerSettingsPage?>((_) => null);

/// The server the settings place shows.
final serverSettingsTargetProvider = Provider<String?>((ref) =>
    ref.watch(serverSettingsServerIdProvider) ??
    ref.watch(selectedServerProvider));

/// Opens [serverId]'s settings in the centre, on [page] when given. The
/// selection underneath stays, so closing returns to the channel it covered.
void openServerSettings(ProviderRead read, String serverId,
    {ServerSettingsPage? page}) {
  setShellTab(read, null);
  // Always explicit: a split's right pane reads its OWN selected server, so
  // "the selected one" is ambiguous from there.
  read(serverSettingsServerIdProvider.notifier).state = serverId;
  read(serverSettingsPageProvider.notifier).state = page;
  read(serverSettingsOpenProvider.notifier).state = true;
}

void closeServerSettings(ProviderRead read) {
  read(serverSettingsOpenProvider.notifier).state = false;
}

/// One CRDT server setting, read once. Pages seed local state from it and keep
/// their own optimistic value: a read right after a write sees the old one.
final serverSettingProvider = FutureProvider.autoDispose
    .family<String, ({String serverId, String key})>((ref, a) =>
        crdt_api.getServerSetting(serverId: a.serverId, key: a.key));

/// The permission bits and role both loaded, or null while either is loading:
/// rendering before that flashes the wrong pages.
final serverSettingsAccessProvider =
    Provider.family<({int perms, String role})?, String>((ref, serverId) {
  final perms = ref.watch(myPermissionsProvider(serverId));
  final role = ref.watch(myRoleProvider(serverId));
  if (!perms.hasValue || !role.hasValue) return null;
  return (perms: perms.value ?? 0, role: role.value ?? 'member');
});

/// A draft save that failed for a reason the person can fix.
class ServerDraftError implements Exception {
  final String message;
  const ServerDraftError(this.message);
  @override
  String toString() => message;
}

class ServerDraftState {
  final bool dirty;
  final bool saving;
  const ServerDraftState({this.dirty = false, this.saving = false});
}

typedef _Texts = ({String name, String description, String max, String nick});

/// Unsaved text edits for one server's settings: name, description, member
/// limit and your nickname. They outlive a page switch or a close, so the place
/// shows ONE unsaved bar wherever the person is. Switches, chips and menus
/// apply at once and never pass through here.
class ServerSettingsDraftNotifier
    extends FamilyNotifier<ServerDraftState, String> {
  late TextEditingController _name;
  late TextEditingController _description;
  late TextEditingController _max;
  late TextEditingController _nick;

  TextEditingController get name => _name;
  TextEditingController get description => _description;
  TextEditingController get maxMembers => _max;
  TextEditingController get nickname => _nick;

  _Texts _baseline = (name: '', description: '', max: '', nick: '');
  bool _syncing = false;
  int _loadGen = 0;

  @override
  ServerDraftState build(String serverId) {
    _name = TextEditingController();
    _description = TextEditingController();
    _max = TextEditingController();
    _nick = TextEditingController();
    final all = [_name, _description, _max, _nick];
    for (final c in all) {
      c.addListener(_onText);
    }
    ref.onDispose(() {
      for (final c in all) {
        c.dispose();
      }
    });
    _baseline = (
      name: ref.read(serverListProvider)[serverId]?.name ?? '',
      description: '',
      max: '',
      nick: '',
    );
    _setTexts(_baseline);
    // A rename from another device lands in a clean draft.
    ref.listen(serverListProvider.select((s) => s[serverId]?.name),
        (_, next) {
      if (next == null || state.dirty || state.saving) return;
      _baseline = (
        name: next,
        description: _baseline.description,
        max: _baseline.max,
        nick: _baseline.nick,
      );
      _setTexts(_baseline);
    });
    _load();
    return const ServerDraftState();
  }

  _Texts _texts() => (
        name: _name.text,
        description: _description.text,
        max: _max.text,
        nick: _nick.text,
      );

  void _onText() {
    if (_syncing) return;
    final dirty = _texts() != _baseline;
    if (dirty != state.dirty) state = ServerDraftState(dirty: dirty);
  }

  void _setTexts(_Texts t) {
    _syncing = true;
    try {
      if (_name.text != t.name) _name.text = t.name;
      if (_description.text != t.description) {
        _description.text = t.description;
      }
      if (_max.text != t.max) _max.text = t.max;
      if (_nick.text != t.nick) _nick.text = t.nick;
    } finally {
      _syncing = false;
    }
  }

  /// Fills the fields from the saved server, unless edits are pending.
  Future<void> _load() async {
    final gen = ++_loadGen;
    final sid = arg;
    String description = '';
    String max = '';
    String nick = '';
    try {
      description = await ref.read(
          serverSettingProvider((serverId: sid, key: 'description')).future);
      final raw = await ref
          .read(serverSettingProvider((serverId: sid, key: 'max_members')).future);
      max = (raw.isEmpty || raw == '0') ? '' : raw;
      final me = ref.read(identityProvider).peerId ?? '';
      final members = await ref.read(serverMembersProvider(sid).future);
      nick = members.where((m) => m.peerId == me).firstOrNull?.nickname ?? '';
    } catch (_) {
      // A missing node leaves the fields at what we have.
    }
    if (gen != _loadGen || state.dirty || state.saving) return;
    _baseline = (
      name: ref.read(serverListProvider)[sid]?.name ?? _baseline.name,
      description: description,
      max: max,
      nick: nick,
    );
    _setTexts(_baseline);
  }

  /// Drops every unsaved edit and re-reads the saved values.
  void reset() {
    if (state.saving) return;
    _setTexts(_baseline);
    state = const ServerDraftState();
    ref.invalidate(serverSettingProvider);
    _load();
  }

  /// Commits what changed. Rethrows with the edits intact; a
  /// [ServerDraftError] names something the person can fix.
  Future<void> save() async {
    if (state.saving) return;
    final sid = arg;
    final sent = _texts();
    final name = sent.name.trim();
    if (name.isEmpty) throw const ServerDraftError('A server needs a name');
    state = const ServerDraftState(dirty: true, saving: true);
    try {
      final parsed = int.tryParse(sent.max.trim()) ?? 0;
      final maxValue = parsed > 0 ? '$parsed' : '0';
      if (sent.max != _baseline.max && parsed > 0) {
        // The live count is the authority; a cached one may be stale.
        final count =
            (await crdt_api.getServerMembers(serverId: sid)).length;
        if (parsed < count) {
          throw ServerDraftError(
              "Max can't be below the current member count ($count).");
        }
      }
      if (name != _baseline.name.trim()) {
        await crdt_api.renameServer(serverId: sid, newName: name);
      }
      if (sent.description != _baseline.description) {
        await crdt_api.updateServerSetting(
            serverId: sid,
            key: 'description',
            value: sent.description.trim());
      }
      if (sent.max != _baseline.max) {
        await crdt_api.updateServerSetting(
            serverId: sid, key: 'max_members', value: maxValue);
      }
      if (sent.nick != _baseline.nick) {
        await crdt_api.setNickname(
          serverId: sid,
          peerId: ref.read(identityProvider).peerId ?? '',
          nickname: sent.nick.trim(),
        );
        ref.invalidate(serverMembersProvider(sid));
      }
      _baseline = (
        name: name,
        description: sent.description.trim(),
        max: maxValue == '0' ? '' : maxValue,
        nick: sent.nick.trim(),
      );
      // Anything typed while the save was in flight stays pending.
      if (_texts() == sent) _setTexts(_baseline);
      state = ServerDraftState(dirty: _texts() != _baseline);
    } catch (_) {
      state = const ServerDraftState(dirty: true);
      rethrow;
    }
  }
}

final serverSettingsDraftProvider = NotifierProvider.family<
    ServerSettingsDraftNotifier,
    ServerDraftState,
    String>(ServerSettingsDraftNotifier.new);

/// A staged channel-list edit: order, categories and dividers wait for Save
/// layout; everything else about a channel writes at once. Null when nothing
/// is staged. Keyed by server so a page switch keeps it.
class ChannelLayoutDraftNotifier
    extends FamilyNotifier<List<LayoutItem>?, String> {
  @override
  List<LayoutItem>? build(String serverId) => null;

  /// The staged layout, or the saved one, with every channel placed.
  List<LayoutItem> shown(Map<String, ChannelInfo> channels, String savedJson) =>
      effectiveLayoutFrom(state ?? parseLayoutJson(savedJson), channels);

  /// Whether the staged layout differs from the saved one.
  bool dirty(Map<String, ChannelInfo> channels, String savedJson) {
    final staged = state;
    if (staged == null) return false;
    return !sameLayout(effectiveLayoutFrom(staged, channels),
        effectiveLayout(savedJson, channels));
  }

  void stage(List<LayoutItem> layout) => state = List.unmodifiable(layout);

  void discard() => state = null;

  /// Writes the staged layout through [layout], the one layout write path.
  /// It is the caller's `channelLayoutProvider`, which a split's right pane
  /// scopes to its own server.
  void save(Map<String, ChannelInfo> channels, ChannelLayoutNotifier layout) {
    final staged = state;
    if (staged == null) return;
    layout.mutate(arg, channels, (_) => effectiveLayoutFrom(staged, channels));
    state = null;
  }
}

final channelLayoutDraftProvider = NotifierProvider.family<
    ChannelLayoutDraftNotifier,
    List<LayoutItem>?,
    String>(ChannelLayoutDraftNotifier.new);

/// Two layouts name the same things in the same order.
bool sameLayout(List<LayoutItem> a, List<LayoutItem> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    final x = a[i];
    final y = b[i];
    if (x.runtimeType != y.runtimeType) return false;
    if (x is CategoryItem && y is CategoryItem && x.name != y.name) {
      return false;
    }
    if (x is ChannelItem && y is ChannelItem && x.channelId != y.channelId) {
      return false;
    }
  }
  return true;
}
