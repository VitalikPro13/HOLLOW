import 'dart:math' as math;
import 'dart:ui' show FilterQuality, Size;

/// The media viewer's zoom arithmetic, with no widget in sight so the numbers
/// behind "100% is actual size" stay testable.
class MediaZoomMath {
  const MediaZoomMath._();

  /// Logical size [image] occupies inside [viewport] at fit scale. Never
  /// upscales, which is what makes fit the floor of the zoom range.
  static Size fitSize(Size image, Size viewport) {
    if (image.width <= 0 || image.height <= 0) return viewport;
    if (viewport.width <= 0 || viewport.height <= 0) return image;
    final factor = math.min(
      math.min(viewport.width / image.width, viewport.height / image.height),
      1.0,
    );
    return Size(image.width * factor, image.height * factor);
  }

  /// The zoom factor at which one image pixel covers one DEVICE pixel.
  ///
  /// [devicePixelRatio] is the display's own ratio and [uiScale] the interface
  /// zoom; a `MediaQuery` read inside `UiScale` has already multiplied the two,
  /// so a caller reading it there passes `uiScale: 1.0`.
  static double actualScale({
    required double imagePixelWidth,
    required double fitLogicalWidth,
    required double devicePixelRatio,
    required double uiScale,
  }) {
    final denominator = fitLogicalWidth * devicePixelRatio * uiScale;
    if (imagePixelWidth <= 0 || denominator <= 0) return 1.0;
    return imagePixelWidth / denominator;
  }

  /// The readout: 100 means one image pixel per device pixel.
  static int zoomPercent(double currentScale, double actualScale) {
    if (actualScale <= 0) return 100;
    return (currentScale / actualScale * 100).round();
  }

  /// Zoom ceiling. A thumbnail-sized image would otherwise top out before it
  /// reached its own pixels.
  static double maxScaleFor(double actualScale) =>
      math.max(8.0, actualScale * 2);

  /// Zoom floor: fit, or actual size when that is smaller. On a display scaled
  /// past 100% an image smaller than the viewport is already drawn LARGER than
  /// its own pixels at fit, and a floor of fit would put actual size out of
  /// reach of the 1:1 control.
  static double minScaleFor(double actualScale) =>
      math.min(1.0, actualScale <= 0 ? 1.0 : actualScale);

  /// The double-tap cycle: fit, actual size, twice actual, back to fit. Stops
  /// that fall below fit or above [maxScale] drop out of the cycle.
  static double nextDoubleTapScale(
      double current, double actualScale, double maxScale) {
    const epsilon = 0.01;
    final stops = <double>[
      for (final stop in [actualScale, actualScale * 2])
        if (stop > 1.0 + epsilon && stop <= maxScale + epsilon) stop,
    ]..sort();
    for (final stop in stops) {
      if (stop > current + epsilon) return stop;
    }
    return 1.0;
  }

  /// Which filter the image is drawn with. Crisp mode is what keeps pixel art,
  /// screenshots and emotes from turning to mush once the pixels are visible.
  static FilterQuality filterQualityFor({
    required double currentScale,
    required double actualScale,
    required bool crisp,
  }) {
    final ratio = actualScale <= 0 ? 1.0 : currentScale / actualScale;
    if (crisp && ratio >= 2.0) return FilterQuality.none;
    return ratio < 1.0 ? FilterQuality.medium : FilterQuality.high;
  }
}
