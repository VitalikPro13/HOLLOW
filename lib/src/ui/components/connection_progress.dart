import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Connection stage for the progress indicator.
enum ConnectionStage {
  /// No peers online yet.
  connecting,

  /// Peer(s) online, encryption handshake in progress.
  encrypting,

  /// Fully encrypted session established.
  encrypted,
}

/// Animated connection progress bar that shows:
/// Connecting... → Encrypting... → fade to lock + "Encrypted"
///
/// Progress: connecting = 33%, encrypting = 66%, encrypted = 100% then fade.
class ConnectionProgress extends StatefulWidget {
  final ConnectionStage stage;
  /// Optional detail text override (e.g., "Connecting via relay...").
  final String? detail;

  const ConnectionProgress({super.key, required this.stage, this.detail});

  @override
  State<ConnectionProgress> createState() => _ConnectionProgressState();
}

class _ConnectionProgressState extends State<ConnectionProgress>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late Animation<double> _progress;
  late Animation<double> _barOpacity;

  ConnectionStage _prevStage = ConnectionStage.connecting;
  bool _showEncrypted = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _progress = Tween<double>(begin: 0.0, end: _targetProgress(widget.stage))
        .animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    ));
    _barOpacity = Tween<double>(begin: 1.0, end: 1.0).animate(_controller);

    if (widget.stage == ConnectionStage.encrypted) {
      _showEncrypted = true;
      _controller.value = 1.0;
    } else {
      _controller.forward();
    }
  }

  double _targetProgress(ConnectionStage stage) {
    switch (stage) {
      case ConnectionStage.connecting:
        return 0.33;
      case ConnectionStage.encrypting:
        return 0.66;
      case ConnectionStage.encrypted:
        return 1.0;
    }
  }

  @override
  void didUpdateWidget(ConnectionProgress oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.stage != oldWidget.stage) {
      _prevStage = oldWidget.stage;
      final target = _targetProgress(widget.stage);

      if (widget.stage == ConnectionStage.encrypted) {
        // Animate to 100%, then after a brief hold, fade out and show encrypted.
        _progress = Tween<double>(
          begin: _targetProgress(_prevStage),
          end: 1.0,
        ).animate(CurvedAnimation(
          parent: _controller,
          curve: const Interval(0.0, 0.6, curve: Curves.easeOutCubic),
        ));
        _barOpacity = Tween<double>(begin: 1.0, end: 0.0).animate(
          CurvedAnimation(
            parent: _controller,
            curve: const Interval(0.7, 1.0, curve: Curves.easeOut),
          ),
        );
        _controller.reset();
        _controller.forward().then((_) {
          if (mounted) setState(() => _showEncrypted = true);
        });
      } else {
        // Animate progress bar to new stage.
        _progress = Tween<double>(
          begin: _targetProgress(_prevStage),
          end: target,
        ).animate(CurvedAnimation(
          parent: _controller,
          curve: Curves.easeOutCubic,
        ));
        _barOpacity = Tween<double>(begin: 1.0, end: 1.0).animate(_controller);
        _showEncrypted = false;
        _controller.reset();
        _controller.forward();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    if (_showEncrypted) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.lock, size: 14, color: hollow.success),
          const SizedBox(width: HollowSpacing.xs),
          Text(
            'Encrypted',
            style: HollowTypography.caption.copyWith(color: hollow.success),
          ),
        ],
      );
    }

    final String label;
    final Color labelColor;
    switch (widget.stage) {
      case ConnectionStage.connecting:
        label = widget.detail ?? 'Offline';
        labelColor = hollow.textSecondary;
      case ConnectionStage.encrypting:
        label = widget.detail ?? 'Encrypting...';
        labelColor = hollow.accent;
      case ConnectionStage.encrypted:
        label = widget.detail ?? 'Encrypted';
        labelColor = hollow.success;
    }

    return FadeTransition(
      opacity: _barOpacity,
      child: AnimatedBuilder(
        animation: _progress,
        builder: (context, _) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Progress bar
              SizedBox(
                width: 48,
                height: 3,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: Stack(
                    children: [
                      // Background track
                      Container(color: hollow.border),
                      // Filled portion
                      FractionallySizedBox(
                        widthFactor: _progress.value,
                        child: Container(
                          decoration: BoxDecoration(
                            color: widget.stage == ConnectionStage.connecting
                                ? hollow.textSecondary
                                : hollow.accent,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: HollowSpacing.xs),
              Text(
                label,
                style: HollowTypography.caption.copyWith(color: labelColor),
              ),
            ],
          );
        },
      ),
    );
  }
}
