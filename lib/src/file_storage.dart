/// Optional synchronous file adapters; use from an isolate in UI applications.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:xcfkit/src/exception.dart';
import 'package:xcfkit/src/storage.dart';

/// Bounded cached file input, owned and closed by its caller.
final class XcfFileInput implements XcfInput {
  /// Open read handle.
  final RandomAccessFile _file;

  /// Maximum cache capacity.
  final int cacheBytes;

  /// Byte position of the cached range.
  int _start = 0;

  /// Most recently read range.
  Uint8List _cache = Uint8List(0);

  /// Whether this source has been closed.
  bool _closed = false;

  @override
  final int length;

  /// Opens a file without reading its contents.
  factory XcfFileInput(String path, {int cacheBytes = 64 * 1024}) {
    if (cacheBytes < 0) {
      throw ArgumentError.value(cacheBytes, 'cacheBytes');
    }
    final RandomAccessFile file = File(path).openSync();
    try {
      return XcfFileInput._(file, file.lengthSync(), cacheBytes);
    } catch (_) {
      file.closeSync();
      rethrow;
    }
  }

  /// Retains an opened handle and its fixed length.
  XcfFileInput._(this._file, this.length, this.cacheBytes);

  @override
  Uint8List read(int offset, int count) {
    if (_closed) {
      throw StateError('XCF input is closed');
    }
    if (offset < 0 || count < 0 || count > length - offset) {
      throw RangeError('XCF input range is outside the file');
    }
    if (offset >= _start && offset + count <= _start + _cache.length) {
      return Uint8List.sublistView(_cache, offset - _start, offset - _start + count);
    }
    _file.setPositionSync(offset);
    final int size = (count > cacheBytes ? count : cacheBytes).clamp(0, length - offset);
    final Uint8List bytes = _file.readSync(size);
    if (bytes.length != size) {
      throw const XcfFormatException('File changed or was truncated during XCF reading');
    }
    if (size <= cacheBytes) {
      _start = offset;
      _cache = bytes;
    }
    return Uint8List.sublistView(bytes, 0, count);
  }

  /// Releases the handle; rasters referring to this source can no longer read.
  void close() {
    if (!_closed) {
      _closed = true;
      _cache = Uint8List(0);
      _file.closeSync();
    }
  }
}

/// Seekable file output, with no retained encoded image buffer.
final class XcfFileOutput implements XcfOutput {
  /// Open write handle.
  final RandomAccessFile _file;

  /// Creates/truncates a destination; use a temporary path for safe replacement.
  XcfFileOutput(String path) : _file = File(path).openSync(mode: FileMode.write);

  @override
  void write(int offset, Uint8List bytes) {
    _file.setPositionSync(offset);
    _file.writeFromSync(bytes);
  }

  /// Flushes, optionally truncates to the codec's returned length, and closes.
  void close({int? length}) {
    try {
      if (length != null) {
        _file.truncateSync(length);
      }
      _file.flushSync();
    } finally {
      _file.closeSync();
    }
  }
}
