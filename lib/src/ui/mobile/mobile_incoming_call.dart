import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/color_utils.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/app.dart' show hollowNavigatorKey;
import 'package:hollow/src/ui/call/call_ringtone.dart';
import 'package:hollow/src/ui/call/call_stage_sources.dart' show dmCallPeerName;
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/mobile/mobile_call_chrome.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The phone's incoming call: the whole screen, the caller large in their
/// colour, a red Decline and a teal Accept. Accept opens the call screen.
///
/// Mounted above the app's navigator (`app.dart`), so it reaches the call
/// screen through [hollowNavigatorKey].
class MobileIncomingCallOverlay extends ConsumerStatefulWidget {
  /// Where Accept opens the call; the app's navigator unless a test says.
  final GlobalKey<NavigatorState>? navigatorKey;

  const MobileIncomingCallOverlay({super.key, this.navigatorKey});

  @override
  ConsumerState<MobileIncomingCallOverlay> createState() =>
      _MobileIncomingCallOverlayState();
}

class _MobileIncomingCallOverlayState
    extends ConsumerState<MobileIncomingCallOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this);
  late final Animation<double> _fade = CurvedAnimation(
      parent: _controller,
      curve: HollowCurves.enter,
      reverseCurve: HollowCurves.exit);
  final _ringtone = CallRingtone();
  bool _wasVisible = false;

  // Cached so the screen does not go blank during its exit.
  String _master = '';
  String _name = '';
  bool _video = false;
  String? _leavesRoom;

  @override
  void dispose() {
    _ringtone.stop();
    _controller.dispose();
    super.dispose();
  }

  void _accept() {
    final master = _master;
    ref.read(callProvider.notifier).acceptCall().catchError((Object _) {
      if (mounted) {
        HollowToast.show(context, "Couldn't answer the call",
            type: HollowToastType.error);
      }
    });
    final nav = (widget.navigatorKey ?? hollowNavigatorKey).currentState;
    if (nav != null && master.isNotEmpty) openMobileDmCall(nav, master);
  }

  void _decline() {
    ref.read(callProvider.notifier).rejectCall().catchError((Object _) {});
  }

  @override
  Widget build(BuildContext context) {
    final call = ref.watch(callProvider);
    final visible = call.status == CallStatus.ringing &&
        call.direction == CallDirection.incoming;

    if (visible) {
      // The invite carries the caller's DEVICE; names and colours are the
      // person's.
      _master = ref.watch(deviceLinkProvider).identityOf(call.peerId ?? '');
      _name = dmCallPeerName(ref, _master);
      _video = call.isVideoCall;
      // Answering leaves the voice room (issue #49), so it says so.
      final vc = ref.watch(voiceChannelProvider);
      _leavesRoom =
          vc.isInVoiceChannel ? (vc.currentChannelName ?? 'voice') : null;
    }

    if (visible && !_wasVisible) {
      _controller.duration = HollowDurations.normal;
      _controller.forward(from: 0);
      _ringtone.start(ref, stillRinging: () => mounted && _wasVisible);
    } else if (!visible && _wasVisible) {
      _controller.reverseDuration = HollowDurations.fast;
      _controller.reverse();
      _ringtone.stop();
    }
    _wasVisible = visible;

    if (!visible && !_controller.isAnimating) return const SizedBox.shrink();

    final hollow = HollowTheme.of(context);
    final kind = _video ? 'Video call' : 'Voice call';
    return Positioned.fill(
      child: FadeTransition(
        opacity: _fade,
        child: IgnorePointer(
          ignoring: !visible,
          // Above the navigator, outside any Scaffold: it brings its own
          // canvas and text defaults.
          child: ColoredBox(
            color: hollow.background,
            child: DefaultTextStyle(
              style: HollowTypography.body.copyWith(color: hollow.textPrimary),
              child: SafeArea(
                child: Semantics(
                  container: true,
                  liveRegion: true,
                  label: '$kind from $_name',
                  child: Column(
                    children: [
                      Expanded(
                        child: Center(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.symmetric(
                                horizontal: HollowSpacing.xl),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Their frame stays: a ring has no speaking
                                // cue to be mistaken for.
                                HollowAvatar(
                                  peerId: _master,
                                  size: MobileCallMetrics.incomingAvatar,
                                ),
                                const SizedBox(height: HollowSpacing.lg),
                                Text(
                                  _name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: HollowTypography.display.copyWith(
                                      color: nameColorFor(_master, hollow)),
                                ),
                                const SizedBox(height: HollowSpacing.xs),
                                Text(
                                  kind,
                                  style: HollowTypography.bodyTouch
                                      .copyWith(color: hollow.textSecondary),
                                ),
                                if (_leavesRoom != null) ...[
                                  const SizedBox(height: HollowSpacing.sm),
                                  Text(
                                    'Answering will leave #$_leavesRoom',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                    style: HollowTypography.bodySmall
                                        .copyWith(color: hollow.warning),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          HollowSpacing.xxl,
                          0,
                          HollowSpacing.xxl,
                          HollowSpacing.xxl * 2,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            _AnswerButton(
                              icon: LucideIcons.phoneOff,
                              label: 'Decline',
                              fill: hollow.error,
                              ink: hollow.textOnError,
                              onTap: _decline,
                            ),
                            _AnswerButton(
                              icon: _video
                                  ? LucideIcons.video
                                  : LucideIcons.phone,
                              label: 'Accept',
                              fill: hollow.accent,
                              ink: hollow.textOnAccent,
                              onTap: _accept,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One of the two answers: a 72 round button, its word under it.
class _AnswerButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color fill;
  final Color ink;
  final VoidCallback onTap;

  const _AnswerButton({
    required this.icon,
    required this.label,
    required this.fill,
    required this.ink,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        HollowPressable(
          onTap: onTap,
          semanticLabel: label,
          borderRadius:
              BorderRadius.circular(MobileCallMetrics.incomingButton / 2),
          backgroundColor: fill,
          child: SizedBox.square(
            dimension: MobileCallMetrics.incomingButton,
            child: Icon(icon, size: 24, color: ink),
          ),
        ),
        const SizedBox(height: HollowSpacing.sm),
        ExcludeSemantics(
          child: Text(label,
              style:
                  HollowTypography.label.copyWith(color: hollow.textSecondary)),
        ),
      ],
    );
  }
}
