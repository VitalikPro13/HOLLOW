import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/models/chat_message.dart';
import 'package:hollow/src/core/models/node_status.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/providers/channel_chat_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/chat_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/member_panel_provider.dart';
import 'package:hollow/src/core/providers/node_provider.dart';
import 'package:hollow/src/core/providers/peers_provider.dart';
import 'package:hollow/src/core/providers/favourite_friends_provider.dart';
import 'package:hollow/src/core/providers/hidden_archive_dm_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/verified_peers_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/providers/accent_color_provider.dart';
import 'package:hollow/src/core/providers/background_provider.dart';
import 'package:hollow/src/core/shared_tickers.dart';
import 'package:hollow/src/core/providers/local_nickname_provider.dart';
import 'package:hollow/src/core/providers/server_avatar_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_strip_layout_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/system_notification_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/animations/ambient_background.dart';
import 'package:hollow/src/ui/animations/startup_reveal.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/ui/chat/channel_chat_pane.dart';
import 'package:hollow/src/ui/chat/chat_pane.dart';
import 'package:hollow/src/ui/chat/voice_channel_pane.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/components/notification_overlay.dart';
import 'package:hollow/src/ui/components/active_call_bar.dart';
import 'package:hollow/src/ui/dialogs/incoming_call_dialog.dart';
import 'package:hollow/src/ui/dialogs/create_channel_dialog.dart';
import 'package:hollow/src/ui/dialogs/mnemonic_dialog.dart';
import 'package:hollow/src/ui/dialogs/user_settings_dialog.dart';
import 'package:hollow/src/ui/dialogs/welcome_dialog.dart';
import 'package:hollow/src/ui/dialogs/license_key_dialog.dart';
import 'package:hollow/src/core/providers/license_key_provider.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/core/providers/relay_status_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/ui/settings/server_settings_panel.dart';
import 'package:hollow/src/core/providers/layout_provider.dart';
import 'package:hollow/src/core/providers/split_view_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/ui/shell/bottom_bar.dart';
import 'package:hollow/src/ui/shell/channel_sidebar.dart';
import 'package:hollow/src/ui/shell/friends_bar.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/core/providers/share_tab_provider.dart';
import 'package:hollow/src/ui/shell/archive_dashboard.dart';
import 'package:hollow/src/ui/share/share_dashboard.dart';
import 'package:hollow/src/ui/shell/home_dashboard.dart';
import 'package:hollow/src/ui/shell/member_panel.dart';
import 'package:hollow/src/ui/shell/mobile_nav.dart';
import 'package:hollow/src/ui/mobile/mobile_shell.dart';
import 'package:hollow/src/ui/shell/server_strip.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:window_manager/window_manager.dart';

/// Breakpoints for adaptive layout.
const _kDesktopBreakpoint = 1024.0;
const _kTabletBreakpoint = 600.0;

/// Main application shell — Discord-like multi-panel layout.
///
/// Desktop: ServerStrip | ChannelSidebar | ChatPane | MemberPanel
/// Tablet:  ServerStrip | ChannelSidebar | ChatPane (member panel toggleable)
/// Mobile:  Active tab view + bottom navigation bar
class HollowShell extends ConsumerStatefulWidget {
  const HollowShell({super.key});

  @override
  ConsumerState<HollowShell> createState() => _HollowShellState();
}

