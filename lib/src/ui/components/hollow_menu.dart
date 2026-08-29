import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The shared right-click / context menu surface (issue #61).
///
/// One primitive behind every context menu in the app: messages, channels,
/// categories, members, server icons, the Home button. Each caller supplies a
/// list of [HollowMenuEntry] and an anchor; this file owns presentation,
/// positioning, dismissal and keyboard operation.
///
/// ## Why a dialog route and not a raw OverlayEntry
/// Chat surfaces sit inside `chatSelectionArea`, and a raw [OverlayEntry] under
/// a [SelectionArea] has its taps eaten by the selection gesture arena (see the
/// "Never use raw OverlayEntry inside SelectionArea" rule). Rather than run two
/// hosts and make every call site pick correctly, every menu goes through
/// [showGeneralDialog] with a transparent barrier. That also buys outside-click
/// dismissal, Escape, and a focus scope for arrow-key traversal for free.
///
/// ## Coordinates
/// `UiScale` wraps the Navigator, so the dialog route and the widget that was
/// right-clicked share one coordinate space, but window coordinates (what
/// `details.globalPosition` returns) are NOT that space. Call sites MUST pass
/// an anchor resolved through `overlayPositionOf` / `overlayAnchorOf`.
///
/// ## Submenus
/// Submenus drill in and replace the menu body behind a back row, rather than
/// flying out sideways. This mirrors the mobile action sheets, which already
/// drill in, keeps one keyboard model, and avoids a second layer of flip and
/// clamp positioning against the screen edge.
sealed class HollowMenuEntry {
  const HollowMenuEntry();
}

/// One activatable row. Supply either [onTap] or [submenu], not both.
class HollowMenuItem extends HollowMenuEntry {
  final IconData? icon;
  final String label;

  /// Right-aligned hint, e.g. a shortcut or the current value of a setting.
  final String? trailing;

  final VoidCallback? onTap;

  /// Nested entries. When set the row shows a chevron and drills in.
  final List<HollowMenuEntry>? submenu;

  /// Destructive intent: the icon and label take the error tint.
  final bool isDanger;

  /// Renders a check mark in the trailing slot (toggle-style rows).
  final bool isChecked;

  final bool enabled;

  const HollowMenuItem({
    required this.label,
    this.icon,
    this.trailing,
    this.onTap,
    this.submenu,
    this.isDanger = false,
    this.isChecked = false,
    this.enabled = true,
  });
}

/// A hairline between groups of rows.
class HollowMenuDivider extends HollowMenuEntry {
  const HollowMenuDivider();
}

/// A small uppercase caption above a group.
class HollowMenuSection extends HollowMenuEntry {
  final String label;
  const HollowMenuSection(this.label);
}

/// A non-interactive sentence at the top of a menu, for the case where the
/// menu has to SAY something before it offers anything.
///
/// Distinct from [HollowMenuSection], which is a shouty little category label:
/// this wraps, reads as prose, and never highlights on hover, because there is
/// nothing here to press. The parked-join menu is the first user — a tile with
/// no name and no icon has to explain itself somewhere.
class HollowMenuNote extends HollowMenuEntry {
  final String text;
  const HollowMenuNote(this.text);
}

/// An arbitrary widget row, e.g. the quick reaction strip on the message menu.
///
/// The child is responsible for dismissing the menu; [HollowMenuScope.dismiss]
/// is available from its context.
class HollowMenuCustom extends HollowMenuEntry {
  final Widget child;
  const HollowMenuCustom(this.child);
}

/// Lets a [HollowMenuCustom] child close the menu it lives in.
class HollowMenuScope extends InheritedWidget {
  final VoidCallback _dismiss;

  const HollowMenuScope({
    super.key,
    required VoidCallback dismiss,
    required super.child,
  }) : _dismiss = dismiss;

  static void dismiss(BuildContext context) {
    // Read-only lookup: registering a dependency from inside a tap callback
    // would rebuild the row for a widget that is about to be torn down.
    final scope = context
        .getElementForInheritedWidgetOfExactType<HollowMenuScope>()
        ?.widget as HollowMenuScope?;
    scope?._dismiss.call();
  }

  @override
  bool updateShouldNotify(HollowMenuScope oldWidget) => false;
}

/// Wraps anything that has a context menu, so the menu has more than one way
/// in (issue #61, cross-cutting).
///
/// Right click is the obvious route and the only one most people use, but it
/// is a POINTER route. Everything reachable only by right-clicking is
/// unreachable without a mouse, and several of these menus own actions that
/// live nowhere else. This adds the two standard alternatives:
///
/// * **Menu key / Shift+F10** while the wrapped control has keyboard focus,
///   the platform convention on Windows and Linux. It only fires when focus is
///   inside this subtree, so it never collides with the app shortcuts.
/// * **A "Show menu" screen-reader action**, which is how VoiceOver, TalkBack
///   and Narrator expose a secondary action; the focus mechanics above do not
///   have to line up for it to work.
///
/// The child still has to be focusable for the keyboard route to reach it —
/// [HollowPressable] and [HollowButton] both are.
class ContextMenuTarget extends StatelessWidget {
  final Widget child;

  /// Opens the menu. [anchor] is already in OVERLAY space — pass it straight
  /// to [showHollowMenu].
  final void Function(Offset anchor) onOpen;

  /// The screen-reader action label. Say what the menu is FOR when the
  /// default reads as vague ("Channel actions", "Member actions").
  final String semanticLabel;

  /// False leaves [child] alone entirely: no gestures, no shortcuts, no
  /// semantics action. Use it for rows whose menu would be empty.
  final bool enabled;

  final HitTestBehavior behavior;

  const ContextMenuTarget({
    super.key,
    required this.child,
    required this.onOpen,
    this.semanticLabel = 'Show menu',
    this.enabled = true,
    this.behavior = HitTestBehavior.deferToChild,
  });

  /// Opens the menu hanging off the control itself, for the routes that have
  /// no pointer position: keyboard and assistive tech.
  void _openAtWidget(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    final size = box?.hasSize == true ? box!.size : Size.zero;
    // Bottom-left of the control, the same place a menu-key press opens a
    // menu everywhere else on the platform.
    onOpen(overlayAnchorOf(context, localOffset: Offset(0, size.height)));
  }

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return Builder(
      builder: (innerContext) => Semantics(
        customSemanticsActions: {
          CustomSemanticsAction(label: semanticLabel): () =>
              _openAtWidget(innerContext),
        },
        child: Shortcuts(
          shortcuts: const <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.contextMenu):
                _ShowContextMenuIntent(),
            SingleActivator(LogicalKeyboardKey.f10, shift: true):
                _ShowContextMenuIntent(),
          },
          child: Actions(
            actions: <Type, Action<Intent>>{
              _ShowContextMenuIntent:
                  CallbackAction<_ShowContextMenuIntent>(onInvoke: (_) {
                _openAtWidget(innerContext);
                return null;
              }),
            },
            child: GestureDetector(
              behavior: behavior,
              onSecondaryTapUp: (details) =>
                  onOpen(overlayPositionOf(innerContext, details.globalPosition)),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

class _ShowContextMenuIntent extends Intent {
  const _ShowContextMenuIntent();
}

const double _kMenuMinWidth = 210;
const double _kMenuMaxWidth = 320;

/// Builds a menu's rows. Called on every rebuild, inside a [Consumer], so a
/// menu that stays open while its underlying state changes redraws instead of
/// showing what was true when it opened.
typedef HollowMenuBuilder = List<HollowMenuEntry> Function(
    BuildContext context, WidgetRef ref);

/// Opens a context menu at [anchor].
///
/// [anchor] must already be in overlay space: pass
/// `overlayPositionOf(context, details.globalPosition)` for a pointer position,
/// or `overlayAnchorOf(context)` to hang the menu off a widget.
///
/// [builder] is re-run whenever anything it watches changes, so rows must read
/// live state through its `ref` rather than closing over a snapshot.
Future<void> showHollowMenu({
  required BuildContext context,
  required Offset anchor,
  required HollowMenuBuilder builder,
  double minWidth = _kMenuMinWidth,
  double maxWidth = _kMenuMaxWidth,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss menu',
    barrierColor: Colors.transparent,
    transitionDuration: HollowDurations.animationsDisabled
        ? Duration.zero
        : const Duration(milliseconds: 120),
    // The menu is built ONCE in pageBuilder, not in transitionBuilder: the
    // latter reruns every animation frame, and the host owns drill-in state.
    pageBuilder: (_, _, _) => _HollowMenuHost(
      anchor: anchor,
      entriesBuilder: builder,
      minWidth: minWidth,
      maxWidth: maxWidth,
    ),
    transitionBuilder: (_, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: HollowCurves.enter,
        reverseCurve: Curves.easeIn,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1.0).animate(curved),
          // The menu grows out of the click point, not the screen centre.
          alignment: Alignment.topLeft,
          child: child,
        ),
      );
    },
  );
}

class _HollowMenuHost extends StatefulWidget {
  final Offset anchor;
  final HollowMenuBuilder entriesBuilder;
  final double minWidth;
  final double maxWidth;

  const _HollowMenuHost({
    required this.anchor,
    required this.entriesBuilder,
    required this.minWidth,
    required this.maxWidth,
  });

  @override
  State<_HollowMenuHost> createState() => _HollowMenuHostState();
}

class _HollowMenuHostState extends State<_HollowMenuHost> {
  /// Drill-in position as a PATH of row indices into the freshly built
  /// entries, not as captured submenu lists. The rows are rebuilt whenever the
  /// state behind them changes, so a captured list would go stale the moment
  /// the thing it describes is edited — which is the whole point of rebuilding.
  final List<int> _path = [];

  /// Pops THIS route by identity rather than "whatever is on top".
  ///
  /// A plain `Navigator.pop()` is a guess about what the topmost route is, and
  /// an action that opens its own dialog makes that guess wrong. Removing the
  /// route we actually own is unambiguous.
  void _dismiss() {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    final navigator = Navigator.of(context);
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
  }

  /// Closes the menu, THEN runs the action on the next frame.
  ///
  /// Actions routinely open a dialog of their own. Running one synchronously
  /// races the pop we just requested, and the menu can end up sitting behind
  /// the dialog it opened — visible, inert, and still showing pre-edit values.
  /// Deferring by a frame makes the ordering deterministic.
  void _activate(VoidCallback action) {
    _dismiss();
    WidgetsBinding.instance.addPostFrameCallback((_) => action());
  }

  void _push(int index) => setState(() => _path.add(index));

  void _pop() {
    if (_path.isEmpty) return;
    setState(() => _path.removeLast());
  }

  /// Walks [_path] through [root] to the entries currently on screen.
  ///
  /// Falls back to the root when the path no longer resolves — a submenu whose
  /// parent row disappeared after an edit, for instance. Showing the top of the
  /// menu beats showing a frame that describes something that is gone.
  ({List<HollowMenuEntry> entries, String? title}) _resolve(
      List<HollowMenuEntry> root) {
    var current = root;
    String? title;
    for (final index in _path) {
      if (index < 0 || index >= current.length) {
        return (entries: root, title: null);
      }
      final item = current[index];
      if (item is! HollowMenuItem) return (entries: root, title: null);
      final submenu = item.submenu;
      if (submenu == null || submenu.isEmpty) {
        return (entries: root, title: null);
      }
      title = item.label;
      current = submenu;
    }
    return (entries: current, title: title);
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return HollowMenuScope(
      dismiss: _dismiss,
      child: CustomSingleChildLayout(
        delegate: _MenuLayoutDelegate(widget.anchor),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: widget.minWidth,
            maxWidth: widget.maxWidth,
          ),
          child: Material(
            // showHollowDialog overlays need a Material ancestor or every
            // Text picks up the yellow debug underline.
            type: MaterialType.transparency,
            child: Container(
              decoration: BoxDecoration(
                color: hollow.elevated,
                borderRadius: BorderRadius.circular(hollow.radiusMd),
                border: Border.all(color: hollow.border),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.22),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: AnimatedSize(
                duration: HollowDurations.fast,
                curve: HollowCurves.enter,
                alignment: Alignment.topCenter,
                // Consumer, so anything the builder watches redraws the open
                // menu instead of leaving it showing what was true on open.
                child: Consumer(
                  builder: (context, ref, _) {
                    final frame =
                        _resolve(widget.entriesBuilder(context, ref));
                    return SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (frame.title != null)
                            _MenuBackRow(title: frame.title!, onTap: _pop),
                          for (var i = 0; i < frame.entries.length; i++)
                            _buildEntry(hollow, frame.entries[i], i),
                          const SizedBox(height: HollowSpacing.xxs),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEntry(HollowTheme hollow, HollowMenuEntry entry, int index) {
    switch (entry) {
      case HollowMenuDivider():
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: HollowSpacing.xxs),
          child: Divider(height: 1, thickness: 1, color: hollow.border),
        );
      case HollowMenuSection(:final label):
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            HollowSpacing.sm + 2,
            HollowSpacing.sm,
            HollowSpacing.sm,
            HollowSpacing.xxs,
          ),
          child: Text(
            label.toUpperCase(),
            style: HollowTypography.caption.copyWith(
              color: hollow.textTertiary,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              fontSize: 10,
            ),
          ),
        );
      case HollowMenuNote(:final text):
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            HollowSpacing.sm + 2,
            HollowSpacing.sm,
            HollowSpacing.sm + 2,
            HollowSpacing.xs,
          ),
          child: Text(
            text,
            style: HollowTypography.bodySmall.copyWith(
              color: hollow.textSecondary,
              height: 1.35,
            ),
          ),
        );
      case HollowMenuCustom(:final child):
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            HollowSpacing.xs,
            HollowSpacing.xs,
            HollowSpacing.xs,
            HollowSpacing.xxs,
          ),
          child: child,
        );
      case HollowMenuItem():
        return _MenuRow(
          item: entry,
          onActivate: () {
            final submenu = entry.submenu;
            if (submenu != null && submenu.isNotEmpty) {
              _push(index);
              return;
            }
            final tap = entry.onTap;
            if (tap != null) _activate(tap);
          },
        );
    }
  }
}

/// Header row of a drilled-in submenu: chevron plus the parent's label.
class _MenuBackRow extends StatelessWidget {
  final String title;
  final VoidCallback onTap;

  const _MenuBackRow({required this.title, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HollowPressable(
          onTap: onTap,
          subtle: true,
          hoverColor: hollow.surface,
          padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.sm + 2,
            vertical: HollowSpacing.sm,
          ),
          child: Row(
            children: [
              Icon(LucideIcons.chevronLeft, size: 15, color: hollow.textSecondary),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: Text(
                  title,
                  style: HollowTypography.label.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        Divider(height: 1, thickness: 1, color: hollow.border),
      ],
    );
  }
}

class _MenuRow extends StatelessWidget {
  final HollowMenuItem item;
  final VoidCallback onActivate;

  const _MenuRow({required this.item, required this.onActivate});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final hasSubmenu = item.submenu != null && item.submenu!.isNotEmpty;
    final enabled = item.enabled && (item.onTap != null || hasSubmenu);
    final tint = item.isDanger ? hollow.error : hollow.textPrimary;
    final iconTint = item.isDanger ? hollow.error : hollow.textSecondary;

    return HollowPressable(
      onTap: enabled ? onActivate : null,
      disabled: !enabled,
      subtle: true,
      // Rows sit on `elevated`, so the hover state has to move AWAY from it or
      // it reads as dead. Never animate from Colors.transparent here.
      hoverColor: item.isDanger
          ? hollow.error.withValues(alpha: 0.12)
          : hollow.surface,
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm + 2,
        vertical: HollowSpacing.sm,
      ),
      child: Row(
        children: [
          if (item.icon != null) ...[
            Icon(item.icon, size: 15, color: iconTint),
            const SizedBox(width: HollowSpacing.sm),
          ],
          Expanded(
            child: Text(
              item.label,
              style: HollowTypography.label.copyWith(color: tint),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (item.trailing != null) ...[
            const SizedBox(width: HollowSpacing.sm),
            Text(
              item.trailing!,
              style: HollowTypography.caption.copyWith(
                color: hollow.textTertiary,
              ),
            ),
          ],
          if (item.isChecked) ...[
            const SizedBox(width: HollowSpacing.xs),
            Icon(LucideIcons.check, size: 14, color: hollow.accent),
          ],
          if (hasSubmenu) ...[
            const SizedBox(width: HollowSpacing.xs),
            Icon(
              LucideIcons.chevronRight,
              size: 14,
              color: hollow.textTertiary,
            ),
          ],
        ],
      ),
    );
  }
}

/// Positions the menu at the anchor, flipping and clamping against the screen
/// edges using the child's MEASURED size rather than an estimate.
class _MenuLayoutDelegate extends SingleChildLayoutDelegate {
  final Offset anchor;
  static const double _margin = 8;

  const _MenuLayoutDelegate(this.anchor);

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints.loose(Size(
      constraints.maxWidth - _margin * 2,
      constraints.maxHeight - _margin * 2,
    ));
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    // Open down-right of the cursor; flip to the other side when that would
    // overflow, then clamp so the menu is never partly off screen.
    var x = anchor.dx;
    if (x + childSize.width > size.width - _margin) {
      x = anchor.dx - childSize.width;
    }
    var y = anchor.dy;
    if (y + childSize.height > size.height - _margin) {
      y = anchor.dy - childSize.height;
    }
    return Offset(
      x.clamp(_margin, (size.width - childSize.width - _margin).clamp(_margin, double.infinity)),
      y.clamp(_margin, (size.height - childSize.height - _margin).clamp(_margin, double.infinity)),
    );
  }

  @override
  bool shouldRelayout(_MenuLayoutDelegate oldDelegate) =>
      oldDelegate.anchor != anchor;
}
