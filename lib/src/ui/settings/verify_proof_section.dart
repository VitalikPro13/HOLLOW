import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/time_labels.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Opens the proof checker as a dialog, the desktop Security page's entry.
Future<void> showVerifyProofDialog(BuildContext context) {
  return showHollowDialog<void>(
    context: context,
    builder: (ctx) => const _VerifyProofDialog(),
  );
}

/// The checker with Import and Verify in the dialog's own action row.
class _VerifyProofDialog extends StatefulWidget {
  const _VerifyProofDialog();

  @override
  State<_VerifyProofDialog> createState() => _VerifyProofDialogState();
}

class _VerifyProofDialogState extends State<_VerifyProofDialog> {
  final _section = GlobalKey<VerifyProofSectionState>();

  @override
  Widget build(BuildContext context) {
    final section = _section.currentState;
    return HollowDialog(
      title: 'Check a message proof',
      width: 560,
      showClose: true,
      content: VerifyProofSection(
        key: _section,
        showActions: false,
        onChanged: () => setState(() {}),
      ),
      leadingActions: [
        HollowButton.ghost(
          onPressed: () => _section.currentState?.importFile(),
          icon: const Icon(LucideIcons.fileUp, size: 16),
          child: const Text('Import file'),
        ),
      ],
      actions: [
        HollowButton.filled(
          onPressed: (section?.canVerify ?? false)
              ? () => _section.currentState?.verifyPasted()
              : null,
          loading: section?.verifying ?? false,
          child: const Text('Verify'),
        ),
      ],
    );
  }
}

/// Verify a proof: paste or import a proof JSON and check it with the same
/// Ed25519 verification as the Message Proof dialog. One implementation shared
/// by the desktop Security page and the mobile Settings tab.
class VerifyProofSection extends StatefulWidget {
  /// False when a dialog carries Import and Verify in its action row.
  final bool showActions;

  /// Called when the pasted text or the running check changes, so a host
  /// holding the actions can rebuild them.
  final VoidCallback? onChanged;

  const VerifyProofSection({super.key, this.showActions = true, this.onChanged});

  @override
  State<VerifyProofSection> createState() => VerifyProofSectionState();
}

class VerifyProofSectionState extends State<VerifyProofSection> {
  final _controller = TextEditingController();
  final _resultKey = GlobalKey();
  _ProofResult? _result;
  bool _verifying = false;

  bool get verifying => _verifying;
  bool get canVerify => !_verifying && _controller.text.trim().isNotEmpty;

  void _setState(VoidCallback fn) {
    setState(fn);
    widget.onChanged?.call();
  }

