import 'dart:ui';

/// Hollow's five surface levels, dimmest to brightest on the dark theme.
///
/// Chrome (dock, sidebars, title bar) sits one step BELOW the canvas so the
/// content is the brightest thing on screen; raised, overlay and hover climb
/// from there. The light theme keeps the same names with the canvas on top.
class SurfaceLadder {
  final Color chrome;
  final Color canvas;
  final Color raised;
  final Color overlay;
  final Color hover;

  const SurfaceLadder({
    required this.chrome,
    required this.canvas,
    required this.raised,
    required this.overlay,
    required this.hover,
  });

  List<Color> get all => [chrome, canvas, raised, overlay, hover];
}

/// Chosen by eye on the decision sheet (2026-09-18) from three dark and two
/// light candidates.
abstract final class SurfaceLadders {
  static const dark = SurfaceLadder(
    chrome: Color(0xFF0B0C10),
    canvas: Color(0xFF111318),
    raised: Color(0xFF181A20),
    overlay: Color(0xFF1E2127),
    hover: Color(0xFF262930),
  );

  static const light = SurfaceLadder(
    chrome: Color(0xFFF1F2F4),
    canvas: Color(0xFFFFFFFF),
    raised: Color(0xFFF5F6F8),
    overlay: Color(0xFFFFFFFF),
    hover: Color(0xFFEBEDF0),
  );
}
