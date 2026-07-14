import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

// ── Shared searchable participant list ──────────────────────────

/// Size preset — desktop dialog vs mobile bottom sheet keep their exact
/// pre-dedup dimensions.
class _FilterListStyle {
  final EdgeInsets searchPadding;
  final double searchIconSize;
  final EdgeInsets allRowPadding;
  final double allIconSize;
  final EdgeInsets rowPadding;
  final double avatarSize;
  final double checkIconSize;
  final double fontSize;

  const _FilterListStyle({
    required this.searchPadding,
    required this.searchIconSize,
    required this.allRowPadding,
    required this.allIconSize,
    required this.rowPadding,
    required this.avatarSize,
    required this.checkIconSize,
    required this.fontSize,
  });
}

const _desktopStyle = _FilterListStyle(
  searchPadding: EdgeInsets.all(HollowSpacing.sm),
  searchIconSize: 12,
  allRowPadding:
      EdgeInsets.symmetric(horizontal: HollowSpacing.md, vertical: 6),
  allIconSize: 14,
  rowPadding: EdgeInsets.symmetric(horizontal: HollowSpacing.md, vertical: 5),
  avatarSize: 20,
  checkIconSize: 14,
  fontSize: 13,
);

const _mobileStyle = _FilterListStyle(
  searchPadding: EdgeInsets.all(HollowSpacing.md),
  searchIconSize: 14,
  allRowPadding:
      EdgeInsets.symmetric(horizontal: HollowSpacing.lg, vertical: 10),
  allIconSize: 16,
  rowPadding: EdgeInsets.symmetric(horizontal: HollowSpacing.lg, vertical: 8),
  avatarSize: 24,
  checkIconSize: 16,
  fontSize: 14,
);

/// Search field + "All participants" row + sender rows. [onPick] receives
/// null for "All participants". [wrapList] bounds the ListView (dialog:
/// Flexible within the 360px container; sheet: 40%-screen ConstrainedBox).
class _SenderFilterList extends StatefulWidget {
  final List<String> senderIds;
  final String? selectedSender;
  final Map<String, String> senderNames;
  final _FilterListStyle style;
  final void Function(String? id) onPick;
  final Widget Function(Widget list) wrapList;

  const _SenderFilterList({
    required this.senderIds,
    required this.selectedSender,
    required this.senderNames,
    required this.style,
    required this.onPick,
    required this.wrapList,
  });

  @override
  State<_SenderFilterList> createState() => _SenderFilterListState();
}

class _SenderFilterListState extends State<_SenderFilterList> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final style = widget.style;

    final filtered = _query.isEmpty
        ? widget.senderIds
        : widget.senderIds.where((id) {
            final name = (widget.senderNames[id] ?? id).toLowerCase();
            return name.contains(_query.toLowerCase());
          }).toList();

    final allActive = widget.selectedSender == null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: style.searchPadding,
          child: HollowTextField(
            hintText: 'Search participants...',
            isDense: true,
            autofocus: true,
            prefixIcon: Icon(LucideIcons.search,
                size: style.searchIconSize, color: hollow.textSecondary),
            onChanged: (val) => setState(() => _query = val),
          ),
        ),
        HollowPressable(
          onTap: () => widget.onPick(null),
          padding: style.allRowPadding,
          child: Row(
            children: [
              Icon(LucideIcons.users,
                  size: style.allIconSize,
                  color: allActive ? hollow.accent : hollow.textSecondary),
              const SizedBox(width: HollowSpacing.sm),
              Text(
                'All participants',
                style: HollowTypography.body.copyWith(
                  color: allActive ? hollow.accent : hollow.textPrimary,
                  fontWeight:
                      allActive ? FontWeight.w600 : FontWeight.normal,
                  fontSize: style.fontSize,
                ),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: hollow.border),
        widget.wrapList(
          ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: HollowSpacing.xs),
            shrinkWrap: true,
            itemCount: filtered.length,
            itemBuilder: (_, index) {
              final id = filtered[index];
              final name = widget.senderNames[id] ?? id.substring(0, 8);
              final isActive = widget.selectedSender == id;

              return HollowPressable(
                onTap: () => widget.onPick(id),
                padding: style.rowPadding,
                child: Row(
                  children: [
                    HollowAvatar(peerId: id, size: style.avatarSize),
                    const SizedBox(width: HollowSpacing.sm),
                    Expanded(
                      child: Text(
                        name,
                        style: HollowTypography.body.copyWith(
                          color:
                              isActive ? hollow.accent : hollow.textPrimary,
                          fontWeight: isActive
                              ? FontWeight.w600
                              : FontWeight.normal,
                          fontSize: style.fontSize,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isActive)
                      Icon(LucideIcons.check,
                          size: style.checkIconSize, color: hollow.accent),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

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

class ArchiveFilterDialog extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

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
            child: _SenderFilterList(
              senderIds: senderIds,
              selectedSender: selectedSender,
              senderNames: senderDisplayNames,
              style: _desktopStyle,
              onPick: (id) => Navigator.of(context).pop(id ?? '_clear_'),
              wrapList: (list) => Flexible(child: list),
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

class ArchiveFilterSheet extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

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
          _SenderFilterList(
            senderIds: senderIds,
            selectedSender: selectedSender,
            senderNames: senderNames,
            style: _mobileStyle,
            onPick: (id) {
              Navigator.pop(context);
              onSelected(id);
            },
            wrapList: (list) => ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.4,
              ),
              child: list,
            ),
          ),
          const SizedBox(height: HollowSpacing.sm),
        ],
      ),
    );
  }
}
