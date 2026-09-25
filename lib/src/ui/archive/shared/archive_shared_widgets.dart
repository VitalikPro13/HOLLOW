import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/time_labels.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/dialogs/message_proof_dialog.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Where a message's text starts, past the avatar column, so the markers under
/// a message line up with its words.
const double _kMessageTextInset = 42;

String _clock(DateTime at) =>
    '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';

class ArchiveSearchBar extends StatefulWidget {
  final int matchCount;
  final int currentMatch;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback? onNext;
  final VoidCallback? onPrev;
  final VoidCallback onClose;

  const ArchiveSearchBar({
    super.key,
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
              hintText: 'Search messages',
              isDense: true,
              prefixIcon: Icon(LucideIcons.search,
                  size: 14, color: hollow.textSecondary),
              onChanged: (q) {
                setState(() {});
                widget.onQueryChanged(q);
              },
              onSubmitted: (_) => widget.onNext?.call(),
            ),
          ),
          // Plain, non-flex: a Flexible here would share the Row's free space
          // with the Expanded field and halve the text field whenever the
          // counter appears.
          if (_controller.text.isNotEmpty) ...[
            const SizedBox(width: HollowSpacing.sm),
            Text(
              widget.matchCount > 0
                  ? '${widget.currentMatch + 1} of ${widget.matchCount}'
                  : 'No results',
              maxLines: 1,
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
          const SizedBox(width: HollowSpacing.xs),
          HollowIconButton(
            icon: LucideIcons.chevronUp,
            label: 'Previous match',
            onPressed: widget.onPrev,
          ),
          const SizedBox(width: HollowSpacing.xs),
          HollowIconButton(
            icon: LucideIcons.chevronDown,
            label: 'Next match',
            onPressed: widget.onNext,
          ),
          const SizedBox(width: HollowSpacing.xs),
          HollowIconButton(
            icon: LucideIcons.x,
            label: 'Close search',
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }
}

/// A message someone deleted, kept in the archive: faded, with when it went.
class ArchiveDeletedOverlay extends StatelessWidget {
  final DateTime hiddenAt;
  final Widget child;

  const ArchiveDeletedOverlay(
      {super.key, required this.hiddenAt, required this.child});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnimatedOpacity(
          opacity: 0.5,
          duration: Duration.zero,
          child: child,
        ),
        Padding(
          padding: const EdgeInsets.only(
              left: _kMessageTextInset, top: HollowSpacing.xxs),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.trash2, size: 14, color: hollow.error),
              const SizedBox(width: HollowSpacing.xs),
              Text(
                'Deleted at ${_clock(hiddenAt)}',
                style: HollowTypography.caption.copyWith(
                  color: hollow.error,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// "Edited 2 times" under a message, opening to every earlier version with its
/// signature.
class EditHistoryIndicator extends StatefulWidget {
  final List<ArchiveEditEntry> edits;
  final String? senderPeerId;
  final String? proofContext;
  final String? proofMsgType;
  /// Needed to verify the first edit's oldText, which is the message before any
  /// edit and is covered by the original signature.
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
      padding: const EdgeInsets.only(
          left: _kMessageTextInset, top: HollowSpacing.xxs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HollowPressable(
            onTap: () => setState(() => _expanded = !_expanded),
            semanticLabel: _expanded ? 'Hide edit history' : 'Show edit history',
            borderRadius: BorderRadius.circular(hollow.radiusXs),
            padding: const EdgeInsets.symmetric(vertical: HollowSpacing.xxs),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Edited $count ${count == 1 ? 'time' : 'times'}',
                  style: HollowTypography.caption
                      .copyWith(color: hollow.accentText),
                ),
                const SizedBox(width: HollowSpacing.xs),
                Icon(
                  _expanded ? LucideIcons.chevronUp : LucideIcons.chevronDown,
                  size: 14,
                  color: hollow.accentText,
                ),
              ],
            ),
          ),
          if (_expanded) ...[
            const SizedBox(height: HollowSpacing.xs),
            for (int i = 0; i < widget.edits.length; i++) _version(hollow, i),
          ],
        ],
      ),
    );
  }

  Widget _version(HollowTheme hollow, int i) {
    final e = widget.edits[i];
    // The row shows e.oldText, and the signature that covers it is the
    // original message's for i==0, else the previous edit's: that one signed
    // its newText, which is this row's oldText.
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
    final canVerify =
        proofSig != null && proofPk != null && widget.senderPeerId != null;

    return Padding(
      padding: const EdgeInsets.only(bottom: HollowSpacing.xs),
      child: Container(
        padding: const EdgeInsets.all(HollowSpacing.sm),
        decoration: BoxDecoration(
          color: hollow.elevated,
          borderRadius: BorderRadius.circular(hollow.radiusMd),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '${calendarDateLabel(e.editedAt)}, ${_clock(e.editedAt)}',
                  style: HollowTypography.caption
                      .copyWith(color: hollow.textTertiary),
                ),
                const Spacer(),
                HollowIconButton(
                  icon: canVerify ? LucideIcons.shieldCheck : LucideIcons.shieldOff,
                  label: canVerify
                      ? 'View signature details'
                      : 'This version was not signed',
                  size: 24,
                  onPressed: canVerify
                      ? () {
                          final profiles = ProviderScope.containerOf(context)
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
                ),
              ],
            ),
            Text(
              e.oldText,
              style: HollowTypography.bodySmall.copyWith(
                color: hollow.textSecondary,
                decoration: TextDecoration.lineThrough,
                decorationColor: hollow.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
