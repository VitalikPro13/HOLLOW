import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/attachment_image.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:hollow/src/ui/components/hollow_badge.dart';

/// Data needed to display and export a message's cryptographic proof.
class MessageProofData {
  final String senderPeerId;
  final String senderDisplayName;
  final String text;
  final int timestampMs;
  final String? signature;
  final String? publicKey;
  final String? messageId;
  final String context; // recipient peer_id for DM, "server_id:channel_id" for channel
  final String msgType; // "dm" or "ch"
  final FileAttachment? fileAttachment;

  /// A verdict computed elsewhere, for a row this dialog cannot verify itself
  /// (an imported archive, already checked by the Rust loader). Null verifies
  /// here against the local DB row.
  ///
  /// There is deliberately NO Dart-side payload reconstruction: the v1 grammar
  /// covered the text only, so rebuilding it here would show a message with a
  /// grafted file id, reply or link preview as VERIFIED. A message that cannot
  /// be v2-verified shows as unverified.
  final bool? preverified;

  const MessageProofData({
    required this.senderPeerId,
    required this.senderDisplayName,
    required this.text,
    required this.timestampMs,
    this.signature,
    this.publicKey,
    this.messageId,
    required this.context,
    required this.msgType,
    this.fileAttachment,
    this.preverified,
  });

  /// A short display fingerprint derived from the public key.
  String? get publicKeyFingerprint {
    if (publicKey == null) return null;
    try {
      final bytes = base64.decode(publicKey!);
      final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final fingerprint = hex.substring(0, 32).toUpperCase(); // design-ignore: hex fingerprint, data
      return '${fingerprint.substring(0, 4)} ${fingerprint.substring(4, 8)} '
          '${fingerprint.substring(8, 12)} ${fingerprint.substring(12, 16)} '
          '${fingerprint.substring(16, 20)} ${fingerprint.substring(20, 24)} '
          '${fingerprint.substring(24, 28)} ${fingerprint.substring(28, 32)}';
    } catch (_) {
      return null;
    }
  }

}

/// Show the message proof dialog.
void showMessageProofDialog(BuildContext context, MessageProofData proof) {
  showHollowDialog(
    context: context,
    builder: (_) => _MessageProofDialogContent(proof: proof),
  );
}

class _MessageProofDialogContent extends StatefulWidget {
  final MessageProofData proof;
  const _MessageProofDialogContent({required this.proof});

  @override
  State<_MessageProofDialogContent> createState() =>
      _MessageProofDialogContentState();
}

