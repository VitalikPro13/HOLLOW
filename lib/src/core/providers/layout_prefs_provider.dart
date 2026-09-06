import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// Shell chrome the user can size and shape (issue #54).
///
/// Everything here is watched by the very first frame, so each one is a plain
/// synchronous [Notifier] with an explicit `load()` from
/// `HollowShell._bootstrap`, never an `AsyncNotifier` awaiting `loadSetting` in
/// `build()` (feedback_load_persisted_setting_from_bootstrap_not_build).
///
/// [loadLayoutPrefs] is the one call the bootstrap makes.

/// How a click on a user opens their profile.
enum ProfileCardStyle {
  /// The small card anchored next to whatever was clicked (default).
  compact,

  /// Straight to the full profile with the showcase board.
  expanded;

  static ProfileCardStyle fromKey(String? raw) =>
      raw == 'expanded' ? ProfileCardStyle.expanded : ProfileCardStyle.compact;

  String get key => name;
}

const double kChannelSidebarWidthDefault = 240.0;
const double kChannelSidebarWidthMin = 180.0;
const double kChannelSidebarWidthMax = 460.0;

const double kMemberPanelWidthDefault = 240.0;
const double kMemberPanelWidthMin = 180.0;
const double kMemberPanelWidthMax = 420.0;

const double kPanelScaleDefault = 1.0;
const double kPanelScaleMin = 0.8;
const double kPanelScaleMax = 1.4;

/// Awaits every layout preference. Called once from `_bootstrap`, after the
/// store is open.
Future<void> loadLayoutPrefs(WidgetRef ref) async {
  await ref.read(profileCardStyleProvider.notifier).load();
  await ref.read(channelSidebarWidthProvider.notifier).load();
  await ref.read(memberPanelWidthProvider.notifier).load();
  await ref.read(panelScaleProvider.notifier).load();
  await ref.read(collapsedMemberGroupsProvider.notifier).load();
}

/// Whether clicking a user opens the compact card or the full profile.
final profileCardStyleProvider =
    NotifierProvider<ProfileCardStyleNotifier, ProfileCardStyle>(
        ProfileCardStyleNotifier.new);

class ProfileCardStyleNotifier extends Notifier<ProfileCardStyle> {
  @override
  ProfileCardStyle build() => ProfileCardStyle.compact;

  Future<void> load() async {
    try {
      final raw = await storage_api.loadSetting(key: 'profile_card_style');
      if (raw == null || raw.isEmpty) return;
      state = ProfileCardStyle.fromKey(raw);
    } catch (e) {
      debugPrint('[HOLLOW] profileCardStyle.load() failed: $e');
    }
  }

  Future<void> setStyle(ProfileCardStyle style) async {
    if (state == style) return;
    state = style;
    try {
      await storage_api.saveSetting(
          key: 'profile_card_style', value: style.key);
    } catch (e) {
      debugPrint('[HOLLOW] profileCardStyle save failed: $e');
    }
  }
}

/// Shared body of the two width preferences: same clamp, same write-through,
/// different key and bounds.
abstract class _PanelWidthNotifier extends Notifier<double> {
  String get settingKey;
  double get defaultWidth;
  double get minWidth;
  double get maxWidth;

  @override
  double build() => defaultWidth;

  Future<void> load() async {
    try {
      final raw = await storage_api.loadSetting(key: settingKey);
      if (raw == null || raw.isEmpty) return;
      state = clampWidth(double.tryParse(raw) ?? defaultWidth);
    } catch (e) {
      debugPrint('[HOLLOW] $settingKey.load() failed: $e');
    }
  }

  /// Live drag: state moves on the frame, the write trails it. A dropped
  /// write only costs the width on next launch, so it is logged, not surfaced.
  Future<void> setWidth(double width) async {
    final clamped = clampWidth(width);
    if ((state - clamped).abs() < 0.5) return;
    state = clamped;
    try {
      await storage_api.saveSetting(
          key: settingKey, value: clamped.toStringAsFixed(0));
    } catch (e) {
      debugPrint('[HOLLOW] $settingKey save failed: $e');
    }
  }

