import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;

/// A single channel chat message.
class ChannelChatMessage {
  final String senderId;
  final String text;
  final bool isMe;
  final DateTime timestamp;
  final String? signature;
  final String? publicKey;
  final String? messageId;
  final DateTime? editedAt;
  final DateTime? hiddenAt;
  final String? replyToMid;
  /// Emoji reactions: emoji → list of peer IDs who reacted.
  final Map<String, List<String>> reactions;
  /// File attachment (null if text-only message).
  final FileAttachment? fileAttachment;
  /// OG link preview for the first URL. Null when there is no URL, the fetch
  /// failed, or the message predates link previews.
  final network_api.LinkPreviewRef? linkPreview;

  /// Signature verdict for a message loaded from an IMPORTED ARCHIVE, computed
  /// by the Rust archive loader. Null for live messages, which verify through
  /// `verifyMessageProofV2` against the local DB row an archive does not have.
  final bool? archiveSignatureValid;

  ChannelChatMessage({
    required this.senderId,
    required this.text,
    required this.isMe,
    DateTime? timestamp,
    this.signature,
    this.publicKey,
    this.messageId,
    this.editedAt,
    this.hiddenAt,
    this.replyToMid,
    Map<String, List<String>>? reactions,
    this.fileAttachment,
    this.linkPreview,
    this.archiveSignatureValid,
  })  : timestamp = timestamp ?? DateTime.now(),
        reactions = reactions ?? const {};

  /// Create a copy with updated fields (for editing/deletion/reactions).
  ChannelChatMessage copyWith({
    String? text,
    DateTime? timestamp,
    DateTime? editedAt,
    DateTime? hiddenAt,
    Map<String, List<String>>? reactions,
    FileAttachment? fileAttachment,
    network_api.LinkPreviewRef? linkPreview,
    /// Drop the card entirely — see the DM twin in [ChatMessage.copyWith].
    bool clearLinkPreview = false,
    String? signature,
    String? publicKey,
  }) {
    return ChannelChatMessage(
      senderId: senderId,
      text: text ?? this.text,
      isMe: isMe,
      timestamp: timestamp ?? this.timestamp,
      signature: signature ?? this.signature,
      publicKey: publicKey ?? this.publicKey,
      messageId: messageId,
      editedAt: editedAt ?? this.editedAt,
      hiddenAt: hiddenAt ?? this.hiddenAt,
      replyToMid: replyToMid,
      reactions: reactions ?? this.reactions,
      fileAttachment: fileAttachment ?? this.fileAttachment,
      linkPreview: clearLinkPreview ? null : (linkPreview ?? this.linkPreview),
      archiveSignatureValid: archiveSignatureValid,
    );
  }

}
