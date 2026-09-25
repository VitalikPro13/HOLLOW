import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_sheet.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

String _senderName(Map<String, String> names, String id) =>
    names[id] ?? (id.length > 8 ? id.substring(0, 8) : id);

/// The desktop "Filter by sender" control: a menu hanging off the button, the
/// current choice checked.
class ArchiveFilterButton extends StatelessWidget {
  final List<String> senderIds;
  final String? selectedSender;
  final Map<String, String> senderDisplayNames;
  final ValueChanged<String?>? onSenderFilterChanged;

  const ArchiveFilterButton({
    super.key,
    required this.senderIds,
    this.selectedSender,
    required this.senderDisplayNames,
    this.onSenderFilterChanged,
  });

  @override
  Widget build(BuildContext context) {
    final sorted = [...senderIds]..sort((a, b) =>
        _senderName(senderDisplayNames, a)
            .toLowerCase()
            .compareTo(_senderName(senderDisplayNames, b).toLowerCase()));
    return Builder(
      builder: (buttonContext) => HollowIconButton(
        icon: LucideIcons.filter,
        label: 'Filter by sender',
        selected: selectedSender != null,
        onPressed: () => showHollowMenu(
          context: buttonContext,
          alignEnd: true,
          anchor: overlayAnchorOf(buttonContext,
              localOffset: Offset(
                  buttonContext.size?.width ?? 0,
                  buttonContext.size?.height ?? 0)),
          builder: (_, _) => [
            HollowMenuItem(
              label: 'Everyone',
              isChecked: selectedSender == null,
              onTap: () => onSenderFilterChanged?.call(null),
            ),
            const HollowMenuDivider(),
            for (final id in sorted)
              HollowMenuItem(
                label: _senderName(senderDisplayNames, id),
                isChecked: selectedSender == id,
                onTap: () => onSenderFilterChanged?.call(id),
              ),
          ],
        ),
      ),
    );
  }
}

/// The phone's sender filter: a sheet with a search field, since a long
/// channel's senders outgrow a menu on a small screen.
void showArchiveFilterSheet(
  BuildContext context, {
  required List<String> senderIds,
  String? selectedSender,
  required Map<String, String> senderNames,
  required ValueChanged<String?> onSelected,
}) {
  showHollowSheet(
    context: context,
    scrollControlled: true,
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

  void _pick(String? id) {
    Navigator.pop(context);
    widget.onSelected(id);
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final q = _query.toLowerCase();
    final shown = widget.senderIds
        .where((id) =>
            q.isEmpty ||
            _senderName(widget.senderNames, id).toLowerCase().contains(q))
        .toList();
    final check = Icon(LucideIcons.check, size: 20, color: hollow.accentText);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const HollowSheetTitle('Show messages from'),
          Padding(
            padding: const EdgeInsets.only(
                left: HollowSpacing.lg,
                right: HollowSpacing.lg,
                bottom: HollowSpacing.sm),
            child: HollowTextField(
              hintText: 'Search people',
              isDense: true,
              prefixIcon: Icon(LucideIcons.search,
                  size: 16, color: hollow.textSecondary),
              onChanged: (val) => setState(() => _query = val),
            ),
          ),
          HollowListRow(
            title: 'Everyone',
            leading:
                Icon(LucideIcons.users, size: 20, color: hollow.textSecondary),
            trailing: widget.selectedSender == null ? check : null,
            touch: true,
            onTap: () => _pick(null),
          ),
          const HollowDivider(),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.4,
            ),
            child: shown.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(HollowSpacing.lg),
                    child: HollowEmptyState(dense: true, title: 'No matches'),
                  )
                : ListView.builder(
                    padding:
                        const EdgeInsets.symmetric(vertical: HollowSpacing.xs),
                    shrinkWrap: true,
                    itemCount: shown.length,
                    itemBuilder: (_, index) {
                      final id = shown[index];
                      return HollowListRow(
                        title: _senderName(widget.senderNames, id),
                        leading: HollowAvatar(peerId: id, size: 28),
                        trailing:
                            widget.selectedSender == id ? check : null,
                        touch: true,
                        onTap: () => _pick(id),
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
