import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/profile_card_body.dart';
import 'package:hollow/src/ui/dialogs/profile_dialog.dart';

// showLocalNicknameDialog historically lived here; it moved to the shared
// profile card body alongside the rest of the profile UI.
export 'package:hollow/src/ui/components/profile_card_body.dart'
    show showLocalNicknameDialog;

/// Shows a profile card popup anchored near the tap position.
///
/// This is the COMPACT density of [ProfileCardBody] — the fast hover
/// inspection surface. The expand affordance on the banner opens the full
/// [ProfileDialog].
void showProfileCardPopup({
  required BuildContext context,
  required WidgetRef ref,
  required String peerId,
  String? nickname,
  String? role,
  String? twitchUsername,
  List<crdt_api.LabelFfi>? labels,
  String? serverId,
  required Offset anchor,
  bool anchorBottom = false,
}) {
  final overlay = Overlay.of(context);
  late final OverlayEntry entry;

  entry = OverlayEntry(
    builder: (context) => _ProfileCardOverlay(
      peerId: peerId,
      nickname: nickname,
      role: role,
      twitchUsername: twitchUsername,
      labels: labels,
      serverId: serverId,
      anchor: anchor,
      anchorBottom: anchorBottom,
      onDismiss: () { entry.remove(); entry.dispose(); },
    ),
  );

  overlay.insert(entry);
}

/// Width of the compact anchored card. Anchor offsets at call sites
/// (e.g. member panel) are derived from this.
const double kProfileCardPopupWidth = 300.0;

class _ProfileCardOverlay extends ConsumerStatefulWidget {
  final String peerId;
  final String? nickname;
  final String? role;
  final String? twitchUsername;
  final List<crdt_api.LabelFfi>? labels;
  final String? serverId;
  final Offset anchor;
  final bool anchorBottom;
  final VoidCallback onDismiss;

  const _ProfileCardOverlay({
    required this.peerId,
    required this.nickname,
    required this.role,
    this.twitchUsername,
    this.labels,
    this.serverId,
    required this.anchor,
    this.anchorBottom = false,
    required this.onDismiss,
  });

  @override
  ConsumerState<_ProfileCardOverlay> createState() =>
      _ProfileCardOverlayState();
}

class _ProfileCardOverlayState extends ConsumerState<_ProfileCardOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnim;
  late final Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: HollowDurations.animationsDisabled ? Duration.zero : const Duration(milliseconds: 180),
    );
    _scaleAnim = Tween<double>(begin: 0.92, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );
    _fadeAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _dismiss() {
    _controller.reverse().then((_) => widget.onDismiss());
  }

  /// Close the popup instantly and open the full profile dialog.
  void _expand() {
    final navContext = Navigator.of(context, rootNavigator: true).context;
    widget.onDismiss();
    showProfileDialog(
      navContext,
      peerId: widget.peerId,
      nickname: widget.nickname,
      role: widget.role,
      twitchUsername: widget.twitchUsername,
      labels: widget.labels,
      serverId: widget.serverId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    const cardWidth = kProfileCardPopupWidth;

    // Position: card appears near the anchor
    final screenSize = MediaQuery.of(context).size;
    double left = widget.anchor.dx;

    // Clamp horizontal
    if (left < 8) left = 8;
    if (left + cardWidth > screenSize.width - 8) {
      left = screenSize.width - cardWidth - 8;
    }

    // Vertical positioning. The card height is variable; estimate a generous
    // max so we can keep it on-screen. When opening downward would push the
    // card off the bottom, flip it to open UPWARD from the anchor instead
    // (and clamp to the top edge if even that doesn't fit).
    const estimatedCardHeight = 400.0;
    double? top;
    double? bottom;
    if (widget.anchorBottom) {
      // anchor.dy is where the card's bottom should be
      bottom = screenSize.height - widget.anchor.dy;
      if (bottom < 8) bottom = 8;
    } else {
      final wouldOverflowBottom =
          widget.anchor.dy + estimatedCardHeight > screenSize.height - 8;
      if (wouldOverflowBottom) {
        // Open upward: card's bottom sits at the anchor.
        bottom = (screenSize.height - widget.anchor.dy).clamp(8.0, double.infinity);
      } else {
        top = widget.anchor.dy;
        if (top < 8) top = 8;
      }
    }

    return Stack(
      children: [
        // Dismiss barrier
        Positioned.fill(
          child: GestureDetector(
            onTap: _dismiss,
            behavior: HitTestBehavior.opaque,
            child: const SizedBox.expand(),
          ),
        ),

        // Card with animation
        Positioned(
          left: left,
          top: top,
          bottom: bottom,
          child: FadeTransition(
            opacity: _fadeAnim,
            child: ScaleTransition(
              scale: _scaleAnim,
              alignment: Alignment.bottomCenter,
              child: Material(
                color: Colors.transparent,
                child: Container(
                  width: cardWidth,
                  decoration: BoxDecoration(
                    color: hollow.surface.withValues(alpha: 0.96),
                    borderRadius: BorderRadius.circular(hollow.radiusLg),
                    border: Border.all(
                      color: hollow.accent.withValues(alpha: 0.15),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.35),
                        blurRadius: 28,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: ProfileCardBody(
                    peerId: widget.peerId,
                    nickname: widget.nickname,
                    role: widget.role,
                    twitchUsername: widget.twitchUsername,
                    labels: widget.labels,
                    serverId: widget.serverId,
                    density: ProfileCardDensity.compact,
                    dismissHost: widget.onDismiss,
                    onExpand: _expand,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
