import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/recording_provider.dart';
import 'package:hollow/src/core/providers/settings_place_provider.dart';
import 'package:hollow/src/core/services/macos_version.dart';
import 'package:hollow/src/theme/hollow_shadows.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/call/call_stage_data.dart';
import 'package:hollow/src/ui/call/call_theme.dart';
import 'package:hollow/src/ui/components/call_duration_text.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:hollow/src/ui/components/ptt_mic_visual.dart';
import 'package:hollow/src/ui/components/recording_indicator.dart';
import 'package:hollow/src/ui/components/share_volume_control.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Everything the bar needs from a call: its state and what each control does.
class CallBarModel {
  /// Null while the call is still connecting.
  final DateTime? startedAt;
  final bool muted;
  final bool deafened;
  final VoidCallback onMute;
  final VoidCallback onDeafen;
  final bool cameraOn;
  final VoidCallback? onCamera;
  final bool sharing;

  /// Null hides Share (a platform with no capture).
  final VoidCallback? onShare;
  final CallLayoutAction? layout;
  final VoidCallback? onLayout;
  final bool fullscreen;

  /// Null hides Full screen (a platform with no window to fill).
  final VoidCallback? onFullscreen;

  /// Receiving a share, so More offers its audio volume.
  final bool watching;
  final String leaveLabel;
  final VoidCallback onLeave;

  const CallBarModel({
    required this.startedAt,
    required this.muted,
    required this.deafened,
    required this.onMute,
    required this.onDeafen,
    required this.cameraOn,
    required this.onCamera,
    required this.sharing,
    required this.onShare,
    required this.layout,
    required this.onLayout,
    required this.fullscreen,
    required this.onFullscreen,
    required this.watching,
    required this.leaveLabel,
    required this.onLeave,
  });
}

/// THE control bar of a call (D9): timer, mute and deafen, camera and share,
/// layout, full screen and More, then one red Leave. The same widget on a DM
/// stage, a voice room and a meeting. It never hides itself; only the
/// fullscreen stage fades it.
class CallStageBar extends ConsumerWidget {
  final CallBarModel model;

  const CallStageBar({super.key, required this.model});

  static bool get recorderAvailable => Platform.isWindows || Platform.isMacOS;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final m = model;
    final rec = ref.watch(recordingProvider);
    Widget button({
      required IconData icon,
      required String label,
      required VoidCallback? onPressed,
      bool on = false,
      bool alarm = false,
      Color? color,
      String? tooltip,
    }) =>
        CallToggleButton(
          icon: icon,
          label: label,
          tooltip: tooltip,
          on: on,
          alarm: alarm,
          color: color,
          onPressed: onPressed,
        );

    final layout = m.layout;
    final groups = <List<Widget>>[
      [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.sm),
          child: m.startedAt == null
              ? Text('Connecting',
                  style: HollowTypography.label
                      .copyWith(color: hollow.textSecondary))
              : CallDurationText(
                  startedAt: m.startedAt!,
                  style: HollowTypography.mono.copyWith(
                    color: hollow.textSecondary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
        ),
        if (rec.isMyRecording)
          RecordingIndicator(startedAt: rec.myStartedAt)
        else if (rec.remoteRecorders.isNotEmpty)
          const RecordingIndicator(),
      ],
      [
        CallMuteButton(muted: m.muted, onPressed: m.onMute),
        button(
          icon: m.deafened ? LucideIcons.headphoneOff : LucideIcons.headphones,
          label: m.deafened ? 'Undeafen' : 'Deafen',
          alarm: m.deafened,
          onPressed: m.onDeafen,
        ),
      ],
      [
        button(
          icon: m.cameraOn ? LucideIcons.video : LucideIcons.videoOff,
          label: m.cameraOn ? 'Turn off camera' : 'Turn on camera',
          on: m.cameraOn,
          onPressed: m.onCamera,
        ),
        if (m.onShare != null)
          button(
            icon: m.sharing ? LucideIcons.monitorOff : LucideIcons.monitorUp,
            label: m.sharing ? 'Stop sharing' : 'Share your screen',
            on: m.sharing,
            onPressed: m.onShare,
          ),
      ],
      [
        if (layout != null)
          button(
            icon: switch (layout) {
              CallLayoutAction.showEveryone => LucideIcons.layoutGrid,
              CallLayoutAction.focusScreen => LucideIcons.monitor,
              CallLayoutAction.backToChat => LucideIcons.minimize2,
            },
            label: callLayoutLabel(layout),
            onPressed: m.onLayout,
          ),
        if (m.onFullscreen != null)
          button(
            icon: m.fullscreen ? LucideIcons.minimize : LucideIcons.maximize,
            label: m.fullscreen ? 'Exit full screen' : 'Full screen',
            onPressed: m.onFullscreen,
          ),
        Builder(
          builder: (buttonContext) => button(
            icon: LucideIcons.ellipsis,
            label: 'More',
            onPressed: () => _openMore(buttonContext, ref),
          ),
        ),
      ],
      [
        CallLeaveButton(label: m.leaveLabel, onPressed: m.onLeave),
      ],
    ];