class _HollowShellState extends ConsumerState<HollowShell>
    with TickerProviderStateMixin {
  bool _initialized = false;

  // Startup reveal animation — master controller shared via InheritedWidget.
  late final AnimationController _revealController;
  bool _revealComplete = false;

  // Chat pane reveal sub-animation.
  late final Animation<double> _chatReveal;

  // Dock layout reveal sub-animations.
  late final Animation<double> _friendsBarReveal;
  late final Animation<double> _bottomBarReveal;
  late final Animation<double> _dockChatReveal;

  @override
  void initState() {
    super.initState();

    _revealController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    );

    _chatReveal = CurvedAnimation(
      parent: _revealController,
      curve: const Interval(0.30, 0.70, curve: Curves.easeOutCubic),
    );

    _friendsBarReveal = CurvedAnimation(
      parent: _revealController,
      curve: const Interval(0.0, 0.25, curve: Curves.easeOutCubic),
    );
    _bottomBarReveal = CurvedAnimation(
      parent: _revealController,
      curve: const Interval(0.05, 0.30, curve: Curves.easeOutCubic),
    );
    _dockChatReveal = CurvedAnimation(
      parent: _revealController,
      curve: const Interval(0.20, 0.60, curve: Curves.easeOutCubic),
    );

    _revealController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        setState(() => _revealComplete = true);
      }
    });

    // Register global keyboard shortcut handler.
    HardwareKeyboard.instance.addHandler(_handleGlobalKey);

    // Delay reveal until after the first frame so the window is visible.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealController.forward();
    });
    _bootstrap();
    _listenForLicenseErrors();
    _listenForNicknameChanges();
  }

  void _listenForNicknameChanges() {
    ref.listenManual(localNicknameProvider, (_, next) {
      setLocalNicknamesRef(next);
    });
  }

  void _listenForLicenseErrors() {
    ref.listenManual(licenseErrorProvider, (prev, next) {
      if (next != null && mounted) {
        _handleLicenseError(next);
      }
    });
  }

  Future<void> _handleLicenseError(String reason) async {
    // Stop the node so we don't keep retrying.
    ref.read(nodeProvider.notifier).stop();
    await ref.read(licenseKeyProvider.notifier).clearKey();
    ref.read(licenseErrorProvider.notifier).state = null;

    final friendlyMessage = switch (reason) {
      'invalid_license_key' => 'Invalid license key',
      'license_key_in_use' =>
        'This key is already in use on another device',
      'license_key_required' => 'A license key is required to connect',
      _ => 'License error: $reason',
    };

    if (!mounted) return;
    final newKey =
        await showLicenseKeyDialog(context, error: friendlyMessage);
    if (!mounted) return;
    if (newKey != null) {
      await ref.read(licenseKeyProvider.notifier).setKey(newKey);
      await network_api.setLicenseKey(key: newKey);
      await ref.read(nodeProvider.notifier).start();
    }
  }

  Future<void> _bootstrap() async {
    if (_initialized) return;
    _initialized = true;

    // Check if an identity already exists on disk.
    final hasExisting = await storage_api.hasIdentity();

    // First launch — show welcome dialog before creating identity.
    WelcomeResult? welcomeResult;
    if (!hasExisting && mounted) {
      welcomeResult = await showWelcomeDialog(context);
      if (!mounted) return;

      // 'restored_mnemonic' / 'restored_backup' — identity already on disk.
      // 'create_new' / null — proceed to normal load (will generate new).
    }

    await ref.read(identityProvider.notifier).load();

    final identity = ref.read(identityProvider);
    if (identity.error != null) return;

    // Restore animation toggle from DB (must be after identity load opens DB).
    try {
      final disableAnim =
          await storage_api.loadSetting(key: 'disable_animations');
      if (disableAnim == 'true') {
        HollowDurations.animationsDisabled = true;
        SharedTickers.instance.disabled = true;
        SharedTickers.instance.pause();
        // Skip the startup reveal animation instantly.
        if (!_revealController.isCompleted) {
          _revealController.value = 1.0;
        }
      }
    } catch (_) {}

    if (identity.mnemonic != null && mounted) {
      // New identity was generated — save mnemonic to DB then show dialog.
      await storage_api.saveMnemonic(mnemonic: identity.mnemonic!);
      if (!mounted) return;
      showMnemonicDialog(context, identity.mnemonic!);
    }

    // Load relay domain and saved relay list from DB.
    await ref.read(relayDomainProvider.notifier).loadCached();
    await ref.read(savedRelayListProvider.notifier).loadCached();
    if (welcomeResult != null && welcomeResult.relayDomain != kDefaultRelayDomain) {
      await ref.read(relayDomainProvider.notifier).setDomain(welcomeResult.relayDomain);
      await ref.read(savedRelayListProvider.notifier).addRelay(welcomeResult.relayDomain);
    }
    final relayDomain = ref.read(relayDomainProvider);
    await network_api.setRelayUrl(domain: relayDomain);

    // License key gate — check relay status and prompt if required.
    await ref.read(licenseKeyProvider.notifier).loadCached();
    final relayStatus = await fetchRelayStatus(domain: relayDomain);
    if (relayStatus.licenseRequired) {
      var cachedKey = ref.read(licenseKeyProvider);
      if (cachedKey == null && mounted) {
        final enteredKey = await showLicenseKeyDialog(context);
        if (!mounted) return;
        if (enteredKey != null) {
          await ref.read(licenseKeyProvider.notifier).setKey(enteredKey);
          cachedKey = enteredKey;
        } else {
          return;
        }
      }
      if (cachedKey != null) {
        await network_api.setLicenseKey(key: cachedKey);
      }
    }

    // Load servers from local DB (needed for unread computation).
    await ref.read(serverListProvider.notifier).loadFromDb();

    // Load unread state from DB BEFORE starting the node,
    // so sync events don't race with loadAll.
    try {
      final servers = ref.read(serverListProvider);
      final serverChannels = <String, List<String>>{};
      for (final sid in servers.keys) {
        final channels = await crdt_api.getServerChannels(serverId: sid);
        serverChannels[sid] = channels.map((c) => c.channelId).toList();
      }
      final dmPeerIds = await storage_api.getDmPeerIds();
      // Load notification settings BEFORE unread — unread depends on notif levels.
      await ref.read(notificationSettingsProvider.notifier)
          .loadAll(servers.keys.toList(), serverChannels, dmPeerIds);
      await ref.read(unreadProvider.notifier).loadAll(serverChannels, dmPeerIds);
    } catch (e) {
      debugPrint('[HOLLOW] Failed to load unread state: $e');
    }

    await ref.read(nodeProvider.notifier).start();

    // Load invisible mode preference (non-blocking — Rust already loaded it
    // from DB at node startup, this is just for the Dart UI to show the
    // correct toggle/status).
    ref.read(invisibleModeProvider.notifier).load();

    // Load server strip layout (folders + ordering).
    await ref.read(serverStripLayoutProvider.notifier).loadLayout();

    // Load server avatars.
    final serverIds = ref.read(serverListProvider).keys.toList();
    ref.read(serverAvatarProvider.notifier).loadAll(serverIds);

    // Load cached user profiles into memory.
    await ref.read(profileProvider.notifier).loadAll();

    // Load accent color, background, local nicknames.
    await ref.read(accentHueProvider.notifier).load();
    await ref.read(backgroundProvider.notifier).load();
    await ref.read(accentPresetsProvider.notifier).load();
    await ref.read(localNicknameProvider.notifier).loadAll();
    setLocalNicknamesRef(ref.read(localNicknameProvider));

    // Load friends list from local DB.
    await ref.read(friendsProvider.notifier).loadAll();

    // Load share entries so hollow://share cards in chat show correct state.
    ref.read(shareTabProvider.notifier).loadAll();

    // Pre-load last message per DM peer for home dashboard previews.
    final acceptedPeerIds = ref
        .read(friendsProvider)
        .values
        .where((f) => f.status == 'accepted')
        .map((f) => f.peerId)
        .toList();
    if (acceptedPeerIds.isNotEmpty) {
      ref.read(chatProvider.notifier).loadLastMessagePreviews(acceptedPeerIds);
    }

    // Load favourite friends order from local DB.
    await ref.read(favouriteFriendsProvider.notifier).load();

    // Load hidden Archive DMs from local DB.
    await ref.read(hiddenArchiveDmsProvider.notifier).load();

    // Load verified peers from local DB.
    await ref.read(verifiedPeersProvider.notifier).load();

    // Initialize native notifications (for tray mode).
    await ref.read(systemNotificationProvider.notifier).init();
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleGlobalKey);
    _revealController.dispose();
    super.dispose();
  }

  /// Global keyboard shortcut handler — registered on HardwareKeyboard
  /// so it works regardless of which widget currently has focus.
  bool _handleGlobalKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;

    final isCtrl = HardwareKeyboard.instance.isControlPressed;
    final isShift = HardwareKeyboard.instance.isShiftPressed;

    // Ctrl+, → Open settings dialog.
    if (isCtrl &&
        !isShift &&
        event.logicalKey == LogicalKeyboardKey.comma) {
      showUserSettingsDialog(context, ref);
      return true;
    }

    // Ctrl+Shift+M → Toggle member panel.
    if (isCtrl &&
        isShift &&
        event.logicalKey == LogicalKeyboardKey.keyM) {
      final current = ref.read(memberPanelProvider);
      ref.read(memberPanelProvider.notifier).state = !current;
      return true;
    }

    // Ctrl+K → Toggle channel search.
    if (isCtrl &&
        !isShift &&
        event.logicalKey == LogicalKeyboardKey.keyK) {
      final current = ref.read(channelSearchOpenProvider);
      ref.read(channelSearchOpenProvider.notifier).state = !current;
      return true;
    }

    // Ctrl+Shift+\ → Toggle split view (dock mode only).
    if (isCtrl &&
        isShift &&
        event.logicalKey == LogicalKeyboardKey.backslash) {
      final layoutMode =
          ref.read(layoutModeProvider).valueOrNull ?? LayoutMode.dock;
      if (layoutMode == LayoutMode.dock) {
        final split = ref.read(splitViewProvider);
        if (split.isSplit) {
          ref.read(splitViewProvider.notifier).closeSplit();
        } else {
          ref.read(splitViewProvider.notifier).openSplit();
        }
        return true;
      }
    }

    // Ctrl+1 → Focus left pane.
    if (isCtrl &&
        !isShift &&
        event.logicalKey == LogicalKeyboardKey.digit1) {
      final split = ref.read(splitViewProvider);
      if (split.isSplit) {
        ref.read(splitViewProvider.notifier).setFocus(0);
        return true;
      }
    }

    // Ctrl+2 → Focus right pane.
    if (isCtrl &&
        !isShift &&
        event.logicalKey == LogicalKeyboardKey.digit2) {
      final split = ref.read(splitViewProvider);
      if (split.isSplit) {
        ref.read(splitViewProvider.notifier).setFocus(1);
        return true;
      }
    }

    return false;
  }

  ChatMessage? _lastMessage(
      String peerId, Map<String, ChatMessage> lastMessages) {
    return lastMessages[peerId];
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.month}/${dt.day}';
  }

  Widget _buildChannelSidebar({
    required Map<String, dynamic> peers,
    required Map<String, ChatMessage> lastMessages,
    required String? selectedPeerId,
    required NodeStatus nodeStatus,
    required ServerInfo? selectedServer,
    required Map<String, ChannelInfo> channels,
    required String? selectedChannelId,
    required String channelLayoutJson,
    double? width = 240,
    bool dockMode = false,
  }) {
    return ChannelSidebar(
      peers: Map.from(peers),
      lastMessages: lastMessages,
      selectedPeerId: selectedPeerId,
      nodeStatus: nodeStatus,
      width: width,
      dockMode: dockMode,
      showUserBar: !dockMode,
      onPeerSelected: (peerId) {
        ref.read(shareTabOpenProvider.notifier).state = false;
        ref.read(archiveTabOpenProvider.notifier).state = false;
        ref.read(selectedPeerProvider.notifier).state = peerId;
        // Mark DM as read — use ref.read (not watch) since this is a callback.
        final lastMsg = ref.read(lastDmMessageProvider)[peerId];
        ref.read(unreadProvider.notifier).markDmSeen(peerId, lastMsg?.messageId);
        // On mobile, switch to chat tab when peer is selected.
        ref.read(mobileTabProvider.notifier).state = 1;
      },
      lastMessage: (peerId) => _lastMessage(peerId, lastMessages),
      formatTime: _formatTime,
      // Server mode props
      selectedServer: selectedServer,
      channels: channels,
      selectedChannelId: selectedChannelId,
      onChannelSelected: (channelId) {
        ref.read(selectedChannelProvider.notifier).state = channelId;
        // Remember last channel for this server.
        final serverId = ref.read(selectedServerProvider);
        if (serverId != null) {
          final map = Map<String, String>.from(
              ref.read(lastChannelPerServerProvider));
          map[serverId] = channelId;
          ref.read(lastChannelPerServerProvider.notifier).state = map;
          // Mark channel as read.
          final chState = ref.read(channelChatProvider);
          final msgs = chState['$serverId:$channelId'];
          final latestId = msgs != null && msgs.isNotEmpty
              ? msgs.last.messageId
              : null;
          ref.read(unreadProvider.notifier)
              .markChannelSeen(serverId, channelId, latestId);
          // Subscribe to this channel for topic-based relay routing.
          // Include channels with unread messages so @mentions still arrive.
          final unread = ref.read(unreadProvider);
          final prefix = '$serverId:';
          final unreadChannels = unread.channelUnreadCounts.entries
              .where((e) => e.key.startsWith(prefix) && e.value > 0)
              .map((e) => e.key.substring(prefix.length))
              .toList();
          final topics = <String>{channelId, ...unreadChannels}.toList();
          network_api.subscribeChannels(serverId: serverId, channelIds: topics);
        }
        // On mobile, switch to chat tab when channel is selected.
        ref.read(mobileTabProvider.notifier).state = 1;
      },
      onCreateChannel: () {
        if (selectedServer != null) {
          showCreateChannelDialog(context, selectedServer.serverId);
        }
      },
      onOpenSettings: () {
        final split = ref.read(splitViewProvider);
        if (split.isSplit && selectedServer != null) {
          _showServerSettingsDialog(context, selectedServer);
        } else {
          ref.read(serverSettingsOpenProvider.notifier).state =
              !ref.read(serverSettingsOpenProvider);
        }
      },
      canManageChannels: selectedServer != null &&
          (ref.watch(myPermissionsProvider(selectedServer.serverId)).whenOrNull(
              data: (perms) => (perms & Permission.manageChannels) != 0) ?? false),
      channelLayoutJson: channelLayoutJson,
    );
  }

  Widget _buildEmptyChat(HollowTheme hollow) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            LucideIcons.messageSquare,
            size: 64,
            color: hollow.textSecondary.withValues(alpha: 0.3),
          ),
          const SizedBox(height: HollowSpacing.lg),
          Text(
            'Select a peer to start chatting',
            style: HollowTypography.body.copyWith(
              color: hollow.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChannelPlaceholder(HollowTheme hollow, ChannelInfo? channel) {
    return Column(
      children: [
        // Channel header
        Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
          decoration: BoxDecoration(
            color: hollow.surface,
            border: Border(bottom: BorderSide(color: hollow.border)),
          ),
          child: Row(
            children: [
              Icon(LucideIcons.hash, size: 20, color: hollow.textSecondary),
              const SizedBox(width: HollowSpacing.sm),
              Text(
                channel?.name ?? 'Unknown Channel',
                style: HollowTypography.subheading.copyWith(
                  color: hollow.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              HollowTooltip(
                message: 'Toggle member panel',
                child: HollowPressable(
                  onTap: () => ref
                      .read(memberPanelProvider.notifier)
                      .state = !ref.read(memberPanelProvider),
                  borderRadius: BorderRadius.circular(hollow.radiusSm),
                  padding: const EdgeInsets.all(HollowSpacing.xs),
                  child: Icon(LucideIcons.users,
                      size: 20, color: hollow.textSecondary),
                ),
              ),
            ],
          ),
        ),
        // Placeholder body
        Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.hash,
                    size: 64,
                    color: hollow.textSecondary.withValues(alpha: 0.3)),
                const SizedBox(height: HollowSpacing.lg),
                Text(
                  'Welcome to #${channel?.name ?? "general"}',
                  style: HollowTypography.heading
                      .copyWith(color: hollow.textPrimary),
                ),
                const SizedBox(height: HollowSpacing.sm),
                Text(
                  'Channel messages coming soon.',
                  style: HollowTypography.body
                      .copyWith(color: hollow.textSecondary),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildChatOrEmpty({
    required HollowTheme hollow,
    required String? selectedPeerId,
    required Map<String, dynamic> peers,
    required String? selectedChannelId,
    required Map<String, ChannelInfo> channels,
  }) {
    // Share tab view
    final shareOpen = ref.watch(shareTabOpenProvider);
    if (shareOpen) {
      return const ShareDashboard();
    }

    // Archive tab view
    final archiveOpen = ref.watch(archiveTabOpenProvider);
    if (archiveOpen) {
      return const ArchiveDashboard();
    }

    // Server channel view
    if (selectedChannelId != null) {
      final channel = channels[selectedChannelId];
      final serverId = ref.read(selectedServerProvider);
      if (serverId != null && channel != null) {
        // Voice channels get a dedicated pane with lounge + screen sharing.
        if (channel.channelType == ChannelType.voice) {
          return VoiceChannelPane(
            key: ValueKey('vc:$selectedChannelId'),
            serverId: serverId,
            channelId: selectedChannelId,
            channelName: channel.name,
          );
        }
        return ChannelChatPane(
          key: ValueKey('ch:$selectedChannelId'),
          serverId: serverId,
          channelId: selectedChannelId,
          channelName: channel.name,
        );
      }
      return _buildChannelPlaceholder(hollow, channel);
    }
    // DM chat view — show Home dashboard when nothing selected (dock mode)
    if (selectedPeerId == null) {
      final layoutMode =
          ref.read(layoutModeProvider).valueOrNull ?? LayoutMode.dock;
      if (layoutMode == LayoutMode.dock) {
        return const HomeDashboard();
      }
      return _buildEmptyChat(hollow);
    }
    return ChatPane(
      key: ValueKey(selectedPeerId),
      peerId: selectedPeerId,
    );
  }

  /// Wraps the chat pane with a fade for the startup reveal.
  /// Always keeps the FadeTransition in the tree so the child's State
  /// (e.g. AmbientBackground's AnimationController) is preserved when
  /// the reveal completes — avoids resetting the ambient blob positions.
  Widget _chatRevealWrap(Widget child) {
    return FadeTransition(
      opacity: _chatReveal,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    final nodeState = ref.watch(nodeProvider);
    final peers = ref.watch(peersProvider);
    final selectedPeerId = ref.watch(selectedPeerProvider);
    final lastMessages = ref.watch(lastDmMessageProvider);

    final memberPanelOpen = ref.watch(memberPanelProvider);

    // Server/channel state
    final servers = ref.watch(serverListProvider);
    final selectedServerId = ref.watch(selectedServerProvider);
    final channels = ref.watch(visibleChannelsProvider);
    final selectedChannelId = ref.watch(selectedChannelProvider);
    final selectedServer =
        selectedServerId != null ? servers[selectedServerId] : null;
    final channelLayout = ref.watch(channelLayoutProvider);
    final settingsOpen = ref.watch(serverSettingsOpenProvider);

    // Layout mode
    final layoutMode =
        ref.watch(layoutModeProvider).valueOrNull ?? LayoutMode.dock;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final isDesktop = width >= _kDesktopBreakpoint;
        final isMobile = width < _kTabletBreakpoint;

        if (isMobile) {
          return const MobileShell();
        }

        final isDesktopPlatform =
            Platform.isWindows || Platform.isLinux || Platform.isMacOS;

        Widget body;

        if (layoutMode == LayoutMode.dock) {
          body = _buildDockLayout(
            hollow: hollow,
            isDesktopPlatform: isDesktopPlatform,
            isDesktop: isDesktop,
            peers: peers,
            lastMessages: lastMessages,
            selectedPeerId: selectedPeerId,
            nodeStatus: nodeState.status,
            selectedServer: selectedServer,
            selectedServerId: selectedServerId,
            channels: channels,
            selectedChannelId: selectedChannelId,
            channelLayout: channelLayout,
            settingsOpen: settingsOpen,
            memberPanelOpen: memberPanelOpen,
          );
        } else {
          body = _buildClassicLayout(
            hollow: hollow,
            isDesktopPlatform: isDesktopPlatform,
            isDesktop: isDesktop,
            isMobile: isMobile,
            peers: peers,
            lastMessages: lastMessages,
            selectedPeerId: selectedPeerId,
            nodeStatus: nodeState.status,
            selectedServer: selectedServer,
            selectedServerId: selectedServerId,
            channels: channels,
            selectedChannelId: selectedChannelId,
            channelLayout: channelLayout,
            settingsOpen: settingsOpen,
            memberPanelOpen: memberPanelOpen,
          );
        }

        // Wrap in DragToResizeArea to restore edge/corner resize handles
        // after setAsFrameless() removed them.
        if (isDesktopPlatform) {
          body = DragToResizeArea(child: body);
        }

        return _ShellScaffold(body: body);
      },
    );
  }

  /// Classic Discord-like layout: ServerStrip | ChannelSidebar | ChatPane | MemberPanel
  Widget _buildClassicLayout({
    required HollowTheme hollow,
    required bool isDesktopPlatform,
    required bool isDesktop,
    required bool isMobile,
    required Map<String, dynamic> peers,
    required Map<String, ChatMessage> lastMessages,
    required String? selectedPeerId,
    required NodeStatus nodeStatus,
    required ServerInfo? selectedServer,
    required String? selectedServerId,
    required Map<String, ChannelInfo> channels,
    required String? selectedChannelId,
    required String channelLayout,
    required bool settingsOpen,
    required bool memberPanelOpen,
  }) {
    // Check if viewing a voice channel with active screen share (full-bleed mode).
    final vcState = ref.watch(voiceChannelProvider);
    final selectedChannel = selectedChannelId != null ? channels[selectedChannelId] : null;
    final vcScreenShareFullBleed = selectedChannel?.channelType == ChannelType.voice
        && vcState.isInVoiceChannel
        && vcState.currentChannelId == selectedChannelId
        && (vcState.isScreenShareActive || vcState.isCameraActive);

    return StartupRevealScope(
      controller: _revealController,
      isComplete: _revealComplete,
      child: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                const RepaintBoundary(child: ServerStrip()),
                _buildChannelSidebar(
                  peers: peers,
                  lastMessages: lastMessages,
                  selectedPeerId: selectedPeerId,
                  nodeStatus: nodeStatus,
                  selectedServer: selectedServer,
                  channels: channels,
                  selectedChannelId: selectedChannelId,
                  channelLayoutJson: channelLayout,
                ),
                Expanded(
                  child: _chatRevealWrap(
                    RepaintBoundary(
                      child: AmbientBackground(
                        color1: hollow.accent,
                        color2: const Color(0xFF6366F1),
                        child: AnimatedSwitcher(
                          duration: HollowDurations.normal,
                          switchInCurve: HollowCurves.enter,
                          switchOutCurve: HollowCurves.exit,
                          layoutBuilder: (currentChild, previousChildren) {
                            return Stack(
                              alignment: Alignment.topCenter,
                              children: [
                                ...previousChildren,
                                ?currentChild,
                              ],
                            );
                          },
                          child: Container(
                            key: ValueKey(
                                ref.watch(shareTabOpenProvider) ? 'share'
                                    : ref.watch(archiveTabOpenProvider) ? 'archive'
                                    : settingsOpen && selectedServer != null
                                    ? 'settings-${selectedServer.serverId}'
                                    : selectedChannelId ?? selectedPeerId ?? 'empty'),
                            color: hollow.background,
                            child: settingsOpen && selectedServer != null
                                ? ServerSettingsPanel(server: selectedServer)
                                : _buildChatOrEmpty(
                                    hollow: hollow,
                                    selectedPeerId: selectedPeerId,
                                    peers: peers,
                                    selectedChannelId: selectedChannelId,
                                    channels: channels,
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (isDesktop || !isMobile)
                  _MemberPanelSlider(
                    visible: selectedServerId != null && memberPanelOpen && !vcScreenShareFullBleed,
                    serverId: selectedServerId,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Dock layout: FriendsBar (top) | ChannelSidebar + ChatPane + MemberPanel | BottomBar
  Widget _buildDockLayout({
    required HollowTheme hollow,
    required bool isDesktopPlatform,
    required bool isDesktop,
    required Map<String, dynamic> peers,
    required Map<String, ChatMessage> lastMessages,
    required String? selectedPeerId,
    required NodeStatus nodeStatus,
    required ServerInfo? selectedServer,
    required String? selectedServerId,
    required Map<String, ChannelInfo> channels,
    required String? selectedChannelId,
    required String channelLayout,
    required bool settingsOpen,
    required bool memberPanelOpen,
  }) {
    final splitState = ref.watch(splitViewProvider);

    // Check if viewing a voice channel with active screen share (full-bleed mode).
    final vcState = ref.watch(voiceChannelProvider);
    final selectedChannel = selectedChannelId != null ? channels[selectedChannelId] : null;
    final vcScreenShareFullBleed = selectedChannel?.channelType == ChannelType.voice
        && vcState.isInVoiceChannel
        && vcState.currentChannelId == selectedChannelId
        && (vcState.isScreenShareActive || vcState.isCameraActive);

    // Handle pending migration: when the left pane was closed in split mode,
    // the right pane's context needs to be applied to global providers.
    if (splitState.pendingMigration != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final migration = ref.read(splitViewProvider).pendingMigration;
        if (migration == null) return;
        if (migration.serverId != null) {
          // Fetch first, then batch all writes — no intermediate rebuilds.
          final channels = await ChannelListNotifier.fetchChannels(
              migration.serverId!);
          final layout = await ChannelLayoutNotifier.fetchLayout(
              migration.serverId!);
          ref.read(selectedPeerProvider.notifier).state = null;
          ref.read(channelListProvider.notifier).setChannels(channels);
          ref.read(channelLayoutProvider.notifier).setLayout(layout);
          ref.read(selectedServerProvider.notifier).state =
              migration.serverId;
          ref.read(selectedChannelProvider.notifier).state =
              migration.channelId;
        } else if (migration.peerId != null) {
          ref.read(selectedPeerProvider.notifier).state =
              migration.peerId;
          ref.read(selectedServerProvider.notifier).state = null;
          ref.read(selectedChannelProvider.notifier).state = null;
        }
        ref.read(splitViewProvider.notifier).clearPendingMigration();
      });
    }

    // Member panel shows for focused pane's server.
    final effectiveServerId = splitState.isSplit && splitState.focusedPane == 1
        ? splitState.rightPane?.serverId
        : selectedServerId;

    return StartupRevealScope(
      controller: _revealController,
      isComplete: _revealComplete,
      child: Column(
        children: [

          // Friends bar (top) — slides down from top
          ClipRect(
            child: AnimatedBuilder(
              animation: _friendsBarReveal,
              builder: (context, child) => Align(
                alignment: Alignment.bottomCenter,
                heightFactor: _friendsBarReveal.value.clamp(0.0, 1.0),
                child: child,
              ),
              child: FadeTransition(
                opacity: _friendsBarReveal,
                child: const RepaintBoundary(child: FriendsBar()),
              ),
            ),
          ),

          // Main content area
          Expanded(
            child: ClipRect(child: Row(
              children: [
                // Channel sidebar — animated slide in/out in dock mode
                _DockSidebarSlider(
                  visible: selectedServerId != null,
                  child: _buildChannelSidebar(
                    peers: peers,
                    lastMessages: lastMessages,
                    selectedPeerId: selectedPeerId,
                    nodeStatus: nodeStatus,
                    selectedServer: selectedServer,
                    channels: channels,
                    selectedChannelId: selectedChannelId,
                    channelLayoutJson: channelLayout,
                    dockMode: true,
                  ),
                ),

                // Chat area (single pane or split, animated transition)
                Expanded(
                  child: FadeTransition(
                    opacity: _dockChatReveal,
                    child: AnimatedSwitcher(
                      duration: HollowDurations.normal,
                      switchInCurve: HollowCurves.enter,
                      switchOutCurve: HollowCurves.exit,
                      layoutBuilder: (currentChild, previousChildren) {
                        return Stack(
                          alignment: Alignment.topCenter,
                          children: [
                            ...previousChildren,
                            ?currentChild,
                          ],
                        );
                      },
                      child: splitState.isSplit
                          ? _SplitChatArea(
                              key: const ValueKey('split'),
                              hollow: hollow,
                              selectedPeerId: selectedPeerId,
                              selectedChannelId: selectedChannelId,
                              channels: channels,
                              settingsOpen: settingsOpen,
                              selectedServer: selectedServer,
                            )
                          : RepaintBoundary(
                              key: ValueKey(
                                  'single-${settingsOpen && selectedServer != null ? 'settings-${selectedServer.serverId}' : selectedChannelId ?? selectedPeerId ?? 'empty'}'),
                              child: AmbientBackground(
                                color1: hollow.accent,
                                color2: const Color(0xFF6366F1),
                                child: AnimatedSwitcher(
                                  duration: HollowDurations.normal,
                                  switchInCurve: HollowCurves.enter,
                                  switchOutCurve: HollowCurves.exit,
                                  layoutBuilder: (currentChild,
                                      previousChildren) {
                                    return Stack(
                                      alignment: Alignment.topCenter,
                                      children: [
                                        ...previousChildren,
                                        ?currentChild,
                                      ],
                                    );
                                  },
                                  child: Container(
                                    key: ValueKey(ref.watch(shareTabOpenProvider)
                                        ? 'share'
                                        : ref.watch(archiveTabOpenProvider)
                                        ? 'archive'
                                        : settingsOpen &&
                                            selectedServer != null
                                        ? 'settings-${selectedServer.serverId}'
                                        : selectedChannelId ??
                                            selectedPeerId ??
                                            'empty'),
                                    color: settingsOpen ? hollow.surface : hollow.background,
                                    child: settingsOpen &&
                                            selectedServer != null
                                        ? ServerSettingsPanel(
                                            server: selectedServer)
                                        : _buildChatOrEmpty(
                                            hollow: hollow,
                                            selectedPeerId:
                                                selectedPeerId,
                                            peers: peers,
                                            selectedChannelId:
                                                selectedChannelId,
                                            channels: channels,
                                          ),
                                  ),
                                ),
                              ),
                            ),
                    ),
                  ),
                ),

                // Member panel — hidden during split view and VC screen share
                if (isDesktop && !splitState.isSplit)
                  _MemberPanelSlider(
                    visible:
                        effectiveServerId != null && memberPanelOpen && !vcScreenShareFullBleed,
                    serverId: effectiveServerId,
                  ),
              ],
            )),
          ),

          // Bottom bar (dock) — slides up from bottom
          ClipRect(
            child: AnimatedBuilder(
              animation: _bottomBarReveal,
              builder: (context, child) => Align(
                alignment: Alignment.topCenter,
                heightFactor: _bottomBarReveal.value.clamp(0.0, 1.0),
                child: child,
              ),
              child: FadeTransition(
                opacity: _bottomBarReveal,
                child: const RepaintBoundary(child: BottomBar()),
              ),
            ),
          ),
        ],
      ),
    );
  }

}

/// Animates the member panel sliding in/out from the right edge.
/// Uses clip + width factor like the startup RevealClip.
///
/// Freezes the panel content during close animation by overriding
/// [selectedServerProvider] with the last known server ID, preventing
/// the "No peers online" flash.
class _MemberPanelSlider extends StatefulWidget {
  final bool visible;
  final String? serverId;

  const _MemberPanelSlider({
    required this.visible,
    this.serverId,
  });

  @override
  State<_MemberPanelSlider> createState() => _MemberPanelSliderState();
}

class _MemberPanelSliderState extends State<_MemberPanelSlider>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _curved;

  /// Cached server ID — kept while closing so panel doesn't flash.
  String? _frozenServerId;

  @override
  void initState() {
    super.initState();
    _frozenServerId = widget.serverId;
    _controller = AnimationController(
      vsync: this,
      duration: HollowDurations.normal,
      value: widget.visible ? 1.0 : 0.0,
    );
    _curved = CurvedAnimation(
      parent: _controller,
      curve: HollowCurves.enter,
      reverseCurve: HollowCurves.exit,
    );
  }

  /// True while the panel is animating closed — freezes content.
  bool _isClosing = false;

  @override
  void didUpdateWidget(_MemberPanelSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible != oldWidget.visible) {
      _controller.duration = HollowDurations.normal;
      if (widget.visible) {
        // Opening — unfreeze content, update server ID.
        _isClosing = false;
        _frozenServerId = widget.serverId;
        _controller.forward();
      } else {
        // Closing — freeze content so it doesn't flash "No peers online".
        _isClosing = true;
        _controller.reverse();
      }
    } else if (widget.visible && widget.serverId != oldWidget.serverId) {
      // Server changed while panel is open — update live.
      _frozenServerId = widget.serverId;
    }
  }

  @override
  void dispose() {
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _curved,
      builder: (context, child) {
        // Hide completely when animation finishes closing.
        if (_curved.value == 0.0) return const SizedBox.shrink();

        return ClipRect(
          child: Align(
            alignment: Alignment.centerRight,
            widthFactor: _curved.value,
            child: FadeTransition(
              opacity: _curved,
              child: child,
            ),
          ),
        );
      },
      // Only override selectedServerProvider during close animation
      // to freeze content. Otherwise let it use the real provider.
      child: _isClosing && _frozenServerId != null
          ? ProviderScope(
              overrides: [
                selectedServerProvider.overrideWith(
                  (ref) => _frozenServerId,
                ),
              ],
              child: const RepaintBoundary(child: MemberPanel()),
            )
          : const RepaintBoundary(child: MemberPanel()),
    );
  }
}

/// Animates the channel sidebar sliding in/out from the left in dock mode.
class _DockSidebarSlider extends StatefulWidget {
  final bool visible;
  final Widget child;

  const _DockSidebarSlider({
    required this.visible,
    required this.child,
  });

  @override
  State<_DockSidebarSlider> createState() => _DockSidebarSliderState();
}

class _DockSidebarSliderState extends State<_DockSidebarSlider>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _curved;

  /// Cached child widget — kept during close animation so content
  /// doesn't collapse before the slide-out finishes.
  Widget? _frozenChild;
  bool _isClosing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: HollowDurations.normal,
      value: widget.visible ? 1.0 : 0.0,
    );
    _curved = CurvedAnimation(
      parent: _controller,
      curve: HollowCurves.enter,
      reverseCurve: HollowCurves.exit,
    );
    if (widget.visible) _frozenChild = widget.child;
  }

  @override
  void didUpdateWidget(_DockSidebarSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible != oldWidget.visible) {
      _controller.duration = HollowDurations.normal;
      if (widget.visible) {
        _isClosing = false;
        _frozenChild = widget.child;
        _controller.forward();
      } else {
        // Freeze the current child so it stays visible during close.
        _isClosing = true;
        _controller.reverse();
      }
    } else if (widget.visible) {
      // Update child while open.
      _frozenChild = widget.child;
    }
  }

  @override
  void dispose() {
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _curved,
      builder: (context, child) {
        if (_curved.value == 0.0) return const SizedBox.shrink();
        return ClipRect(
          child: Align(
            alignment: Alignment.centerLeft,
            widthFactor: _curved.value,
            child: FadeTransition(
              opacity: _curved,
              child: child,
            ),
          ),
        );
      },
      // During close animation, show the frozen child.
      child: _isClosing ? _frozenChild : widget.child,
    );
  }
}

/// Split chat area — two panes side by side with a draggable divider.
class _SplitChatArea extends ConsumerStatefulWidget {
  final HollowTheme hollow;
  final String? selectedPeerId;
  final String? selectedChannelId;
  final Map<String, ChannelInfo> channels;
  final bool settingsOpen;
  final ServerInfo? selectedServer;

  const _SplitChatArea({
    super.key,
    required this.hollow,
    required this.selectedPeerId,
    required this.selectedChannelId,
    required this.channels,
    required this.settingsOpen,
    required this.selectedServer,
  });

  @override
  ConsumerState<_SplitChatArea> createState() => _SplitChatAreaState();
}

class _SplitChatAreaState extends ConsumerState<_SplitChatArea> {
  @override
  Widget build(BuildContext context) {
    final hollow = widget.hollow;
    final splitState = ref.watch(splitViewProvider);
    final rightPane = splitState.rightPane ?? const PaneContext();
    final dividerPos = splitState.dividerPosition;
    final focusedPane = splitState.focusedPane;

    final leftFlex = (dividerPos * 1000).round();
    final rightFlex = ((1 - dividerPos) * 1000).round();

    // ProviderScope for the entire right section (sidebar + chat).
    return ProviderScope(
      key: ValueKey('split-${rightPane.serverId}:${rightPane.channelId}:${rightPane.peerId}'),
      overrides: [
        selectedServerProvider
            .overrideWith((ref) => rightPane.serverId),
        selectedChannelProvider
            .overrideWith((ref) => rightPane.channelId),
        selectedPeerProvider
            .overrideWith((ref) => rightPane.peerId),
      ],
      child: Row(
        children: [
          // ── Left Pane Chat (uses global providers) ──
          Flexible(
            flex: leftFlex,
            child: GestureDetector(
              onTap: () =>
                  ref.read(splitViewProvider.notifier).setFocus(0),
              child: AnimatedContainer(
                duration: HollowDurations.fast,
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: focusedPane == 0
                          ? hollow.accent
                          : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
                child: RepaintBoundary(
                  child: AmbientBackground(
                    color1: hollow.accent,
                    color2: const Color(0xFF6366F1),
                    child: AnimatedSwitcher(
                      duration: HollowDurations.normal,
                      switchInCurve: HollowCurves.enter,
                      switchOutCurve: HollowCurves.exit,
                      layoutBuilder: (currentChild, previousChildren) {
                        return Stack(
                          alignment: Alignment.topCenter,
                          children: [
                            ...previousChildren,
                            ?currentChild,
                          ],
                        );
                      },
                      child: Container(
                        key: ValueKey(widget.settingsOpen &&
                                widget.selectedServer != null
                            ? 'settings-${widget.selectedServer!.serverId}'
                            : widget.selectedChannelId ??
                                widget.selectedPeerId ??
                                'empty-left'),
                        color: hollow.background,
                        child: widget.settingsOpen &&
                                widget.selectedServer != null
                            ? ServerSettingsPanel(
                                server: widget.selectedServer!)
                            : _buildLeftChatOrEmpty(hollow),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // ── Draggable Divider ──
          _SplitDivider(
            onDrag: (details) {
              // Use delta-based dragging to avoid snap-to-center.
              final renderBox = context.findRenderObject() as RenderBox;
              final totalWidth = renderBox.size.width;
              if (totalWidth > 0) {
                final delta = details.delta.dx / totalWidth;
                final current = ref.read(splitViewProvider).dividerPosition;
                ref
                    .read(splitViewProvider.notifier)
                    .setDividerPosition(current + delta);
              }
            },
          ),

          // ── Right Pane Sidebar (fixed width, if server selected) ──
          _RightPaneSidebar(hollow: hollow),

          // ── Right Pane Chat ──
          Flexible(
            flex: rightFlex,
            child: GestureDetector(
              onTap: () =>
                  ref.read(splitViewProvider.notifier).setFocus(1),
              child: AnimatedContainer(
                duration: HollowDurations.fast,
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: focusedPane == 1
                          ? hollow.accent
                          : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
                child: RepaintBoundary(
                  child: AmbientBackground(
                    color1: hollow.accent,
                    color2: const Color(0xFF6366F1),
                    child: _RightPaneChatContent(hollow: hollow),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLeftChatOrEmpty(HollowTheme hollow) {
    if (widget.selectedChannelId != null) {
      final channel = widget.channels[widget.selectedChannelId];
      final serverId = ref.read(selectedServerProvider);
      if (serverId != null && channel != null) {
        return ChannelChatPane(
          key: ValueKey('ch:${widget.selectedChannelId}'),
          serverId: serverId,
          channelId: widget.selectedChannelId!,
          channelName: channel.name,
          splitPaneIndex: 0,
        );
      }
    }
    if (widget.selectedPeerId != null) {
      return ChatPane(
        key: ValueKey(widget.selectedPeerId),
        peerId: widget.selectedPeerId!,
        splitPaneIndex: 0,
      );
    }
    return _buildSplitEmptyChat(hollow);
  }

  Widget _buildSplitEmptyChat(HollowTheme hollow) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            LucideIcons.messageSquare,
            size: 48,
            color: hollow.textSecondary.withValues(alpha: 0.3),
          ),
          const SizedBox(height: HollowSpacing.md),
          Text(
            'Select a conversation',
            style: HollowTypography.body.copyWith(
              color: hollow.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Channel sidebar for the right pane in split view (fixed width).
/// Loads channels from FFI independently of the global channelListProvider.
class _RightPaneSidebar extends ConsumerStatefulWidget {
  final HollowTheme hollow;
  const _RightPaneSidebar({required this.hollow});

  @override
  ConsumerState<_RightPaneSidebar> createState() =>
      _RightPaneSidebarState();
}

class _RightPaneSidebarState extends ConsumerState<_RightPaneSidebar> {
  Map<String, ChannelInfo> _channels = {};
  String _channelLayoutJson = '[]';
  String? _loadedServerId;

  @override
  Widget build(BuildContext context) {
    final selectedServerId = ref.watch(selectedServerProvider);

    if (selectedServerId == null) return const SizedBox.shrink();

    if (selectedServerId != _loadedServerId) {
      _loadChannels(selectedServerId);
    }

    final selectedChannelId = ref.watch(selectedChannelProvider);
    final servers = ref.watch(serverListProvider);
    final selectedServer = servers[selectedServerId];

    return ChannelSidebar(
      peers: const {},
      lastMessages: const {},
      selectedPeerId: null,
      nodeStatus: NodeStatus.connected,
      onPeerSelected: (_) {},
      lastMessage: (_) => null,
      formatTime: (_) => '',
      selectedServer: selectedServer,
      channels: _channels,
      selectedChannelId: selectedChannelId,
      onChannelSelected: (channelId) {
        ref.read(splitViewProvider.notifier).setRightChannel(channelId);
      },
      onCreateChannel: () {
        if (selectedServer != null) {
          showCreateChannelDialog(context, selectedServer.serverId);
        }
      },
      onOpenSettings: () {
        if (selectedServer != null) {
          _showServerSettingsDialog(context, selectedServer);
        }
      },
      canManageChannels: selectedServer != null &&
          (ref
                  .watch(
                      myPermissionsProvider(selectedServer.serverId))
                  .whenOrNull(
                      data: (perms) =>
                          (perms & Permission.manageChannels) != 0) ??
              false),
      channelLayoutJson: _channelLayoutJson,
      width: 200,
      dockMode: true,
      showUserBar: false,
    );
  }

  Future<void> _loadChannels(String serverId) async {
    _loadedServerId = serverId;
    try {
      final channels =
          await crdt_api.getServerChannels(serverId: serverId);
      final map = <String, ChannelInfo>{};
      for (final ch in channels) {
        map[ch.channelId] = ChannelInfo(
          channelId: ch.channelId,
          name: ch.name,
          category: ch.category,
        );
      }
      final layoutJson =
          await crdt_api.getChannelLayout(serverId: serverId);
      if (mounted) {
        setState(() {
          _channels = map;
          _channelLayoutJson = layoutJson;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _channels = {};
          _channelLayoutJson = '[]';
        });
      }
    }
  }
}

/// Chat content for the right pane in split view (no sidebar).
class _RightPaneChatContent extends ConsumerWidget {
  final HollowTheme hollow;
  const _RightPaneChatContent({required this.hollow});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedChannelId = ref.watch(selectedChannelProvider);
    final selectedPeerId = ref.watch(selectedPeerProvider);
    final selectedServerId = ref.watch(selectedServerProvider);

    if (selectedChannelId != null && selectedServerId != null) {
      // Get channel name from the sibling sidebar's loaded data.
      // Use a FutureBuilder to load it if needed.
      return _RightChannelChat(
        serverId: selectedServerId,
        channelId: selectedChannelId,
      );
    }

    if (selectedPeerId != null && selectedPeerId.isNotEmpty) {
      return Container(
        color: hollow.background,
        child: ChatPane(
          key: ValueKey('dm-r:$selectedPeerId'),
          peerId: selectedPeerId,
          splitPaneIndex: 1,
        ),
      );
    }

    // Empty state
    return Container(
      color: hollow.background,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.columns,
              size: 48,
              color: hollow.textSecondary.withValues(alpha: 0.3),
            ),
            const SizedBox(height: HollowSpacing.md),
            Text(
              'Select a conversation',
              style: HollowTypography.body.copyWith(
                color: hollow.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Loads channel name from FFI and renders ChannelChatPane.
class _RightChannelChat extends StatefulWidget {
  final String serverId;
  final String channelId;
  const _RightChannelChat({
    required this.serverId,
    required this.channelId,
  });

  @override
  State<_RightChannelChat> createState() => _RightChannelChatState();
}

class _RightChannelChatState extends State<_RightChannelChat> {
  final Map<String, String> _nameCache = {};

  @override
  Widget build(BuildContext context) {
    final cacheKey = '${widget.serverId}:${widget.channelId}';
    final name = _nameCache[cacheKey];

    if (name == null) {
      _loadName();
      return const SizedBox.shrink();
    }

    return ChannelChatPane(
      key: ValueKey('ch-r:${widget.channelId}'),
      serverId: widget.serverId,
      channelId: widget.channelId,
      channelName: name,
      splitPaneIndex: 1,
    );
  }

  Future<void> _loadName() async {
    final cacheKey = '${widget.serverId}:${widget.channelId}';
    if (_nameCache.containsKey(cacheKey)) return;
    try {
      final channels = await crdt_api.getServerChannels(
          serverId: widget.serverId);
      for (final ch in channels) {
        _nameCache['${widget.serverId}:${ch.channelId}'] = ch.name;
      }
    } catch (_) {
      _nameCache[cacheKey] = widget.channelId;
    }
    if (mounted) setState(() {});
  }
}

/// Shows server settings as a dialog popup (used during split view).
void _showServerSettingsDialog(BuildContext context, ServerInfo server) {
  showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Server Settings',
    barrierColor: Colors.black.withValues(alpha: 0.5),
    transitionDuration: HollowDurations.normal,
    pageBuilder: (context, anim1, anim2) {
      return Center(
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: 800,
            height: 600,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: HollowTheme.of(context).background,
              borderRadius: BorderRadius.circular(
                HollowTheme.of(context).radiusLg,
              ),
              border: Border.all(
                color: HollowTheme.of(context).border,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: ServerSettingsPanel(
              server: server,
              onClose: () => Navigator.of(context).pop(),
            ),
          ),
        ),
      );
    },
    transitionBuilder: (context, anim1, anim2, child) {
      return FadeTransition(
        opacity: CurvedAnimation(parent: anim1, curve: Curves.easeOut),
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.95, end: 1.0).animate(
            CurvedAnimation(parent: anim1, curve: Curves.easeOut),
          ),
          child: child,
        ),
      );
    },
  );
}

/// Draggable vertical divider between split panes.
class _SplitDivider extends StatefulWidget {
  final void Function(DragUpdateDetails) onDrag;

  const _SplitDivider({required this.onDrag});

  @override
  State<_SplitDivider> createState() => _SplitDividerState();
}

class _SplitDividerState extends State<_SplitDivider> {
  bool _hovering = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final isActive = _hovering || _dragging;

    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onHorizontalDragStart: (_) => setState(() => _dragging = true),
        onHorizontalDragUpdate: widget.onDrag,
        onHorizontalDragEnd: (_) => setState(() => _dragging = false),
        child: AnimatedContainer(
          duration: HollowDurations.fast,
          width: 6,
          color: isActive
              ? hollow.accent.withValues(alpha: 0.3)
              : Colors.transparent,
          child: Center(
            child: AnimatedContainer(
              duration: HollowDurations.fast,
              width: isActive ? 2 : 1,
              height: 40,
              decoration: BoxDecoration(
                color: isActive
                    ? hollow.accent
                    : hollow.border,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Isolates the background image and scaffold from the main shell build.
/// Only rebuilds when backgroundProvider changes.
class _ShellScaffold extends ConsumerWidget {
  final Widget body;
  const _ShellScaffold({required this.body});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final bg = ref.watch(backgroundProvider);

    Widget scaffold = Scaffold(
      backgroundColor: bg.hasBackground ? Colors.transparent : hollow.background,
      body: Stack(
        children: [
          body,
          const NotificationOverlay(),
          const ActiveCallBar(),
          const IncomingCallOverlay(),
        ],
      ),
    );

    if (bg.hasBackground) {
      scaffold = Stack(
        children: [
          Positioned.fill(
            child: Container(
              color: Colors.black,
              child: Image.memory(
                bg.imageBytes!,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                width: double.infinity,
                height: double.infinity,
              ),
            ),
          ),
          scaffold,
        ],
      );
    }

    return scaffold;
  }
}
