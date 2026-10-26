import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:xcfkit/src/binary.dart';
import 'package:xcfkit/src/compression.dart';
import 'package:xcfkit/xcfkit.dart';

void main() {
  test('RLE handles all four specified opcodes and byte-plane interleaving', () {
    final Uint8List encoded = Uint8List.fromList([
      2,
      10,
      127,
      0,
      2,
      20,
      253,
      30,
      40,
      50,
      128,
      0,
      8,
      0,
      1,
      2,
      3,
      4,
      5,
      6,
      7,
    ]);
    expect(decodeXcfTile(XcfReader(encoded), 8, 2, XcfCompression.rle), [10, 0, 10, 1, 10, 2, 20, 3, 20, 4, 30, 5, 40, 6, 50, 7]);
  });
  test('RLE refuses zero runs, overlong runs, and truncated literals', () {
    for (final List<int> bytes in [
      [127, 0, 0, 1],
      [128, 0, 0],
      [2, 1],
      [254, 1],
    ]) {
      expect(() => decodeXcfTile(XcfReader(Uint8List.fromList(bytes)), 2, 1, XcfCompression.rle), throwsA(isA<XcfFormatException>()));
    }
  });
  test('zlib verifies its header, exact decoded size, and checksum', () {
    // Python zlib.compress(bytes([1, 2, 3])): independent compressed stream.
    final Uint8List bytes = Uint8List.fromList([120, 156, 99, 100, 98, 6, 0, 0, 13, 0, 7]);
    expect(decodeXcfTile(XcfReader(bytes), 3, 1, XcfCompression.zlib), [1, 2, 3]);
    for (final int size in [2, 4]) {
      expect(() => decodeXcfTile(XcfReader(bytes), size, 1, XcfCompression.zlib), throwsA(isA<XcfFormatException>()));
    }
    bytes[10] ^= 1;
    expect(() => decodeXcfTile(XcfReader(bytes), 3, 1, XcfCompression.zlib), throwsA(isA<XcfFormatException>()));
  });
}
