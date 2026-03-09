/// A single chat message.
class ChatMessage {
  final String text;
  final bool isMe;
  final DateTime timestamp;
  final String? signature;
  final String? publicKey;

  ChatMessage({
    required this.text,
    required this.isMe,
    DateTime? timestamp,
    this.signature,
    this.publicKey,
  }) : timestamp = timestamp ?? DateTime.now();
}
