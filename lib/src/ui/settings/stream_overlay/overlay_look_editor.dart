import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/color_utils.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/models/overlay_look.dart';
import 'package:hollow/src/core/providers/accent_color_provider.dart';
import 'package:hollow/src/core/providers/avatar_provider.dart';
import 'package:hollow/src/core/providers/overlay_settings_provider.dart';
import 'package:hollow/src/core/providers/profile_anim_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_badge.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:hollow/src/ui/settings/stream_overlay/overlay_live_input.dart';
import 'package:hollow/src/ui/settings/stream_overlay/overlay_look_draft.dart';
import 'package:hollow/src/ui/settings/stream_overlay/overlay_preview_engine.dart';
import 'package:hollow/src/ui/settings/stream_overlay/overlay_stage.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// An overlay image's bytes by hash, for thumbnails and the preview.
final overlayImageBytesProvider = FutureProvider.autoDispose
    .family<Uint8List?, String>((ref, hash) => overlayImageBytes(hash));

/// [look] with any image picked in [draft] but swept before its save processed
/// again from its file (the sweep only keeps images a saved look names).
Future<OverlayLook> reprocessSwept(OverlayLook look, OverlayLookDraft draft,
    OverlayOwnNotifier own) async {
  for (final s in OverlayLookState.values) {
    final hash = look.hashOf(s);
    final path = draft.pickedPaths[hash];
    if (hash.isEmpty || path == null) continue;
    if (await overlayImageBytes(hash) != null) continue;
    final again = await own.processImage(path);
    look = look.withState(s, again.hash);
  }
  return look;
}

/// Asks for an image file; swappable in tests. Null when the person cancels.
Future<String?> Function() overlayPickImagePath = () async {
  final result = await FilePicker.platform.pickFiles(type: FileType.image);
  return result?.files.firstOrNull?.path;
};

/// The order the slots show in: the talking group, then the quiet extras.
const List<OverlayLookState> kOverlaySlotOrder = [
  OverlayLookState.idle,
  OverlayLookState.talking,
  OverlayLookState.loud,
  OverlayLookState.blink,
  OverlayLookState.muted,
  OverlayLookState.deafened,
];

String overlayStateLabel(OverlayLookState s) => switch (s) {
      OverlayLookState.idle => 'Idle',
      OverlayLookState.talking => 'Talking',
      OverlayLookState.loud => 'Loud',
      OverlayLookState.blink => 'Blink',
      OverlayLookState.muted => 'Muted',
      OverlayLookState.deafened => 'Deafened',
    };

/// What shows in [s] while it has no image of its own.
String _fallbackHint(OverlayLookState s) => switch (s) {
      OverlayLookState.idle => 'Avatar',
      OverlayLookState.talking => 'Idle image',
      OverlayLookState.loud => 'Talking image',
      OverlayLookState.blink => 'None',
      OverlayLookState.muted || OverlayLookState.deafened => 'Idle, dimmed',
    };

/// overlay.js `initialsOf`: the first letter of up to two words.
String overlayInitials(String name) {
  final words =
      name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).take(2);
  final out = words.map((w) => w.characters.first).join();
  return (out.isEmpty ? '?' : out).toUpperCase(); // design-ignore: initials art, as overlay.js
}

/// The look editor: a live preview that moves the way OBS draws it, one image
/// slot per state, and every effect with what it does. [draft] holds the
/// edit and [onCommit] tells the host an edit is finished, so it can save:
/// a slider only on release. [master] is whose name, colour and avatar the
/// preview wears: ours in OWN mode, the person's in LOCAL mode.
class OverlayLookEditor extends ConsumerStatefulWidget {
  final OverlayLookDraft draft;
  final String master;

  /// OWN mode only: our real mic drives the preview while something measures
  /// it.
  final bool followLiveMic;

  final VoidCallback? onCommit;

  const OverlayLookEditor({
    super.key,
    required this.draft,
    required this.master,
    this.followLiveMic = false,
    this.onCommit,
  });

