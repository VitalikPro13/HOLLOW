import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/dialogs/message_proof_dialog.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

// ── Search bar for archive viewers ──────────────────────────────

class ArchiveSearchBar extends StatefulWidget {
  final int matchCount;
  final int currentMatch;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback? onNext;
  final VoidCallback? onPrev;
  final VoidCallback onClose;

  const ArchiveSearchBar({
    required this.matchCount,
    required this.currentMatch,
    required this.onQueryChanged,
    this.onNext,
    this.onPrev,
    required this.onClose,
  });

  @override
  State<ArchiveSearchBar> createState() => ArchiveSearchBarState();
}

class ArchiveSearchBarState extends State<ArchiveSearchBar> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return Container(
      constraints: const BoxConstraints(minHeight: 40),
      padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.md, vertical: HollowSpacing.xs),
      decoration: BoxDecoration(
        color: hollow.surface,
        border: Border(bottom: BorderSide(color: hollow.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: HollowTextField(
              controller: _controller,
              focusNode: _focusNode,
              hintText: 'Search messages...',
              isDense: true,
              prefixIcon: Icon(LucideIcons.search,
                  size: 14, color: hollow.textSecondary),
              onChanged: widget.onQueryChanged,
              onSubmitted: (_) => widget.onNext?.call(),
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          // Plain (non-flex) child: a Flexible here shares the Row's free
          // space 50/50 with the Expanded field, halving the text field
          // whenever the counter appears.
          if (_controller.text.isNotEmpty)
            Text(
              widget.matchCount > 0
                  ? '${widget.currentMatch + 1} of ${widget.matchCount}'
                  : '0 results',
              maxLines: 1,
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontSize: 11,
              ),
            ),
          const SizedBox(width: HollowSpacing.xs),
          HollowPressable(
            onTap: widget.onPrev,
            semanticLabel: 'Previous match',
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            padding: const EdgeInsets.all(4),
            child: Icon(LucideIcons.chevronUp,
                size: 14,
                color: widget.onPrev != null
                    ? hollow.textPrimary
                    : hollow.textSecondary.withValues(alpha: 0.3)),
          ),
          HollowPressable(
            onTap: widget.onNext,
            semanticLabel: 'Next match',
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            padding: const EdgeInsets.all(4),
            child: Icon(LucideIcons.chevronDown,
                size: 14,
                color: widget.onNext != null
                    ? hollow.textPrimary
                    : hollow.textSecondary.withValues(alpha: 0.3)),
          ),
          const SizedBox(width: HollowSpacing.xs),
          HollowPressable(
            onTap: widget.onClose,
            semanticLabel: 'Close search',
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            padding: const EdgeInsets.all(4),
            child: Icon(LucideIcons.x,
                size: 14, color: hollow.textSecondary),
          ),
        ],
      ),
    );
  }
}

// ── Deleted message overlay ─────────────────────────────────────

class ArchiveDeletedOverlay extends StatelessWidget {
  final DateTime hiddenAt;
  final Widget child;

  const ArchiveDeletedOverlay(
      {super.key, required this.hiddenAt, required this.child});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final time =
        '${hiddenAt.hour.toString().padLeft(2, '0')}:${hiddenAt.minute.toString().padLeft(2, '0')}';

