import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/chat_message.dart';
import 'package:hollow/src/core/models/channel_chat_message.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/models/peer_info.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/providers/accent_color_provider.dart';
import 'package:hollow/src/core/providers/background_provider.dart';
import 'package:hollow/src/core/providers/channel_chat_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/chat_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/layout_provider.dart';
import 'package:hollow/src/core/providers/license_key_provider.dart';
import 'package:hollow/src/core/providers/member_panel_provider.dart';
import 'package:hollow/src/core/providers/node_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/peers_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_strip_layout_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/reduce_motion.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/core/providers/event_provider.dart';
import 'package:hollow/src/core/providers/hidden_archive_dm_provider.dart';
import 'package:hollow/src/core/providers/server_avatar_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/core/models/strip_item.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/mobile/mobile_shell.dart';
import 'package:hollow/src/ui/shell/hollow_shell.dart';

import 'test_data.dart';

/// Standard provider overrides that mock all FFI-dependent providers.
List<Override> hollowTestOverrides({
  List<Override> extra = const [],
}) =>
    [
      // --- Identity & node (skip bootstrap) ---
      identityProvider.overrideWith(() => _MockIdentityNotifier()),
      nodeProvider.overrideWith(() => _MockNodeNotifier()),

      // --- Event stream (no-op, don't start Rust event loop) ---
      eventStreamProvider.overrideWith(() => _MockEventStreamNotifier()),

      // --- Server & channel state ---
      serverListProvider.overrideWith(() => _MockServerListNotifier()),
      channelListProvider.overrideWith(() => _MockChannelListNotifier()),

      // --- Friends ---
      friendsProvider.overrideWith(() => _MockFriendsNotifier()),

      // --- Chat messages (empty) ---
      chatProvider.overrideWith(() => _MockChatNotifier()),
      channelChatProvider.overrideWith(() => _MockChannelChatNotifier()),

      // --- Profiles (empty map — no FFI) ---
      profileProvider.overrideWith(() => _MockProfileNotifier()),

      // --- Peers (empty — no one online in test) ---
      peersProvider.overrideWith(() => _MockPeersNotifier()),

      // --- Unread & notifications ---
      unreadProvider.overrideWith(() => _MockUnreadNotifier()),
      notificationSettingsProvider
          .overrideWith(() => _MockNotificationSettingsNotifier()),

      // --- Hidden DMs, server avatars, voice channels ---
      hiddenArchiveDmsProvider
          .overrideWith(() => _MockHiddenArchiveDmsNotifier()),
      serverAvatarProvider
          .overrideWith(() => _MockServerAvatarNotifier()),
      voiceChannelProvider
          .overrideWith(() => _MockVoiceChannelNotifier()),

      // --- UI state (safe defaults) ---
      accentHueProvider.overrideWith(() => _MockAccentHueNotifier()),
      backgroundProvider.overrideWith(() => _MockBackgroundNotifier()),
      layoutModeProvider.overrideWith(() => _MockLayoutModeNotifier()),
      reduceMotionProvider
          .overrideWith(() => _MockReduceMotionNotifier()),
      invisibleModeProvider
          .overrideWith(() => _MockInvisibleModeNotifier()),
      serverStripLayoutProvider
          .overrideWith(() => _MockServerStripLayoutNotifier()),

      // --- Relay & license (skip gates) ---
      relayDomainProvider
          .overrideWith(() => _MockRelayDomainNotifier()),
      savedRelayListProvider
          .overrideWith(() => _MockSavedRelayListNotifier()),
      licenseKeyProvider.overrideWith(() => _MockLicenseKeyNotifier()),
      licenseErrorProvider.overrideWith((ref) => null),
      windowVisibleProvider.overrideWith((ref) => true),

      // --- User-provided overrides (last wins) ---
      ...extra,
    ];

/// Sets up the test viewport.
void _setupViewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

/// Pumps MobileShell directly (bypasses HollowShell's _bootstrap FFI calls).
///
/// This is the primary way to test mobile UI. The mobile shell reads
/// providers for tab state, unread counts, friends — all mocked.
Future<void> pumpHollowMobile(
  WidgetTester tester, {
  Size viewportSize = const Size(400, 800),
  List<Override> extraOverrides = const [],
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  _setupViewport(tester, viewportSize);

  await tester.pumpWidget(
    ProviderScope(
      overrides: hollowTestOverrides(extra: extraOverrides),
      child: MaterialApp(
        title: 'Hollow Test',
        debugShowCheckedModeBanner: false,
        theme: HollowThemeData.dark(),
        // a11y Phase 3: tests can pump the shell at an OS text scale (e.g.
        // 2.0×) to assert the hardened layouts don't RenderFlex-overflow.
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: child!,
        ),
        home: const MobileShell(),
      ),
    ),
  );

  await tester.pumpAndSettle(const Duration(seconds: 3));
}

