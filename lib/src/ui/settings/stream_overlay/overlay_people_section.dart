import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/color_utils.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/models/overlay_look.dart';
import 'package:hollow/src/core/providers/overlay_settings_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_badge.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_settings_tab.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:hollow/src/ui/settings/stream_overlay/overlay_look_draft.dart';
import 'package:hollow/src/ui/settings/stream_overlay/overlay_look_editor.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// What a person's source badge says.
String overlaySourceLabel(OverlayLookSource s) => switch (s) {
      OverlayLookSource.theirs => 'Their images',
      OverlayLookSource.mine => 'My picks',
      OverlayLookSource.avatar => 'Avatar',
    };

/// How many people show before "Show all".
const int kOverlayPeopleShown = 5;

/// Above this many people the list gets a filter field.
const int kOverlayPeopleFilterAbove = 8;

/// Everyone we ticked "Show on my stream overlay" for, on this computer. The
/// list stays short: the first few, then Show all, and a filter once it is
/// long.
class OverlayPeopleSection extends ConsumerStatefulWidget {
  const OverlayPeopleSection({super.key});

  @override
  ConsumerState<OverlayPeopleSection> createState() =>
      _OverlayPeopleSectionState();
}

class _OverlayPeopleSectionState extends ConsumerState<OverlayPeopleSection> {
  final TextEditingController _filter = TextEditingController();
  String _query = '';
  bool _all = false;

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final people = ref.watch(overlayPeopleProvider);
    final list = people.valueOrNull;
    final filtering = (list?.length ?? 0) > kOverlayPeopleFilterAbove;
    final query = filtering ? _query.trim().toLowerCase() : '';
    var matches = list ?? const <OverlayPerson>[];
    if (query.isNotEmpty) {
      final profiles = ref.watch(profileProvider);
      matches = [
        for (final p in matches)
          if (displayNameForPeer(profiles[p.master], p.master)
              .toLowerCase()
              .contains(query))
            p,
      ];
    }
    final long = matches.length > kOverlayPeopleShown;
    final shown = long && !_all ? matches.take(kOverlayPeopleShown) : matches;
    final total = list?.length ?? 0;
    const subtitle = 'Your picks for someone stay on this computer and only '
        'you see them.';
    return SettingsSection(
      title: 'People on my overlay',
      subtitle: subtitle,
      count: total == 0
          ? null
          : (query.isEmpty ? '$total' : '${matches.length} of $total'),
      // In the header, so Show all and Show less sit on the same spot.
      action: long
          ? HollowButton.ghost(
              compact: true,
              onPressed: () => setState(() => _all = !_all),
              child: Text(_all ? 'Show less' : 'Show all'),
            )
          : null,
      children: [
        if (list == null && people.hasError)
          SettingsLoadFailed(
            title: "Couldn't load the people on your overlay",
            onRetry: () => ref.invalidate(overlayPeopleProvider),
          )
        else if (list == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: HollowSpacing.lg),
            child: Center(child: HollowSpinner.medium(delayed: true)),
          )
        else if (list.isEmpty)
          const HollowEmptyState(
            dense: true,
            title: 'Nobody on your overlay yet',
            description: "Open someone's profile, choose More, then Show on "
                'my stream overlay. Everyone in your voice room shows up '
                'anyway, with their avatar.',
          )
        else ...[
          if (filtering)
            Padding(
              padding: const EdgeInsets.only(bottom: HollowSpacing.sm),
              child: HollowTextField(
                controller: _filter,
                hintText: 'Find a person',
                isDense: true,
                prefixIcon: Icon(LucideIcons.search,
                    size: 16, color: hollow.textSecondary),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
          if (matches.isEmpty)
            const HollowEmptyState(
              dense: true,
              title: 'Nobody here matches that',
              description: 'Check the spelling, or clear the search.',
            ),
          for (final p in shown) _PersonRow(key: ValueKey(p.master), person: p),
        ],
      ],
    );
  }
}

class _PersonRow extends ConsumerWidget {
  final OverlayPerson person;

  const _PersonRow({super.key, required this.person});

  String? _note() => switch (person.field) {
        'show' => "Doesn't share images, so their avatar shows unless you "
            'pick some.',
        'share' when person.theirs == null =>
          'Their images arrive the next time you are both online.',
        _ => null,
      };

  Future<void> _remove(BuildContext context, WidgetRef ref, String name) async {
    Future<void> remove() =>
        ref.read(overlayPeopleProvider.notifier).remove(person.master);
    if (person.hasOwnPicks) {
      await showHollowConfirm(
        context: context,
        title: 'Remove $name from your overlay?',
        message: 'The images you picked for them are deleted too.',
        confirmLabel: 'Remove',
        destructive: true,
        onConfirm: remove,
      );
      return;
    }
    try {
      await remove();
    } catch (e) {
      if (!context.mounted) return;
      HollowToast.show(context,
          friendlyError(e, fallback: "Couldn't remove them. Try again."),
          type: HollowToastType.error);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final touch = SettingsDensity.touchOf(context);
    final profile =
        ref.watch(profileProvider.select((p) => p[person.master]));
    final name = displayNameForPeer(profile, person.master);
    // Desktop only, and only while the overlay runs: a link is no use before.
    final base = overlayServerSupported()
        ? ref.watch(overlayServerProvider.select((s) =>
            s.status.running ? s.links?.personBase : null))
        : null;
    return SettingsRow(
      leading: HollowAvatar(peerId: person.master, size: 32),
      title: name,
      titleColor: nameColorFor(person.master, hollow),
      titleTrailing: HollowBadge(overlaySourceLabel(person.source)),
      subtitle: _note(),
      wideTrailing: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          HollowButton.outline(
            compact: !touch,
            touch: touch,
            onPressed: () => openOverlayLocalEditor(context, person),
            child: const Text('Pick images'),
          ),
          if (base != null) ...[
            const SizedBox(width: HollowSpacing.xs),
            HollowIconButton(
              icon: LucideIcons.link,
              label: 'Copy the OBS link for $name',
              size: 32,
              onPressed: () {
                Clipboard.setData(ClipboardData(text: '$base${person.slot}'));
                HollowToast.show(context, 'Link copied',
                    type: HollowToastType.success);
              },
            ),
          ],
          const SizedBox(width: HollowSpacing.xs),
          HollowIconButton(
            icon: LucideIcons.x,
            label: 'Remove $name from the overlay',
            size: touch ? 44 : 32,
            onPressed: () => _remove(context, ref, name),
          ),
        ],
      ),
    );
  }
}

