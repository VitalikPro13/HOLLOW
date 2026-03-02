import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/core/providers/channel_provider.dart';
import 'package:haven/src/core/providers/server_provider.dart';
import 'package:haven/src/theme/haven_spacing.dart';
import 'package:haven/src/theme/haven_theme.dart';
import 'package:haven/src/ui/animations/haven_curves.dart';
import 'package:haven/src/ui/components/haven_tooltip.dart';
import 'package:haven/src/ui/dialogs/create_server_dialog.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Vertical server icon strip (72px wide) — like Discord's left column.
///
/// Shows the Haven home icon, server icons from [serverListProvider],
/// and an "add server" button at the bottom.
class ServerStrip extends ConsumerStatefulWidget {
  const ServerStrip({super.key});

  @override
  ConsumerState<ServerStrip> createState() => _ServerStripState();
}

class _ServerStripState extends ConsumerState<ServerStrip> {
  /// Tracks server IDs that existed on first build — these skip the
  /// entrance animation so the strip doesn't bounce on app startup.
  Set<String>? _initialServerIds;

  @override
  Widget build(BuildContext context) {
    final haven = HavenTheme.of(context);
    final servers = ref.watch(serverListProvider);
    final selectedServerId = ref.watch(selectedServerProvider);

    // Capture initial server IDs on first build.
    _initialServerIds ??= servers.keys.toSet();

    final serverEntries = servers.values.toList();

    return Container(
      width: 72,
      decoration: BoxDecoration(
        color: haven.background,
        border: Border(
          right: BorderSide(color: haven.border),
        ),
      ),
      child: Column(
        children: [
          const SizedBox(height: HavenSpacing.md),

          // Haven home button
          _ServerIconWithIndicator(
            isSelected: selectedServerId == null,
            child: _ServerIcon(
              isSelected: selectedServerId == null,
              backgroundColor: haven.accent,
              onTap: () {
                ref.read(selectedServerProvider.notifier).state = null;
                ref.read(channelListProvider.notifier).clear();
                ref.read(selectedChannelProvider.notifier).state = null;
              },
              child: Text(
                'H',
                style: TextStyle(
                  color: haven.textOnAccent,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),

          const SizedBox(height: HavenSpacing.sm),

          // Short divider
          Container(
            width: 32,
            height: 2,
            decoration: BoxDecoration(
              color: haven.border,
              borderRadius: BorderRadius.circular(1),
            ),
          ),

          const SizedBox(height: HavenSpacing.sm),

          // Server icon list
          Expanded(
            child: ListView.builder(
              itemCount: serverEntries.length,
              padding: const EdgeInsets.symmetric(vertical: HavenSpacing.xs),
              itemBuilder: (context, index) {
                final server = serverEntries[index];
                final isSelected = server.serverId == selectedServerId;
                final isNew =
                    !_initialServerIds!.contains(server.serverId);

                Widget icon = _ServerIconWithIndicator(
                  isSelected: isSelected,
                  child: _ServerIcon(
                    isSelected: isSelected,
                    backgroundColor: _colorFromId(server.serverId),
                    tooltip: server.name,
                    onTap: () {
                      ref.read(selectedServerProvider.notifier).state =
                          server.serverId;
                      ref
                          .read(channelListProvider.notifier)
                          .loadForServer(server.serverId);
                      // Clear peer selection when entering server view.
                      ref.read(selectedChannelProvider.notifier).state =
                          null;
                    },
                    child: Text(
                      _initialsFromName(server.name),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                );

                // Animate new servers with scale-bounce.
                if (isNew) {
                  icon = _ScaleBounceEntry(
                    key: ValueKey('bounce-${server.serverId}'),
                    child: icon,
                  );
                }

                return Padding(
                  padding: const EdgeInsets.only(bottom: HavenSpacing.sm),
                  child: icon,
                );
              },
            ),
          ),

          // Add server button
          Padding(
            padding: const EdgeInsets.only(bottom: HavenSpacing.md),
            child: _ServerIcon(
              backgroundColor: haven.elevated,
              tooltip: 'Create a server',
              onTap: () => showCreateServerDialog(context),
              child: Icon(
                LucideIcons.plus,
                color: haven.accent,
                size: 24,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Deterministic color from an ID string (same logic as HavenAvatar).
Color _colorFromId(String id) {
  final hash = id.hashCode;
  final hue = (hash % 360).abs().toDouble();
  return HSLColor.fromAHSL(1.0, hue, 0.5, 0.45).toColor();
}

/// Extract 1–2 letter initials from a server name.
String _initialsFromName(String name) {
  final words = name.trim().split(RegExp(r'\s+'));
  if (words.length >= 2) {
    return '${words[0][0]}${words[1][0]}'.toUpperCase();
  }
  return name.substring(0, name.length.clamp(0, 2)).toUpperCase();
}

/// Wraps a server icon with a Discord-style left-edge selection indicator.
class _ServerIconWithIndicator extends StatefulWidget {
  final bool isSelected;
  final Widget child;

  const _ServerIconWithIndicator({
    required this.isSelected,
    required this.child,
  });

  @override
  State<_ServerIconWithIndicator> createState() =>
      _ServerIconWithIndicatorState();
}

class _ServerIconWithIndicatorState
    extends State<_ServerIconWithIndicator> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final haven = HavenTheme.of(context);

    // Indicator height: selected=36, hovering=20, default=0.
    final indicatorHeight =
        widget.isSelected ? 36.0 : (_hovering ? 20.0 : 0.0);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: SizedBox(
        width: 72,
        height: 48,
        child: Row(
          children: [
            // Left-edge pill indicator
            AnimatedContainer(
              duration: HavenDurations.fast,
              curve: HavenCurves.enter,
              width: 3,
              height: indicatorHeight,
              decoration: BoxDecoration(
                color: haven.textPrimary,
                borderRadius: const BorderRadius.only(
                  topRight: Radius.circular(4),
                  bottomRight: Radius.circular(4),
                ),
              ),
            ),
            const Spacer(),
            widget.child,
            const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }
}

/// A single icon in the server strip.
/// Rounded square by default, animates to pill shape on hover or when selected.
class _ServerIcon extends StatefulWidget {
  final Widget child;
  final Color backgroundColor;
  final VoidCallback? onTap;
  final String? tooltip;
  final bool isSelected;

  const _ServerIcon({
    required this.child,
    required this.backgroundColor,
    this.onTap,
    this.tooltip,
    this.isSelected = false,
  });

  @override
  State<_ServerIcon> createState() => _ServerIconState();
}

class _ServerIconState extends State<_ServerIcon> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final haven = HavenTheme.of(context);

    // Stay pill-shaped when selected or hovering.
    final radius =
        (_hovering || widget.isSelected) ? 16.0 : haven.radiusLg;

    // Hover brightens the background slightly.
    final effectiveBg = _hovering && !widget.isSelected
        ? Color.lerp(widget.backgroundColor, haven.accent, 0.15)!
        : widget.backgroundColor;

    Widget icon = MouseRegion(
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOutCubic,
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: effectiveBg,
            borderRadius: BorderRadius.circular(radius),
            border: widget.isSelected
                ? Border.all(
                    color: haven.accent.withValues(alpha: 0.6),
                    width: 2,
                  )
                : null,
          ),
          alignment: Alignment.center,
          child: widget.child,
        ),
      ),
    );

    if (widget.tooltip != null) {
      icon = HavenTooltip(message: widget.tooltip!, child: icon);
    }

    return icon;
  }
}

/// Plays a scale-bounce animation when first built.
/// Used for newly created server icons.
class _ScaleBounceEntry extends StatefulWidget {
  final Widget child;

  const _ScaleBounceEntry({super.key, required this.child});

  @override
  State<_ScaleBounceEntry> createState() => _ScaleBounceEntryState();
}

class _ScaleBounceEntryState extends State<_ScaleBounceEntry>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _scale = TweenSequence<double>([
      TweenSequenceItem(
          tween: Tween(begin: 0.0, end: 1.1), weight: 60),
      TweenSequenceItem(
          tween: Tween(begin: 1.1, end: 0.95), weight: 20),
      TweenSequenceItem(
          tween: Tween(begin: 0.95, end: 1.0), weight: 20),
    ]).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    ));
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(scale: _scale, child: widget.child);
  }
}
