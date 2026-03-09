/// A single channel chat message.
class ChannelChatMessage {
  final String senderId;
  final String text;
  final bool isMe;
  final DateTime timestamp;
  final String? signature;
  final String? publicKey;

  ChannelChatMessage({
    required this.senderId,
    required this.text,
    required this.isMe,
    DateTime? timestamp,
    this.signature,
    this.publicKey,
  }) : timestamp = timestamp ?? DateTime.now();
}
