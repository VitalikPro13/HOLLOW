import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:haven/src/rust/api/identity.dart';
import 'package:haven/src/rust/api/network.dart';
import 'package:haven/src/rust/api/storage.dart';
import 'package:haven/src/rust/frb_generated.dart';

Future<void> main() async {
  await RustLib.init();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Haven',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
        brightness: Brightness.dark,
      ),
      home: const HavenHome(),
    );
  }
}

/// Connection status for the P2P node.
enum NodeStatus { loading, starting, connected, error }

/// A single chat message.
class ChatMessage {
  final String text;
  final bool isMe;
  final DateTime timestamp;

  ChatMessage({required this.text, required this.isMe, DateTime? timestamp})
      : timestamp = timestamp ?? DateTime.now();
}

class HavenHome extends StatefulWidget {
  const HavenHome({super.key});

  @override
  State<HavenHome> createState() => _HavenHomeState();
}

class _HavenHomeState extends State<HavenHome> {
  String? _localPeerId;
  String? _mnemonic;
  NodeStatus _status = NodeStatus.loading;
  String? _error;
  Timer? _pollTimer;

  String? _selectedPeerId;
  final Map<String, List<String>> _discoveredPeers = {};
  final Map<String, List<ChatMessage>> _chatHistory = {};
  final Set<String> _encryptedPeers = {};
  String? _activeRoom;
  final _roomController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadIdentity();
  }

  Future<void> _loadIdentity() async {
    try {
      final info = await loadOrCreateIdentity();
      await openMessageStore();
      setState(() {
        _localPeerId = info.peerId;
        _mnemonic = info.mnemonic;
      });
      if (info.mnemonic != null && mounted) {
        _showMnemonicDialog(info.mnemonic!);
      }
      // Auto-start node after identity loads.
      _autoStartNode();
    } catch (e) {
      setState(() {
        _status = NodeStatus.error;
        _error = e.toString();
      });
    }
  }

  Future<void> _autoStartNode() async {
    setState(() => _status = NodeStatus.starting);
    try {
      final peerId = await startNode();
      setState(() {
        _localPeerId = peerId;
        _status = NodeStatus.connected;
        _error = null;
      });
      _pollTimer = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) => _pollEvents(),
      );
    } catch (e) {
      setState(() {
        _status = NodeStatus.error;
        _error = e.toString();
      });
    }
  }

  void _showMnemonicDialog(String mnemonic) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Your Recovery Phrase'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This is your 24-word recovery phrase. Write it down and keep '
              'it safe. You will need it to restore your identity if you lose '
              'access to this device.',
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.amber.withValues(alpha: 0.5)),
              ),
              child: SelectableText(
                mnemonic,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 14,
                  height: 1.6,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: mnemonic));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Copied to clipboard')),
                    );
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copy'),
                ),
              ],
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('I\'ve saved it'),
          ),
        ],
      ),
    );
  }

  Future<void> _pollEvents() async {
    while (true) {
      final event = await pollNetworkEvent();
      if (event == null) break;

      setState(() {
        switch (event) {
          case NetworkEvent_PeerDiscovered(:final peer):
            debugPrint('[HAVEN] Peer discovered: ${peer.peerId} at ${peer.addresses}');
            final existing = _discoveredPeers[peer.peerId] ?? [];
            final allAddrs = {...existing, ...peer.addresses}.toList();
            _discoveredPeers[peer.peerId] = allAddrs;
          case NetworkEvent_PeerExpired(:final peerId):
            _discoveredPeers.remove(peerId);
            if (_selectedPeerId == peerId) {
              _selectedPeerId = null;
            }
          case NetworkEvent_Listening(:final address):
            debugPrint('[HAVEN] Listening: $address');
            break;
          case NetworkEvent_MessageReceived(:final fromPeer, :final text):
            final now = DateTime.now();
            _chatHistory.putIfAbsent(fromPeer, () => []);
            _chatHistory[fromPeer]!
                .add(ChatMessage(text: text, isMe: false, timestamp: now));
            saveMessage(
              peerId: fromPeer,
              text: text,
              isMine: false,
              timestamp: now.millisecondsSinceEpoch,
            );
          case NetworkEvent_SessionEstablished(:final peerId):
            _encryptedPeers.add(peerId);
          case NetworkEvent_MessageSent():
            break;
          case NetworkEvent_MessageSendFailed(:final toPeer, :final error):
            _chatHistory.putIfAbsent(toPeer, () => []);
            _chatHistory[toPeer]!.add(
              ChatMessage(text: '[Failed to send: $error]', isMe: true),
            );
          case NetworkEvent_Error(:final message):
            debugPrint('[HAVEN] $message');
            _error = message;
        }
      });
    }
  }

  Future<void> _sendMessage(String peerId, String text) async {
    await sendMessage(peerId: peerId, text: text);
    final now = DateTime.now();
    setState(() {
      _chatHistory.putIfAbsent(peerId, () => []);
      _chatHistory[peerId]!
          .add(ChatMessage(text: text, isMe: true, timestamp: now));
    });
    await saveMessage(
      peerId: peerId,
      text: text,
      isMine: true,
      timestamp: now.millisecondsSinceEpoch,
    );
  }

  Future<void> _joinRoom(String roomCode) async {
    if (roomCode.isEmpty || _status != NodeStatus.connected) return;
    try {
      await joinRoom(roomCode: roomCode);
      setState(() => _activeRoom = roomCode);
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _roomController.dispose();
    super.dispose();
  }

  // -- Status indicator helpers --

  Color _statusColor() {
    return switch (_status) {
      NodeStatus.connected => Colors.green,
      NodeStatus.starting => Colors.orange,
      NodeStatus.loading => Colors.grey,
      NodeStatus.error => Colors.red,
    };
  }

  String _statusText() {
    return switch (_status) {
      NodeStatus.connected => 'Connected',
      NodeStatus.starting => 'Starting...',
      NodeStatus.loading => 'Loading...',
      NodeStatus.error => 'Error',
    };
  }

  // -- Peer card helpers --

  ChatMessage? _lastMessage(String peerId) {
    final msgs = _chatHistory[peerId];
    if (msgs == null || msgs.isEmpty) return null;
    return msgs.last;
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.month}/${dt.day}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shortPeerId = _localPeerId != null && _localPeerId!.length > 12
        ? '${_localPeerId!.substring(0, 12)}...'
        : _localPeerId ?? '---';

    return Scaffold(
      body: Column(
        children: [
          // -- Top bar --
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              border: Border(
                bottom: BorderSide(color: theme.dividerColor),
              ),
            ),
            child: Row(
              children: [
                Text(
                  'Haven',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                // Error tooltip
                if (_error != null)
                  Tooltip(
                    message: _error!,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Icon(
                        Icons.warning_amber_rounded,
                        size: 18,
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                // Status dot
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _statusColor(),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _statusText(),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                  ),
                ),
                const SizedBox(width: 16),
                // Peer ID (tap to copy)
                Tooltip(
                  message: _localPeerId ?? 'Loading...',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: () {
                      if (_localPeerId != null) {
                        Clipboard.setData(
                            ClipboardData(text: _localPeerId!));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Peer ID copied to clipboard'),
                            duration: Duration(seconds: 1),
                          ),
                        );
                      }
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      child: Text(
                        shortPeerId,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                  ),
                ),
                // Settings menu (recovery phrase)
                if (_mnemonic != null)
                  IconButton(
                    icon: const Icon(Icons.key, size: 18),
                    tooltip: 'Recovery phrase',
                    onPressed: () => _showMnemonicDialog(_mnemonic!),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                  ),
              ],
            ),
          ),

          // -- Main content: sidebar + chat area --
          Expanded(
            child: Row(
              children: [
                // Left sidebar
                _Sidebar(
                  peers: _discoveredPeers,
                  chatHistory: _chatHistory,
                  selectedPeerId: _selectedPeerId,
                  nodeStatus: _status,
                  encryptedPeers: _encryptedPeers,
                  onPeerSelected: (peerId) {
                    setState(() => _selectedPeerId = peerId);
                  },
                  lastMessage: _lastMessage,
                  formatTime: _formatTime,
                  activeRoom: _activeRoom,
                  roomController: _roomController,
                  onJoinRoom: _joinRoom,
                ),

                // Right chat area
                Expanded(
                  child: _selectedPeerId != null
                      ? _ChatPane(
                          key: ValueKey(_selectedPeerId),
                          peerId: _selectedPeerId!,
                          chatHistory: _chatHistory,
                          isEncrypted:
                              _encryptedPeers.contains(_selectedPeerId),
                          onSend: (text) =>
                              _sendMessage(_selectedPeerId!, text),
                        )
                      : Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.chat_outlined,
                                size: 64,
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: 0.2),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'Select a peer to start chatting',
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  color: theme.colorScheme.onSurface
                                      .withValues(alpha: 0.4),
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Sidebar
// =============================================================================

class _Sidebar extends StatelessWidget {
  final Map<String, List<String>> peers;
  final Map<String, List<ChatMessage>> chatHistory;
  final String? selectedPeerId;
  final NodeStatus nodeStatus;
  final Set<String> encryptedPeers;
  final ValueChanged<String> onPeerSelected;
  final ChatMessage? Function(String) lastMessage;
  final String Function(DateTime) formatTime;
  final String? activeRoom;
  final TextEditingController roomController;
  final Future<void> Function(String) onJoinRoom;

  const _Sidebar({
    required this.peers,
    required this.chatHistory,
    required this.selectedPeerId,
    required this.nodeStatus,
    required this.encryptedPeers,
    required this.onPeerSelected,
    required this.lastMessage,
    required this.formatTime,
    required this.activeRoom,
    required this.roomController,
    required this.onJoinRoom,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: 280,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          right: BorderSide(color: theme.dividerColor),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Room code section
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: activeRoom != null
                ? Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: theme.colorScheme.primary.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.cloud_done,
                          size: 16,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Room: $activeRoom',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w500,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  )
                : Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 36,
                          child: TextField(
                            controller: roomController,
                            style: theme.textTheme.bodySmall,
                            decoration: InputDecoration(
                              hintText: 'Room code...',
                              hintStyle: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: 0.4),
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 0,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                              isDense: true,
                            ),
                            onSubmitted: (v) => onJoinRoom(v.trim()),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      SizedBox(
                        height: 36,
                        child: FilledButton(
                          onPressed: () =>
                              onJoinRoom(roomController.text.trim()),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                          ),
                          child: const Text('Join'),
                        ),
                      ),
                    ],
                  ),
          ),
          const Divider(height: 1),

          // Sidebar header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              'Peers (${peers.length})',
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
          ),
          const Divider(height: 1),

          // Peer list
          Expanded(
            child: peers.isEmpty
                ? _EmptyPeerList(nodeStatus: nodeStatus)
                : ListView.builder(
                    itemCount: peers.length,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemBuilder: (context, index) {
                      final peerId = peers.keys.elementAt(index);
                      final isSelected = peerId == selectedPeerId;
                      final last = lastMessage(peerId);

                      return _PeerCard(
                        peerId: peerId,
                        isSelected: isSelected,
                        isEncrypted: encryptedPeers.contains(peerId),
                        lastMessage: last,
                        formatTime: formatTime,
                        onTap: () => onPeerSelected(peerId),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _EmptyPeerList extends StatelessWidget {
  final NodeStatus nodeStatus;

  const _EmptyPeerList({required this.nodeStatus});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final String text;
    final IconData icon;

    switch (nodeStatus) {
      case NodeStatus.connected:
        text = 'Searching for peers\non your local network...';
        icon = Icons.radar;
      case NodeStatus.starting:
        text = 'Starting node...';
        icon = Icons.hourglass_top;
      case NodeStatus.loading:
        text = 'Loading identity...';
        icon = Icons.person_outline;
      case NodeStatus.error:
        text = 'Failed to start node.\nCheck the error above.';
        icon = Icons.error_outline;
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 36,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Peer Card
// =============================================================================

class _PeerCard extends StatelessWidget {
  final String peerId;
  final bool isSelected;
  final bool isEncrypted;
  final ChatMessage? lastMessage;
  final String Function(DateTime) formatTime;
  final VoidCallback onTap;

  const _PeerCard({
    required this.peerId,
    required this.isSelected,
    required this.isEncrypted,
    required this.lastMessage,
    required this.formatTime,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shortId = peerId.length > 16
        ? '${peerId.substring(0, 16)}...'
        : peerId;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: isSelected
            ? theme.colorScheme.primary.withValues(alpha: 0.15)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                // Online indicator
                Container(
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(
                    color: Colors.green,
                    shape: BoxShape.circle,
                  ),
                ),
                if (isEncrypted) ...[
                  const SizedBox(width: 4),
                  Icon(
                    Icons.lock,
                    size: 12,
                    color: Colors.green.shade300,
                  ),
                ],
                const SizedBox(width: 10),
                // Peer info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        shortId,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontFamily: 'monospace',
                          fontWeight:
                              isSelected ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                      if (lastMessage != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          lastMessage!.isMe
                              ? 'You: ${lastMessage!.text}'
                              : lastMessage!.text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.5),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                // Timestamp
                if (lastMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      formatTime(lastMessage!.timestamp),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface
                            .withValues(alpha: 0.4),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Chat Pane (inline, no Scaffold/AppBar)
// =============================================================================

class _ChatPane extends StatefulWidget {
  final String peerId;
  final Map<String, List<ChatMessage>> chatHistory;
  final bool isEncrypted;
  final Future<void> Function(String text) onSend;

  const _ChatPane({
    super.key,
    required this.peerId,
    required this.chatHistory,
    required this.isEncrypted,
    required this.onSend,
  });

  @override
  State<_ChatPane> createState() => _ChatPaneState();
}

class _ChatPaneState extends State<_ChatPane> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  Timer? _refreshTimer;
  bool _historyLoaded = false;

  List<ChatMessage> get _messages =>
      widget.chatHistory[widget.peerId] ?? [];

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _refreshTimer = Timer.periodic(
      const Duration(milliseconds: 300),
      (_) {
        if (mounted) setState(() {});
      },
    );
  }

  Future<void> _loadHistory() async {
    if (_historyLoaded) return;
    _historyLoaded = true;
    try {
      widget.chatHistory.putIfAbsent(widget.peerId, () => []);
      final existing = widget.chatHistory[widget.peerId]!;
      if (existing.isNotEmpty) return;

      final stored = await loadMessages(peerId: widget.peerId, limit: 200);
      if (stored.isNotEmpty && mounted) {
        setState(() {
          existing.addAll(stored.map((m) => ChatMessage(
                text: m.text,
                isMe: m.isMine,
                timestamp:
                    DateTime.fromMillisecondsSinceEpoch(m.timestamp),
              )));
        });
        _scrollToBottom();
      }
    } catch (e) {
      debugPrint('Failed to load message history: $e');
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _handleSend() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _controller.clear();
    await widget.onSend(text);
    setState(() {});
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        // Peer ID header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: theme.dividerColor),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: Colors.green,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(
                  widget.peerId,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                  ),
                ),
              ),
              if (widget.isEncrypted) ...[
                Icon(
                  Icons.lock,
                  size: 14,
                  color: Colors.green.shade300,
                ),
                const SizedBox(width: 4),
                Text(
                  'Encrypted',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Colors.green.shade300,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              IconButton(
                icon: const Icon(Icons.copy, size: 16),
                tooltip: 'Copy peer ID',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: widget.peerId));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Peer ID copied'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                  minWidth: 28,
                  minHeight: 28,
                ),
              ),
            ],
          ),
        ),

        // Messages list
        Expanded(
          child: _messages.isEmpty
              ? Center(
                  child: Text(
                    'No messages yet. Say hello!',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurface
                          .withValues(alpha: 0.4),
                    ),
                  ),
                )
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(12),
                  itemCount: _messages.length,
                  itemBuilder: (context, index) {
                    final msg = _messages[index];
                    return _MessageBubble(
                      message: msg,
                      theme: theme,
                    );
                  },
                ),
        ),

        // Input bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(
              top: BorderSide(color: theme.dividerColor),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  decoration: const InputDecoration(
                    hintText: 'Type a message...',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                  onSubmitted: (_) => _handleSend(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: _handleSend,
                icon: const Icon(Icons.send),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// Message Bubble
// =============================================================================

class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final ThemeData theme;

  const _MessageBubble({required this.message, required this.theme});

  @override
  Widget build(BuildContext context) {
    final isMe = message.isMe;
    final time =
        '${message.timestamp.hour.toString().padLeft(2, '0')}:${message.timestamp.minute.toString().padLeft(2, '0')}';

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.5,
        ),
        decoration: BoxDecoration(
          color: isMe
              ? theme.colorScheme.primary
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment:
              isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(
              message.text,
              style: TextStyle(
                color: isMe
                    ? theme.colorScheme.onPrimary
                    : theme.colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              time,
              style: TextStyle(
                fontSize: 11,
                color: isMe
                    ? theme.colorScheme.onPrimary.withValues(alpha: 0.7)
                    : theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