class _MessageProofDialogContentState
    extends State<_MessageProofDialogContent>
{
  bool? _verified;

  /// The v2 verification result when the row is in the local DB; null means
  /// there is nothing exportable.
  network_api.MessageProofV2? _v2;

  /// A proof is copyable only once Rust has produced its canonical v2 payload;
  /// everything else has no payload to put in the file.
  bool get _canExport => _v2 != null;
  MessageProofData get proof => widget.proof;

  @override
  void initState() {
    super.initState();
    _verifySignature();
  }

  Future<void> _verifySignature() async {
    if (proof.signature == null || proof.publicKey == null) return;
    // Archive rows carry the loader's verdict: there is no local DB row, and
    // Dart must not rebuild a payload of its own.
    final pre = proof.preverified;
    if (pre != null) {
      setState(() => _verified = pre);
      return;
    }
    // Rust builds and verifies the canonical v2 payload, so the grammar stays
    // single-sourced there. NO v1 fallback: a message with no verifiable v2
    // signature reports unverified, which is the truth about it.
    final mid = proof.messageId;
    if (mid == null || mid.isEmpty) {
      setState(() => _verified = false);
      return;
    }
    try {
      final r = await network_api.verifyMessageProofV2(
        msgType: proof.msgType,
        context: proof.context,
        senderPeerId: proof.senderPeerId,
        messageId: mid,
      );
      if (mounted) {
        setState(() {
          _v2 = r;
          _verified = r.valid;
        });
      }
    } catch (_) {
      // No row found, so there is nothing verifiable.
      if (mounted) setState(() => _verified = false);
    }
  }

  /// The exported proof JSON, always the v2 envelope. Only reachable behind
  /// [_canExport], so `_v2` is non-null. The v1 envelope is gone: it advertised
  /// a canonical payload covering the text only.
  String _proofJsonString() {
    final v2 = _v2!;
    final body = <String, dynamic>{
        'version': 2,
        'protocol': 'hollow-proof-v2',
        'message': {
          'text': v2.text,
          // The SIGNED timestamp, which is edited_at for an edited message.
          'timestamp_ms': v2.timestampMs,
          'message_id': proof.messageId,
          if (v2.editedAt != null) 'edited_at': v2.editedAt,
          if (v2.replyTo != null) 'reply_to': v2.replyTo,
          if (v2.fileId != null) 'file_id': v2.fileId,
          if (v2.orderUs != null) 'order_us': v2.orderUs,
          if (v2.lpDigest != null) 'link_preview_digest': v2.lpDigest,
          if (v2.albumId != null) 'album': v2.albumId,
        },
        'sender': {
          'peer_id': proof.senderPeerId,
          'public_key_base64': v2.publicKeyB64,
        },
        'context': {
          'type': proof.msgType == 'dm' ? 'direct_message' : 'channel',
          'id': proof.context,
        },
        'signature': {
          'algorithm': 'Ed25519',
          'payload_version': v2.albumId != null ? 3 : 2,
          'canonical_payload': v2.canonicalPayload,
          'signature_base64': v2.signatureB64,
        },
        'verification': {
          'instructions': [
            '1. Base64-decode the public_key to get the protobuf-wrapped Ed25519 pubkey (36 bytes: header 08 01 12 20 + 32-byte key)',
            '2. Extract the raw 32-byte Ed25519 public key (bytes 4..36)',
            '3. Base64-decode the signature to get the 64-byte Ed25519 signature',
            '4. Rebuild the payload: hollow-msg2:{type}:{context}:{sender}:{timestamp_ms}:{message_id}:{reply_to}:{file_id}:{order_us}:{link_preview_digest}:{text} (absent fields = empty string), or for a message with an album hollow-msg3:{type}:{context}:{sender}:{timestamp_ms}:{message_id}:{reply_to}:{file_id}:{order_us}:{link_preview_digest}:{album}:{text}, and check it equals canonical_payload',
            '5. Verify: Ed25519_verify(public_key, signature, canonical_payload.as_bytes())',
            '6. Derive PeerId: Identity-multihash(protobuf_pubkey) -> Base58btc -> must match sender.peer_id',
          ],
        },
    };
    return const JsonEncoder.withIndent('  ').convert(body);
  }

  Future<void> _exportProofFile(BuildContext context) async {
    final json = _proofJsonString();
    final jsonBytes = Uint8List.fromList(utf8.encode(json));
    final defaultName = 'hollow-proof-${proof.messageId ?? proof.timestampMs}.json';
    try {
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Export message proof',
        fileName: defaultName,
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: jsonBytes,
      );
      if (savePath == null) return;
      if (!Platform.isAndroid && !Platform.isIOS) {
        final path = savePath.endsWith('.json') ? savePath : '$savePath.json';
        await File(path).writeAsString(json);
      }
      if (context.mounted) {
        HollowToast.show(
          context,
          'Proof exported',
          type: HollowToastType.success,
        );
      }
    } catch (e) {
      if (context.mounted) {
        HollowToast.show(
          context,
          'Export failed: $e',
          type: HollowToastType.error,
        );
      }
    }
  }

  Widget _buildStatus(bool hasSig) {
    final verified = _verified;
    if (hasSig && verified == null) {
      return const SizedBox.shrink(key: ValueKey('pending'));
    }
    final (label, kind) = !hasSig
        ? ('Unsigned', HollowBadgeKind.neutral)
        : verified!
            ? ('Verified', HollowBadgeKind.success)
            : ('Invalid', HollowBadgeKind.error);
    return HollowBadge(label, key: ValueKey(label), kind: kind);
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final hasSig = proof.signature != null && proof.publicKey != null;
    final timestamp = DateTime.fromMillisecondsSinceEpoch(proof.timestampMs);
    final fingerprint = proof.publicKeyFingerprint;

    return HollowDialog(
      title: 'Message proof',
      showClose: true,
      maxWidth: 520,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedSwitcher(
            duration: HollowDurations.normal,
            transitionBuilder: (child, anim) =>
                FadeTransition(opacity: anim, child: child),
            child: _buildStatus(hasSig),
          ),
          const SizedBox(height: HollowSpacing.md),
          _MessagePreview(hollow: hollow, proof: proof),
          const SizedBox(height: HollowSpacing.lg),
          _InfoRow(
            hollow: hollow,
            label: 'Sender peer ID',
            value: proof.senderPeerId,
            mono: true,
            copyable: true,
          ),
          const SizedBox(height: HollowSpacing.sm),
          _InfoRow(
            hollow: hollow,
            label: 'Timestamp',
            value:
                '${timestamp.toUtc().toIso8601String()} (${proof.timestampMs})',
          ),
          if (proof.messageId != null) ...[
            const SizedBox(height: HollowSpacing.sm),
            _InfoRow(
              hollow: hollow,
              label: 'Message ID',
              value: proof.messageId!,
              mono: true,
              copyable: true,
            ),
          ],
          if (fingerprint != null) ...[
            const SizedBox(height: HollowSpacing.sm),
            _InfoRow(
              hollow: hollow,
              label: 'Public key fingerprint',
              value: fingerprint,
              mono: true,
              copyable: true,
            ),
          ],
          if (hasSig) ...[
            const SizedBox(height: HollowSpacing.sm),
            _InfoRow(
              hollow: hollow,
              label: 'Ed25519 signature',
              value: proof.signature!,
              mono: true,
              copyable: true,
              truncate: true,
            ),
          ],
        ],
      ),
      // Copy and Export need Rust's canonical v2 payload, so they key on
      // `_canExport` and not on "has a signature".
      leadingActions: [
        if (_canExport) ...[
          HollowButton.ghost(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _proofJsonString()));
              HollowToast.show(
                context,
                'Proof copied to clipboard',
                type: HollowToastType.success,
              );
            },
            icon: const Icon(LucideIcons.copy, size: 14),
            child: const Text('Copy proof'),
          ),
          HollowButton.ghost(
            onPressed: () => _exportProofFile(context),
            icon: const Icon(LucideIcons.download, size: 14),
            child: const Text('Export proof'),
          ),
        ],
      ],
    );
  }
}

