import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;

/// A single chat message.
class ChatMessage {
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
  /// OG link preview for the first URL in the message (Phase 6.75).
  /// Null when the message has no URL, when the OG fetch failed, or when
  /// the message was sent before link previews existed.
  final network_api.LinkPreviewRef? linkPreview;

  /// Signature verdict for a message loaded from an IMPORTED ARCHIVE, computed
  /// by the Rust archive loader (`archive::loader::verify_one_message`, v2
  /// payload). Null for live messages — those verify through
  /// `verifyMessageProofV2`, which reads the row out of the local DB. The
  /// archive has no such row, and Dart cannot rebuild a v2 payload on its own
  /// (it would need the link-preview digest), so the loader's verdict is
  /// carried instead of re-deriving one.
  final bool? archiveSignatureValid;

  ChatMessage({
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
  ChatMessage copyWith({
    String? text,
    DateTime? timestamp,
    DateTime? editedAt,
    DateTime? hiddenAt,
    Map<String, List<String>>? reactions,
    FileAttachment? fileAttachment,
    network_api.LinkPreviewRef? linkPreview,
    /// Drop the card entirely. Needed because a null `linkPreview` reads as
    /// "leave it alone" here, and an edit that removes the URL has to be able
    /// to say "there is no card now" (issue #45).
    bool clearLinkPreview = false,
    String? signature,
    String? publicKey,
  }) {
    return ChatMessage(
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