    final row = <Widget>[];
    for (final group in groups) {
      if (group.isEmpty) continue;
      if (row.isNotEmpty) {
        row.add(const Padding(
          padding: EdgeInsets.symmetric(horizontal: HollowSpacing.xs),
          child: SizedBox(
            height: HollowSpacing.xl,
            child: HollowVerticalDivider(),
          ),
        ));
      }
      for (var i = 0; i < group.length; i++) {
        if (i > 0) row.add(const SizedBox(width: HollowSpacing.xs));
        row.add(group[i]);
      }
    }

    return Semantics(
      container: true,
      label: 'Call controls',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: hollow.overlay,
          borderRadius: BorderRadius.circular(hollow.radiusLg),
          border: Border.all(color: hollow.border),
          boxShadow: HollowShadows.float,
        ),
        child: Padding(
          padding: const EdgeInsets.all(HollowSpacing.xs),
          child: Row(mainAxisSize: MainAxisSize.min, children: row),
        ),
      ),
    );
  }

  void _openMore(BuildContext buttonContext, WidgetRef ref) {
    final box = buttonContext.findRenderObject() as RenderBox?;
    showHollowMenu(
      context: buttonContext,
      anchor: overlayAnchorOf(buttonContext,
          localOffset: Offset(box?.size.width ?? 0, 0)),
      alignEnd: true,
      builder: (_, menuRef) {
        final rec = menuRef.watch(recordingProvider);
        final blocked = MacOsScreenAudioSupport.recordBlockedByOldOs;
        return [
          if (recorderAvailable)
            HollowMenuItem(
              icon: rec.isMyRecording ? LucideIcons.circleStop : LucideIcons.circle,
              label: rec.isMyRecording ? 'Stop recording' : 'Record the call',
              enabled: !blocked,
              trailing: blocked ? 'Needs macOS 13' : null,
              onTap: () {
                final notifier = ref.read(recordingProvider.notifier);
                rec.isMyRecording
                    ? notifier.stopRecording()
                    : notifier.startRecording();
              },
            ),
          if (model.watching) ...[
            const HollowMenuDivider(),
            const HollowMenuCustom(ShareVolumePanel()),
            const HollowMenuDivider(),
          ],
          HollowMenuItem(
            icon: LucideIcons.settings2,
            label: 'Audio and video settings',
            onTap: () =>
                openSettings(ref.read, category: SettingsCategory.audio),
          ),
        ];
      },
    );
  }
}

/// One call control: grey at rest, a grey fill while on (camera, sharing),
/// and the error wash only for muted or deafened.
class CallToggleButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool on;
  final bool alarm;
  final Color? color;
  final String? tooltip;
  final double size;

  const CallToggleButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.on = false,
    this.alarm = false,
    this.color,
    this.tooltip,
    this.size = CallMetrics.barButton,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowIconButton(
      icon: icon,
      label: label,
      tooltip: tooltip,
      size: size,
      selected: on,
      fill: alarm ? hollow.error.withValues(alpha: 0.14) : null,
      color: alarm ? hollow.error : color,
      onPressed: onPressed,
    );
  }
}

/// The mic control, push-to-talk aware (issue #38): gated while PTT idles,
/// live while the key is held, the red crossed mic while muted.
class CallMuteButton extends ConsumerWidget {
  final bool muted;
  final VoidCallback? onPressed;
  final double size;

  const CallMuteButton({
    super.key,
    required this.muted,
    required this.onPressed,
    this.size = CallMetrics.barButton,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final mic = micButtonVisual(ref,
        isMuted: muted, hollow: hollow, idleColor: hollow.textSecondary);
    return CallToggleButton(
      icon: mic.icon,
      label: muted ? 'Unmute' : 'Mute',
      tooltip: mic.tooltip,
      color: muted ? null : mic.color,
      alarm: muted,
      size: size,
      onPressed: onPressed,
    );
  }
}

/// The bar's layout slot, in words.
String callLayoutLabel(CallLayoutAction action) => switch (action) {
      CallLayoutAction.showEveryone => 'Show everyone',
      CallLayoutAction.focusScreen => 'Focus the screen',
      CallLayoutAction.backToChat => 'Back to the chat',
    };

/// Leave: the one filled danger control of a call, red with a white handset.
class CallLeaveButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final double width;
  final double height;

  const CallLeaveButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.width = CallMetrics.leaveWidth,
    this.height = CallMetrics.barButton,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowTooltip(
      message: label,
      child: HollowPressable(
        onTap: onPressed,
        semanticLabel: label,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        backgroundColor: hollow.errorFill,
        child: SizedBox(
          width: width,
          height: height,
          child: Icon(LucideIcons.phoneOff,
              size: 20, color: hollow.textOnError),
        ),
      ),
    );
  }
}
