/// The media viewer's zoom must anchor where the pointer is, at every display
/// scale and interface zoom. A trackpad pinch reaches Flutter as pan-zoom
/// events rather than as a scroll, so it is driven here the way Windows sends
/// it rather than through a scroll shortcut.
library;

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/ui_scale.dart';
import 'package:hollow/src/ui/media/media_item.dart';
import 'package:hollow/src/ui/media/media_zoom_view.dart';

/// Display scale and interface zoom, the two factors between window pixels and
/// the coordinates the zoom view works in.
class _Geometry {
  final double dpr;
  final double uiScale;

  const _Geometry(this.dpr, this.uiScale);

  @override
  String toString() => 'dpr $dpr, interface zoom $uiScale';
}

const _geometries = <_Geometry>[
  _Geometry(1.0, 1.0),
  _Geometry(1.25, 1.0),
  _Geometry(2.0, 1.0),
  _Geometry(1.0, 1.25),
  _Geometry(1.25, 1.25),
  _Geometry(2.0, 1.25),
];

/// Logical window size every case lays out in.
const _window = Size(1200, 800);

/// Roughly a quarter in from the top left, the spot Vitalik reported.
const _cursor = Offset(312, 168);

late final String _imagePath;

MediaItem _item() => MediaItem(
      attachment: FileAttachment(
        fileId: 'zoom-fixture',
        fileName: 'zoom.png',
        fileExt: 'png',
        mimeType: 'image/png',
        sizeBytes: 4,
        isImage: true,
        width: 1920,
        height: 1080,
        totalChunks: 1,
        isComplete: true,
        diskPath: _imagePath,
      ),
    );

