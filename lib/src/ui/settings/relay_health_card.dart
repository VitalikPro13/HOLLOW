import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/relay_stats_provider.dart';
import 'package:hollow/src/core/reduce_motion.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/stat_bar.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:hollow/src/ui/shell/system_status_banner.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Settings > Network: the service notice and the relay's live load.
class RelayHealthCard extends StatelessWidget {
  const RelayHealthCard({super.key});

  @override
  Widget build(BuildContext context) {
    return const SettingsCard(
      title: 'Relay Health',
      children: [
        HomeStatusCard(),
        SizedBox(height: HollowSpacing.md),
        RelayLoadBars(),
      ],
    );
  }
}

/// The relay's live RAM and bandwidth, the poll sweep, and who is on it.
///
/// Shared by Home's relay card and Settings > Network. Watching
/// [relayStatsProvider] is what runs its 7 s poll, so it polls only while one
/// of them is on screen.
class RelayLoadBars extends ConsumerStatefulWidget {
  const RelayLoadBars({super.key});

  @override
  ConsumerState<RelayLoadBars> createState() => _RelayLoadBarsState();
}

class _RelayLoadBarsState extends ConsumerState<RelayLoadBars> {
  /// Progress of the poll-cycle sweep, 0..1.
  ///
  /// A [Timer] and a [ValueNotifier], never an [AnimationController]: one
  /// restarted as often as its own duration never stops its Ticker
  /// (feedback_ticker_is_a_frame_request). One step per second, which also
  /// reads as the countdown to the next poll.
  final ValueNotifier<double> _sweep = ValueNotifier<double>(0);
  final Stopwatch _since = Stopwatch();
  Timer? _timer;
  int _lastFetchCount = 0;

  /// Matched to the 7s stats poll in `relay_stats_provider.dart`.
  static const _sweepStep = Duration(seconds: 1);
  static const _sweepSteps = 7;

  @override
  void initState() {
    super.initState();
    _restartSweep();
  }

  void _restartSweep() {
    _timer?.cancel();
    if (ReduceMotionController.instance.isReduced) {
      _sweep.value = 1.0;
      return;
    }
    _sweep.value = 0;
    _since
      ..reset()
      ..start();
    _timer = Timer.periodic(_sweepStep, (t) {
      final step = (_since.elapsedMilliseconds / _sweepStep.inMilliseconds)
          .floor()
          .clamp(0, _sweepSteps);
      _sweep.value = step / _sweepSteps;
      if (step >= _sweepSteps) {
        t.cancel();
        _timer = null;
        _since.stop();
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final stats = ref.watch(relayStatsProvider);
    if (stats.fetchCount != _lastFetchCount) {
      _lastFetchCount = stats.fetchCount;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _restartSweep();
      });
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StatBar(
          hollow: hollow,
          icon: LucideIcons.memoryStick,
          label: 'RAM',
          value: stats.memLabel,
          progress: stats.memUsagePercent,
        ),
        const SizedBox(height: HollowSpacing.sm),
        StatBar(
          hollow: hollow,
          icon: LucideIcons.activity,
          label: 'Bandwidth',
          value: stats.bandwidthLabel,
          progress: stats.bandwidthUsagePercent,
        ),
        const SizedBox(height: HollowSpacing.sm),
        RepaintBoundary(
          child: ValueListenableBuilder<double>(
            valueListenable: _sweep,
            builder: (context, sweep, _) => ClipRRect(
              borderRadius: BorderRadius.circular(hollow.radiusXs),
              child: SizedBox(
                height: HollowSpacing.xxs,
                child: LinearProgressIndicator(
                  value: sweep,
                  backgroundColor: hollow.border,
                  valueColor: AlwaysStoppedAnimation<Color>(hollow.accentMuted),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: HollowSpacing.sm),
        // A third stat in the bars' own row style: inside a card titled Relay,
        // "Online" already means on this relay.
        Row(
          children: [
            Icon(LucideIcons.users, size: 12, color: hollow.textSecondary),
            const SizedBox(width: HollowSpacing.xs),
            Expanded(
              child: Text(
                'Online',
                style: HollowTypography.micro
                    .copyWith(color: hollow.textSecondary),
              ),
            ),
            Text(
              '${stats.onlineUsers}',
              style: HollowTypography.micro.copyWith(
                color: hollow.textPrimary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ],
    );
  }
}