/// Chat-style message preview.
class _MessagePreview extends StatelessWidget {
  final HollowTheme hollow;
  final MessageProofData proof;

  const _MessagePreview({required this.hollow, required this.proof});

  @override
  Widget build(BuildContext context) {
    final timestamp = DateTime.fromMillisecondsSinceEpoch(proof.timestampMs);
    final timeStr =
        '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}';
    final file = proof.fileAttachment;
    final hasMedia = file != null && file.diskPath != null;
    final isImage = file != null && file.isImage;
    final isVideo = file != null && file.videoThumb != null;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(HollowSpacing.md),
      decoration: BoxDecoration(
        color: hollow.elevated,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HollowAvatar(
            peerId: proof.senderPeerId,
            size: 32,
          ),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        proof.senderDisplayName,
                        style: HollowTypography.label.copyWith(
                          color: hollow.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: HollowSpacing.xs),
                    Text(
                      timeStr,
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textTertiary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                if (hasMedia && (isImage || isVideo)) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(hollow.radiusMd),
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: AttachmentImage(
                        path: file.diskPath!,
                        fit: BoxFit.cover,
                        errorWidget: Container(
                          color: hollow.elevated,
                          child: Icon(
                            isVideo ? LucideIcons.film : LucideIcons.image,
                            size: 20,
                            color: hollow.textSecondary,
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (proof.text.isNotEmpty &&
                      !proof.text.startsWith('[file:'))
                    const SizedBox(height: 4),
                ],
                if (file != null && !isImage && !isVideo) ...[
                  Row(
                    children: [
                      Icon(LucideIcons.paperclip,
                          size: 12, color: hollow.textSecondary),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          file.fileName,
                          style: HollowTypography.bodySmall
                              .copyWith(color: hollow.textSecondary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  if (proof.text.isNotEmpty &&
                      !proof.text.startsWith('[file:'))
                    const SizedBox(height: 4),
                ],
                if (proof.text.isNotEmpty && !proof.text.startsWith('[file:'))
                  Text(
                    proof.text.length > 200
                        ? '${proof.text.substring(0, 200)}...'
                        : proof.text,
                    style: HollowTypography.body
                        .copyWith(color: hollow.textPrimary),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A single info row, with an optional copy button.
class _InfoRow extends StatelessWidget {
  final HollowTheme hollow;
  final String label;
  final String value;
  final bool mono;
  final bool copyable;
  final bool truncate;

  const _InfoRow({
    required this.hollow,
    required this.label,
    required this.value,
    this.mono = false,
    this.copyable = false,
    this.truncate = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: HollowTypography.caption.copyWith(
            color: hollow.textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            Expanded(
              child: SelectableText(
                truncate && value.length > 48
                    ? '${value.substring(0, 24)}...${value.substring(value.length - 24)}'
                    : value,
                style: (mono ? HollowTypography.monoSmall : HollowTypography.bodySmall)
                    .copyWith(color: hollow.textPrimary),
                maxLines: 2,
              ),
            ),
            if (copyable)
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: value));
                    HollowToast.show(
                      context,
                      'Copied to clipboard',
                      type: HollowToastType.success,
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.only(left: HollowSpacing.xs),
                    child: Icon(
                      LucideIcons.copy,
                      size: 12,
                      color: hollow.textSecondary,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
