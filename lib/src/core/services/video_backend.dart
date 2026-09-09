import 'dart:io';

import 'package:fvp/fvp.dart' as fvp;

/// fvp provides the video_player backend on desktop, where the official
/// plugin has no native support.
///
/// Linux decodes in software only. mdk's default list tries VAAPI, CUDA and
/// VDPAU first, and on a laptop with the NVIDIA driver but no libnvcuvid the
/// CUDA path called a null function pointer and killed the process on the
/// first Play tap (issue #72, 2026-09-09).
void registerVideoBackend() {
  if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) return;
  if (Platform.isLinux) {
    fvp.registerWith(options: {
      'video.decoders': ['FFmpeg', 'dav1d'],
    });
    return;
  }
  fvp.registerWith();
}
