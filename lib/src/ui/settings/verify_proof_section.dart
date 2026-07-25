import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Verify a Proof — paste or import a proof JSON and verify it using the same
/// Ed25519 verification as the Message Proof dialog. One implementation shared
/// by the desktop Security category and the mobile Settings tab.
class VerifyProofSection extends StatefulWidget {
  const VerifyProofSection({super.key});

  @override
  State<VerifyProofSection> createState() => _VerifyProofSectionState();
}

class _VerifyProofSectionState extends State<VerifyProofSection> {
  final _controller = TextEditingController();
  final _resultKey = GlobalKey();
  _ProofResult? _result;
  bool _verifying = false;

  void _scrollToResult() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _resultKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx,
            duration: const Duration(milliseconds: 200));
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _importFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        dialogTitle: 'Import Proof JSON',
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true, // mobile pickers may not expose a filesystem path
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.single;
      final String content;
      if (file.bytes != null) {
        content = utf8.decode(file.bytes!);
      } else if (file.path != null) {
        content = await File(file.path!).readAsString();
      } else {
        return;
      }
      _controller.text = content;
      _verify(content);
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Failed to read file: $e',
            type: HollowToastType.error);
      }
    }
  }

  Future<void> _verify(String jsonStr) async {
    setState(() {
      _verifying = true;
      _result = null;
    });

    void fail(String error) {
      setState(() {
        _verifying = false;
        _result = _ProofResult(valid: false, error: error);
      });
      _scrollToResult();
    }

    try {
      final map = json.decode(jsonStr) as Map<String, dynamic>;

      // Extract fields from the proof JSON.
      final message = map['message'] as Map<String, dynamic>?;
      final sender = map['sender'] as Map<String, dynamic>?;
      final ctx = map['context'] as Map<String, dynamic>?;
      final sig = map['signature'] as Map<String, dynamic>?;

      final envelopeError = _envelopeError(map, message, sender, sig);
      if (envelopeError != null) {
        fail(envelopeError);
        return;
      }

      final text = message!['text'] as String? ?? '';
      final timestampMs = message['timestamp_ms'] as int? ?? 0;
      final messageId = message['message_id'] as String?;
      final peerId = sender!['peer_id'] as String? ?? '';
      final publicKeyB64 = sender['public_key_base64'] as String? ?? '';
      final signatureB64 = sig!['signature_base64'] as String? ?? '';
      final canonicalPayload = sig['canonical_payload'] as String? ?? '';
      final contextType = ctx?['type'] as String? ?? '';
      final contextId = ctx?['id'] as String? ?? '';

      if (peerId.isEmpty ||
          publicKeyB64.isEmpty ||
          signatureB64.isEmpty ||
          canonicalPayload.isEmpty) {
        fail('Proof is missing signature or public key data.');
        return;
      }

      // Reconstruct the canonical payload from the individual JSON fields
      // and verify it matches the embedded one. This catches field tampering
      // (e.g. changing message text while keeping the old canonical_payload).
      // The grammar mirrors Rust's `message_signing_payload_v2` (absent fields
      // serialize as empty strings) — the one place it is dual-defined.
      //
      // v1 proofs are refused outright in `_envelopeError`: their canonical
      // payload covers the text ONLY, so a v1 proof whose reply_to / file_id /
      // order_us / link preview were rewritten would reconstruct cleanly and
      // verify. Accepting one here would reintroduce finding 2.3 through the
      // manual verifier.
      final replyTo = message['reply_to'] as String? ?? '';
      final fileId = message['file_id'] as String? ?? '';
      final orderUs = message['order_us']?.toString() ?? '';
      final lpDigest = message['link_preview_digest'] as String? ?? '';
      final reconstructed =
          'hollow-msg2:${_canonicalMsgType(contextType)}:$contextId:$peerId:'
          '$timestampMs:${messageId ?? ''}:$replyTo:$fileId:$orderUs:$lpDigest:$text';
      if (reconstructed != canonicalPayload) {
        fail('Payload mismatch — the message fields do not match the '
            'canonical payload. The proof JSON may have been tampered with.\n\n'
            'Expected: $canonicalPayload\n'
            'Got: $reconstructed');
        return;
      }

      final isValid = await network_api.verifyMessageProof(
        senderPeerId: peerId,
        signatureB64: signatureB64,
        publicKeyB64: publicKeyB64,
        canonicalPayload: canonicalPayload,
      );

      if (!mounted) return;
      setState(() {
        _verifying = false;
        _result = _ProofResult(
          valid: isValid,
          text: text,
          timestampMs: timestampMs,
          messageId: messageId,
          senderPeerId: peerId,
          contextType: contextType,
          contextId: contextId,
        );
      });
      _scrollToResult();
    } on FormatException {
      if (!mounted) return;
      fail('Invalid JSON format.');
    } catch (e) {
      if (!mounted) return;
      fail('Verification failed: $e');
    }
  }

  /// Validate the proof envelope fields that must have exact expected values.
  /// Returns the error message to show, or null when the envelope is valid.
  static String? _envelopeError(
    Map<String, dynamic> map,
    Map<String, dynamic>? message,
    Map<String, dynamic>? sender,
    Map<String, dynamic>? sig,
  ) {
    if (message == null || sender == null || sig == null) {
      return 'Invalid proof format — missing required fields.';
    }
    final version = map['version'];
    final protocol = map['protocol'] as String?;
    final algorithm = sig['algorithm'] as String?;
    // v1 (hollow-proof-v1) is refused since 0.8.5. Its canonical payload
    // covered the message TEXT only, so the reply target, attachment, ordering
    // stamp and link preview sat outside the signature and could be rewritten
    // while the proof still verified. Accepting one would let a doctored proof
    // display as authentic.
    if (version == 1) {
      return 'This is a legacy v1 proof. The v1 signature covered only the '
          'message text — the attachment, reply target, ordering and link '
          'preview were not signed — so Hollow no longer accepts it. Re-export '
          'the proof from Hollow 0.8.5 or newer.';
    }
    if (version != 2) {
      return 'Unknown proof version: $version (expected 2).';
    }
    if (protocol != 'hollow-proof-v2') {
      return 'Unknown protocol: "$protocol" (expected "hollow-proof-v2").';
    }
    if (algorithm != 'Ed25519') {
      return 'Unknown algorithm: "$algorithm" (expected "Ed25519").';
    }
    return null;
  }

  /// Map the human-readable context type back to the canonical short form
  /// used in the signing payload ('dm'/'ch'/'dm-delete'/'ch-delete').
  static String _canonicalMsgType(String contextType) {
    if (contextType == 'direct_message') return 'dm';
    if (contextType == 'channel') return 'ch';
    return contextType; // pass through delete types as-is
  }

  void _onVerifyPressed() {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      HollowToast.show(context, 'Paste a proof JSON first',
          type: HollowToastType.info);
      return;
    }
    _verify(text);
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Paste a proof JSON or import a .json file to verify '
          'that a message was authentically signed by its sender.',
          style: HollowTypography.body.copyWith(
            color: hollow.textSecondary,
            fontSize: 12,
          ),
        ),
        const SizedBox(height: HollowSpacing.md),

        // Input area
        Container(
          width: double.infinity,
          height: 120,
          decoration: BoxDecoration(
            color: hollow.background,
            borderRadius: BorderRadius.circular(hollow.radiusMd),
            border: Border.all(color: hollow.border),
          ),
          child: TextField(
            controller: _controller,
            maxLines: null,
            expands: true,
            style: HollowTypography.mono.copyWith(
              color: hollow.textPrimary,
              fontSize: 11,
            ),
            decoration: InputDecoration(
              hintText: '{"version":1,"protocol":"hollow-proof-v1",...}',
              hintStyle: HollowTypography.mono.copyWith(
                color: hollow.textSecondary.withValues(alpha: 0.4),
                fontSize: 11,
              ),
              contentPadding: const EdgeInsets.all(HollowSpacing.sm),
              border: InputBorder.none,
            ),
          ),
        ),
        const SizedBox(height: HollowSpacing.md),

        // Buttons
        Row(
          children: [
            HollowButton.ghost(
              onPressed: _importFile,
              icon: const Icon(LucideIcons.fileUp, size: 16),
              child: const Text('Import File'),
            ),
            const SizedBox(width: HollowSpacing.sm),
            HollowButton.filled(
              onPressed: _verifying ? null : _onVerifyPressed,
              icon: const Icon(LucideIcons.shieldCheck, size: 16),
              child: Text(_verifying ? 'Verifying...' : 'Verify'),
            ),
          ],
        ),

        // Result
        if (_result != null) ...[
          const SizedBox(height: HollowSpacing.lg),
          KeyedSubtree(key: _resultKey, child: _buildResult(hollow)),
        ],
      ],
    );
  }

  Widget _buildResult(HollowTheme hollow) {
    final r = _result!;
    if (r.error != null) return _buildErrorResult(hollow, r.error!);
    return _buildVerdictResult(hollow, r);
  }

  Widget _buildErrorResult(HollowTheme hollow, String error) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(HollowSpacing.md),
      decoration: BoxDecoration(
        color: hollow.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(color: hollow.error.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.shieldAlert, size: 16, color: hollow.error),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Text(
              error,
              style: HollowTypography.body.copyWith(
                color: hollow.error,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Human-readable label for the proof's context type.
  static String _contextLabelFor(String? contextType) {
    if (contextType == 'direct_message') return 'Direct Message';
    if (contextType == 'channel') return 'Channel';
    return contextType ?? '';
  }

  Widget _buildVerdictResult(HollowTheme hollow, _ProofResult r) {
    final bgColor = r.valid
        ? hollow.accent.withValues(alpha: 0.08)
        : hollow.error.withValues(alpha: 0.08);
    final borderColor = r.valid
        ? hollow.accent.withValues(alpha: 0.3)
        : hollow.error.withValues(alpha: 0.3);
    final statusColor = r.valid ? hollow.accent : hollow.error;
    final statusIcon =
        r.valid ? LucideIcons.shieldCheck : LucideIcons.shieldAlert;
    final statusText = r.valid ? 'VERIFIED' : 'INVALID SIGNATURE';

    final timestamp = r.timestampMs != null && r.timestampMs! > 0
        ? DateTime.fromMillisecondsSinceEpoch(r.timestampMs!)
        : null;
    final contextLabel = _contextLabelFor(r.contextType);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(HollowSpacing.md),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Status badge
          Row(
            children: [
              Icon(statusIcon, size: 16, color: statusColor),
              const SizedBox(width: HollowSpacing.sm),
              Text(
                statusText,
                style: HollowTypography.label.copyWith(
                  color: statusColor,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: HollowSpacing.md),

          // Message text
          if (r.text != null && r.text!.isNotEmpty) ..._messageBlock(hollow, r),

          // Sender
          if (r.senderPeerId != null) ..._senderBlock(hollow, r),

          // Context + Timestamp
          Row(
            children: [
              if (contextLabel.isNotEmpty) ...[
                Text(
                  contextLabel,
                  style: HollowTypography.bodySmall
                      .copyWith(color: hollow.textSecondary),
                ),
                const SizedBox(width: HollowSpacing.md),
              ],
              if (timestamp != null)
                Text(
                  timestamp.toUtc().toIso8601String(),
                  style: HollowTypography.bodySmall
                      .copyWith(color: hollow.textSecondary),
                ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _messageBlock(HollowTheme hollow, _ProofResult r) {
    return [
      Text(
        'MESSAGE',
        style: HollowTypography.caption.copyWith(
          color: hollow.textSecondary,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
          fontSize: 10,
        ),
      ),
      const SizedBox(height: 2),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(HollowSpacing.sm),
        decoration: BoxDecoration(
          color: hollow.surface.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(hollow.radiusSm),
        ),
        child: Text(
          r.text!.length > 300 ? '${r.text!.substring(0, 300)}...' : r.text!,
          style: HollowTypography.body.copyWith(
            color: hollow.textPrimary,
            fontSize: 13,
          ),
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      const SizedBox(height: HollowSpacing.sm),
    ];
  }

  List<Widget> _senderBlock(HollowTheme hollow, _ProofResult r) {
    return [
      Text(
        'SENDER',
        style: HollowTypography.caption.copyWith(
          color: hollow.textSecondary,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
          fontSize: 10,
        ),
      ),
      const SizedBox(height: 2),
      SelectableText(
        r.senderPeerId!,
        style: HollowTypography.mono.copyWith(
          color: hollow.textPrimary,
          fontSize: 11,
        ),
        maxLines: 1,
      ),
      const SizedBox(height: HollowSpacing.sm),
    ];
  }
}

class _ProofResult {
  final bool valid;
  final String? error;
  final String? text;
  final int? timestampMs;
  final String? messageId;
  final String? senderPeerId;
  final String? contextType;
  final String? contextId;

  const _ProofResult({
    required this.valid,
    this.error,
    this.text,
    this.timestampMs,
    this.messageId,
    this.senderPeerId,
    this.contextType,
    this.contextId,
  });
}
