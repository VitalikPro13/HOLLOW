import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// The side of the avatar the Android call notification gets: it shows it at
/// about 64 dp, so this stays sharp up to roughly 2.5x density.
const int kOsCallAvatarSide = 160;

/// A DM friend's face for the Android call notification (#154): a square of
/// premultiplied RGBA pixels this app drew, so native copies pixels and never
/// runs an image decoder on peer bytes.
@immutable
class OsCallAvatar {
  final int side;
  final Uint8List rgba;

  const OsCallAvatar(this.side, this.rgba);
}

/// Draws the first frame of [bytes] (an animated avatar gives a still),
/// centre-cropped to a [side] square. [bytes] must be what `image_gate`
/// passed (`getAvatar`); null when they do not decode.
Future<OsCallAvatar?> renderOsCallAvatar(Uint8List bytes,
    {int side = kOsCallAvatarSide}) async {
  if (bytes.isEmpty || side <= 0) return null;
  ui.Codec? codec;
  ui.Image? frame;
  ui.Image? square;
  try {
    codec = await ui.instantiateImageCodec(bytes);
    frame = (await codec.getNextFrame()).image;
    final w = frame.width.toDouble();
    final h = frame.height.toDouble();
    if (w <= 0 || h <= 0) return null;
    final crop = w < h ? w : h;
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      frame,
      ui.Rect.fromLTWH((w - crop) / 2, (h - crop) / 2, crop, crop),
      ui.Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    final picture = recorder.endRecording();
    square = await picture.toImage(side, side);
    picture.dispose();
    final data = await square.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null || data.lengthInBytes != side * side * 4) return null;
    return OsCallAvatar(
        side, data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
  } catch (_) {
    return null;
  } finally {
    square?.dispose();
    frame?.dispose();
    codec?.dispose();
  }
}
