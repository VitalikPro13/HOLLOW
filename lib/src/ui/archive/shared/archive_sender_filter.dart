import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

// ── Peer filter button (opens showDialog) — desktop ─────────────

class ArchiveFilterButton extends StatelessWidget {
  final List<String> senderIds;
  final String? selectedSender;
  final Map<String, String> senderDisplayNames;
  final Map<String, dynamic> senderAvatars;
  final ValueChanged<String?>? onSenderFilterChanged;

  const ArchiveFilterButton({
    super.key,
    required this.senderIds,
    this.selectedSender,
    required this.senderDisplayNames,
    this.senderAvatars = const {},
    this.onSenderFilterChanged,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowPressable(
      onTap: () async {
        final picked = await showDialog<String?>(
          context: context,
          barrierColor: Colors.transparent,
          builder: (ctx) => ArchiveFilterDialog(
            senderIds: senderIds,
            selectedSender: selectedSender,
            senderDisplayNames: senderDisplayNames,
            senderAvatars: senderAvatars,
          ),
        );
        if (picked != null) {
          // Use '_clear_' sentinel to mean "All participants".
          onSenderFilterChanged?.call(picked == '_clear_' ? null : picked);
        }
      },
      semanticLabel: 'Filter by sender',
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      padding: const EdgeInsets.all(6),
      child: Icon(
        LucideIcons.filter,
        size: 16,
        color: selectedSender != null
            ? hollow.accent
            : hollow.textSecondary,
      ),
    );
  }
}

class ArchiveFilterDialog extends StatefulWidget {
  final List<String> senderIds;
  final String? selectedSender;
  final Map<String, String> senderDisplayNames;
  final Map<String, dynamic> senderAvatars;

  const ArchiveFilterDialog({
    super.key,
    required this.senderIds,
    this.selectedSender,
    required this.senderDisplayNames,
    this.senderAvatars = const {},
  });

  @override
  State<ArchiveFilterDialog> createState() => _ArchiveFilterDialogState();
}

class _ArchiveFilterDialogState extends State<ArchiveFilterDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    final filtered = _query.isEmpty
        ? widget.senderIds
        : widget.senderIds.where((id) {
            final name =
                (widget.senderDisplayNames[id] ?? id).toLowerCase();
            return name.contains(_query.toLowerCase());
          }).toList();

