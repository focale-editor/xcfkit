@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:xcfkit/src/binary.dart';
import 'package:xcfkit/xcfkit_io.dart';

void main() {
  test('file input, progressive output and explicit source lifetime', () {
    final Directory directory = Directory.systemTemp.createTempSync('xcfkit-storage-');
    try {
      final XcfDocument document = XcfDocument(
        width: 129,
        height: 67,
        layers: [XcfLayer.rgba(name: 'Tiles', width: 129, height: 67, pixels: List.generate(129 * 67 * 4, (index) => index % 251))],
      );
      final Uint8List expected = XcfCodec.encode(document);
      final File original = File('${directory.path}/source.xcf')..writeAsBytesSync(expected);
      final XcfFileInput input = XcfFileInput(original.path, cacheBytes: 1024);
      final XcfDocument lazy = XcfCodec.open(input);
      final XcfFileOutput output = XcfFileOutput('${directory.path}/destination.xcf');
      final int length = XcfCodec.encodeTo(lazy, output);
      output.close(length: length);
      expect(File('${directory.path}/destination.xcf').readAsBytesSync(), expected);
      expect(lazy.layers.single.raster!.bytes, document.layers.single.raster!.bytes);
      input.close();
      input.close();
      expect(() => lazy.layers.single.raster!.bytes, throwsStateError);
    } finally {
      directory.deleteSync(recursive: true);
    }
  });

  test('real sparse file follows 64-bit offsets beyond 4 GiB without loading gaps', () {
    final Directory directory = Directory.systemTemp.createTempSync('xcfkit-sparse-');
    try {
      final Uint8List bytes = XcfCodec.encode(
        XcfDocument(
          version: 11,
          width: 1,
          height: 1,
          compression: XcfCompression.raw,
          layers: [
            XcfLayer.rgba(name: 'Sparse', width: 1, height: 1, pixels: [9, 8, 7, 6]),
          ],
        ),
      );
      final XcfReader root = XcfReader(bytes, offset: 30);
      _skipProperties(root);
      final int layerSlot = root.offset;
      final int layerOffset = root.pointer(true);
      final XcfReader layer = XcfReader(bytes, offset: layerOffset)..take(12);
      layer.string(1024);
      _skipProperties(layer);
      final int hierarchySlot = layer.offset;
      final int hierarchyOffset = layer.pointer(true);
      final XcfReader hierarchy = XcfReader(bytes, offset: hierarchyOffset)..take(12);
      final int levelSlot = hierarchy.offset;
      final int levelOffset = hierarchy.pointer(true);
      final XcfReader level = XcfReader(bytes, offset: levelOffset)..take(8);
      final int tileSlot = level.offset;
      final int tileOffset = level.pointer(true);
      const int delta = 0x100000000;
      final ByteData data = ByteData.sublistView(bytes);
      for (final (int slot, int value) in [(layerSlot, layerOffset), (hierarchySlot, hierarchyOffset), (levelSlot, levelOffset), (tileSlot, tileOffset)]) {
        data
          ..setUint32(slot, (value + delta) ~/ 0x100000000)
          ..setUint32(slot + 4, (value + delta) % 0x100000000);
      }
      final String path = '${directory.path}/sparse.xcf';
      final RandomAccessFile file = File(path).openSync(mode: FileMode.write);
      file.writeFromSync(bytes, 0, layerOffset);
      file.setPositionSync(layerOffset + delta);
      file.writeFromSync(bytes, layerOffset);
      file.closeSync();
      final XcfFileInput input = XcfFileInput(path, cacheBytes: 128);
      try {
        expect(input.length, greaterThan(0xffffffff));
        final XcfDocument document = XcfCodec.open(input, options: const XcfReadOptions(maxInputBytes: 5 * 1024 * 1024 * 1024));
        expect(document.layers.single.raster!.bytes, [9, 8, 7, 6]);
        final XcfDocument compacted = XcfCodec.decode(XcfCodec.encode(document));
        expect(compacted.layers.single.raster!.bytes, [9, 8, 7, 6]);
      } finally {
        input.close();
      }
    } finally {
      directory.deleteSync(recursive: true);
    }
  });
}

/// Skips fixed-length envelopes in a freshly encoded test document.
void _skipProperties(XcfReader reader) {
  while (reader.u32() != 0) {
    reader.take(reader.u32());
  }
  expect(reader.u32(), 0);
}