/// Our picks for [person]: a dialog on desktop, a page on a phone.
void openOverlayLocalEditor(BuildContext context, OverlayPerson person) {
  if (SettingsDensity.touchOf(context)) {
    Navigator.of(context).push(hollowMobileRoute(
      builder: (_) => _LocalEditorPage(person: person),
    ));
    return;
  }
  showHollowDialog<void>(
    context: context,
    builder: (_) => _LocalEditorDialog(person: person),
  );
}

OverlayLookDraft _localDraft(WidgetRef ref, OverlayPerson person) =>
    OverlayLookDraft.local(
      saved: person.local,
      theirs: person.theirs,
      avatarEffects: ref.read(overlayLayoutProvider).defaults,
    );

/// Our picks save as they are made; closing the editor only closes it.
OverlayLookAutosave _localAutosave(WidgetRef ref, OverlayPerson person,
    OverlayLookDraft draft, BuildContext Function() context) {
  final own = ref.read(overlayOwnProvider.notifier);
  final people = ref.read(overlayPeopleProvider.notifier);
  return OverlayLookAutosave(
    draft: draft,
    save: (look) async {
      final stored = await reprocessSwept(look, draft, own);
      await people.setLocal(person.master, stored.isEmpty ? null : stored);
      return stored;
    },
    onError: (e) {
      final c = context();
      if (!c.mounted) return;
      HollowToast.show(c,
          friendlyError(e, fallback: "Couldn't save your picks. Try again."),
          type: HollowToastType.error);
    },
  );
}

class _LocalEditorDialog extends ConsumerStatefulWidget {
  final OverlayPerson person;

  const _LocalEditorDialog({required this.person});

  @override
  ConsumerState<_LocalEditorDialog> createState() => _LocalEditorDialogState();
}

class _LocalEditorDialogState extends ConsumerState<_LocalEditorDialog> {
  late final OverlayLookDraft _draft = _localDraft(ref, widget.person)
    ..addListener(_changed);
  late final OverlayLookAutosave _autosave =
      _localAutosave(ref, widget.person, _draft, () => context);

  void _changed() => setState(() {});

  @override
  void dispose() {
    _autosave.close();
    _draft.dispose();
    super.dispose();
  }

  void _resetAll() {
    _draft.resetAll();
    _autosave.commit();
  }

  @override
  Widget build(BuildContext context) {
    final profile =
        ref.watch(profileProvider.select((p) => p[widget.person.master]));
    final name = displayNameForPeer(profile, widget.person.master);
    return HollowDialog(
      title: 'How $name looks on my overlay',
      width: 760,
      maxWidth: 760,
      content: OverlayLookEditor(
        draft: _draft,
        master: widget.person.master,
        onCommit: _autosave.commit,
      ),
      leadingActions: [
        HollowButton.ghost(
          onPressed: _draft.draft.isEmpty ? null : _resetAll,
          child: const Text('Reset all'),
        ),
      ],
      actions: [
        HollowButton.filled(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

class _LocalEditorPage extends ConsumerStatefulWidget {
  final OverlayPerson person;

  const _LocalEditorPage({required this.person});

  @override
  ConsumerState<_LocalEditorPage> createState() => _LocalEditorPageState();
}

class _LocalEditorPageState extends ConsumerState<_LocalEditorPage> {
  late final OverlayLookDraft _draft = _localDraft(ref, widget.person)
    ..addListener(_changed);
  late final OverlayLookAutosave _autosave =
      _localAutosave(ref, widget.person, _draft, () => context);

  void _changed() => setState(() {});

  @override
  void dispose() {
    _autosave.close();
    _draft.dispose();
    super.dispose();
  }

  void _resetAll() {
    _draft.resetAll();
    _autosave.commit();
  }

  @override
  Widget build(BuildContext context) {
    final profile =
        ref.watch(profileProvider.select((p) => p[widget.person.master]));
    final name = displayNameForPeer(profile, widget.person.master);
    return MobileSettingsSubPage(
      title: name,
      child: SettingsDensity(
        touch: true,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(HollowSpacing.lg, HollowSpacing.sm,
              HollowSpacing.lg, HollowSpacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OverlayLookEditor(
                draft: _draft,
                master: widget.person.master,
                onCommit: _autosave.commit,
              ),
              const SizedBox(height: HollowSpacing.lg),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  HollowButton.ghost(
                    touch: true,
                    onPressed: _draft.draft.isEmpty ? null : _resetAll,
                    child: const Text('Reset all'),
                  ),
                  const SizedBox(width: HollowSpacing.sm),
                  HollowButton.outline(
                    touch: true,
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: const Text('Done'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
