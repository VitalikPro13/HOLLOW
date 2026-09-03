import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/layout_prefs_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/profile_card_body.dart';
import 'package:hollow/src/ui/dialogs/profile_dialog.dart';

// showLocalNicknameDialog historically lived here; it moved to the shared
// profile card body alongside the rest of the profile UI.
export 'package:hollow/src/ui/components/profile_card_body.dart'
    show showLocalNicknameDialog;

/// Shows a profile card for [peerId].
///
/// Normally the COMPACT density of [ProfileCardBody] — the fast inspection
/// card, anchored next to whatever was clicked, with an expand affordance on
/// its banner that opens the full [ProfileDialog]. When the user has set
/// [ProfileCardStyle.expanded] (Settings > Appearance), one click goes
/// straight to the full profile instead (issue #54).
///
/// [anchorOf] is a FUNCTION, not a point: the window can be resized (or
/// maximized) while the card is open, and a point captured at click time
/// leaves the card stranded in the middle of the chat. It is re-read after any
/// viewport change, so the card follows the thing it belongs to. Call sites
/// with nothing to follow (a menu action) pass a constant closure.
void showProfileCardPopup({
  required BuildContext context,
  required WidgetRef ref,
  required String peerId,
  String? nickname,
  String? role,
  List<crdt_api.LabelFfi>? labels,
  String? serverId,
  required Offset Function() anchorOf,
  bool anchorBottom = false,
}) {
  if (ref.read(profileCardStyleProvider) == ProfileCardStyle.expanded) {
    showProfileDialog(
      context,
      peerId: peerId,
      nickname: nickname,
      role: role,
      labels: labels,
      serverId: serverId,
    );
    return;
  }

  final overlay = Overlay.of(context);
  late final OverlayEntry entry;

  entry = OverlayEntry(
    builder: (context) => _ProfileCardOverlay(
      peerId: peerId,
      nickname: nickname,
      role: role,
      labels: labels,
      serverId: serverId,
      anchorOf: anchorOf,
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
  final List<crdt_api.LabelFfi>? labels;
  final String? serverId;
  final Offset Function() anchorOf;
  final bool anchorBottom;
  final VoidCallback onDismiss;

  const _ProfileCardOverlay({
    required this.peerId,
    required this.nickname,
    required this.role,
    this.labels,
    this.serverId,
    required this.anchorOf,
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

  /// Where the card is pinned right now. Seeded at open, re-read from
  /// [_ProfileCardOverlay.anchorOf] after the viewport changes size.
  late Offset _anchor;
  Size? _lastViewport;

  @override
  void initState() {
    super.initState();
    _anchor = widget.anchorOf();
    // A raw OverlayEntry is not a route, so nothing else gives this card an
    // Escape key. Without it a card can be left stranded on screen with no
    // keyboard way out.
    HardwareKeyboard.instance.addHandler(_onKey);
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    final viewport = MediaQuery.sizeOf(context);
    if (_lastViewport != null && _lastViewport != viewport) _reanchor();
    _lastViewport = viewport;
  }

  /// Re-reads the anchor AFTER the frame: this runs during build, and the
  /// source widget has not been laid out at the new window size yet — reading
  /// its render box now returns the position it had BEFORE the resize, which
  /// is exactly the bug (issue #54).
  ///
  /// Twice, because a resize can also start a panel animation (the member
  /// panel folds itself away on a narrow window): the first read lands
  /// mid-slide, the second one after it settles.
  void _reanchor() {
    _applyAnchor();
    Future.delayed(const Duration(milliseconds: 280), _applyAnchor);
  }

  void _applyAnchor() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final Offset next;
      try {
        next = widget.anchorOf();
      } catch (_) {
        return;
      }
      // Zero means the source has no render box any more — the row was
      // scrolled out, or the whole panel folded away. A card pointing at
      // something that is no longer there should leave, not float.
      if (next == Offset.zero) {
        _dismiss();
        return;
      }
      if (next == _anchor) return;
      setState(() => _anchor = next);
    });
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.escape) return false;
    _dismiss();
    return true;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _controller.dispose();
    super.dispose();
  }

  /// One dismiss only: [onDismiss] removes AND disposes the overlay entry, so
  /// a second run (barrier tap during the fade, both re-anchor attempts
  /// finding the source gone) would tear down an entry that is already gone.
  bool _dismissing = false;

  void _dismiss() {
    if (_dismissing) return;
    _dismissing = true;
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
    double left = _anchor.dx;

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
    // How far up the card may be pushed before its TOP leaves the window.
    // Without this ceiling a short window (or one the user just shrank) lifts
    // the card clean off the top edge, which is how a card ends up half
    // painted behind the title bar (issue #54).
    final maxBottom =
        (screenSize.height - estimatedCardHeight - 8).clamp(8.0, double.infinity);
    if (widget.anchorBottom) {
      // anchor.dy is where the card's bottom should be
      bottom = (screenSize.height - _anchor.dy).clamp(8.0, maxBottom);
    } else {
      final wouldOverflowBottom =
          _anchor.dy + estimatedCardHeight > screenSize.height - 8;
      if (wouldOverflowBottom) {
        // Open upward: card's bottom sits at the anchor.
        bottom = (screenSize.height - _anchor.dy).clamp(8.0, maxBottom);
      } else {
        top = _anchor.dy;
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