/// Pumps the full HollowShell (desktop layout).
///
/// WARNING: HollowShell's _bootstrap() makes direct FFI calls
/// (storage_api.hasIdentity, network_api.setRelayUrl, etc.) that
/// can't be intercepted via provider overrides. This test helper
/// will work only after we add a test-mode flag to skip _bootstrap,
/// or when running as a real integration test with RustLib.init().
///
/// For now, use [pumpHollowDesktopShell] for isolated desktop widget tests.
Future<void> pumpHollowApp(
  WidgetTester tester, {
  Size viewportSize = const Size(1280, 800),
  List<Override> extraOverrides = const [],
}) async {
  _setupViewport(tester, viewportSize);

  await tester.pumpWidget(
    ProviderScope(
      overrides: hollowTestOverrides(extra: extraOverrides),
      child: MaterialApp(
        title: 'Hollow Test',
        debugShowCheckedModeBanner: false,
        theme: HollowThemeData.dark(),
        home: const HollowShell(),
      ),
    ),
  );

  // Don't pumpAndSettle — _bootstrap is async and may throw.
  // Just pump a few frames to let the sync build complete.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

// ---------------------------------------------------------------------------
// Mock Notifiers — return static test data, never call FFI.
// ---------------------------------------------------------------------------

class _MockIdentityNotifier extends IdentityNotifier {
  @override
  IdentityState build() => testIdentity;
}

class _MockNodeNotifier extends NodeNotifier {
  @override
  NodeState build() => testNodeConnected;
}

class _MockEventStreamNotifier extends EventStreamNotifier {
  @override
  bool build() => false;
}

class _MockServerListNotifier extends ServerListNotifier {
  @override
  Map<String, ServerInfo> build() => const {};
}

class _MockChannelListNotifier extends ChannelListNotifier {
  @override
  Map<String, ChannelInfo> build() => testChannels;
}

class _MockFriendsNotifier extends FriendsNotifier {
  @override
  Map<String, FriendInfo> build() => testFriends;
}

class _MockChatNotifier extends ChatNotifier {
  @override
  Map<String, List<ChatMessage>> build() => {};
}

class _MockChannelChatNotifier extends ChannelChatNotifier {
  @override
  Map<String, List<ChannelChatMessage>> build() => const {};
}

class _MockProfileNotifier extends ProfileNotifier {
  @override
  Map<String, storage_api.UserProfile> build() => {};
}

class _MockPeersNotifier extends PeersNotifier {
  @override
  Map<String, PeerInfo> build() => const {};
}

class _MockUnreadNotifier extends UnreadNotifier {
  @override
  UnreadState build() => testUnreadEmpty;
}

class _MockNotificationSettingsNotifier
    extends NotificationSettingsNotifier {
  @override
  NotificationSettingsState build() => testNotificationSettings;
}

class _MockAccentHueNotifier extends AccentHueNotifier {
  @override
  double build() => 175.0;
}

class _MockBackgroundNotifier extends BackgroundNotifier {
  @override
  BackgroundState build() => const BackgroundState();
}

class _MockLayoutModeNotifier extends LayoutModeNotifier {
  @override
  Future<LayoutMode> build() async => LayoutMode.dock;
}

class _MockReduceMotionNotifier extends ReduceMotionNotifier {
  @override
  Future<ReduceMotionMode> build() async =>
      ReduceMotionMode.on; // reduce motion in tests
}

class _MockInvisibleModeNotifier extends InvisibleModeNotifier {
  @override
  bool build() => false;
}

class _MockServerStripLayoutNotifier extends ServerStripLayoutNotifier {
  @override
  List<StripItem> build() => [];
}

class _MockRelayDomainNotifier extends RelayDomainNotifier {
  @override
  String build() => 'relay.anonlisten.com';
}

class _MockSavedRelayListNotifier extends SavedRelayListNotifier {
  @override
  List<String> build() => ['relay.anonlisten.com'];
}

class _MockLicenseKeyNotifier extends LicenseKeyNotifier {
  @override
  String? build() => null;
}

class _MockHiddenArchiveDmsNotifier extends HiddenArchiveDmsNotifier {
  @override
  Set<String> build() => const {};
}

class _MockServerAvatarNotifier extends ServerAvatarNotifier {
  @override
  Map<String, Uint8List> build() => const {};
}

class _MockVoiceChannelNotifier extends VoiceChannelNotifier {
  @override
  VoiceChannelState build() => const VoiceChannelState();
}
