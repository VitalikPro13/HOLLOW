import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/screen_share_service.dart';
import 'package:hollow/src/ui/components/share_source_quality_chip.dart';

void main() {
  group('ShareQualityChip.receivedLabel', () {
    test('shows the received short edge with the source fps suffix', () {
      expect(ShareQualityChip.receivedLabel(1465, 824, '1080p60'), '824p60');
    });

    test('source-quality stream reads the same as the source label', () {
      expect(ShareQualityChip.receivedLabel(1920, 1080, '1080p60'), '1080p60');
    });

    test('no frames yet falls back to the source label', () {
      expect(ShareQualityChip.receivedLabel(0, 0, '1080p60'), '1080p60');
    });

    test('rotation does not change the p number', () {
      expect(ShareQualityChip.receivedLabel(824, 1465, '1080p60'), '824p60');
    });

    test('no source label (old client) still shows the received resolution',
        () {
      expect(ShareQualityChip.receivedLabel(1465, 824, null), '824p');
    });
  });

  group('ScreenShareService.effectiveViewerCap', () {
    test('4K share clamps to a 1080p viewer', () {
      expect(
        ScreenShareService.effectiveViewerCap(3840, 2160, 1920, 1080),
        (1920, 1080),
      );
    });

    test('4K share clamps to a 1440p viewer', () {
      expect(
        ScreenShareService.effectiveViewerCap(3840, 2160, 2560, 1440),
        (2560, 1440),
      );
    });

    test('a big viewer display never raises the share cap', () {
      expect(
        ScreenShareService.effectiveViewerCap(1920, 1080, 3840, 2160),
        (1920, 1080),
      );
    });

    test('source quality lifts the viewer clamp entirely', () {
      expect(
        ScreenShareService.effectiveViewerCap(3840, 2160, 1920, 1080,
            sourceQuality: true),
        (3840, 2160),
      );
    });

    test('unknown viewer size (old client) leaves the cap untouched', () {
      expect(
        ScreenShareService.effectiveViewerCap(3840, 2160, 0, 0),
        (3840, 2160),
      );
    });

    test('portrait phone viewing a landscape share is orientation-normalized',
        () {
      // Pixel-8-Pro-ish portrait panel: rotated it can show 2992 wide.
      expect(
        ScreenShareService.effectiveViewerCap(3840, 2160, 1344, 2992),
        (2992, 1344),
      );
    });

    test('portrait share cap keeps its orientation after clamping', () {
      // Portrait window share seen by a landscape 1440p monitor.
      expect(
        ScreenShareService.effectiveViewerCap(1080, 1920, 2560, 1440),
        (1080, 1920),
      );
    });
  });
}
