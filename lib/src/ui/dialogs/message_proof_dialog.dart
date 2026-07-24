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
import 'package:lucide_icons_flutter/lucide_icons.dart';

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
    extends State<_MessageProofDialogContent>
    with SingleTickerProviderStateMixin {
  bool? _verified;

  /// Versioned verification result (v2 → v1 fallback), when the message has a
  /// message_id to load the row by. Null = legacy payload-string verification.
  network_api.MessageProofV2? _v2;
  late final AnimationController _staggerController;
  late final List<Animation<double>> _fadeAnims;
  late final List<Animation<Offset>> _slideAnims;

  MessageProofData get proof => widget.proof;

  static const _itemCount = 7;

  @override
  void initState() {
    super.initState();
    _staggerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
      reverseDuration: const Duration(milliseconds: 200),
    );

    _fadeAnims = List.generate(_itemCount, (i) {
      final start = (i * 0.1).clamp(0.0, 0.7);
      final end = (start + 0.4).clamp(0.0, 1.0);
      return CurvedAnimation(
        parent: _staggerController,
        curve: Interval(start, end, curve: Curves.easeOut),
      );
    });

    _slideAnims = List.generate(_itemCount, (i) {
      final start = (i * 0.1).clamp(0.0, 0.7);
      final end = (start + 0.4).clamp(0.0, 1.0);
      return Tween<Offset>(
        begin: const Offset(0, 0.08),
        end: Offset.zero,
      ).animate(CurvedAnimation(
        parent: _staggerController,
        curve: Interval(start, end, curve: Curves.easeOutCubic),
      ));
    });

    _staggerController.forward();
    _verifySignature();
  }

  @override
  void dispose() {
    _staggerController.dispose();
    super.dispose();
  }

  Future<void> _closeDialog() async {
    await _staggerController.reverse();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _verifySignature() async {
    if (proof.signature == null || proof.publicKey == null) return;
    // Versioned path (0.8.3): Rust loads the row by message_id, builds the
    // canonical payload (v2 binds mid/reply_to/file_id/order_us/link-preview
    // digest) and verifies-both — the grammar stays single-sourced in Rust.
    final mid = proof.messageId;
    if (mid != null && mid.isNotEmpty) {
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
        return;
      } catch (_) {
        // Row not found (e.g. legacy list entry) — fall through to the
        // payload-string path below.
      }
    }
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

  /// Exported proof JSON. A v2-verified message exports the v2 envelope (its
  /// signature covers the structured fields); everything else keeps the exact
  /// legacy v1 format so existing external verifiers stay compatible.
  String _proofJsonString() {
    final v2 = _v2;
    final Map<String, dynamic> body;
    if (v2 != null && v2.sigVersion == 2) {
      body = {
        'version': 2,
        'protocol': 'hollow-proof-v2',
        'message': {
          'text': v2.text,
          // The SIGNED timestamp: edited_at for an edited message.
          'timestamp_ms': v2.timestampMs,
          'message_id': proof.messageId,
          if (v2.editedAt != null) 'edited_at': v2.editedAt,
          if (v2.replyTo != null) 'reply_to': v2.replyTo,
          if (v2.fileId != null) 'file_id': v2.fileId,
          if (v2.orderUs != null) 'order_us': v2.orderUs,
          if (v2.lpDigest != null) 'link_preview_digest': v2.lpDigest,
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
          'payload_version': 2,
          'canonical_payload': v2.canonicalPayload,
          'signature_base64': v2.signatureB64,
        },
        'verification': {
          'instructions': [
            '1. Base64-decode the public_key to get the protobuf-wrapped Ed25519 pubkey (36 bytes: header 08 01 12 20 + 32-byte key)',
            '2. Extract the raw 32-byte Ed25519 public key (bytes 4..36)',
            '3. Base64-decode the signature to get the 64-byte Ed25519 signature',
            '4. Rebuild the payload: hollow-msg2:{type}:{context}:{sender}:{timestamp_ms}:{message_id}:{reply_to}:{file_id}:{order_us}:{link_preview_digest}:{text} (absent fields = empty string) and check it equals canonical_payload',
            '5. Verify: Ed25519_verify(public_key, signature, canonical_payload.as_bytes())',
            '6. Derive PeerId: Identity-multihash(protobuf_pubkey) -> Base58btc -> must match sender.peer_id',
          ],
        },
      };
    } else {
      body = proof.toProofJson();
    }
    return const JsonEncoder.withIndent('  ').convert(body);
  }

  Future<void> _exportProofFile(BuildContext context) async {
    final json = _proofJsonString();
    final jsonBytes = Uint8List.fromList(utf8.encode(json));
    final defaultName = 'hollow-proof-${proof.messageId ?? proof.timestampMs}.json';
    try {
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Export Message Proof',
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

  Widget _stagger(int index, {required Widget child}) {
    final i = index.clamp(0, _itemCount - 1);
    return SlideTransition(
      position: _slideAnims[i],
      child: FadeTransition(
        opacity: _fadeAnims[i],
        child: child,
      ),
    );
  }

  Widget _buildBadge(HollowTheme hollow, bool hasSig) {
    final String label;
    final Color color;
    if (!hasSig) {
      label = 'UNSIGNED';
      color = hollow.textSecondary;
    } else if (_verified == null) {
      return const SizedBox.shrink(key: ValueKey('pending'));
    } else if (_verified!) {
      label = 'VERIFIED';
      color = hollow.accent;
    } else {
      label = 'INVALID';
      color = hollow.error;
    }
    return Container(
      key: ValueKey(label),
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
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isCompact = screenWidth < 600;
    final outerPadding = isCompact ? HollowSpacing.md : HollowSpacing.xl;
    final minWidth = isCompact
        ? (screenWidth - outerPadding * 2).clamp(0.0, 520.0)
        : 300.0;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closeDialog();
      },
      child: Center(
      child: Padding(
        padding: EdgeInsets.all(outerPadding),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 520, minWidth: minWidth),
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: EdgeInsets.all(
                  isCompact ? HollowSpacing.lg : HollowSpacing.xl),
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
                  _stagger(0, child: Row(
                    children: [
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: child),
                        child: Icon(
                          hasSig
                              ? (_verified == true
                                  ? LucideIcons.shieldCheck
                                  : _verified == false
                                      ? LucideIcons.shieldAlert
                                      : LucideIcons.shield)
                              : LucideIcons.shieldOff,
                          key: ValueKey(_verified),
                          size: 18,
                          color: !hasSig
                              ? hollow.textSecondary
                              : _verified == true
                                  ? hollow.accent
                                  : _verified == false
                                      ? hollow.error
                                      : hollow.textSecondary,
                        ),
                      ),
                      const SizedBox(width: HollowSpacing.sm),
                      Text(
                        'Message Proof',
                        style: HollowTypography.heading
                            .copyWith(color: hollow.textPrimary),
                      ),
                      const Spacer(),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
                        child: _buildBadge(hollow, hasSig),
                      ),
                    ],
                  )),
                  const SizedBox(height: HollowSpacing.lg),

                  // Preview + info rows scroll when the screen is short.
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Message preview
                          _stagger(1,
                              child: _MessagePreview(
                                  hollow: hollow, proof: proof)),
                          const SizedBox(height: HollowSpacing.lg),

                          // Info rows
                          _stagger(2, child: _InfoRow(
                            hollow: hollow,
                            label: 'Sender Peer ID',
                            value: proof.senderPeerId,
                            mono: true,
                            copyable: true,
                          )),
                          const SizedBox(height: HollowSpacing.sm),
                          _stagger(3, child: _InfoRow(
                            hollow: hollow,
                            label: 'Timestamp',
                            value:
                                '${timestamp.toUtc().toIso8601String()} (${proof.timestampMs})',
                          )),
                          if (proof.messageId != null) ...[
                            const SizedBox(height: HollowSpacing.sm),
                            _stagger(4, child: _InfoRow(
                              hollow: hollow,
                              label: 'Message ID',
                              value: proof.messageId!,
                              mono: true,
                              copyable: true,
                            )),
                          ],
                          if (fingerprint != null) ...[
                            const SizedBox(height: HollowSpacing.sm),
                            _stagger(5, child: _InfoRow(
                              hollow: hollow,
                              label: 'Public Key Fingerprint',
                              value: fingerprint,
                              mono: true,
                              copyable: true,
                            )),
                          ],
                          if (hasSig) ...[
                            const SizedBox(height: HollowSpacing.sm),
                            _stagger(5, child: _InfoRow(
                              hollow: hollow,
                              label: 'Ed25519 Signature',
                              value: proof.signature!,
                              mono: true,
                              copyable: true,
                              truncate: true,
                            )),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: HollowSpacing.xl),

                  // Actions — stacked full-width on phones, row on desktop.
                  _stagger(6, child: isCompact
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (hasSig) ...[
                              Row(
                                children: [
                                  Expanded(
                                    child: HollowButton.ghost(
                                      onPressed: () {
                                        Clipboard.setData(ClipboardData(
                                            text: _proofJsonString()));
                                        HollowToast.show(
                                          context,
                                          'Proof copied to clipboard',
                                          type: HollowToastType.success,
                                        );
                                      },
                                      expand: true,
                                      icon: const Icon(LucideIcons.copy,
                                          size: 14),
                                      child: const Text('Copy'),
                                    ),
                                  ),
                                  const SizedBox(width: HollowSpacing.sm),
                                  Expanded(
                                    child: HollowButton.ghost(
                                      onPressed: () =>
                                          _exportProofFile(context),
                                      expand: true,
                                      icon: const Icon(LucideIcons.download,
                                          size: 14),
                                      child: const Text('Export'),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: HollowSpacing.sm),
                            ],
                            HollowButton.filled(
                              onPressed: _closeDialog,
                              expand: true,
                              child: const Text('Close'),
                            ),
                          ],
                        )
                      : Row(
                          children: [
                            if (hasSig)
                              HollowButton.ghost(
                                onPressed: () {
                                  Clipboard.setData(ClipboardData(
                                      text: _proofJsonString()));
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
                                icon: const Icon(LucideIcons.download,
                                    size: 14),
                                child: const Text('Export Proof'),
                              ),
                              const SizedBox(width: HollowSpacing.sm),
                            ],
                            HollowButton.filled(
                              onPressed: _closeDialog,
                              child: const Text('Close'),
                            ),
                          ],
                        )),
                ],
              ),
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
