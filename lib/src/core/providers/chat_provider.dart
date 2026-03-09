import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/core/models/chat_message.dart';
import 'package:haven/src/core/providers/service_providers.dart';

class ChatNotifier extends Notifier<Map<String, List<ChatMessage>>> {
  @override
  Map<String, List<ChatMessage>> build() => {};

  /// Send a message to a peer (FFI + persist + update state).
  Future<void> sendMessage(String peerId, String text) async {
    final networkService = ref.read(networkServiceProvider);
    final storageService = ref.read(storageServiceProvider);

    await networkService.sendMessage(peerId: peerId, text: text);

    final now = DateTime.now();
    final msg = ChatMessage(text: text, isMe: true, timestamp: now);

    _addMessage(peerId, msg);

    await storageService.saveMessage(
      peerId: peerId,
      text: text,
      isMine: true,
      timestamp: now.millisecondsSinceEpoch,
    );
  }

  /// Receive a message from a peer (from network events).
  void receiveMessage(String fromPeer, String text) {
    final now = DateTime.now();
    final msg = ChatMessage(text: text, isMe: false, timestamp: now);
    _addMessage(fromPeer, msg);

    // Persist in background — don't block UI.
    ref.read(storageServiceProvider).saveMessage(
      peerId: fromPeer,
      text: text,
      isMine: false,
      timestamp: now.millisecondsSinceEpoch,
    );
  }

  /// Add a send-failure message (shown as a local system message).
  void addSendFailure(String toPeer, String error) {
    _addMessage(
      toPeer,
      ChatMessage(text: '[Failed to send: $error]', isMe: true),
    );
  }

  /// Load chat history from SQLCipher for a peer.
  Future<void> loadHistory(String peerId) async {
    final existing = state[peerId];
    if (existing != null && existing.isNotEmpty) return;

    try {
      final storageService = ref.read(storageServiceProvider);
      final stored = await storageService.loadMessages(
        peerId: peerId,
        limit: 200,
      );

      if (stored.isNotEmpty) {
        final messages = stored
            .map((m) => ChatMessage(
                  text: m.text,
                  isMe: m.isMine,
                  timestamp:
                      DateTime.fromMillisecondsSinceEpoch(m.timestamp),
                  signature: m.signature,
                  publicKey: m.publicKey,
                ))
            .toList();

        final updated = Map.of(state);
        updated[peerId] = [...messages, ...?state[peerId]];
        state = updated;
      }
    } catch (e) {
      debugPrint('[HAVEN] Failed to load history for $peerId: $e');
    }
  }

  void _addMessage(String peerId, ChatMessage message) {
    final current = state[peerId] ?? [];
    final updated = Map.of(state);
    updated[peerId] = [...current, message];
    state = updated;
  }
}

final chatProvider =
    NotifierProvider<ChatNotifier, Map<String, List<ChatMessage>>>(
        ChatNotifier.new);
