import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:lucide_icons/lucide_icons.dart';

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
  });

  /// Reconstruct the canonical signing payload (must match Rust's
  /// `message_signing_payload` in swarm.rs).
  String get canonicalPayload =>
      'hollow-msg:$msgType:$context:$senderPeerId:$timestampMs:$text';

  /// Derive a short fingerprint from the public key for display.
  String? get publicKeyFingerprint {
    if (publicKey == null) return null;
    try {
      final bytes = base64.decode(publicKey!);
      final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      // Show as groups of 4 chars separated by spaces for readability.
      final fingerprint = hex.substring(0, 32).toUpperCase();
      return '${fingerprint.substring(0, 4)} ${fingerprint.substring(4, 8)} '
          '${fingerprint.substring(8, 12)} ${fingerprint.substring(12, 16)} '
          '${fingerprint.substring(16, 20)} ${fingerprint.substring(20, 24)} '
          '${fingerprint.substring(24, 28)} ${fingerprint.substring(28, 32)}';
    } catch (_) {
      return null;
    }
  }

  /// Export as a standalone JSON proof that can be verified externally.
  Map<String, dynamic> toProofJson() => {
        'version': 1,
        'protocol': 'hollow-proof-v1',
        'message': {
          'text': text,
          'timestamp_ms': timestampMs,
          'message_id': messageId,
        },
        'sender': {
          'peer_id': senderPeerId,
          'public_key_base64': publicKey,
        },
        'context': {
          'type': msgType == 'dm' ? 'direct_message' : 'channel',
          'id': context,
        },
        'signature': {
          'algorithm': 'Ed25519',
          'canonical_payload': canonicalPayload,
          'signature_base64': signature,
        },
        'verification': {
          'instructions': [
            '1. Base64-decode the public_key to get the protobuf-wrapped Ed25519 pubkey (36 bytes: header 08 01 12 20 + 32-byte key)',
            '2. Extract the raw 32-byte Ed25519 public key (bytes 4..36)',
            '3. Base64-decode the signature to get the 64-byte Ed25519 signature',
            '4. Verify: Ed25519_verify(public_key, signature, canonical_payload.as_bytes())',
            '5. Derive PeerId: Identity-multihash(protobuf_pubkey) -> Base58btc -> must match sender.peer_id',
          ],
        },
      };
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