Future<TransformationController> _pump(
  WidgetTester tester,
  _Geometry geometry,
) async {
  tester.view.devicePixelRatio = geometry.dpr;
  tester.view.physicalSize = _window * geometry.dpr;
  addTearDown(tester.view.reset);

  final transform = TransformationController();
  addTearDown(transform.dispose);

  await tester.pumpWidget(
    MaterialApp(
      theme: HollowThemeData.dark(),
      home: Scaffold(
        backgroundColor: const Color(0xFF000000),
        body: UiScaleBox(
          scale: geometry.uiScale,
          child: MediaZoomView(
            item: _item(),
            transform: transform,
            maxScale: 8.0,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return transform;
}

/// Where a window point lands inside the zoom view, the way the framework
/// itself converts it.
Offset _local(WidgetTester tester, Offset global) => tester
    .renderObject<RenderBox>(find.byType(InteractiveViewer))
    .globalToLocal(global);

double _scaleOf(TransformationController t) =>
    t.value.getMaxScaleOnAxis();

Future<void> _wheel(WidgetTester tester, Offset global, double dy) async {
  final pointer = TestPointer(7, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(pointer.hover(global));
  await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
  await tester.pump();
}

/// A pinch as Windows reports it: pan-zoom events on a trackpad pointer.
/// [pan] is what Direct Manipulation adds to the focal point.
Future<void> _pinchRaw(
  WidgetTester tester,
  Offset global, {
  double scale = 1.5,
  Offset pan = Offset.zero,
}) async {
  final pointer = TestPointer(8, PointerDeviceKind.trackpad);
  await tester.sendEventToBinding(pointer.panZoomStart(global));
  await tester.pump();
  await tester.sendEventToBinding(
    pointer.panZoomUpdate(
      global,
      pan: pan,
      scale: scale,
      timeStamp: const Duration(milliseconds: 16),
    ),
  );
  await tester.pump();
}

/// The shape Windows produces: the reported pan grows with the scale, so the
/// framework's focal point walks away from the cursor as the pinch continues.
Future<void> _pinchAccumulating(
  WidgetTester tester,
  Offset global,
  List<double> scales, {
  required bool panFollowsScale,
}) async {
  final mouse = TestPointer(10, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(mouse.hover(global));
  final pointer = TestPointer(9, PointerDeviceKind.trackpad);
  await tester.sendEventToBinding(pointer.panZoomStart(global));
  await tester.pump();
  var ms = 0;
  for (final scale in scales) {
    ms += 16;
    await tester.sendEventToBinding(
      pointer.panZoomUpdate(
        global,
        pan: panFollowsScale ? global * (scale - 1.0) : Offset.zero,
        scale: scale,
        timeStamp: Duration(milliseconds: ms),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _pinchGesture(
  WidgetTester tester,
  Offset global, {
  double scale = 1.5,
}) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.trackpad);
  await gesture.panZoomStart(global);
  await tester.pump();
  await gesture.panZoomUpdate(
    global,
    scale: scale,
    timeStamp: const Duration(milliseconds: 16),
  );
  await tester.pump();
}

/// The whole point of anchored zoom: the scene point under the cursor before
/// the zoom is still under it afterwards.
void _expectAnchored(
  TransformationController transform,
  Offset local,
  Offset sceneBefore,
  double scaleBefore,
  String label,
) {
  final scaleAfter = _scaleOf(transform);
  expect(
    scaleAfter,
    isNot(closeTo(scaleBefore, 1e-6)),
    reason: '$label did not zoom at all, so the anchor proves nothing',
  );
  final sceneAfter = transform.toScene(local);
  final drift = sceneAfter - sceneBefore;
  expect(
    drift.distance,
    lessThan(0.5),
    reason: '$label anchored at the wrong point.\n'
        '  cursor (local)  $local\n'
        '  scene before    $sceneBefore\n'
        '  scene after     $sceneAfter\n'
        '  drift           $drift\n'
        '  scale $scaleBefore -> $scaleAfter',
  );
}

void main() {
  setUpAll(() {
    final dir = Directory.systemTemp.createTempSync('hollow_zoom_test');
    final file = File('${dir.path}${Platform.pathSeparator}zoom.png');
    file.writeAsBytesSync(const [0, 1, 2, 3]);
    _imagePath = file.path;
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {
        // A leftover temp dir is not worth failing a test over.
      }
    });
  });

  for (final geometry in _geometries) {
    group('$geometry', () {
      testWidgets('mouse wheel zooms about the pointer', (tester) async {
        final transform = await _pump(tester, geometry);
        final local = _local(tester, _cursor);
        final before = transform.toScene(local);
        final scaleBefore = _scaleOf(transform);
        await _wheel(tester, _cursor, -100);
        _expectAnchored(transform, local, before, scaleBefore, 'wheel');
      });

      testWidgets('trackpad pinch zooms about the pointer', (tester) async {
        final transform = await _pump(tester, geometry);
        final local = _local(tester, _cursor);
        final before = transform.toScene(local);
        final scaleBefore = _scaleOf(transform);
        await _pinchRaw(tester, _cursor, scale: 1.5);
        _expectAnchored(transform, local, before, scaleBefore, 'pinch');
      });

      testWidgets('trackpad pinch through a test gesture zooms about the '
          'pointer', (tester) async {
        final transform = await _pump(tester, geometry);
        final local = _local(tester, _cursor);
        final before = transform.toScene(local);
        final scaleBefore = _scaleOf(transform);
        await _pinchGesture(tester, _cursor, scale: 1.5);
        _expectAnchored(transform, local, before, scaleBefore, 'gesture pinch');
      });

      testWidgets('a pinch that also reports pan still zooms about the '
          'pointer', (tester) async {
        final transform = await _pump(tester, geometry);
        final local = _local(tester, _cursor);
        final before = transform.toScene(local);
        final scaleBefore = _scaleOf(transform);
        await _pinchRaw(
          tester,
          _cursor,
          scale: 1.5,
          pan: _cursor,
        );
        _expectAnchored(transform, local, before, scaleBefore, 'pinch + pan');
      });

      testWidgets('a pinch whose reported pan grows with the scale stays on '
          'the pointer at every step', (tester) async {
        final transform = await _pump(tester, geometry);
        final local = _local(tester, _cursor);
        final before = transform.toScene(local);
        final scaleBefore = _scaleOf(transform);
        await _pinchAccumulating(
          tester,
          _cursor,
          const [1.1, 1.4, 1.8, 2.3, 3.0],
          panFollowsScale: true,
        );
        _expectAnchored(
            transform, local, before, scaleBefore, 'accumulating pinch');
      });

      testWidgets('the anchor survives the end of the gesture', (tester) async {
        final transform = await _pump(tester, geometry);
        final local = _local(tester, _cursor);
        final before = transform.toScene(local);
        final scaleBefore = _scaleOf(transform);
        await _pinchAccumulating(
          tester,
          _cursor,
          const [1.1, 1.4, 1.8, 2.3, 3.0],
          panFollowsScale: true,
        );
        final pointer = TestPointer(9, PointerDeviceKind.trackpad);
        // Continues the sequence _pinchAccumulating opened on the same pointer.
        pointer.panZoomStart(_cursor);
        await tester.sendEventToBinding(
          pointer.panZoomEnd(timeStamp: const Duration(milliseconds: 96)),
        );
        await tester.pumpAndSettle(const Duration(milliseconds: 16));
        _expectAnchored(transform, local, before, scaleBefore, 'after release');
      });

      testWidgets('pinching back out stays on the pointer', (tester) async {
        final transform = await _pump(tester, geometry);
        const centre = Offset(600, 400);
        await _wheel(tester, centre, -400);
        final local = _local(tester, centre);
        final before = transform.toScene(local);
        final scaleBefore = _scaleOf(transform);
        expect(scaleBefore, greaterThan(2.0));
        await _pinchAccumulating(
          tester,
          centre,
          const [0.9, 0.75, 0.6],
          panFollowsScale: true,
        );
        expect(_scaleOf(transform), lessThan(scaleBefore));
        _expectAnchored(transform, local, before, scaleBefore, 'pinch out');
      });

      testWidgets('a two finger pan still moves the image', (tester) async {
        final transform = await _pump(tester, geometry);
        const centre = Offset(600, 400);
        await _wheel(tester, centre, -400);
        final local = _local(tester, centre);
        final before = transform.toScene(local);
        final scale = _scaleOf(transform);

        final pointer = TestPointer(11, PointerDeviceKind.trackpad);
        await tester.sendEventToBinding(pointer.panZoomStart(centre));
        await tester.pump();
        await tester.sendEventToBinding(
          pointer.panZoomUpdate(
            centre,
            pan: const Offset(40, 0),
            timeStamp: const Duration(milliseconds: 16),
          ),
        );
        await tester.pump();

        expect(_scaleOf(transform), closeTo(scale, 1e-6));
        final moved = before - transform.toScene(local);
        expect(moved.dx, greaterThan(1.0),
            reason: 'the image did not follow a two finger pan');
        expect(moved.dy, closeTo(0, 0.5));
      });
    });
  }
}
