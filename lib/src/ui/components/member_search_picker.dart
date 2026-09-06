import 'package:flutter/material.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/label_visuals.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Searchable member list shared by every member picker. Search matches the
/// display name, the server nickname AND the raw peer id, so a pasted id works,
/// and each row carries the short id suffix so two members sharing a name stay
/// distinguishable.
///
/// Pure UI: the caller owns the member set, the name lookup, the trailing
/// widget and the tap behaviour. No FFI or provider access in here.
class MemberSearchPicker extends StatefulWidget {
  final List<crdt_api.MemberFfi> members;

  /// Resolved display name; the nickname and profile precedence is the
  /// caller's business, and desktop and mobile resolve differently.
  final String Function(crdt_api.MemberFfi member) nameOf;

  /// Trailing widget per row (check square, chevron, …).
  final Widget Function(crdt_api.MemberFfi member) trailingOf;

  /// Row tap; null disables every row.
  final void Function(crdt_api.MemberFfi member)? onTapMember;

  /// The list hugs short content and scrolls past this height.
  final double maxListHeight;

  const MemberSearchPicker({
    super.key,
    required this.members,
    required this.nameOf,
    required this.trailingOf,
    required this.onTapMember,
    this.maxListHeight = 220,
  });

  @override
  State<MemberSearchPicker> createState() => _MemberSearchPickerState();
}

class _MemberSearchPickerState extends State<MemberSearchPicker> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool _matches(crdt_api.MemberFfi m) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return widget.nameOf(m).toLowerCase().contains(q) ||
        m.nickname.toLowerCase().contains(q) ||
        m.displayName.toLowerCase().contains(q) ||
        m.peerId.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final filtered = widget.members.where(_matches).toList();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HollowTextField(
          controller: _searchController,
          hintText: 'Search members',
          isDense: true,
          prefixIcon:
              Icon(LucideIcons.search, size: 16, color: hollow.textSecondary),
          onChanged: (v) => setState(() => _query = v),
        ),
        const SizedBox(height: HollowSpacing.sm),
        if (filtered.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: HollowSpacing.lg),
            child: Center(
              child: Text(
                'No members match',
                style: HollowTypography.bodySmall.copyWith(
                  color: hollow.textSecondary,
                ),
              ),
            ),
          )
        else
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: widget.maxListHeight),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: filtered.length,
              itemBuilder: (_, i) {
                final m = filtered[i];
                final name = widget.nameOf(m);
                return HollowPressable(
                  onTap: widget.onTapMember == null
                      ? null
                      : () => widget.onTapMember!(m),
                  // List rows, not buttons: the row's own text names it and
                  // trailing icons carry any state label.
                  semanticButton: false,
                  subtle: true,
                  // No horizontal padding, so rows stay flush with the caption
                  // and search field above them.
                  padding:
                      const EdgeInsets.symmetric(vertical: HollowSpacing.sm),
                  child: Row(
                    children: [
                      HollowAvatar(peerId: m.peerId, size: 28),
                      const SizedBox(width: HollowSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: HollowTypography.body.copyWith(
                                color: hollow.textPrimary,
                              ),
                            ),
                            Text(
                              shortPeerIdSuffix(m.peerId),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: HollowTypography.caption.copyWith(
                                color: hollow.textTertiary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: HollowSpacing.md),
                      widget.trailingOf(m),
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
