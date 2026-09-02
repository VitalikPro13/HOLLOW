import 'dart:convert';
import 'dart:typed_data';

/// Wire transfer ids ride every stream frame as a 64-byte NUL-padded field and
/// end up inside a temp file name (`.webrtc_recv_<id>.tmp`), so the parser is
/// the gate: anything outside the characters our own ids use is a hostile
/// frame. Own ids are 32-hex file ids, `hex:index` share chunks and shards,
/// and `link_<code>` snapshots. A `/../` in the field escapes the files
/// directory on Windows, where paths are normalised lexically before the
/// filesystem sees them. Mirrors `parse_id` in `ws_stream_transfer.rs`.
final RegExp _wireTransferIdPattern = RegExp(r'^[A-Za-z0-9:_-]{1,64}$');

bool isSafeWireTransferId(String id) => _wireTransferIdPattern.hasMatch(id);

/// Decodes the 64-byte id field at [offset]. Null when the bytes are not UTF-8
/// or the id carries characters outside the allowlist.
String? parseWireTransferId(Uint8List data, int offset) {
  final idBytes = data.sublist(offset, offset + 64);
  final nulIndex = idBytes.indexOf(0);
  final len = nulIndex == -1 ? 64 : nulIndex;
  final String id;
  try {
    id = utf8.decode(idBytes.sublist(0, len));
  } on FormatException {
    return null;
  }
  return isSafeWireTransferId(id) ? id : null;
}