  @override
  ConsumerState<OverlayLookEditor> createState() => _OverlayLookEditorState();
}

class _OverlayLookEditorState extends ConsumerState<OverlayLookEditor> {
  final Set<OverlayLookState> _busy = {};

  OverlayLookDraft get _draft => widget.draft;

  @override
  void initState() {
    super.initState();
    _draft.addListener(_changed);
    // HollowAvatar loads lazily; the preview needs to know whether there is
    // one before it chooses initials.
    Future.microtask(() {
      if (mounted) {
        ref.read(avatarProvider.notifier).loadAvatar(widget.master);
      }
    });
  }

  @override
  void didUpdateWidget(OverlayLookEditor old) {
    super.didUpdateWidget(old);
    if (old.draft != widget.draft) {
      old.draft.removeListener(_changed);
      widget.draft.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _draft.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  bool get _local => _draft.local;
  void _commit() => widget.onCommit?.call();
  bool get _touch => SettingsDensity.touchOf(context);

  Future<void> _pick(OverlayLookState state) async {
    final path = await overlayPickImagePath();
    if (path == null || !mounted) return;
    setState(() => _busy.add(state));
    try {
      final image =
          await ref.read(overlayOwnProvider.notifier).processImage(path);
      _draft.setImage(state, image.hash, path: path);
      _commit();
    } catch (e) {
      if (mounted) {
        HollowToast.show(
            context,
            friendlyError(e,
                fallback: "Couldn't use that image. Try a PNG, GIF or WebP."),
            type: HollowToastType.error);
      }
    } finally {
      if (mounted) setState(() => _busy.remove(state));
    }
  }

  void _openSlotMenu(BuildContext slotContext, OverlayLookState state) {
    final box = slotContext.findRenderObject() as RenderBox?;
    if (box == null) return;
    final theirs = _draft.theirs?.hashOf(state) ?? '';
    showHollowMenu(
      context: slotContext,
      anchor: overlayAnchorOf(slotContext,
          localOffset: Offset(0, box.size.height)),
      builder: (_, _) => [
        HollowMenuItem(
          icon: LucideIcons.imageUp,
          label: 'Choose another image',
          onTap: () => _pick(state),
        ),
        HollowMenuItem(
          icon: _local ? LucideIcons.undo2 : LucideIcons.trash2,
          label: _local
              ? (theirs.isEmpty ? 'Remove my pick' : 'Use their image')
              : 'Remove image',
          onTap: () {
            _draft.clearImage(state);
            _commit();
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final shown = _draft.shown;
    final fx = _draft.effects;
    final profile =
        ref.watch(profileProvider.select((p) => p[widget.master]));
    final name = displayNameForPeer(profile, widget.master);
    // The colour OBS gets: the publisher reads the DARK theme at our accent,
    // whatever theme this window shows.
    final obsTheme = HollowTheme.darkWithHue(ref.watch(accentHueProvider));
    final colour = _local
        ? nameColorFor(widget.master, obsTheme)
        : obsTheme.accentText;
    final hasAvatar = ref.watch(avatarProvider
            .select((a) => a[widget.master]?.isNotEmpty ?? false)) ||
        isProfileAnimHash(profile?.avatarAnim ?? '');
    final pronoun = _local ? 'their' : 'your';

    final preview = _PreviewPanel(
      look: shown,
      master: widget.master,
      name: name,
      colour: colour,
      hasAvatar: hasAvatar,
      followLiveMic: widget.followLiveMic,
    );
    final slots = _Slots(
      draft: _draft,
      busy: _busy,
      onPick: _pick,
      onMenu: _openSlotMenu,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: HollowSpacing.lg),
          child: LayoutBuilder(builder: (context, c) {
            if (!_touch && c.maxWidth >= 560) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  preview,
                  const SizedBox(width: HollowSpacing.xl),
                  Expanded(child: slots),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [preview, const SizedBox(height: HollowSpacing.lg), slots],
            );
          }),
        ),
        _choice(
          key: 'talking',
          title: 'Talking effect',
          value: fx.talking!,
          options: const [
            ('none', 'None'),
            ('bounce', 'Bounce'),
            ('shake', 'Shake'),
            ('pop', 'Pop'),
            ('glow', 'Glow'),
          ],
          subtitle: switch (fx.talking) {
            'bounce' => 'Hops up and down while talking.',
            'shake' => 'Shakes from side to side while talking.',
            'pop' => 'Grows a little while talking.',
            'glow' => 'Glows in $pronoun name colour while talking.',
            _ => 'Only the image changes while talking.',
          },
          set: (v) => _draft.setEffects((e) => e.copyWith(talking: v)),
        ),
        _switch(
          key: 'scale_with_voice',
          title: 'Bigger when louder',
          subtitle: 'The louder the voice, the higher the bounce, the wider '
              'the shake, the bigger the pop and the brighter the glow.',
          value: fx.scaleWithVoice!,
          set: (v) => _draft.setEffects((e) => e.copyWith(scaleWithVoice: v)),
        ),
        _choice(
          key: 'idle',
          title: 'While quiet',
          value: fx.idle!,
          options: const [
            ('none', 'As is'),
            ('dim', 'Dim'),
            ('grayscale', 'Black and white'),
          ],
          subtitle: switch (fx.idle) {
            'dim' => 'Darkens the image while quiet, so whoever talks stands '
                'out.',
            'grayscale' => 'Takes the colour out while quiet.',
            _ => 'The idle image shows as it is.',
          },
          set: (v) => _draft.setEffects((e) => e.copyWith(idle: v)),
        ),
        _choice(
          key: 'transition',
          title: 'Switching images',
          value: fx.transition!,
          options: const [
            ('instant', 'Instant'),
            ('crossfade', 'Crossfade'),
          ],
          subtitle: fx.transition == 'crossfade'
              ? 'Blends from one image into the next.'
              : 'Swaps at once, like a flipbook.',
          set: (v) => _draft.setEffects((e) => e.copyWith(transition: v)),
        ),
        _slider(
          key: 'hold_ms',
          title: 'Hold after talking',
          subtitle: 'Keeps the talking image up for a moment after the voice '
              'stops, so it does not flicker between words.',
          value: fx.holdMs!.toDouble(),
          min: OverlayEffects.holdMsMin.toDouble(),
          max: OverlayEffects.holdMsMax.toDouble(),
          divisions: 24,
          label: '${fx.holdMs} ms',
          set: (v) => _draft.setEffects((e) => e.copyWith(holdMs: v.round())),
        ),
        _slider(
          key: 'blink_every_s',
          title: 'Blink every',
          subtitle: shown.hashOf(OverlayLookState.blink).isEmpty
              ? 'Shows the blink image for a moment, about this often, while '
                  'quiet. Add a blink image to use it.'
              : 'Shows the blink image for a moment, about this often, while '
                  'quiet. The timing varies a little, like a real blink.',
          value: fx.blinkEverySec!.toDouble(),
          min: OverlayEffects.blinkEverySecMin.toDouble(),
          max: OverlayEffects.blinkEverySecMax.toDouble(),
          divisions:
              OverlayEffects.blinkEverySecMax - OverlayEffects.blinkEverySecMin,
          label: '${fx.blinkEverySec} s',
          set: (v) =>
              _draft.setEffects((e) => e.copyWith(blinkEverySec: v.round())),
        ),
        _slider(
          key: 'loud_threshold',
          title: 'Loud above',
          subtitle: shown.hashOf(OverlayLookState.loud).isEmpty
              ? 'Shows the loud image instead of the talking one when the '
                  'voice gets this loud. Add a loud image to use it.'
              : 'Shows the loud image instead of the talking one when the '
                  'voice gets this loud.',
          value: fx.loudThreshold!,
          min: OverlayEffects.loudThresholdMin,
          max: OverlayEffects.loudThresholdMax,
          divisions: 9,
          label: '${(fx.loudThreshold! * 100).round()}%',
          set: (v) => _draft.setEffects((e) =>
              e.copyWith(loudThreshold: (v * 100).roundToDouble() / 100)),
        ),
        _switch(
          key: 'mirror',
          title: 'Mirror',
          subtitle: 'Flips every image left to right.',
          value: fx.mirror!,
          set: (v) => _draft.setEffects((e) => e.copyWith(mirror: v)),
        ),
        _choice(
          key: 'shadow',
          title: 'Shadow',
          value: fx.shadow!,
          options: const [
            ('none', 'None'),
            ('soft', 'Soft'),
            ('outline', 'Outline'),
          ],
          subtitle: switch (fx.shadow) {
            'soft' => 'A soft shadow under the image, so it stands off the '
                'stream behind it.',
            'outline' => 'An outline in $pronoun name colour around the '
                'image.',
            _ => 'No shadow or outline.',
          },
          set: (v) => _draft.setEffects((e) => e.copyWith(shadow: v)),
        ),
      ],
    );
  }

  /// LOCAL mode's mark beside a row's title: "Not overridden", or a Reset.
  Widget? _overrideMark(String key) {
    if (!_local) return null;
    if (!_draft.overrides(key)) return const HollowBadge('Not overridden');
    return HollowButton.ghost(
      compact: true,
      touch: _touch,
      onPressed: () {
        _draft.resetEffect(key);
        _commit();
      },
      child: const Text('Reset'),
    );
  }

  Widget _choice({
    required String key,
    required String title,
    required String subtitle,
    required String value,
    required List<(String, String)> options,
    required ValueChanged<String> set,
  }) =>
      SettingsChoiceRow<String>(
        title: title,
        subtitle: subtitle,
        value: value,
        options: options,
        titleTrailing: _overrideMark(key),
        onChanged: (v) {
          set(v);
          _commit();
        },
      );

  Widget _switch({
    required String key,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> set,
  }) =>
      SettingsSwitchRow(
        title: title,
        subtitle: subtitle,
        value: value,
        titleTrailing: _overrideMark(key),
        onChanged: (v) {
          set(v);
          _commit();
        },
      );

  Widget _slider({
    required String key,
    required String title,
    required String subtitle,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String label,
    required ValueChanged<double> set,
  }) =>
      SettingsSliderRow(
        title: title,
        subtitle: subtitle,
        value: value,
        min: min,
        max: max,
        divisions: divisions,
        valueLabel: label,
        titleTrailing: _overrideMark(key),
        onChanged: set,
        onChangeEnd: (_) => _commit(),
      );
}

/// The six image slots with a line on what they take.
class _Slots extends StatelessWidget {
  final OverlayLookDraft draft;
  final Set<OverlayLookState> busy;
  final void Function(OverlayLookState) onPick;
  final void Function(BuildContext, OverlayLookState) onMenu;

  const _Slots({
    required this.draft,
    required this.busy,
    required this.onPick,
    required this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          draft.local
              ? 'Pick an image for any state. Their own images show where '
                  'you pick nothing.'
              : 'One image per state. PNG, JPEG, GIF, WebP or APNG, any '
                  'shape. Animated images move on stream.',
          style: HollowTypography.bodySmall.copyWith(color: hollow.textSecondary),
        ),
        const SizedBox(height: HollowSpacing.md),
        // Three across: the talking group above, the quiet extras below.
        SizedBox(
          width: _SlotTile._width * 3 + HollowSpacing.sm * 2,
          child: Wrap(
            spacing: HollowSpacing.sm,
            runSpacing: HollowSpacing.md,
            children: [
              for (final s in kOverlaySlotOrder)
                _SlotTile(
                  state: s,
                  draft: draft,
                  busy: busy.contains(s),
                  onPick: () => onPick(s),
                  onMenu: (ctx) => onMenu(ctx, s),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SlotTile extends ConsumerWidget {
  final OverlayLookState state;
  final OverlayLookDraft draft;
  final bool busy;
  final VoidCallback onPick;
  final void Function(BuildContext) onMenu;

  const _SlotTile({
    required this.state,
    required this.draft,
    required this.busy,
    required this.onPick,
    required this.onMenu,
  });

  static const double _thumb = 72;
  static const double _width = 88;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final mine = draft.hasOwnImage(state);
    final theirs = draft.theirs?.hashOf(state) ?? '';
    final hash = draft.shown.hashOf(state);
    final label = overlayStateLabel(state);
    // A filled slot of our own says nothing; the hint is for what stands in.
    final hint = mine
        ? (draft.local ? 'My pick' : '')
        : (draft.local && theirs.isNotEmpty ? 'Theirs' : _fallbackHint(state));

    Widget thumb;
    if (busy) {
      thumb = const Center(child: HollowSpinner());
    } else if (hash.isEmpty) {
      thumb = Center(
        child: Icon(LucideIcons.imagePlus, size: 20, color: hollow.textTertiary),
      );
    } else {
      final bytes = ref.watch(overlayImageBytesProvider(hash)).valueOrNull;
      thumb = bytes == null
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.all(HollowSpacing.xs),
              child: AnimatedGifImage(
                bytes: bytes,
                width: _thumb,
                height: _thumb,
                fit: BoxFit.contain,
              ),
            );
    }

    return SizedBox(
      width: _width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Builder(
            builder: (slotContext) => HollowPressable(
              onTap: busy
                  ? null
                  : (mine ? () => onMenu(slotContext) : onPick),
              semanticLabel: mine
                  ? '$label image. Change or remove'
                  : 'Pick the $label image',
              backgroundColor: hollow.elevated,
              borderRadius: BorderRadius.circular(hollow.radiusMd),
              child: SizedBox(width: _width, height: _thumb, child: thumb),
            ),
          ),
          const SizedBox(height: HollowSpacing.xs),
          Text(label,
              style: HollowTypography.label.copyWith(color: hollow.textPrimary)),
          if (hint.isNotEmpty)
            Text(
            hint,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: HollowTypography.caption.copyWith(color: hollow.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// The live stage and the buttons that drive it.
class _PreviewPanel extends ConsumerStatefulWidget {
  final OverlayLook look;
  final String master;
  final String name;
  final Color colour;
  final bool hasAvatar;
  final bool followLiveMic;

  const _PreviewPanel({
    required this.look,
    required this.master,
    required this.name,
    required this.colour,
    required this.hasAvatar,
    required this.followLiveMic,
  });

  @override
  ConsumerState<_PreviewPanel> createState() => _PreviewPanelState();
}

/// The level a held Talk or Loud button stands for: talking sits below the
/// loudest threshold, loud above every one.
const double _talkLevel = 0.45;
const double _loudLevel = 1.0;

/// Shorter than this is a click, which previews a burst of [_kBurst].
const Duration _kClick = Duration(milliseconds: 300);
const Duration _kBurst = Duration(milliseconds: 1500);

const double _stageSize = 160;

/// The page's own margin (`.overlay` padding), so a bounce or a glow is
/// never clipped.
const double _stageMargin = _stageSize * 0.12;

/// Wide enough for the three preview buttons on one line.
const double _panelWidth = 264;

class _PreviewPanelState extends ConsumerState<_PreviewPanel> {
  late final OverlayPreviewEngine _engine =
      OverlayPreviewEngine(look: _previewLook());
  String _base = 'idle';
  String? _holding;
  Timer? _tapRelease;

  /// A pointer press drives the hold itself; its tap must not add a burst.
  bool _pointerPress = false;
  final Stopwatch _pressed = Stopwatch();

  OverlayPreviewLook _previewLook() {
    final l = widget.look;
    final e = l.effects.filled();
    return OverlayPreviewLook(
      states: {for (final s in OverlayLookState.values) s.name: l.hashOf(s)},
      holdMs: e.holdMs!,
      blinkEverySec: e.blinkEverySec!,
      loudThreshold: e.loudThreshold!,
      scaleWithVoice: e.scaleWithVoice!,
      hasAvatar: widget.hasAvatar,
    );
  }

  @override
  void initState() {
    super.initState();
    _push();
  }

  @override
  void didUpdateWidget(_PreviewPanel old) {
    super.didUpdateWidget(old);
    _engine.look = _previewLook();
  }

  @override
  void dispose() {
    _tapRelease?.cancel();
    _engine.dispose();
    super.dispose();
  }

  OverlaySelfLive? get _live =>
      widget.followLiveMic ? ref.read(overlaySelfLiveProvider) : null;

  void _push() {
    final holding = _holding;
    if (holding != null) {
      _engine.update(
          state: 'talking',
          level: holding == 'loud' ? _loudLevel : _talkLevel);
      return;
    }
    final live = _live;
    if (live != null) {
      _engine.update(state: live.state, level: live.level);
      return;
    }
    _engine.update(state: _base, level: 0);
  }

  void _hold(String? what) {
    _tapRelease?.cancel();
    setState(() => _holding = what);
    _push();
  }

  /// A click or a key press has no hold to follow: a short burst instead,
  /// about one spoken word, counted from the press.
  void _burst(String what, {Duration already = Duration.zero}) {
    if (_holding != what) _hold(what);
    _tapRelease?.cancel();
    final left = _kBurst - already;
    _tapRelease = Timer(left.isNegative ? Duration.zero : left, () {
      if (mounted) _hold(null);
    });
  }

  void _release(String what) {
    final held = _pressed.elapsed;
    _pressed.stop();
    if (held < _kClick) {
      _burst(what, already: held);
    } else {
      _hold(null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final touch = SettingsDensity.touchOf(context);
    OverlaySelfLive? live;
    if (widget.followLiveMic) {
      live = ref.watch(overlaySelfLiveProvider);
      ref.listen(overlaySelfLiveProvider, (_, _) => _push());
    }
    final fx = widget.look.effects.filled();
    final hasBlink = widget.look.hashOf(OverlayLookState.blink).isNotEmpty;
    const size = _stageSize;
    final layers = <String>{
      for (final s in OverlayLookState.values)
        if (widget.look.hashOf(s).isNotEmpty) widget.look.hashOf(s),
      if (widget.hasAvatar) kOverlayAvatarLayer,
    };

    final stage = ValueListenableBuilder<OverlayPreviewFrame>(
      valueListenable: _engine,
      builder: (context, frame, _) => OverlayStage(
        size: size,
        frame: frame,
        colour: widget.colour,
        initials: overlayInitials(widget.name),
        layers: layers,
        effects: OverlayStageEffects(
          talking: fx.talking!,
          idle: fx.idle!,
          transition: fx.transition!,
          mirror: fx.mirror!,
          shadow: fx.shadow!,
        ),
        layerBuilder: (key, fit) => key == kOverlayAvatarLayer
            ? FittedBox(
                fit: fit,
                child: HollowAvatar(
                  peerId: widget.master,
                  size: size,
                  animate: true,
                  frameId: '',
                ),
              )
            : _LayerImage(hash: key, fit: fit),
      ),
    );

    Widget holdButton(String what, String label, IconData icon) => Listener(
          onPointerDown: (_) {
            _pointerPress = true;
            _pressed
              ..reset()
              ..start();
            _hold(what);
          },
          onPointerUp: (_) => _release(what),
          onPointerCancel: (_) {
            _pointerPress = false;
            _hold(null);
          },
          child: HollowButton.ghost(
            compact: !touch,
            touch: touch,
            semanticLabel: 'Preview $label. Hold to keep it going',
            onPressed: () {
              if (_pointerPress) {
                _pointerPress = false;
                return;
              }
              _burst(what);
            },
            icon: Icon(icon),
            child: Text(label),
          ),
        );

    return SizedBox(
      width: touch ? null : _panelWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            decoration: BoxDecoration(
              color: hollow.elevated,
              borderRadius: BorderRadius.circular(hollow.radiusLg),
            ),
            padding: const EdgeInsets.all(_stageMargin),
            alignment: Alignment.center,
            child: Semantics(
              label: 'Preview of the overlay',
              child: SizedBox.square(dimension: size, child: stage),
            ),
          ),
          const SizedBox(height: HollowSpacing.md),
          if (live != null)
            _LiveLine(live: live)
          else
            Wrap(
              spacing: HollowSpacing.sm,
              runSpacing: HollowSpacing.sm,
              children: [
                for (final (s, label) in const [
                  ('idle', 'Idle'),
                  ('muted', 'Muted'),
                  ('deafened', 'Deafened'),
                ])
                  HollowChip(
                    label: label,
                    selected: _base == s,
                    onTap: () {
                      setState(() => _base = s);
                      _push();
                    },
                  ),
              ],
            ),
          const SizedBox(height: HollowSpacing.sm),
          Wrap(
            spacing: HollowSpacing.sm,
            runSpacing: HollowSpacing.sm,
            children: [
              holdButton('talk', 'Talk', LucideIcons.mic),
              holdButton('loud', 'Loud', LucideIcons.volume2),
              HollowButton.ghost(
                compact: !touch,
                touch: touch,
                onPressed: hasBlink ? _engine.blinkNow : null,
                icon: const Icon(LucideIcons.eyeClosed),
                child: const Text('Blink'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// "Following your mic" with a level bar, while a voice room, a call or
/// listening drives the preview.
class _LiveLine extends StatelessWidget {
  final OverlaySelfLive live;

  const _LiveLine({required this.live});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final where = switch (live.source) {
      OverlayLiveSource.voiceRoom => 'Following your mic in the voice room',
      OverlayLiveSource.call => 'Following your mic in the call',
      OverlayLiveSource.listening => 'Following your mic',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(where,
            style:
                HollowTypography.bodySmall.copyWith(color: hollow.textSecondary)),
        const SizedBox(height: HollowSpacing.xs),
        OverlayLevelMeter(level: live.level, active: live.state == 'talking'),
      ],
    );
  }
}

/// A thin voice level bar, 0..1; [threshold] marks where talking starts.
class OverlayLevelMeter extends StatelessWidget {
  final double level;
  final bool active;
  final double? threshold;

  const OverlayLevelMeter({
    super.key,
    required this.level,
    required this.active,
    this.threshold,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Semantics(
      label: 'Mic level',
      value: '${(level * 100).round()}%',
      child: SizedBox(
        height: HollowSpacing.sm,
        child: LayoutBuilder(builder: (context, c) {
          final w = c.maxWidth;
          return Stack(
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: hollow.border,
                    borderRadius: BorderRadius.circular(hollow.radiusXs),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: w * level.clamp(0.0, 1.0),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: active ? hollow.success : hollow.textTertiary,
                    borderRadius: BorderRadius.circular(hollow.radiusXs),
                  ),
                ),
              ),
              if (threshold != null)
                Positioned(
                  left: (w * threshold!.clamp(0.0, 1.0)) - 1,
                  top: 0,
                  bottom: 0,
                  width: 2,
                  child: ColoredBox(color: hollow.textPrimary),
                ),
            ],
          );
        }),
      ),
    );
  }
}

/// One look image off the rail; nothing while it loads, so the frame keeps
/// its size.
class _LayerImage extends ConsumerWidget {
  final String hash;
  final BoxFit fit;

  const _LayerImage({required this.hash, required this.fit});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = ref.watch(overlayImageBytesProvider(hash)).valueOrNull;
    if (bytes == null) return const SizedBox.expand();
    return AnimatedGifImage(bytes: bytes, fit: fit);
  }
}
