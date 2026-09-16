/// The media viewer's zoom arithmetic, kept pure so the one number a user can
/// name ("100% is actual size") is pinned by a test rather than by eyeballing a
/// screenshot.
library;

import 'dart:ui' show FilterQuality, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/ui/media/media_zoom_math.dart';

void main() {
  group('fitSize', () {
    test('a landscape image fills the viewport width', () {
      expect(
        MediaZoomMath.fitSize(const Size(1920, 1080), const Size(1280, 720)),
        const Size(1280, 720),
      );
    });

    test('a portrait image fills the viewport height', () {
      final fit =
          MediaZoomMath.fitSize(const Size(1000, 2000), const Size(1280, 720));
      expect(fit.height, 720);
      expect(fit.width, 360);
    });

    test('a small image is not upscaled to fit', () {
      expect(
        MediaZoomMath.fitSize(const Size(64, 64), const Size(1280, 720)),
        const Size(64, 64),
      );
    });
  });

  group('actualScale', () {
    test('1920 wide shown 1280 wide at dpr 1 needs 1.5x', () {
      expect(
        MediaZoomMath.actualScale(
          imagePixelWidth: 1920,
          fitLogicalWidth: 1280,
          devicePixelRatio: 1.0,
          uiScale: 1.0,
        ),
        closeTo(1.5, 1e-9),
      );
    });

    test('the same image at dpr 2 is already past actual size, so 0.75x', () {
      expect(
        MediaZoomMath.actualScale(
          imagePixelWidth: 1920,
          fitLogicalWidth: 1280,
          devicePixelRatio: 2.0,
          uiScale: 1.0,
        ),
        closeTo(0.75, 1e-9),
      );
    });

    test('interface zoom 1.25 LOWERS actual scale, because app.dart multiplies '
        'devicePixelRatio by the zoom', () {
      final plain = MediaZoomMath.actualScale(
        imagePixelWidth: 1920,
        fitLogicalWidth: 1280,
        devicePixelRatio: 1.0,
        uiScale: 1.0,
      );
      final zoomed = MediaZoomMath.actualScale(
        imagePixelWidth: 1920,
        fitLogicalWidth: 1280,
        devicePixelRatio: 1.0,
        uiScale: 1.25,
      );
      expect(zoomed, lessThan(plain));
      expect(zoomed, closeTo(1.2, 1e-9));
    });

    test('a viewport of zero falls back to 1.0 rather than infinity', () {
      expect(
        MediaZoomMath.actualScale(
          imagePixelWidth: 1920,
          fitLogicalWidth: 0,
          devicePixelRatio: 1.0,
          uiScale: 1.0,
        ),
        1.0,
      );
    });
  });

  group('zoomPercent', () {
    test('fit on a 1.5x actual image reads 67 percent', () {
      expect(MediaZoomMath.zoomPercent(1.0, 1.5), 67);
    });

    test('actual size reads 100 percent', () {
      expect(MediaZoomMath.zoomPercent(1.5, 1.5), 100);
      expect(MediaZoomMath.zoomPercent(0.75, 0.75), 100);
    });

    test('twice actual reads 200 percent', () {
      expect(MediaZoomMath.zoomPercent(3.0, 1.5), 200);
    });
  });

  group('maxScaleFor', () {
    test('never below 8x', () {
      expect(MediaZoomMath.maxScaleFor(1.5), 8.0);
    });

    test('a tiny image can go to twice its actual size', () {
      expect(MediaZoomMath.maxScaleFor(12.0), 24.0);
    });
  });

  group('minScaleFor', () {
    test('an image bigger than its box cannot zoom out past fit', () {
      expect(MediaZoomMath.minScaleFor(1.5), 1.0);
    });

    test('an image already past actual size at fit can zoom out to it', () {
      expect(MediaZoomMath.minScaleFor(0.8), 0.8);
    });
  });

  group('nextDoubleTapScale', () {
    test('fit goes to actual, then twice actual, then back to fit', () {
      const actual = 1.5;
      final max = MediaZoomMath.maxScaleFor(actual);
      final first = MediaZoomMath.nextDoubleTapScale(1.0, actual, max);
      expect(first, closeTo(1.5, 1e-9));
      final second = MediaZoomMath.nextDoubleTapScale(first, actual, max);
      expect(second, closeTo(3.0, 1e-9));
      expect(MediaZoomMath.nextDoubleTapScale(second, actual, max), 1.0);
    });

    test('an image already past actual size at fit skips straight to 2x', () {
      const actual = 0.75;
      final max = MediaZoomMath.maxScaleFor(actual);
      expect(MediaZoomMath.nextDoubleTapScale(1.0, actual, max),
          closeTo(1.5, 1e-9));
      expect(MediaZoomMath.nextDoubleTapScale(1.5, actual, max), 1.0);
    });
  });

  group('filterQualityFor', () {
    test('crisp mode turns interpolation off at twice actual size', () {
      expect(
        MediaZoomMath.filterQualityFor(
            currentScale: 3.0, actualScale: 1.5, crisp: true),
        FilterQuality.none,
      );
    });

    test('crisp mode still interpolates below twice actual size', () {
      expect(
        MediaZoomMath.filterQualityFor(
            currentScale: 2.0, actualScale: 1.5, crisp: true),
        FilterQuality.high,
      );
    });

    test('crisp off keeps interpolation at every zoom', () {
      expect(
        MediaZoomMath.filterQualityFor(
            currentScale: 6.0, actualScale: 1.5, crisp: false),
        FilterQuality.high,
      );
    });

    test('below actual size the cheaper filter is enough', () {
      expect(
        MediaZoomMath.filterQualityFor(
            currentScale: 1.0, actualScale: 1.5, crisp: true),
        FilterQuality.medium,
      );
    });
  });
}