    return Align(
      alignment: Alignment.topRight,
      child: Padding(
        padding: const EdgeInsets.only(top: 100, right: 80),
        child: Material(
          type: MaterialType.transparency,
          child: Container(
            width: 240,
            constraints: const BoxConstraints(maxHeight: 360),
            decoration: BoxDecoration(
              color: hollow.elevated,
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              border: Border.all(color: hollow.border),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(HollowSpacing.sm),
                  child: HollowTextField(
                    hintText: 'Search participants...',
                    isDense: true,
                    autofocus: true,
                    prefixIcon: Icon(LucideIcons.search,
                        size: 12, color: hollow.textSecondary),
                    onChanged: (val) => setState(() => _query = val),
                  ),
                ),
                HollowPressable(
                  onTap: () => Navigator.of(context).pop('_clear_'),
                  padding: const EdgeInsets.symmetric(
                      horizontal: HollowSpacing.md, vertical: 6),
                  child: Row(
                    children: [
                      Icon(LucideIcons.users, size: 14,
                          color: widget.selectedSender == null
                              ? hollow.accent
                              : hollow.textSecondary),
                      const SizedBox(width: HollowSpacing.sm),
                      Text(
                        'All participants',
                        style: HollowTypography.body.copyWith(
                          color: widget.selectedSender == null
                              ? hollow.accent
                              : hollow.textPrimary,
                          fontWeight: widget.selectedSender == null
                              ? FontWeight.w600
                              : FontWeight.normal,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: hollow.border),
                Flexible(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(
                        vertical: HollowSpacing.xs),
                    shrinkWrap: true,
                    itemCount: filtered.length,
                    itemBuilder: (_, index) {
                      final id = filtered[index];
                      final name =
                          widget.senderDisplayNames[id] ?? id.substring(0, 8);
                      final isActive = widget.selectedSender == id;

                      return HollowPressable(
                        onTap: () => Navigator.of(context).pop(id),
                        padding: const EdgeInsets.symmetric(
                            horizontal: HollowSpacing.md, vertical: 5),
                        child: Row(
                          children: [
                            HollowAvatar(peerId: id, size: 20),
                            const SizedBox(width: HollowSpacing.sm),
                            Expanded(
                              child: Text(
                                name,
                                style: HollowTypography.body.copyWith(
                                  color: isActive
                                      ? hollow.accent
                                      : hollow.textPrimary,
                                  fontWeight: isActive
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                  fontSize: 13,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (isActive)
                              Icon(LucideIcons.check,
                                  size: 14, color: hollow.accent),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Filter bottom sheet — mobile ───────────────────────────────

void showArchiveFilterSheet(
  BuildContext context, {
  required List<String> senderIds,
  String? selectedSender,
  required Map<String, String> senderNames,
  required ValueChanged<String?> onSelected,
}) {
  final hollow = HollowTheme.of(context);
  showModalBottomSheet(
    context: context,
    backgroundColor: hollow.surface,
    shape: RoundedRectangleBorder(
      borderRadius:
          BorderRadius.vertical(top: Radius.circular(hollow.radiusXl)),
    ),
    isScrollControlled: true,
    builder: (_) => ArchiveFilterSheet(
      senderIds: senderIds,
      selectedSender: selectedSender,
      senderNames: senderNames,
      onSelected: onSelected,
    ),
  );
}

class ArchiveFilterSheet extends StatefulWidget {
  final List<String> senderIds;
  final String? selectedSender;
  final Map<String, String> senderNames;
  final ValueChanged<String?> onSelected;

  const ArchiveFilterSheet({
    super.key,
    required this.senderIds,
    this.selectedSender,
    required this.senderNames,
    required this.onSelected,
  });

  @override
  State<ArchiveFilterSheet> createState() => _ArchiveFilterSheetState();
}

class _ArchiveFilterSheetState extends State<ArchiveFilterSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    final filtered = _query.isEmpty
        ? widget.senderIds
        : widget.senderIds.where((id) {
            final name =
                (widget.senderNames[id] ?? id).toLowerCase();
            return name.contains(_query.toLowerCase());
          }).toList();

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: HollowSpacing.sm),
            child: Container(
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: hollow.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(HollowSpacing.md),
            child: HollowTextField(
              hintText: 'Search participants...',
              isDense: true,
              autofocus: true,
              prefixIcon: Icon(LucideIcons.search,
                  size: 14, color: hollow.textSecondary),
              onChanged: (val) => setState(() => _query = val),
            ),
          ),
          HollowPressable(
            onTap: () {
              Navigator.pop(context);
              widget.onSelected(null);
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.lg, vertical: 10),
              child: Row(
                children: [
                  Icon(LucideIcons.users,
                      size: 16,
                      color: widget.selectedSender == null
                          ? hollow.accent
                          : hollow.textSecondary),
                  const SizedBox(width: HollowSpacing.sm),
                  Text(
                    'All participants',
                    style: HollowTypography.body.copyWith(
                      color: widget.selectedSender == null
                          ? hollow.accent
                          : hollow.textPrimary,
                      fontWeight: widget.selectedSender == null
                          ? FontWeight.w600
                          : FontWeight.normal,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Divider(height: 1, color: hollow.border),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.4,
            ),
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(
                  vertical: HollowSpacing.xs),
              itemCount: filtered.length,
              itemBuilder: (_, index) {
                final id = filtered[index];
                final name = widget.senderNames[id] ??
                    id.substring(0, 8);
                final isActive = widget.selectedSender == id;

                return HollowPressable(
                  onTap: () {
                    Navigator.pop(context);
                    widget.onSelected(id);
                  },
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: HollowSpacing.lg,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        HollowAvatar(peerId: id, size: 24),
                        const SizedBox(width: HollowSpacing.sm),
                        Expanded(
                          child: Text(
                            name,
                            style: HollowTypography.body.copyWith(
                              color: isActive
                                  ? hollow.accent
                                  : hollow.textPrimary,
                              fontWeight: isActive
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                              fontSize: 14,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isActive)
                          Icon(LucideIcons.check,
                              size: 16, color: hollow.accent),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: HollowSpacing.sm),
        ],
      ),
    );
  }
}