  void _scrollToResult() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _resultKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx,
            duration: HollowDurations.fast);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> importFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        dialogTitle: 'Import proof JSON',
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
        HollowToast.show(context, "Couldn't read that file. Pick a proof .json.",
            type: HollowToastType.error);
      }
    }
  }

  Future<void> _verify(String jsonStr) async {
    _setState(() {
      _verifying = true;
      _result = null;
    });

    void fail(String error) {
      _setState(() {
        _verifying = false;
        _result = _ProofResult(valid: false, error: error);
      });
      _scrollToResult();
    }

    try {
      final map = json.decode(jsonStr) as Map<String, dynamic>;

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

      // Reconstruct the canonical payload from the individual fields and check
      // it against the embedded one, which catches field tampering such as new
      // text kept against an old canonical_payload. The grammar mirrors Rust's
      // `message_signing_payload_v2`, the one place it is dual-defined.
      //
      // v1 proofs are refused in `_envelopeError`: their payload covers the
      // text ONLY, so a v1 proof with a rewritten reply_to, file_id, order_us
      // or link preview would reconstruct cleanly and verify.
      final replyTo = message['reply_to'] as String? ?? '';
      final fileId = message['file_id'] as String? ?? '';
      final orderUs = message['order_us']?.toString() ?? '';
      final lpDigest = message['link_preview_digest'] as String? ?? '';
      // An album id is signed in its own slot (v3); a colon in it would let
      // the text boundary move, so anything but a UUID is refused.
      final album = message['album'] as String? ?? '';
      if (album.isNotEmpty && !_albumIdShape.hasMatch(album)) {
        fail('Invalid album id in the proof.');
        return;
      }
      final fields = '${_canonicalMsgType(contextType)}:$contextId:$peerId:'
          '$timestampMs:${messageId ?? ''}:$replyTo:$fileId:$orderUs:$lpDigest';
      final reconstructed = album.isEmpty
          ? 'hollow-msg2:$fields:$text'
          : 'hollow-msg3:$fields:$album:$text';
      if (reconstructed != canonicalPayload) {
        fail('The message fields do not match the signed payload, so the '
            'proof may have been tampered with.\n\n'
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
      _setState(() {
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
      fail(friendlyError(e,
          fallback: "Couldn't check this proof. Check it and try again."));
    }
  }

  /// Returns the error to show for an invalid proof envelope, or null when its
  /// fields all hold their expected values.
  static final _albumIdShape = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

  static String? _envelopeError(
    Map<String, dynamic> map,
    Map<String, dynamic>? message,
    Map<String, dynamic>? sender,
    Map<String, dynamic>? sig,
  ) {
    if (message == null || sender == null || sig == null) {
      return 'This proof is missing required fields.';
    }
    final version = map['version'];
    final protocol = map['protocol'] as String?;
    final algorithm = sig['algorithm'] as String?;
    // v1 is refused since 0.8.5: its canonical payload covered the message TEXT
    // only, so the reply target, attachment, ordering stamp and link preview
    // sat outside the signature and could be rewritten while the proof still
    // verified.
    if (version == 1) {
      return 'This is a legacy v1 proof. The v1 signature covered only the '
          'message text. The attachment, reply target, ordering and link '
          'preview were not signed, so Hollow no longer accepts it. Re-export '
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

  /// Maps a human-readable context type back to the short form the signing
  /// payload uses ('dm', 'ch', 'dm-delete', 'ch-delete').
  static String _canonicalMsgType(String contextType) {
    if (contextType == 'direct_message') return 'dm';
    if (contextType == 'channel') return 'ch';
    return contextType; // pass through delete types as-is
  }

  /// Checks what is in the field; nothing to check is a disabled Verify.
  void verifyPasted() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _verify(text);
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const HollowDialogText(
          'Paste a proof or import its .json file to check that the sender '
          'really signed the message.',
        ),
        const SizedBox(height: HollowSpacing.md),
        HollowTextField(
          controller: _controller,
          minLines: 5,
          maxLines: 5,
          hintText: 'Paste a proof here',
          style: HollowTypography.monoSmall.copyWith(color: hollow.textPrimary),
          onChanged: (_) => _setState(() {}),
        ),
        if (widget.showActions) ...[
          const SizedBox(height: HollowSpacing.md),
          Row(
            children: [
              HollowButton.ghost(
                onPressed: importFile,
                icon: const Icon(LucideIcons.fileUp, size: 16),
                child: const Text('Import file'),
              ),
              const SizedBox(width: HollowSpacing.sm),
              HollowButton.filled(
                onPressed: canVerify ? verifyPasted : null,
                loading: _verifying,
                child: const Text('Verify'),
              ),
            ],
          ),
        ],
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

  Widget _status(HollowTheme hollow, bool ok, String text) {
    final color = ok ? hollow.success : hollow.error;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(ok ? LucideIcons.shieldCheck : LucideIcons.shieldAlert,
            size: 16, color: color),
        const SizedBox(width: HollowSpacing.sm),
        Expanded(
          child: SelectableText(
            text,
            style: HollowTypography.label.copyWith(color: color),
          ),
        ),
      ],
    );
  }

  Widget _buildErrorResult(HollowTheme hollow, String error) =>
      _status(hollow, false, error);

  /// Human-readable label for the proof's context type.
  static String _contextLabelFor(String? contextType) {
    if (contextType == 'direct_message') return 'Direct message';
    if (contextType == 'channel') return 'Channel';
    return contextType ?? '';
  }

  Widget _buildVerdictResult(HollowTheme hollow, _ProofResult r) {
    final timestamp = r.timestampMs != null && r.timestampMs! > 0
        ? DateTime.fromMillisecondsSinceEpoch(r.timestampMs!)
        : null;
    final contextLabel = _contextLabelFor(r.contextType);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _status(hollow, r.valid, r.valid ? 'Verified' : 'Invalid signature'),
        const SizedBox(height: HollowSpacing.md),
        if (r.text != null && r.text!.isNotEmpty) ..._messageBlock(hollow, r),
        if (r.senderPeerId != null) ..._senderBlock(hollow, r),
        Wrap(
          spacing: HollowSpacing.md,
          children: [
            if (contextLabel.isNotEmpty)
              Text(
                contextLabel,
                style: HollowTypography.bodySmall
                    .copyWith(color: hollow.textSecondary),
              ),
            if (timestamp != null)
              Text(
                'Sent ${calendarDateLabel(timestamp)} at '
                '${timestamp.hour.toString().padLeft(2, '0')}:'
                '${timestamp.minute.toString().padLeft(2, '0')}',
                style: HollowTypography.bodySmall
                    .copyWith(color: hollow.textSecondary),
              ),
          ],
        ),
      ],
    );
  }

  List<Widget> _messageBlock(HollowTheme hollow, _ProofResult r) {
    return [
      const SettingsFieldLabel(label: 'Message'),
      const SizedBox(height: HollowSpacing.xs),
      Text(
        r.text!.length > 300 ? '${r.text!.substring(0, 300)}...' : r.text!,
        style: HollowTypography.body.copyWith(color: hollow.textPrimary),
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
      ),
      const SizedBox(height: HollowSpacing.md),
    ];
  }

  List<Widget> _senderBlock(HollowTheme hollow, _ProofResult r) {
    return [
      const SettingsFieldLabel(label: 'Sender'),
      const SizedBox(height: HollowSpacing.xs),
      SelectableText(
        r.senderPeerId!,
        style: HollowTypography.monoSmall.copyWith(color: hollow.textPrimary),
        maxLines: 1,
      ),
      const SizedBox(height: HollowSpacing.md),
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
