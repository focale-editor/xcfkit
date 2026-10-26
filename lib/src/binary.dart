import 'dart:convert';
import 'dart:typed_data';

import 'package:xcfkit/src/exception.dart';
import 'package:xcfkit/src/storage.dart';

/// Bounded big-endian input, with portable 64-bit offset handling on the Web.
final class XcfReader {
  /// Random-access backing source.
  final XcfInput input;

  /// Exclusive input boundary.
  final int end;

  /// Current byte offset.
  int offset;

  /// Creates a cursor over bytes without copying.
  XcfReader(Uint8List bytes, {int offset = 0, int? end}) : this.input(XcfMemoryInput(bytes), offset: offset, end: end);

  /// Creates a cursor over a random-access source.
  XcfReader.input(this.input, {this.offset = 0, int? end}) : end = end ?? input.length, _memory = input is XcfMemoryInput ? input.read(0, input.length) : null;

  /// Direct memory view for the common in-memory numeric and RLE paths.
  final Uint8List? _memory;

  /// Numeric view created only when this cursor has a memory backing.
  late final ByteData? _data = _memory == null ? null : ByteData.sublistView(_memory);

  /// Reads a validated range without advancing this cursor.
  Uint8List range(int start, int count) {
    if (start < 0 || count < 0 || count > end - start) {
      throw XcfFormatException('Invalid XCF input range', offset: start);
    }
    final Uint8List result = input.read(start, count);
    if (result.length != count) {
      throw XcfFormatException('Short XCF input read', offset: start);
    }
    return result;
  }

  /// Ensures a read stays inside the cursor's boundary.
  void require(int count) {
    if (count < 0 || offset < 0 || count > end - offset) {
      throw XcfFormatException('Truncated XCF data ($count bytes required)', offset: offset);
    }
  }

  /// Reads an unsigned byte.
  int u8() {
    require(1);
    return _memory == null ? take(1).single : _memory[offset++];
  }

  /// Reads an unsigned 32-bit integer.
  int u32() {
    require(4);
    final ByteData? data = _data;
    if (data == null) {
      return ByteData.sublistView(take(4)).getUint32(0);
    }
    final int value = data.getUint32(offset);
    offset += 4;
    return value;
  }

  /// Reads a signed 32-bit integer.
  int i32() {
    require(4);
    final ByteData? data = _data;
    if (data == null) {
      return ByteData.sublistView(take(4)).getInt32(0);
    }
    final int value = data.getInt32(offset);
    offset += 4;
    return value;
  }

  /// Reads a 32-bit float.
  double f32() {
    require(4);
    final ByteData? data = _data;
    if (data == null) {
      return ByteData.sublistView(take(4)).getFloat32(0);
    }
    final double value = data.getFloat32(offset);
    offset += 4;
    return value;
  }

  /// Reads a file pointer, rejecting unsafe JS integers before conversion.
  int pointer(bool wide) {
    final int high = wide ? u32() : 0;
    final int low = u32();
    if (high > 0x1fffff) {
      throw XcfFormatException('XCF pointer exceeds the exact integer range', offset: offset);
    }
    final int value = high * 0x100000000 + low;
    if (value != 0 && value >= input.length) {
      throw XcfFormatException('XCF pointer is outside the file', offset: offset);
    }
    return value;
  }

  /// Reads a byte view.
  Uint8List take(int count) {
    require(count);
    final Uint8List result = range(offset, count);
    offset += count;
    return result;
  }

  /// Reads a length-prefixed, null-terminated UTF-8 string.
  String string(int maxBytes) {
    final int count = u32();
    if (count > maxBytes) {
      throw XcfFormatException('XCF string exceeds the configured limit', offset: offset);
    }
    if (count == 0) {
      return '';
    }
    final Uint8List value = take(count);
    if (value.last != 0) {
      throw XcfFormatException('XCF string has no terminator', offset: offset - 1);
    }
    if (value.take(count - 1).contains(0)) {
      throw XcfFormatException('Embedded null in XCF string', offset: offset - count);
    }
    try {
      return utf8.decode(value.sublist(0, count - 1));
    } on FormatException {
      throw XcfFormatException('Invalid UTF-8 in XCF string', offset: offset - count);
    }
  }
}

