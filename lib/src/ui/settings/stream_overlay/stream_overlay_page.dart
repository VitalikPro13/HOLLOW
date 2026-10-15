import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/overlay_settings_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:hollow/src/ui/settings/stream_overlay/overlay_look_draft.dart';
import 'package:hollow/src/ui/settings/stream_overlay/overlay_look_editor.dart';
import 'package:hollow/src/ui/settings/stream_overlay/overlay_obs_sections.dart';
import 'package:hollow/src/ui/settings/stream_overlay/overlay_people_section.dart';

/// Settings > Stream overlay (#97, plan 3): who may show me, my look, the
/// people on my overlay, and on desktop everything OBS needs. The same page on
/// a phone stops after the people: a phone has no OBS to point at it.
class StreamOverlaySettingsPage extends ConsumerWidget {
  const StreamOverlaySettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final desktop = overlayServerSupported();
    return SettingsPage(
      title: 'Stream overlay',
      intro: desktop
          ? 'Show yourself and your voice room in OBS, reacting as people '
              'talk. It all runs on this computer and nothing goes online.'
          : 'Choose how you look when a friend streams with Hollow, and who '
              'shows up when you stream from your computer.',
      children: [
        const OverlayPrivacySection(),
        const OverlayMyLookSection(),
        const OverlayPeopleSection(),
        if (desktop) ...const [
          OverlayObsSection(),
          OverlayLayoutSection(),
          OverlayListenSection(),
          OverlayCssSection(),
        ],
      ],
    );
  }
}

/// The two identity-wide toggles. The second depends on the first: it greys
/// out with the reason while the first is off, and keeps its place.
class OverlayPrivacySection extends ConsumerWidget {
  const OverlayPrivacySection({super.key});

  Future<void> _set(BuildContext context, WidgetRef ref,
      {required bool allow, required bool share}) async {
    try {
      await ref
          .read(overlayOwnProvider.notifier)
          .setFlags(allow: allow, share: share);
    } catch (e) {
      if (!context.mounted) return;
      HollowToast.show(context,
          friendlyError(e, fallback: "Couldn't change that. Try again."),
          type: HollowToastType.error);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final own = ref.watch(overlayOwnProvider);
    final value = own.valueOrNull;
    if (value == null && own.hasError) {
      return SettingsSection(
        title: 'Who can show me',
        children: [
          SettingsLoadFailed(
            title: "Couldn't read your overlay settings",
            onRetry: () => ref.invalidate(overlayOwnProvider),
          ),
        ],
      );
    }
    final allow = value?.allow ?? false;
    final share = value?.share ?? false;
    final ready = value != null;
    return SettingsSection(
      title: 'Who can show me',
      children: [
        SettingsSwitchRow(
          title: 'Let others show me on their stream overlay',
          subtitle: 'Friends and people in a voice room with you can add you '
              'to the overlay they use in OBS. Turn it off and nobody can. '
              'Their Hollow apps delete what they held for you.',
          value: allow,
          trailingTop: true,
          onChanged: ready
              ? (v) => _set(context, ref, allow: v, share: v && share)
              : null,
        ),
        SettingsSwitchRow(
          title: 'Share my overlay images',
          subtitle: allow
              ? 'People who added you get your images. If you turn this '
                  'off, they can still show your avatar or pick their own '
                  'images.'
              : 'Turn on the switch above first. Nobody can show you right '
                  'now.',
          value: allow && share,
          trailingTop: true,
          onChanged: ready && allow
              ? (v) => _set(context, ref, allow: true, share: v)
              : null,
        ),
      ],
    );
  }
}

/// Our own look. Every finished edit saves itself, like any other setting.
class OverlayMyLookSection extends ConsumerStatefulWidget {
  const OverlayMyLookSection({super.key});

  @override
  ConsumerState<OverlayMyLookSection> createState() =>
      _OverlayMyLookSectionState();
}

class _OverlayMyLookSectionState extends ConsumerState<OverlayMyLookSection> {
  OverlayLookDraft? _draft;
  OverlayLookAutosave? _autosave;

  @override
  void dispose() {
    _autosave?.close();
    _draft?.dispose();
    super.dispose();
  }

  void _onDraft() => setState(() {});

  OverlayLookAutosave _autosaveFor(OverlayLookDraft draft) {
    final own = ref.read(overlayOwnProvider.notifier);
    return OverlayLookAutosave(
      draft: draft,
      save: (look) async =>
          own.saveLook(await reprocessSwept(look, draft, own)),
      onError: (e) {
        if (!mounted) return;
        HollowToast.show(context,
            friendlyError(e, fallback: "Couldn't save your look. Try again."),
            type: HollowToastType.error);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final own = ref.watch(overlayOwnProvider);
    final me = ref.watch(identityProvider).peerId ?? '';
    final value = own.valueOrNull;
    ref.listen(overlayOwnProvider, (_, next) {
      final look = next.valueOrNull?.look;
      if (look != null) _draft?.adopt(look);
    });

    const title = 'My overlay look';
    const subtitle = "How you look on anyone's stream overlay. Changes save "
        'as you make them and reach the people who added you.';
    if (value == null) {
      return SettingsSection(
        title: title,
        subtitle: subtitle,
        children: [
          if (own.hasError)
            SettingsLoadFailed(
              title: "Couldn't load your overlay look",
              onRetry: () => ref.invalidate(overlayOwnProvider),
            )
          else
            const Padding(
              padding: EdgeInsets.symmetric(vertical: HollowSpacing.xl),
              child: Center(child: HollowSpinner.medium(delayed: true)),
            ),
        ],
      );
    }
    var draft = _draft;
    if (draft == null) {
      draft = _draft = OverlayLookDraft.own(value.look);
      draft.addListener(_onDraft);
      _autosave = _autosaveFor(draft);
    }
    return SettingsSection(
      title: title,
      subtitle: subtitle,
      children: [
        OverlayLookEditor(
          draft: draft,
          master: me,
          followLiveMic: true,
          onCommit: _autosave!.commit,
        ),
        if (!value.share)
          const SettingsNote('Share my overlay images is off, so these stay '
              'on your devices. Others see your avatar.'),
      ],
    );
  }
}
