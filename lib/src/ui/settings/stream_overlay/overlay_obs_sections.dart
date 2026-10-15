import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/models/overlay_look.dart';
import 'package:hollow/src/core/providers/overlay_mic_provider.dart';
import 'package:hollow/src/core/providers/overlay_runtime_provider.dart';
import 'package:hollow/src/core/providers/overlay_settings_provider.dart';
import 'package:hollow/src/core/providers/voice_level_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_copy_field.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:hollow/src/ui/settings/stream_overlay/overlay_look_editor.dart';
import 'package:hollow/src/ui/settings/stream_overlay/overlay_port_toast.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

void _toastError(BuildContext context, Object e, String fallback) {
  if (!context.mounted) return;
  HollowToast.show(context, friendlyError(e, fallback: fallback),
      type: HollowToastType.error);
}

/// Run the overlay, its links, its address and Reset link (desktop).
class OverlayObsSection extends ConsumerStatefulWidget {
  const OverlayObsSection({super.key});

  @override
  ConsumerState<OverlayObsSection> createState() => _OverlayObsSectionState();
}

class _OverlayObsSectionState extends ConsumerState<OverlayObsSection> {
  bool _busy = false;

  Future<void> _setRunning(bool on) async {
    setState(() => _busy = true);
    try {
      await ref.read(overlayServerProvider.notifier).setEnabled(on);
    } catch (e) {
      if (mounted) {
        _toastError(context, e,
            on
                ? "Couldn't start the overlay. Try again."
                : "Couldn't stop the overlay. Try again.");
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resetLink() => showHollowConfirm(
        context: context,
        title: 'Reset the overlay link?',
        message: 'Every link you pasted into OBS stops working. Copy the new '
            'ones into your browser sources afterwards.',
        confirmLabel: 'Reset link',
        destructive: true,
        onConfirm: () => ref.read(overlayServerProvider.notifier).resetLink(),
      );

  Widget _linkRow(String title, String subtitle, String url) => SettingsRow(
        title: title,
        subtitle: subtitle,
        trailing: HollowButton.outline(
          compact: true,
          icon: const Icon(LucideIcons.copy),
          semanticLabel: 'Copy the $title link',
          onPressed: () {
            Clipboard.setData(ClipboardData(text: url));
            HollowToast.show(context, 'Link copied',
                type: HollowToastType.success);
          },
          child: const Text('Copy link'),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final server = ref.watch(overlayServerProvider);
    final status = server.status;
    final links = server.links;
    final moved = status.portChanged || ref.watch(overlayPortChangedProvider) != null;

    return SettingsSection(
      title: 'OBS',
      children: [
        SettingsSwitchRow(
          title: 'Run the overlay for OBS',
          subtitle: 'Starts a page only this computer can open. Paste a link '
              'below into an OBS browser source.',
          value: status.enabled,
          onChanged: _busy ? null : _setRunning,
        ),
        if (status.enabled && moved)
          Padding(
            padding: const EdgeInsets.only(bottom: HollowSpacing.sm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(LucideIcons.triangleAlert,
                    size: 16, color: hollow.warning, semanticLabel: 'Warning'),
                const SizedBox(width: HollowSpacing.sm),
                Expanded(
                  child: Text(kOverlayPortMovedText,
                      style: HollowTypography.bodySmall
                          .copyWith(color: hollow.textPrimary)),
                ),
              ],
            ),
          ),
        if (status.enabled && !status.running && !_busy)
          const SettingsNote("The overlay isn't running. Turn it off and on "
              'again, or restart Hollow.'),
        if (status.running && links != null) ...[
          _linkRow(
              'Whole room',
              'Everyone in your voice room who may be shown, you first.',
              links.room),
          _linkRow(
              'Just me',
              'Only you, in a call or not. Use this one for a webcam.',
              links.me),
          SettingsRow(
            title: 'Address',
            subtitle: 'Only this computer can open it, and only with the link.',
            trailing: Text('127.0.0.1:${status.port}',
                style: HollowTypography.mono
                    .copyWith(color: hollow.textSecondary)),
          ),
          SettingsRow(
            title: 'Reset link',
            subtitle: 'Makes new links and stops the old ones. Do this if you '
                'shared an OBS scene collection, because it holds the link.',
            trailing: HollowButton.outline(
              compact: true,
              danger: true,
              onPressed: _resetLink,
              child: const Text('Reset link'),
            ),
          ),
        ],
        const _WebcamHelp(),
      ],
    );
  }
}

/// How to use the Just me page as a webcam through OBS's own Virtual Camera
/// (plan decision 13: Hollow makes no camera of its own).
class _WebcamHelp extends StatelessWidget {
  const _WebcamHelp();

  static const _steps = [
    'In OBS, add the Just me link as a browser source.',
    'Open the gear next to Start Virtual Camera, set Output Type to Source '
        'and pick that browser source.',
    'Press Start Virtual Camera.',
    'In any app, Hollow included, pick OBS Virtual Camera as your camera.',
  ];

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final style =
        HollowTypography.bodySmall.copyWith(color: hollow.textSecondary);
    return Padding(
      padding: const EdgeInsets.only(top: HollowSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Want your look as a webcam in other apps? OBS can turn the '
              'Just me link into a camera.', style: style),
          const SizedBox(height: HollowSpacing.xs),
          for (final (i, step) in _steps.indexed)
            Padding(
              padding: const EdgeInsets.only(top: HollowSpacing.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: HollowSpacing.lg,
                    child: Text('${i + 1}.',
                        style: style.copyWith(
                            fontFeatures: const [FontFeature.tabularFigures()])),
                  ),
                  Expanded(child: Text(step, style: style)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// How the OBS page lays people out (desktop, this computer).
class OverlayLayoutSection extends ConsumerStatefulWidget {
  const OverlayLayoutSection({super.key});

  @override
  ConsumerState<OverlayLayoutSection> createState() =>
      _OverlayLayoutSectionState();
}

class _OverlayLayoutSectionState extends ConsumerState<OverlayLayoutSection> {
  /// A slider's value while it is dragged; saved once on release.
  double? _size;
  double? _gap;

  void _update(OverlayLayout Function(OverlayLayout l) change) {
    final notifier = ref.read(overlayLayoutProvider.notifier);
    notifier
        .update(change(ref.read(overlayLayoutProvider)))
        .catchError((Object e) {
      if (mounted) _toastError(context, e, "Couldn't save the layout.");
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = ref.watch(overlayLayoutProvider);
    final d = l.defaults;
    final size = _size ?? l.size.toDouble();
    final gap = _gap ?? l.gap.toDouble();
    return SettingsSection(
      title: 'Layout',
      subtitle: 'How the overlay arranges people. Changes show in OBS at once.',
      children: [
        SettingsChoiceRow<String>(
          title: 'Arrange',
          subtitle: switch (l.direction) {
            'column' => 'People stack from top to bottom.',
            'grid' => 'People fill a grid of equal cells.',
            _ => 'People sit side by side and wrap onto a new line when the '
                'source is full.',
          },
          value: l.direction,
          options: const [
            ('row', 'Side by side'),
            ('column', 'Stacked'),
            ('grid', 'Grid'),
          ],
          onChanged: (v) => _update((l) => l.copyWith(direction: v)),
        ),
        SettingsChoiceRow<String>(
          title: 'Line up',
          subtitle: 'Where people sit across the browser source.',
          value: l.align,
          options: const [
            ('start', 'Left'),
            ('center', 'Middle'),
            ('end', 'Right'),
          ],
          onChanged: (v) => _update((l) => l.copyWith(align: v)),
        ),
        SettingsSliderRow(
          title: 'Size',
          subtitle: 'How big each person is drawn.',
          value: size,
          min: OverlayLayout.sizeMin.toDouble(),
          max: OverlayLayout.sizeMax.toDouble(),
          divisions: (OverlayLayout.sizeMax - OverlayLayout.sizeMin) ~/ 8,
          valueLabel: '${size.round()} px',
          onChanged: (v) => setState(() => _size = v),
          onChangeEnd: (v) {
            _update((l) => l.copyWith(size: v.round()));
            setState(() => _size = null);
          },
        ),
        SettingsSliderRow(
          title: 'Gap',
          subtitle: 'Space between people.',
          value: gap,
          min: OverlayLayout.gapMin.toDouble(),
          max: OverlayLayout.gapMax.toDouble(),
          divisions: (OverlayLayout.gapMax - OverlayLayout.gapMin) ~/ 4,
          valueLabel: '${gap.round()} px',
          onChanged: (v) => setState(() => _gap = v),
          onChangeEnd: (v) {
            _update((l) => l.copyWith(gap: v.round()));
            setState(() => _gap = null);
          },
        ),
        SettingsChoiceRow<String>(
          title: 'Names',
          subtitle: switch (l.names) {
            'none' => 'No names, only images.',
            'plain' => "Each name in that person's colour, outlined so it "
                'reads over any scene.',
            _ => "Each name on a tag in that person's colour.",
          },
          value: l.names,
          options: const [
            ('none', 'None'),
            ('plain', 'Plain'),
            ('pill', 'Tag'),
          ],
          onChanged: (v) => _update((l) => l.copyWith(names: v)),
        ),
        SettingsSwitchRow(
          title: 'Only people who are talking',
          subtitle: 'Everyone else stays hidden until they talk.',
          value: l.onlyTalking,
          onChanged: (v) => _update((l) => l.copyWith(onlyTalking: v)),
        ),
        SettingsSwitchRow(
          title: 'Only people I added',
          subtitle: "Hides people in your voice room you didn't add. You "
              'always show.',
          value: l.onlyAdded,
          onChanged: (v) => _update((l) => l.copyWith(onlyAdded: v)),
        ),
        SettingsChoiceRow<String>(
          title: 'Avatars while talking',
          subtitle: 'How people shown with their avatar react when they talk.',
          value: d.talking!,
          options: const [
            ('none', 'None'),
            ('bounce', 'Bounce'),
            ('shake', 'Shake'),
            ('pop', 'Pop'),
            ('glow', 'Glow'),
          ],
          onChanged: (v) => _update(
              (l) => l.copyWith(defaults: l.defaults.copyWith(talking: v))),
        ),
        SettingsChoiceRow<String>(
          title: 'Avatars while quiet',
          subtitle: switch (d.idle) {
            'dim' => 'Avatars dim while quiet, so whoever talks stands out.',
            'grayscale' => 'Avatars lose their colour while quiet.',
            _ => 'Avatars show as they are while quiet.',
          },
          value: d.idle!,
          options: const [
            ('none', 'As is'),
            ('dim', 'Dim'),
            ('grayscale', 'Black and white'),
          ],
          onChanged: (v) => _update(
              (l) => l.copyWith(defaults: l.defaults.copyWith(idle: v))),
        ),
      ],
    );
  }
}

/// "Listen to my mic now", its sensitivity and live meter, and what the
/// overlay shows of us when nothing measures the mic (desktop).
class OverlayListenSection extends ConsumerStatefulWidget {
  const OverlayListenSection({super.key});

  @override
  ConsumerState<OverlayListenSection> createState() =>
      _OverlayListenSectionState();
}

class _OverlayListenSectionState extends ConsumerState<OverlayListenSection> {
  bool _busy = false;
  double? _threshold;

  void _saveFailed(Object e) {
    if (mounted) _toastError(context, e, "Couldn't save that.");
  }

  Future<void> _toggle(bool on) async {
    setState(() => _busy = true);
    final mic = ref.read(overlayMicProvider.notifier);
    try {
      if (on) {
        await mic.turnOn();
      } else {
        await mic.turnOff();
      }
    } on OverlayMicRefused catch (e) {
      if (mounted) {
        HollowToast.show(context, e.message, type: HollowToastType.error);
      }
    } catch (e) {
      if (mounted) {
        _toastError(
            context,
            e,
            on
                ? "Couldn't open the microphone. Check that no other app holds "
                    'it.'
                : "Couldn't turn the mic off. Try again.");
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final running = ref.watch(overlayServerRunningProvider);
    final mic = ref.watch(overlayMicProvider);
    final settings = ref.watch(overlayListenSettingsProvider);
    final threshold = _threshold ?? settings.thresholdDb;
    return SettingsSection(
      title: 'Listening',
      children: [
        SettingsSwitchRow(
          title: 'Listen to my mic now',
          subtitle: !running
              ? 'Turn on Run the overlay for OBS first.'
              : mic.paused
                  ? 'Paused while a call or the mic test uses the mic. It '
                      'starts again afterwards.'
                  : "Lets your overlay react to your voice when you're not in "
                      'a call. A call takes the mic over while it runs. It '
                      'turns off when Hollow restarts.',
          value: mic.on,
          onChanged: _busy || (!running && !mic.on) ? null : _toggle,
        ),
        SettingsSliderRow(
          title: 'Sensitivity',
          subtitle: 'Sound above this level counts as talking. Raise it if '
              'your keyboard or the room sets the overlay off.',
          value: threshold,
          min: kOverlayListenThresholdMinDb,
          max: kOverlayListenThresholdMaxDb,
          divisions:
              (kOverlayListenThresholdMaxDb - kOverlayListenThresholdMinDb)
                  .round(),
          valueLabel: '${threshold.round()} dB',
          onChanged: (v) => setState(() => _threshold = v),
          onChangeEnd: (v) {
            ref
                .read(overlayListenSettingsProvider.notifier)
                .setThresholdDb(v)
                .catchError((Object e) {
              _saveFailed(e);
            });
            setState(() => _threshold = null);
          },
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: HollowSpacing.sm),
          child: mic.listening
              ? Consumer(builder: (context, ref, _) {
                  return OverlayLevelMeter(
                    level: ref.watch(listenLevelProvider),
                    active: ref.watch(overlayMicSpeakingProvider),
                    threshold: levelFromDb(threshold),
                  );
                })
              : const SettingsNote(
                  'A meter shows your level here while listening.'),
        ),
        SettingsChoiceRow<bool>(
          title: "When I'm not in a call and not listening",
          subtitle: settings.showIdleWhenInactive
              ? 'You stay on the overlay with your idle image.'
              : 'You leave the overlay until a call or listening starts.',
          value: settings.showIdleWhenInactive,
          options: const [
            (true, 'Show my idle look'),
            (false, 'Show nothing'),
          ],
          onChanged: (v) => ref
              .read(overlayListenSettingsProvider.notifier)
              .setShowIdleWhenInactive(v)
              .catchError((Object e) {
            _saveFailed(e);
          }),
        ),
      ],
    );
  }
}

/// The names OBS's Custom CSS box can target (desktop).
class OverlayCssSection extends StatelessWidget {
  const OverlayCssSection({super.key});

  static const double _hookWidth = 220;

  static const _hooks = [
    ('.overlay', 'The whole page, laid out as a row, a column or a grid.'),
    ('.person', 'One person, with all the attributes below.'),
    ('.stage  .frame', 'The image area, and the frame the images sit in.'),
    ('img.layer  img.layer.on', 'Every image, and the one on show right now.'),
    ('.initials', 'The circle with initials, for someone with no avatar.'),
    ('.badge', 'The muted or deafened mark.'),
    ('.name', 'The name.'),
    ('[data-state]', 'idle, talking, muted or deafened.'),
    ('[data-self]  [data-added]', 'You, and people you added.'),
    ('[data-loud]  [data-blink]', 'While loud, and during a blink.'),
    ('[data-slot]  [data-kind]', "The number in the person's own link, and "
        'look, avatar or initials.'),
    ('[data-badge]', 'muted or deafened, while the mark shows.'),
    ('--c', "The person's name colour."),
  ];

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return SettingsSection(
      title: 'Customise with CSS in OBS',
      subtitle: 'Each browser source in OBS has a Custom CSS box that can '
          'restyle the overlay. These names stay the same between updates.',
      children: [
        for (final (hook, what) in _hooks)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: HollowSpacing.xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: _hookWidth,
                  child: SelectableText(hook,
                      style: HollowTypography.mono
                          .copyWith(color: hollow.textPrimary)),
                ),
                const SizedBox(width: HollowSpacing.md),
                Expanded(
                  child: Text(what,
                      style: HollowTypography.bodySmall
                          .copyWith(color: hollow.textSecondary)),
                ),
              ],
            ),
          ),
        const SizedBox(height: HollowSpacing.md),
        const HollowCopyField(
          label: 'Example',
          value: '.person[data-state="talking"] .name { font-size: 140%; }',
        ),
      ],
    );
  }
}
