import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/screen_share_service.dart';
import 'package:hollow/src/ui/components/share_quality_chip.dart';

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

    test('there is no per-viewer opt-out of the clamp', () {
      // "Source quality" was REMOVED 2026-08-15: the clamp is keyed to the
      // viewer's MONITOR, so it already delivers every pixel they can show,
      // and a shared forwarder branch has no per-viewer encoder for an
      // opt-out to apply to. A 4K share to a 1080p viewer is ALWAYS 1080p.
      expect(
        ScreenShareService.effectiveViewerCap(3840, 2160, 1920, 1080),
        (1920, 1080),
      );
    });
  });

  group('ScreenShareService.viewerWantsLowLayer', () {
    test('a viewer the q layer fully covers rides q', () {
      // Branch cap 1920x1080 => q is 960x540; an 800x600 display fits.
      expect(
        ScreenShareService.viewerWantsLowLayer(1920, 1080, 800, 600),
        isTrue,
      );
    });

    test('a viewer needing more than half the cap stays on f', () {
      expect(
        ScreenShareService.viewerWantsLowLayer(1920, 1080, 1920, 1080),
        isFalse,
      );
    });

    test('exactly half the long edge still rides q', () {
      expect(
        ScreenShareService.viewerWantsLowLayer(1920, 1080, 960, 540),
        isTrue,
      );
    });

    test('unknown viewer size (old client) stays on f', () {
      expect(
        ScreenShareService.viewerWantsLowLayer(1920, 1080, 0, 0),
        isFalse,
      );
    });

    test('orientation is normalized on the long edge', () {
      // Portrait 600x800 viewer against a landscape 1920x1080 branch cap:
      // long edge 800, q long edge 960 => covered.
      expect(
        ScreenShareService.viewerWantsLowLayer(1920, 1080, 600, 800),
        isTrue,
      );
    });
  });
}
