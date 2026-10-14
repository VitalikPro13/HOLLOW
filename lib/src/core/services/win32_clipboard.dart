import 'dart:ffi';
import 'dart:io' show sleep;

import 'package:ffi/ffi.dart';

/// What the clipboard held at one instant.
class ClipboardSnapshot {
  /// Null when the clipboard carries no text.
  final String? text;

  /// True when an image, or a file the image paste can read, is on offer.
  final bool hasImage;

  const ClipboardSnapshot({this.text, this.hasImage = false});
}

/// Reads the Windows clipboard synchronously, trying the open [attempts]
/// times 5 ms apart; null when another program held it throughout.
///
/// The engine's paste opens the clipboard once, after a hop to the platform
/// thread, and fails if anyone holds it at that instant (clipboard history, a
/// clipboard manager, a dictation app putting back what it borrowed, #101).
/// Only call it on Windows.
ClipboardSnapshot? readWin32ClipboardSnapshot(int attempts) =>
    _Win32Clipboard.instance.read(attempts);

class _Win32Clipboard {
  static final _Win32Clipboard instance = _Win32Clipboard._();

  static const _cfBitmap = 2;
  static const _cfTiff = 6;
  static const _cfDib = 8;
  static const _cfUnicodeText = 13;
  static const _cfHdrop = 15;
  static const _cfDibV5 = 17;

  /// The registered names super_clipboard reads images from.
  static const _registeredImageFormats = [
    'PNG', 'JFIF', 'GIF', 'image/png', 'image/jpeg', 'image/gif',
    'image/webp', 'image/bmp',
  ];

  static const _openRetryGap = Duration(milliseconds: 5);

  final int Function(int) _open;
  final int Function() _close;
  final int Function(int) _getData;
  final int Function(int) _available;
  final Pointer<Utf16> Function(int) _lock;
  final int Function(int) _unlock;
  final List<int> _imageFormats;

  _Win32Clipboard._()
      : _open = _user32.lookupFunction<Int32 Function(IntPtr),
            int Function(int)>('OpenClipboard'),
        _close = _user32
            .lookupFunction<Int32 Function(), int Function()>('CloseClipboard'),
        _getData = _user32.lookupFunction<IntPtr Function(Uint32),
            int Function(int)>('GetClipboardData'),
        _available = _user32.lookupFunction<Int32 Function(Uint32),
            int Function(int)>('IsClipboardFormatAvailable'),
        _lock = _kernel32.lookupFunction<Pointer<Utf16> Function(IntPtr),
            Pointer<Utf16> Function(int)>('GlobalLock'),
        _unlock = _kernel32.lookupFunction<Int32 Function(IntPtr),
            int Function(int)>('GlobalUnlock'),
        _imageFormats = [
          _cfBitmap, _cfTiff, _cfDib, _cfHdrop, _cfDibV5,
          ..._registeredImageFormats.map(_registerFormat),
        ].where((f) => f != 0).toList();

  static final _user32 = DynamicLibrary.open('user32.dll');
  static final _kernel32 = DynamicLibrary.open('kernel32.dll');

  static int _registerFormat(String name) {
    final register = _user32.lookupFunction<Uint32 Function(Pointer<Utf16>),
        int Function(Pointer<Utf16>)>('RegisterClipboardFormatW');
    final native = name.toNativeUtf16();
    try {
      return register(native);
    } finally {
      calloc.free(native);
    }
  }

  ClipboardSnapshot? read(int attempts) {
    var opened = false;
    for (var i = 0; i < attempts && !opened; i++) {
      if (i > 0) sleep(_openRetryGap);
      opened = _open(0) != 0;
    }
    if (!opened) return null;
    try {
      return ClipboardSnapshot(
        text: _text(),
        hasImage: _imageFormats.any((f) => _available(f) != 0),
      );
    } finally {
      _close();
    }
  }

  String? _text() {
    final handle = _getData(_cfUnicodeText);
    if (handle == 0) return null;
    final chars = _lock(handle);
    if (chars == nullptr) return null;
    try {
      return chars.toDartString();
    } finally {
      _unlock(handle);
    }
  }
}