/// Growable binary output with bounded allocation and pointer patching.
final class XcfWriter {
  /// Owned expandable backing storage.
  Uint8List _bytes = Uint8List(1024);

  /// Maximum output length.
  final int maxBytes;

  /// Number of bytes already written.
  int length = 0;

  /// Creates an output cursor.
  XcfWriter(this.maxBytes, {this.output});

  /// Optional destination; null retains an in-memory output buffer.
  final XcfOutput? output;

  /// Reserves capacity without exceeding the output byte ceiling.
  void _ensure(int count) {
    if (count < 0 || count > maxBytes - length) {
      throw const XcfFormatException('Encoded XCF exceeds the configured limit');
    }
    if (output != null || length + count <= _bytes.length) {
      return;
    }
    final int capacity = (length + count > _bytes.length * 2 ? length + count : _bytes.length * 2).clamp(0, maxBytes);
    final Uint8List next = Uint8List(capacity)..setRange(0, length, _bytes);
    _bytes = next;
  }

  /// Writes an unsigned byte.
  void u8(int value) {
    _ensure(1);
    if (output != null) {
      output!.write(length++, Uint8List.fromList([value]));
    } else {
      _bytes[length++] = value;
    }
  }

  /// Writes a 32-bit value, including the bits of signed offsets.
  void u32(int value) {
    _ensure(4);
    if (output != null) {
      output!.write(length, (ByteData(4)..setUint32(0, value)).buffer.asUint8List());
    } else {
      ByteData.sublistView(_bytes).setUint32(length, value);
    }
    length += 4;
  }

  /// Writes a 32-bit floating-point value.
  void f32(double value) {
    _ensure(4);
    if (output != null) {
      output!.write(length, (ByteData(4)..setFloat32(0, value)).buffer.asUint8List());
    } else {
      ByteData.sublistView(_bytes).setFloat32(length, value);
    }
    length += 4;
  }

  /// Appends bytes.
  void add(List<int> value) {
    _ensure(value.length);
    if (output != null) {
      output!.write(length, value is Uint8List ? value : Uint8List.fromList(value));
    } else {
      _bytes.setRange(length, length + value.length, value);
    }
    length += value.length;
  }

  /// Writes a UTF-8 string.
  void string(String value) {
    if (value.contains('\u0000')) {
      throw const XcfFormatException('Embedded null in XCF string');
    }
    if (value.isEmpty) {
      u32(0);
      return;
    }
    final List<int> encoded = utf8.encode(value);
    u32(encoded.length + 1);
    add(encoded);
    u8(0);
  }

  /// Reserves a pointer slot and returns its byte position.
  int slot(bool wide) {
    final int position = length;
    if (wide) {
      u32(0);
    }
    u32(0);
    return position;
  }

  /// Updates an already reserved pointer.
  void patch(int position, int value, bool wide) {
    if (!wide && value > 0xffffffff) {
      throw const XcfFormatException('XCF version needs 64-bit offsets');
    }
    if (value < 0 || value > 0x1fffffffffffff || position < 0 || position + (wide ? 8 : 4) > length) {
      throw const XcfFormatException('Invalid XCF pointer patch');
    }
    final ByteData data = output == null ? ByteData.sublistView(_bytes) : ByteData(wide ? 8 : 4);
    final int target = output == null ? position : 0;
    if (wide) {
      data.setUint32(target, value ~/ 0x100000000);
    }
    data.setUint32(target + (wide ? 4 : 0), value % 0x100000000);
    output?.write(position, data.buffer.asUint8List());
  }

  /// Copies the populated part of the output.
  Uint8List finish() {
    if (output != null) {
      throw StateError('External output has no in-memory byte array');
    }
    return Uint8List.fromList(Uint8List.sublistView(_bytes, 0, length));
  }
}