/// Verification state: null = pending, true = valid, false = invalid.
class _MessageProofDialogContentState
    extends State<_MessageProofDialogContent> {
  bool? _verified;

  MessageProofData get proof => widget.proof;

  @override
  void initState() {
    super.initState();
    _verifySignature();
  }

  Future<void> _verifySignature() async {
    if (proof.signature == null || proof.publicKey == null) return;
    try {
      final result = await network_api.verifyMessageProof(
        senderPeerId: proof.senderPeerId,
        signatureB64: proof.signature!,
        publicKeyB64: proof.publicKey!,
        canonicalPayload: proof.canonicalPayload,
      );
      if (mounted) setState(() => _verified = result);
    } catch (_) {
      if (mounted) setState(() => _verified = false);
    }
  }

  String _proofJsonString() =>
      const JsonEncoder.withIndent('  ').convert(proof.toProofJson());

  Future<void> _exportProofFile(BuildContext context) async {
    final json = _proofJsonString();
    final defaultName = 'hollow-proof-${proof.messageId ?? proof.timestampMs}.json';
    try {
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Export Message Proof',
        fileName: defaultName,
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (savePath == null) return;
      final path = savePath.endsWith('.json') ? savePath : '$savePath.json';
      await File(path).writeAsString(json);
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

  Widget _buildBadge(HollowTheme hollow, bool hasSig) {
    final String label;
    final Color color;
    if (!hasSig) {
      label = 'UNSIGNED';
      color = hollow.textSecondary;
    } else if (_verified == null) {
      label = 'VERIFYING...';
      color = hollow.textSecondary;
    } else if (_verified!) {
      label = 'VERIFIED';
      color = hollow.accent;
    } else {
      label = 'INVALID';
      color = hollow.error;
    }
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(hollow.radiusSm),
      ),
      child: Text(
        label,
        style: HollowTypography.caption.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final hasSig = proof.signature != null && proof.publicKey != null;
    final timestamp = DateTime.fromMillisecondsSinceEpoch(proof.timestampMs);
    final fingerprint = proof.publicKeyFingerprint;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HollowSpacing.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, minWidth: 300),
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.all(HollowSpacing.xl),
              decoration: BoxDecoration(
                color: hollow.elevated.withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(hollow.radiusLg),
                border: Border.all(
                  color: hollow.accent.withValues(alpha: 0.15),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 24,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header
                  Row(
                    children: [
                      Icon(
                        hasSig
                            ? (_verified == true
                                ? LucideIcons.shieldCheck
                                : _verified == false
                                    ? LucideIcons.shieldAlert
                                    : LucideIcons.shield)
                            : LucideIcons.shieldOff,
                        size: 18,
                        color: !hasSig
                            ? hollow.textSecondary
                            : _verified == true
                                ? hollow.accent
                                : _verified == false
                                    ? hollow.error
                                    : hollow.textSecondary,
                      ),
                      const SizedBox(width: HollowSpacing.sm),
                      Text(
                        'Message Proof',
                        style: HollowTypography.heading
                            .copyWith(color: hollow.textPrimary),
                      ),
                      const Spacer(),
                      _buildBadge(hollow, hasSig),
                    ],
                  ),
                  const SizedBox(height: HollowSpacing.lg),

                  // Message preview — mimics chat bubble style
                  _MessagePreview(hollow: hollow, proof: proof),
                  const SizedBox(height: HollowSpacing.lg),

                  // Info rows
                  _InfoRow(
                    hollow: hollow,
                    label: 'Sender Peer ID',
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
                      label: 'Public Key Fingerprint',
                      value: fingerprint,
                      mono: true,
                      copyable: true,
                    ),
                  ],
                  if (hasSig) ...[
                    const SizedBox(height: HollowSpacing.sm),
                    _InfoRow(
                      hollow: hollow,
                      label: 'Ed25519 Signature',
                      value: proof.signature!,
                      mono: true,
                      copyable: true,
                      truncate: true,
                    ),
                  ],
                  const SizedBox(height: HollowSpacing.xl),

                  // Actions
                  Row(
                    children: [
                      if (hasSig)
                        HollowButton.ghost(
                          onPressed: () {
                            Clipboard.setData(
                                ClipboardData(text: _proofJsonString()));
                            HollowToast.show(
                              context,
                              'Proof copied to clipboard',
                              type: HollowToastType.success,
                            );
                          },
                          icon: const Icon(LucideIcons.copy, size: 14),
                          child: const Text('Copy Proof'),
                        ),
                      const Spacer(),
                      if (hasSig) ...[
                        HollowButton.ghost(
                          onPressed: () => _exportProofFile(context),
                          icon: const Icon(LucideIcons.download, size: 14),
                          child: const Text('Export Proof'),
                        ),
                        const SizedBox(width: HollowSpacing.sm),
                      ],
                      HollowButton.filled(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Chat-style message preview with avatar, name, timestamp, and content.
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
        color: hollow.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(color: hollow.border.withValues(alpha: 0.5)),
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
                // Name + time
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
                        color: hollow.textSecondary.withValues(alpha: 0.6),
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                // Media thumbnail (if image or video)
                if (hasMedia && (isImage || isVideo)) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(hollow.radiusSm),
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: Image.file(
                        File(file.diskPath!),
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          color: hollow.surface,
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
                // File indicator (non-image files)
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
                // Text content
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

/// A single info row with label, value, and optional copy button.
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
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
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
                style: (mono ? HollowTypography.mono : HollowTypography.body)
                    .copyWith(
                  color: hollow.textPrimary,
                  fontSize: 12,
                ),
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
