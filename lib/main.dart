import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:haven/src/rust/api/identity.dart';
import 'package:haven/src/rust/api/network.dart';
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
  bool _identityLoaded = false;
  bool _nodeRunning = false;
  String? _listenAddress;
  String? _error;
  Timer? _pollTimer;

  final Map<String, List<String>> _discoveredPeers = {};
  final Map<String, List<ChatMessage>> _chatHistory = {};

  @override
  void initState() {
    super.initState();
    _loadIdentity();
  }

  Future<void> _loadIdentity() async {
    try {
      final info = await loadOrCreateIdentity();
      setState(() {
        _localPeerId = info.peerId;
        _mnemonic = info.mnemonic;
        _identityLoaded = true;
        _error = null;
      });
      // If this is a brand new identity, show the mnemonic backup dialog.
      if (info.mnemonic != null && mounted) {
        _showMnemonicDialog(info.mnemonic!);
      }
    } catch (e) {
      setState(() => _error = e.toString());
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

  Future<void> _startNode() async {
    try {
      final peerId = await startNode();
      setState(() {
        _localPeerId = peerId;
        _nodeRunning = true;
        _error = null;
      });
      _pollTimer = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) => _pollEvents(),
      );
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  Future<void> _stopNode() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    try {
      await stopNode();
      setState(() {
        _nodeRunning = false;
        _discoveredPeers.clear();
        _listenAddress = null;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  Future<void> _pollEvents() async {
    while (true) {
      final event = await pollNetworkEvent();
      if (event == null) break;

      setState(() {
        switch (event) {
          case NetworkEvent_PeerDiscovered(:final peer):
            final existing = _discoveredPeers[peer.peerId] ?? [];
            final allAddrs = {...existing, ...peer.addresses}.toList();
            _discoveredPeers[peer.peerId] = allAddrs;
          case NetworkEvent_PeerExpired(:final peerId):
            _discoveredPeers.remove(peerId);
          case NetworkEvent_Listening(:final address):
            _listenAddress = address;
          case NetworkEvent_MessageReceived(:final fromPeer, :final text):
            _chatHistory.putIfAbsent(fromPeer, () => []);
            _chatHistory[fromPeer]!
                .add(ChatMessage(text: text, isMe: false));
          case NetworkEvent_MessageSent():
            // Message delivery confirmed — could update UI status later.
            break;
          case NetworkEvent_MessageSendFailed(:final toPeer, :final error):
            _chatHistory.putIfAbsent(toPeer, () => []);
            _chatHistory[toPeer]!.add(
              ChatMessage(text: '[Failed to send: $error]', isMe: true),
            );
          case NetworkEvent_Error(:final message):
            _error = message;
        }
      });
    }
  }

  void _openChat(String peerId) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ChatScreen(
          peerId: peerId,
          chatHistory: _chatHistory,
          onSend: (text) async {
            await sendMessage(peerId: peerId, text: text);
            setState(() {
              _chatHistory.putIfAbsent(peerId, () => []);
              _chatHistory[peerId]!
                  .add(ChatMessage(text: text, isMe: true));
            });
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Haven'),
        backgroundColor: theme.colorScheme.inversePrimary,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Identity section
            Text('Identity', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            if (!_identityLoaded)
              const Text('Loading identity...')
            else if (_localPeerId != null)
              SelectableText(
                'Peer ID: ${_localPeerId!.substring(0, 20)}...',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontFamily: 'monospace',
                ),
              ),
            if (_mnemonic != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: TextButton.icon(
                  onPressed: () => _showMnemonicDialog(_mnemonic!),
                  icon: const Icon(Icons.key, size: 16),
                  label: const Text('View recovery phrase'),
                ),
              ),

            const SizedBox(height: 12),
            const Divider(),
            const SizedBox(height: 8),

            // Node controls
            Text('P2P Network', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: _identityLoaded
                      ? (_nodeRunning ? _stopNode : _startNode)
                      : null,
                  icon: Icon(_nodeRunning ? Icons.stop : Icons.play_arrow),
                  label: Text(_nodeRunning ? 'Stop Node' : 'Start Node'),
                ),
                const SizedBox(width: 16),
                if (_nodeRunning)
                  Container(
                    width: 10,
                    height: 10,
                    decoration: const BoxDecoration(
                      color: Colors.green,
                      shape: BoxShape.circle,
                    ),
                  ),
                if (_nodeRunning)
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Text('Running'),
                  ),
              ],
            ),
            const SizedBox(height: 12),

            if (_listenAddress != null)
              Text(
                'Listening on: $_listenAddress',
                style: theme.textTheme.bodySmall,
              ),

            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Error: $_error',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),

            const SizedBox(height: 12),
            const Divider(),
            const SizedBox(height: 8),

            // Discovered peers
            Text(
              'Discovered Peers (${_discoveredPeers.length})',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _discoveredPeers.isEmpty
                  ? Center(
                      child: Text(
                        _nodeRunning
                            ? 'Searching for peers on your local network...'
                            : 'Start the node to discover peers.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.6,
                          ),
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _discoveredPeers.length,
                      itemBuilder: (context, index) {
                        final peerId =
                            _discoveredPeers.keys.elementAt(index);
                        final addresses = _discoveredPeers[peerId]!;
                        final unread = _chatHistory[peerId]
                                ?.where((m) => !m.isMe)
                                .length ??
                            0;
                        return Card(
                          child: ListTile(
                            leading: const Icon(Icons.computer),
                            title: Text(
                              '${peerId.substring(0, 16)}...',
                              style:
                                  const TextStyle(fontFamily: 'monospace'),
                            ),
                            subtitle: Text(addresses.join(', ')),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (unread > 0)
                                  Padding(
                                    padding:
                                        const EdgeInsets.only(right: 8),
                                    child: CircleAvatar(
                                      radius: 12,
                                      backgroundColor:
                                          theme.colorScheme.primary,
                                      child: Text(
                                        '$unread',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                  ),
                                const Icon(Icons.chat_bubble_outline),
                              ],
                            ),
                            onTap: () => _openChat(peerId),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Chat screen for direct messaging with a single peer.
class ChatScreen extends StatefulWidget {
  final String peerId;
  final Map<String, List<ChatMessage>> chatHistory;
  final Future<void> Function(String text) onSend;

  const ChatScreen({
    super.key,
    required this.peerId,
    required this.chatHistory,
    required this.onSend,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  Timer? _refreshTimer;

  List<ChatMessage> get _messages =>
      widget.chatHistory[widget.peerId] ?? [];

  @override
  void initState() {
    super.initState();
    // Refresh the message list periodically so incoming messages appear.
    _refreshTimer = Timer.periodic(
      const Duration(milliseconds: 300),
      (_) {
        if (mounted) setState(() {});
      },
    );
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
    final shortId = widget.peerId.length > 16
        ? '${widget.peerId.substring(0, 16)}...'
        : widget.peerId;

    return Scaffold(
      appBar: AppBar(
        title: Text(shortId, style: const TextStyle(fontFamily: 'monospace', fontSize: 14)),
        backgroundColor: theme.colorScheme.inversePrimary,
      ),
      body: Column(
        children: [
          // Messages list
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Text(
                      'No messages yet. Say hello!',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface
                            .withValues(alpha: 0.6),
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
                top: BorderSide(
                  color: theme.dividerColor,
                ),
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
      ),
    );
  }
}

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
          maxWidth: MediaQuery.of(context).size.width * 0.7,
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
