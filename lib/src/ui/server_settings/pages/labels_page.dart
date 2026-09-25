import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_settings_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_text_link.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/label_visuals.dart';
import 'package:hollow/src/ui/components/member_search_picker.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The server's labels, for staff to make and hand out. Wearing a label is on
/// the You group's Profile page.
class LabelsPage extends ConsumerWidget {
  final String serverId;
  const LabelsPage({super.key, required this.serverId});

  /// "Access · opens #patreon-lounge · 3 members".
  String _subtitle(crdt_api.LabelFfi label, Map<String, ChannelInfo> channels,
      List<crdt_api.MemberFfi> members) {
    final count = members
        .where((m) => m.labels.any((l) => l.labelId == label.labelId))
        .length;
    final people = '$count ${count == 1 ? 'member' : 'members'}';
    if (!label.access) return 'Cosmetic · $people';
    final opens = [
      for (final ch in channels.values)
        if (ch.visibilityLabels.contains(label.labelId)) '#${ch.name}',
    ];
    final where = switch (opens.length) {
      0 => 'no channels yet',
      1 => 'opens ${opens.first}',
      _ => 'opens ${opens.length} channels',
    };
    return 'Access · $where · $people';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final labelsAsync = ref.watch(serverLabelsProvider(serverId));
    final overlay = ref.watch(labelWritesProvider(serverId));
    // The stored list caught up with a write: drop it from the overlay.
    ref.listen(serverLabelsProvider(serverId), (_, next) {
      final stored = next.valueOrNull;
      if (stored != null) {
        ref.read(labelWritesProvider(serverId).notifier).prune(stored);
      }
    });
    final members =
        ref.watch(serverMembersProvider(serverId)).valueOrNull ?? const [];
    final channels = ref.watch(channelListProvider);
    final stored = labelsAsync.valueOrNull;
    final labels = stored == null ? null : overlay.over(stored);

    return SettingsPage(
      title: 'Labels',
      intro: 'An access label opens restricted channels, and only staff hand '
          'it out. Anyone can wear the others.',
      children: [
        SettingsSection(
          title: 'Labels',
          count: labels == null ? null : '${labels.length}',
          action: HollowButton.ghost(
            compact: true,
            icon: const Icon(LucideIcons.plus),
            onPressed: () => showLabelEditDialog(context, serverId: serverId),
            child: const Text('New label'),
          ),
          children: [
            if (labels == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: HollowSpacing.lg),
                child: Center(child: HollowSpinner.medium()),
              )
            else if (labels.isEmpty)
              const HollowEmptyState(
                dense: true,
                title: 'No labels yet',
                description: 'New label makes the first one.',
              )
            else
              for (final label in labels)
                SettingsRow(
                  key: ValueKey(label.labelId),
                  title: label.name,
                  subtitle: LabelWrites.isPending(label)
                      ? 'Saving…'
                      : _subtitle(label, channels, members),
                  leading: LabelDot(color: parseLabelColor(label.color)),
                  trailing: LabelWrites.isPending(label)
                      ? null
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            HollowButton.ghost(
                              compact: true,
                              semanticLabel: 'Give ${label.name} to members',
                              onPressed: () => showLabelAssignDialog(context,
                                  serverId: serverId, label: label),
                              child: const Text('Give to members'),
                            ),
                            const SizedBox(width: HollowSpacing.xs),
                            Builder(
                              builder: (buttonContext) => HollowIconButton(
                                icon: LucideIcons.moreHorizontal,
                                label: 'More for ${label.name}',
                                onPressed: () => showHollowMenu(
                                  context: buttonContext,
                                  alignEnd: true,
                                  anchor: overlayAnchorOf(buttonContext,
                                      localOffset: Offset(
                                          buttonContext.size?.width ?? 0,
                                          buttonContext.size?.height ?? 0)),
                                  builder: (_, _) => [
                                    HollowMenuItem(
                                      icon: LucideIcons.pencil,
                                      label: 'Edit',
                                      onTap: () => showLabelEditDialog(context,
                                          serverId: serverId, existing: label),
                                    ),
                                    HollowMenuItem(
                                      icon: LucideIcons.trash2,
                                      label: 'Delete',
                                      isDanger: true,
                                      onTap: () =>
                                          _delete(context, ref, label),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
          ],
        ),
        Text.rich(
          TextSpan(
            style: HollowTypography.bodySmall
                .copyWith(color: hollow.textSecondary),
            children: [
              const TextSpan(text: 'Wearing labels yourself lives in '),
              WidgetSpan(
                alignment: PlaceholderAlignment.baseline,
                baseline: TextBaseline.alphabetic,
                child: HollowTextLink(
                  'Profile',
                  onTap: () => ref
                      .read(serverSettingsPageProvider.notifier)
                      .state = ServerSettingsPage.profile,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _delete(
      BuildContext context, WidgetRef ref, crdt_api.LabelFfi label) async {
    final writes = ref.read(labelWritesProvider(serverId).notifier);
    final ok = await showHollowConfirm(
      context: context,
      title: 'Delete ${label.name}?',
      message: "Everyone wearing it loses it. This can't be undone.",
      confirmLabel: 'Delete label',
      destructive: true,
      onConfirm: () =>
          crdt_api.deleteLabel(serverId: serverId, labelId: label.labelId),
    );
    if (ok) writes.removed(label.labelId);
  }
}

/// This page's own label writes, drawn over the stored list until a refetch
/// shows them: a read right after a queued CrdtStore write still returns the
/// previous labels.
class LabelWrites {
  /// A write per label id: the new label, or null once deleted.
  final Map<String, crdt_api.LabelFfi?> byId;

  /// Made here and not stored yet; their ids are placeholders.
  final List<crdt_api.LabelFfi> created;

  const LabelWrites({this.byId = const {}, this.created = const []});

  static const _pendingPrefix = 'pending:';

  /// A label made here that the store has not returned yet.
  static bool isPending(crdt_api.LabelFfi label) =>
      label.labelId.startsWith(_pendingPrefix);

  static bool _same(crdt_api.LabelFfi a, crdt_api.LabelFfi b) =>
      a.name == b.name && a.color == b.color && a.access == b.access;

  List<crdt_api.LabelFfi> over(List<crdt_api.LabelFfi> stored) => [
        for (final l in stored)
          if (!byId.containsKey(l.labelId)) l else ?byId[l.labelId],
        for (final c in created)
          if (!stored.any((s) => _same(s, c))) c,
      ];
}

class LabelWritesNotifier extends AutoDisposeFamilyNotifier<LabelWrites, String> {
  @override
  LabelWrites build(String serverId) => const LabelWrites();

  void removed(String labelId) => state = LabelWrites(
      byId: {...state.byId, labelId: null}, created: state.created);

  void updated(crdt_api.LabelFfi label) => state = LabelWrites(
      byId: {...state.byId, label.labelId: label}, created: state.created);

  void created(crdt_api.LabelFfi label) => state = LabelWrites(
        byId: state.byId,
        created: [
          ...state.created,
          crdt_api.LabelFfi(
            labelId:
                '${LabelWrites._pendingPrefix}${DateTime.now().microsecondsSinceEpoch}',
            name: label.name,
            color: label.color,
            access: label.access,
          ),
        ],
      );

  /// Forgets every write [stored] already shows.
  void prune(List<crdt_api.LabelFfi> stored) {
    final byId = {
      for (final e in state.byId.entries)
        if (e.value == null
            ? stored.any((s) => s.labelId == e.key)
            : !stored.any((s) =>
                s.labelId == e.key && LabelWrites._same(s, e.value!)))
          e.key: e.value,
    };
    final created = [
      for (final c in state.created)
        if (!stored.any((s) => LabelWrites._same(s, c))) c,
    ];
    if (byId.length != state.byId.length ||
        created.length != state.created.length) {
      state = LabelWrites(byId: byId, created: created);
    }
  }
}

/// This page's pending label writes, per server.
final labelWritesProvider = NotifierProvider.autoDispose
    .family<LabelWritesNotifier, LabelWrites, String>(LabelWritesNotifier.new);

/// A label's colour, as a 12 px dot beside its name.
class LabelDot extends StatelessWidget {
  final Color color;
  const LabelDot({super.key, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// What a screen reader says for each preset colour, in palette order.
const _presetColorNames = [
  'Red', 'Orange', 'Yellow', 'Green', 'Cyan', 'Blue', 'Violet', 'Pink', 'Grey',
];

/// Makes a label, or edits [existing]. Access labels gate channels and only
/// staff can hand them out.
void showLabelEditDialog(BuildContext context,
    {required String serverId, crdt_api.LabelFfi? existing}) {
  showHollowDialog(
    context: context,
    builder: (_) => _LabelEditDialog(serverId: serverId, existing: existing),
  );
}

class _LabelEditDialog extends ConsumerStatefulWidget {
  final String serverId;
  final crdt_api.LabelFfi? existing;
  const _LabelEditDialog({required this.serverId, this.existing});

  @override
  ConsumerState<_LabelEditDialog> createState() => _LabelEditDialogState();
}

class _LabelEditDialogState extends ConsumerState<_LabelEditDialog>
    with HollowDialogAction {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late Color _color = widget.existing != null
      ? parseLabelColor(widget.existing!.color)
      : kLabelPresetColors.first;
  late bool _access = widget.existing?.access ?? false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final hex =
        '#${_color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';
    final writes = ref.read(labelWritesProvider(widget.serverId).notifier);
    final existing = widget.existing;
    final saved = await runDialogAction(() async {
      if (existing == null) {
        await crdt_api.createLabel(
            serverId: widget.serverId,
            name: name,
            color: hex,
            access: _access);
      } else {
        await crdt_api.updateLabel(
            serverId: widget.serverId,
            labelId: existing.labelId,
            name: name,
            color: hex,
            access: _access);
      }
    });
    if (!saved) return;
    final label = crdt_api.LabelFfi(
      labelId: existing?.labelId ?? '',
      name: name,
      color: hex,
      access: _access,
    );
    existing == null ? writes.created(label) : writes.updated(label);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowDialog(
      title: widget.existing == null ? 'New label' : 'Edit label',
      width: 420,
      busy: actionRunning,
      error: actionError,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SettingsFieldLabel(label: 'Name'),
          const SizedBox(height: HollowSpacing.sm),
          HollowTextField(
            controller: _name,
            hintText: 'VIP, Artist, Night owl',
            autofocus: true,
            maxLength: 32,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: HollowSpacing.md),
          const SettingsFieldLabel(label: 'Colour'),
          const SizedBox(height: HollowSpacing.sm),
          Wrap(
            spacing: HollowSpacing.xs,
            runSpacing: HollowSpacing.xs,
            children: [
              for (final (i, c) in kLabelPresetColors.indexed)
                Semantics(
                  selected: c == _color,
                  inMutuallyExclusiveGroup: true,
                  child: HollowPressable(
                    semanticLabel: _presetColorNames[i],
                    onTap: () => setState(() => _color = c),
                    borderRadius: BorderRadius.circular(hollow.radiusMd),
                    padding: const EdgeInsets.all(HollowSpacing.xs),
                    child: Container(
                      width: HollowSpacing.xl,
                      height: HollowSpacing.xl,
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: c == _color
                            ? Border.all(
                                color: hollow.textPrimary,
                                width: HollowSpacing.xxs)
                            : null,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: HollowSpacing.md),
          const SettingsFieldLabel(label: 'Kind'),
          const SizedBox(height: HollowSpacing.sm),
          Wrap(
            spacing: HollowSpacing.sm,
            runSpacing: HollowSpacing.sm,
            children: [
              for (final (access, icon, text) in const [
                (false, LucideIcons.tag, 'Cosmetic'),
                (true, LucideIcons.lock, 'Access'),
              ])
                Semantics(
                  selected: _access == access,
                  inMutuallyExclusiveGroup: true,
                  child: HollowChip(
                    icon: icon,
                    label: text,
                    selected: _access == access,
                    onTap: () => setState(() => _access = access),
                  ),
                ),
            ],
          ),
          const SizedBox(height: HollowSpacing.sm),
          Text(
            _access
                ? 'It can open restricted channels, and only staff hand it out.'
                : "Anyone here can wear it on their profile. It doesn't open any channels.",
            style:
                HollowTypography.bodySmall.copyWith(color: hollow.textSecondary),
          ),
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: actionRunning ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          loading: actionRunning,
          onPressed: _name.text.trim().isEmpty ? null : _save,
          child: Text(widget.existing == null ? 'Create' : 'Save'),
        ),
      ],
    );
  }
}

/// Opens the "Give <label>" member picker. Public so the widget tests and the
/// screenshot harness can drive it without pumping the whole page.
Future<void> showLabelAssignDialog(
  BuildContext context, {
  required String serverId,
  required crdt_api.LabelFfi label,
  VoidCallback? onDone,
}) {
  return showHollowDialog(
    context: context,
    builder: (_) => _AssignDialog(serverId: serverId, label: label),
  ).then((_) => onDone?.call());
}

class _AssignDialog extends ConsumerStatefulWidget {
  final String serverId;
  final crdt_api.LabelFfi label;

  const _AssignDialog({required this.serverId, required this.label});

  @override
  ConsumerState<_AssignDialog> createState() => _AssignDialogState();
}

class _AssignDialogState extends ConsumerState<_AssignDialog> {
  Set<String> _assignedPeerIds = {};

  /// Seeded ONCE from the first member data and never re-derived: the refetch
  /// after a toggle races the queued CRDT write and returns the PREVIOUS value,
  /// which would visually revert the optimistic toggle.
  bool _seeded = false;

  @override
  void initState() {
    super.initState();
    ref.read(serverMembersProvider(widget.serverId)).whenData(_seed);
  }

  void _seed(List<crdt_api.MemberFfi> members) {
    if (_seeded) return;
    _seeded = true;
    final assigned = <String>{
      for (final m in members)
        if (m.labels.any((l) => l.labelId == widget.label.labelId)) m.peerId,
    };
    if (mounted) setState(() => _assignedPeerIds = assigned);
  }

  Future<void> _toggle(String peerId, String name) async {
    final wasAssigned = _assignedPeerIds.contains(peerId);
    // The box flips now; a failure flips it back.
    setState(() => wasAssigned
        ? _assignedPeerIds.remove(peerId)
        : _assignedPeerIds.add(peerId));
    try {
      if (wasAssigned) {
        await crdt_api.unassignLabel(
            serverId: widget.serverId,
            labelId: widget.label.labelId,
            peerId: peerId);
      } else {
        await crdt_api.assignLabel(
            serverId: widget.serverId,
            labelId: widget.label.labelId,
            peerId: peerId);
      }
      ref.invalidate(serverMembersProvider(widget.serverId));
    } catch (e) {
      if (!mounted) return;
      setState(() => wasAssigned
          ? _assignedPeerIds.add(peerId)
          : _assignedPeerIds.remove(peerId));
      HollowToast.show(
          context,
          friendlyError(e,
              fallback: wasAssigned
                  ? "Couldn't take ${widget.label.name} from $name. Try again."
                  : "Couldn't give ${widget.label.name} to $name. Try again."),
          type: HollowToastType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final membersAsync = ref.watch(serverMembersProvider(widget.serverId));
    final profiles = ref.watch(profileProvider);
    final color = parseLabelColor(widget.label.color);

    // Members may still be loading when the dialog opens.
    ref.listen(serverMembersProvider(widget.serverId), (_, next) {
      next.whenData(_seed);
    });

    return HollowDialog(
      title: 'Give ${widget.label.name}',
      width: 480,
      showClose: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const HollowDialogText(
              'Tap a member to give or take the label. Changes apply at once.'),
          const SizedBox(height: HollowSpacing.lg),
          membersAsync.when(
            data: (members) => MemberSearchPicker(
              members: members,
              maxListHeight: 280,
              nameOf: (m) =>
                  serverDisplayNameFor(profiles, m.peerId, nickname: m.nickname),
              trailingOf: (m) {
                final isAssigned = _assignedPeerIds.contains(m.peerId);
                return Icon(
                  isAssigned ? LucideIcons.checkSquare : LucideIcons.square,
                  size: 20,
                  color: isAssigned ? color : hollow.textSecondary,
                  semanticLabel: isAssigned ? 'Has it' : 'Does not have it',
                );
              },
              onTapMember: (m) => _toggle(
                  m.peerId,
                  serverDisplayNameFor(profiles, m.peerId,
                      nickname: m.nickname)),
            ),
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: HollowSpacing.lg),
              child: Center(child: HollowSpinner.medium()),
            ),
            error: (_, _) => const HollowEmptyState(
              dense: true,
              title: "Couldn't load the members",
              description: 'Close this and try again.',
            ),
          ),
        ],
      ),
    );
  }
}
