import 'dart:convert';
import 'dart:typed_data';

/// Wire transfer ids ride every stream frame as a 64-byte NUL-padded field and
/// end up inside a temp file name, so the parser IS the gate: anything outside
/// the characters our own ids use is a hostile frame, and a `/../` there
/// escapes the files directory on Windows, which normalises paths lexically
/// before the filesystem sees them. Own ids are file and shard stream ids,
/// `hex:index` share chunks, and `link_<code>` snapshots. Mirrors `parse_id` in
/// `ws_stream_transfer.rs`.
final RegExp _wireTransferIdPattern = RegExp(r'^[A-Za-z0-9:_-]{1,64}$');

/// A file or shard stream id: 64 lowercase hex, one per transfer
/// (`file_stream_id` / `shard_stream_id` in Rust).
final RegExp _streamIdPattern = RegExp(r'^[0-9a-f]{64}$');

bool isSafeWireTransferId(String id) => _wireTransferIdPattern.hasMatch(id);

bool isStreamTransferId(String id) => _streamIdPattern.hasMatch(id);

/// Whether a stream of [kind] may open under [id]: a file or shard stream only under
/// a stream id, the shape Rust's `is_stream_id` takes on the relay lane.
bool rtcStreamIdFits(String kind, String id) =>
    (kind != 'file' && kind != 'shard') || isStreamTransferId(id);

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