  Future<void> reset() => setWidth(defaultWidth);

  double clampWidth(double v) => v.clamp(minWidth, maxWidth).toDouble();
}

/// Width of the channel / conversation sidebar. Drag its right edge.
final channelSidebarWidthProvider =
    NotifierProvider<ChannelSidebarWidthNotifier, double>(
        ChannelSidebarWidthNotifier.new);

class ChannelSidebarWidthNotifier extends _PanelWidthNotifier {
  @override
  String get settingKey => 'channel_sidebar_width';
  @override
  double get defaultWidth => kChannelSidebarWidthDefault;
  @override
  double get minWidth => kChannelSidebarWidthMin;
  @override
  double get maxWidth => kChannelSidebarWidthMax;
}

/// Width of the right-hand member panel. Drag its left edge.
final memberPanelWidthProvider =
    NotifierProvider<MemberPanelWidthNotifier, double>(
        MemberPanelWidthNotifier.new);

class MemberPanelWidthNotifier extends _PanelWidthNotifier {
  @override
  String get settingKey => 'member_panel_width';
  @override
  double get defaultWidth => kMemberPanelWidthDefault;
  @override
  double get minWidth => kMemberPanelWidthMin;
  @override
  double get maxWidth => kMemberPanelWidthMax;
}

/// Zoom for the side panels ONLY: server strip, channel sidebar, member panel.
/// Avatars, icons, names and counts grow together, because icon sizes live in
/// hundreds of hardcoded `size:` literals no text scaler can reach (issue #54).
final panelScaleProvider =
    NotifierProvider<PanelScaleNotifier, double>(PanelScaleNotifier.new);

class PanelScaleNotifier extends Notifier<double> {
  @override
  double build() => kPanelScaleDefault;

  Future<void> load() async {
    try {
      final raw = await storage_api.loadSetting(key: 'panel_scale');
      if (raw == null || raw.isEmpty) return;
      state = _clamp(double.tryParse(raw) ?? kPanelScaleDefault);
    } catch (e) {
      debugPrint('[HOLLOW] panelScale.load() failed: $e');
    }
  }

  Future<void> setScale(double scale) async {
    final clamped = _clamp(scale);
    if ((state - clamped).abs() < 0.001) return;
    state = clamped;
    try {
      await storage_api.saveSetting(
          key: 'panel_scale', value: clamped.toStringAsFixed(2));
    } catch (e) {
      debugPrint('[HOLLOW] panelScale save failed: $e');
    }
  }

  Future<void> reset() => setScale(kPanelScaleDefault);

  double _clamp(double v) => v.clamp(kPanelScaleMin, kPanelScaleMax).toDouble();
}

/// Member-list sections the user has folded away, keyed `serverId:label`
/// (issue #54). Per server, because "hide Offline" on a 200-member server says
/// nothing about a 4-member one.
final collapsedMemberGroupsProvider =
    NotifierProvider<CollapsedMemberGroupsNotifier, Set<String>>(
        CollapsedMemberGroupsNotifier.new);

class CollapsedMemberGroupsNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => const <String>{};

  static String keyFor(String serverId, String label) => '$serverId:$label';

  Future<void> load() async {
    try {
      final raw = await storage_api.loadSetting(key: 'collapsed_member_groups');
      if (raw == null || raw.isEmpty) return;
      state = raw.split('\n').where((e) => e.isNotEmpty).toSet();
    } catch (e) {
      debugPrint('[HOLLOW] collapsedMemberGroups.load() failed: $e');
    }
  }

  bool isCollapsed(String serverId, String label) =>
      state.contains(keyFor(serverId, label));

  Future<void> toggle(String serverId, String label) async {
    final key = keyFor(serverId, label);
    final next = Set<String>.from(state);
    if (!next.remove(key)) next.add(key);
    state = next;
    try {
      await storage_api.saveSetting(
        key: 'collapsed_member_groups',
        value: next.join('\n'),
      );
    } catch (e) {
      debugPrint('[HOLLOW] collapsedMemberGroups save failed: $e');
    }
  }
}
