import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/local_nickname_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/ui/chat/message_row.dart';
import 'package:hollow/src/ui/components/hollow_badge.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_copy_field.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
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

/// What the check found. [notHere] is not a verdict on the message: the row
/// this device would check against is missing, which says nothing about the
/// sender, so it must never read as [invalid].
enum ProofStatus { checking, verified, invalid, unsigned, notHere, failed }

class _MessageProofDialogContent extends ConsumerStatefulWidget {
  final MessageProofData proof;
  const _MessageProofDialogContent({required this.proof});

  @override
  ConsumerState<_MessageProofDialogContent> createState() =>
      _MessageProofDialogContentState();
}

class _MessageProofDialogContentState
    extends ConsumerState<_MessageProofDialogContent> {
  late ProofStatus _status =
      _hasSig ? ProofStatus.checking : ProofStatus.unsigned;

  /// Why the check itself failed, for [ProofStatus.failed].
  String? _failure;

  /// The v2 verification result when the row is in the local DB; null means
  /// there is nothing exportable.
  network_api.MessageProofV2? _v2;

  /// A proof is copyable only once Rust has produced its canonical v2 payload;
  /// everything else has no payload to put in the file.
  bool get _canExport => _v2 != null;
  MessageProofData get proof => widget.proof;
  bool get _hasSig => proof.signature != null && proof.publicKey != null;

  @override
  void initState() {
    super.initState();
    _verifySignature();
  }

  Future<void> _verifySignature() async {
    if (!_hasSig) return;
    // Archive rows carry the loader's verdict: there is no local DB row, and
    // Dart must not rebuild a payload of its own.
    final pre = proof.preverified;
    if (pre != null) {
      _status = pre ? ProofStatus.verified : ProofStatus.invalid;
      return;
    }
    // Rust builds and verifies the canonical v2 payload, so the grammar stays
    // single-sourced there. NO v1 fallback: a message with no verifiable v2
    // signature reports unverified, which is the truth about it.
    final mid = proof.messageId;
    if (mid == null || mid.isEmpty) {
      _status = ProofStatus.notHere;
      return;
    }
    try {
      final r = await network_api.verifyMessageProofV2(
        msgType: proof.msgType,
        context: proof.context,
        senderPeerId: proof.senderPeerId,
        messageId: mid,
      );
      if (!mounted) return;
      setState(() {
        _v2 = r;
        _status = r.valid
            ? ProofStatus.verified
            : r.hasSignature
                ? ProofStatus.invalid
                : ProofStatus.unsigned;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.toString().toLowerCase().contains('not found')) {
          _status = ProofStatus.notHere;
        } else {
          _status = ProofStatus.failed;
          _failure = friendlyError(e,
              fallback: "Hollow couldn't check this signature. Try again.");
        }
      });
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
          friendlyError(e, fallback: "Couldn't export the proof. Try again."),
          type: HollowToastType.error,
        );
      }
    }
  }

  (String, HollowBadgeKind, String?) _statusWords() => switch (_status) {
        ProofStatus.checking => ('Checking', HollowBadgeKind.neutral, null),
        ProofStatus.verified => (
            'Verified',
            HollowBadgeKind.success,
            "Signed with the sender's key, and unchanged since it was sent.",
          ),
        ProofStatus.invalid => (
            'Invalid',
            HollowBadgeKind.error,
            "The signature doesn't match this message. It was changed after "
                'it was signed, or signed by an older version of Hollow.',
          ),
        ProofStatus.unsigned => (
            'Unsigned',
            HollowBadgeKind.neutral,
            'This message carries no signature, so there is nothing to check.',
          ),
        ProofStatus.notHere => (
            'Not on this device',
            HollowBadgeKind.neutral,
            "This message isn't saved on this device, so its signature can't "
                'be checked here. Check it on a device that has the '
                'conversation, or ask the sender for an exported proof.',
          ),
        ProofStatus.failed => ('Not checked', HollowBadgeKind.neutral, _failure),
      };

  @override
  Widget build(BuildContext context) {
    final fingerprint = proof.publicKeyFingerprint;
    final (label, kind, explanation) = _statusWords();
    final timestamp = DateTime.fromMillisecondsSinceEpoch(proof.timestampMs);
    final links = ref.watch(deviceLinkProvider);
    final me = links.identityOf(ref.watch(identityProvider).peerId ?? '');
    final signature = proof.signature;
    // A proof names who SIGNED: their own profile name, then what you call
    // them, never the nickname alone.
    final sender = links.identityOf(proof.senderPeerId);
    final ownName =
        ref.watch(profileProvider.select((p) => p[sender]?.displayName)) ?? '';
    final yourName = ref.watch(localNicknameProvider.select((n) => n[sender]));
    final senderLine = [
      if (ownName.isNotEmpty) ownName,
      if (yourName != null && yourName.isNotEmpty && yourName != ownName)
        'you call them $yourName',
    ].join(', ');

    Widget field(String label, String value, {String? copyValue}) => Padding(
          padding: const EdgeInsets.only(top: HollowSpacing.md),
          child: HollowCopyField(
            label: label,
            value: value,
            copyValue: copyValue,
          ),
        );

    return HollowDialog(
      title: 'Message proof',
      showClose: true,
      maxWidth: 520,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: HollowBadge(label, key: ValueKey(label), kind: kind),
          ),
          if (explanation != null) ...[
            const SizedBox(height: HollowSpacing.sm),
            HollowDialogText(explanation),
          ],
          const SizedBox(height: HollowSpacing.lg),
          // The one message row, read-only here: no reactions, no reply. Its
          // own inset bleeds out so the avatar sits on the dialog's text edge.
          HollowBleed(
            horizontal: MessageRow.horizontalInset,
            child: MessageRow(
              messageId: proof.messageId,
              senderId: proof.senderPeerId,
              isMe: links.identityOf(proof.senderPeerId) == me,
              text: proof.text,
              timestamp: timestamp,
              editedAt: null,
              replyToMid: null,
              reactions: const {},
              fileAttachment: proof.fileAttachment,
              linkPreview: null,
              showHeader: true,
            ),
          ),
          const SizedBox(height: HollowSpacing.xl),
          const HollowSectionHeader('Details', dense: true),
          if (senderLine.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: HollowSpacing.md),
              child: HollowCopyField(
                label: 'Sender',
                value: senderLine,
                copyValue: ownName.isNotEmpty ? ownName : yourName,
                mono: false,
              ),
            ),
          field("Sender's user ID", proof.senderPeerId),
          field('Time (UTC)', timestamp.toUtc().toIso8601String(),
              copyValue: '${timestamp.toUtc().toIso8601String()} '
                  '(${proof.timestampMs})'),
          if (proof.messageId != null) field('Message ID', proof.messageId!),
          if (fingerprint != null) field('Key fingerprint', fingerprint),
          if (signature != null && _hasSig)
            field(
              'Signature',
              signature.length > 48
                  ? '${signature.substring(0, 24)}...'
                      '${signature.substring(signature.length - 24)}'
                  : signature,
              copyValue: signature,
            ),
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
                'Proof copied',
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
