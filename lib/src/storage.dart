import 'dart:typed_data';

/// Random-access input for XCF metadata and individual compressed tiles.
///
/// Reads are synchronous and must return exactly [count] bytes. The source must
/// remain open and unchanged while any lazy raster refers to it. Implementations
/// may cache bounded ranges; they must not download/read the whole file implicitly.
abstract interface class XcfInput {
  /// Total byte length, limited to JavaScript's exact integer range.
  int get length;

  /// Reads an owned or immutable range without changing the source.
  Uint8List read(int offset, int count);
}

/// Seekable output receiving bounded chunks with synchronous backpressure.
///
/// The encoder writes offsets relative to zero and patches pointer tables. Use a
/// fresh destination; after success truncate it to the returned encoded length.
/// An exception can leave partial output, so use a temporary file for replacement.
abstract interface class XcfOutput {
  /// Writes all bytes at the requested absolute position before returning.
  void write(int offset, Uint8List bytes);
}

/// Byte-array input; callers must not mutate the array during lazy access.
final class XcfMemoryInput implements XcfInput {
  /// Caller-owned encoded bytes.
  final Uint8List _bytes;

  /// Wraps bytes without copying them.
  XcfMemoryInput(this._bytes);

  @override
  int get length => _bytes.length;

  @override
  Uint8List read(int offset, int count) => Uint8List.sublistView(_bytes, offset, offset + count);
}