    return AnimatedOpacity(
      opacity: 0.4,
      duration: Duration.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          child,
          Padding(
            padding: const EdgeInsets.only(left: 42, top: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.trash2,
                    size: 11,
                    color: hollow.error.withValues(alpha: 0.7)),
                const SizedBox(width: 4),
                Text(
                  'Deleted at $time',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.error.withValues(alpha: 0.7),
                    fontSize: 10,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Edit history indicator ──────────────────────────────────────

/// Shows "Edited N times -> view history" below a message bubble.
/// Tapping expands a timeline of every prior version.
class EditHistoryIndicator extends StatefulWidget {
  final List<ArchiveEditEntry> edits;
  final String? senderPeerId;
  final String? proofContext;
  final String? proofMsgType;
  /// Original message signature/publicKey/timestamp — needed to verify the
  /// first edit's oldText (the original message text before any edits).
  final String? originalSignature;
  final String? originalPublicKey;
  final int? originalTimestampMs;
  final String? messageId;

  const EditHistoryIndicator({
    super.key,
    required this.edits,
    this.senderPeerId,
    this.proofContext,
    this.proofMsgType,
    this.originalSignature,
    this.originalPublicKey,
    this.originalTimestampMs,
    this.messageId,
  });

  @override
  State<EditHistoryIndicator> createState() => _EditHistoryIndicatorState();
}

class _EditHistoryIndicatorState extends State<EditHistoryIndicator> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final count = widget.edits.length;

    return Padding(
      padding: const EdgeInsets.only(left: 42, top: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HollowPressable(
            onTap: () => setState(() => _expanded = !_expanded),
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.pencil,
                    size: 11,
                    color: hollow.accent.withValues(alpha: 0.7)),
                const SizedBox(width: 4),
                Text(
                  'Edited $count ${count == 1 ? 'time' : 'times'}',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.accent.withValues(alpha: 0.7),
                    fontSize: 10,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  _expanded ? LucideIcons.chevronUp : LucideIcons.chevronRight,
                  size: 10,
                  color: hollow.accent.withValues(alpha: 0.5),
                ),
              ],
            ),
          ),
          if (_expanded) ...[
            const SizedBox(height: 4),
            for (int i = 0; i < widget.edits.length; i++) ...[
              () {
                final e = widget.edits[i];
                final time =
                    '${e.editedAt.hour.toString().padLeft(2, '0')}:${e.editedAt.minute.toString().padLeft(2, '0')}';
                final dateStr =
                    '${e.editedAt.year}-${e.editedAt.month.toString().padLeft(2, '0')}-${e.editedAt.day.toString().padLeft(2, '0')}';
                // The displayed text is e.oldText (what the message was before
                // this edit). The signature that covers e.oldText is:
                //   - For i==0: the original message signature (before any edits)
                //   - For i>0: the previous edit's signature (which signed its newText,
                //     and previous newText == current oldText)
                final String? proofSig;
                final String? proofPk;
                final int? proofTs;
                if (i == 0) {
                  proofSig = e.prevSignature ?? widget.originalSignature;
                  proofPk = e.prevPublicKey ?? widget.originalPublicKey;
                  proofTs = e.prevTimestampMs ?? widget.originalTimestampMs;
                } else {
                  final prev = widget.edits[i - 1];
                  proofSig = prev.signature;
                  proofPk = prev.publicKey;
                  proofTs = prev.editedAt.millisecondsSinceEpoch;
                }
                final hasSig = proofSig != null && proofPk != null;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Container(
                    padding: const EdgeInsets.all(HollowSpacing.sm),
                    decoration: BoxDecoration(
                      color: hollow.surface,
                      borderRadius: BorderRadius.circular(hollow.radiusSm),
                      border: Border.all(
                          color: hollow.border.withValues(alpha: 0.5)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              '$dateStr $time',
                              style: HollowTypography.caption.copyWith(
                                color: hollow.textSecondary,
                                fontSize: 10,
                              ),
                            ),
                            const SizedBox(width: 6),
                            HollowPressable(
                              onTap: hasSig && widget.senderPeerId != null
                                  ? () {
                                      final profiles =
                                          ProviderScope.containerOf(context)
                                              .read(profileProvider);
                                      showMessageProofDialog(
                                        context,
                                        MessageProofData(
                                          senderPeerId: widget.senderPeerId!,
                                          senderDisplayName: displayNameFor(
                                              profiles, widget.senderPeerId!),
                                          text: e.oldText,
                                          timestampMs: proofTs!,
                                          signature: proofSig,
                                          publicKey: proofPk,
                                          messageId: widget.messageId ?? e.messageId,
                                          context: widget.proofContext ?? '',
                                          msgType: widget.proofMsgType ?? 'ch',
                                        ),
                                      );
                                    }
                                  : null,
                              semanticLabel: 'View signature details',
                              padding: const EdgeInsets.all(2),
                              child: Icon(
                                hasSig
                                    ? LucideIcons.shieldCheck
                                    : LucideIcons.shieldOff,
                                size: 10,
                                color: hasSig
                                    ? hollow.accent.withValues(alpha: 0.6)
                                    : hollow.textSecondary.withValues(alpha: 0.4),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          e.oldText,
                          style: HollowTypography.body.copyWith(
                            color: hollow.textSecondary,
                            fontSize: 12,
                            decoration: TextDecoration.lineThrough,
                            decorationColor:
                                hollow.textSecondary.withValues(alpha: 0.4),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }(),
            ],
          ],
        ],
      ),
    );
  }
}
