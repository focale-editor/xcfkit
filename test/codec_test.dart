import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:xcfkit/xcfkit.dart';

void main() {
  group('tile and precision preservation', () {
    for (final XcfCompression compression in XcfCompression.values) {
      for (final XcfPrecision precision in XcfPrecision.values) {
        test('${compression.name} ${precision.name}: edge tiles and hidden RGB', () {
          const int width = 67;
          const int height = 65;
          final Random random = Random(71);
          final Uint8List samples = Uint8List.fromList(List.generate(width * height * 4 * precision.bytesPerComponent, (_) => random.nextInt(256)));
          final XcfDocument source = XcfDocument(
            width: width,
            height: height,
            precision: precision,
            compression: compression,
            layers: [
              XcfLayer(
                name: 'Échantillons 🖌',
                width: width,
                height: height,
                raster: XcfRaster(width: width, height: height, bytesPerPixel: 4 * precision.bytesPerComponent, bytes: samples),
              ),
            ],
          );
          final XcfDocument result = XcfCodec.decode(XcfCodec.encode(source));
          expect(result.precision, precision);
          expect(result.compression, compression);
          expect(result.layers.single.name, source.layers.single.name);
          expect(result.layers.single.raster!.bytes, orderedEquals(samples));
        });
      }
    }
  });

  test('legacy 32-bit and modern 64-bit pointer layouts', () {
    for (final int version in [0, 1, 2, 3, 7, 8, 9, 10, 11, 12, 13, 18, 20, 22, 23, 24, 25, 26]) {
      final XcfDocument source = _simple().copyWith(version: version);
      final XcfDocument decoded = XcfCodec.decode(XcfCodec.encode(source));
      expect(decoded.version, version);
      expect(decoded.layers.single.raster!.bytes, source.layers.single.raster!.bytes);
    }
  });

  test('groups, masks, channels, and metadata survive pointer relocation', () {
    final XcfChannel mask = XcfChannel(
      name: 'Mask',
      raster: XcfRaster(width: 2, height: 1, bytesPerPixel: 1, bytes: [0, 128]),
    );
    final XcfLayer group = XcfLayer(
      name: 'Group',
      width: 2,
      height: 1,
      properties: [XcfProperty(type: XcfPropertyId.groupItem, data: [])],
      mask: mask,
    );
    final XcfLayer child = _simple().layers.single.copyWith(
      mask: mask,
      properties: [
        XcfProperty.itemPath([0, 0]),
        XcfProperty.offsets(x: -7, y: 3),
        XcfProperty.integer(type: XcfPropertyId.applyMask, value: 0),
        XcfProperty.integer(type: XcfPropertyId.opacity, value: 128),
        XcfProperty.floating(type: XcfPropertyId.floatOpacity, value: 0.25),
        XcfParasite.toProperty([
          XcfParasite(name: 'test-data', data: [0, 255, 42]),
        ]),
      ],
    );
    final XcfDocument decoded = XcfCodec.decode(XcfCodec.encode(XcfDocument(width: 2, height: 1, layers: [group, child], channels: [mask])));
    expect(decoded.layerTree.single.children.single.layer.name, child.name);
    expect(decoded.layers.last.x, -7);
    expect(decoded.layers.last.y, 3);
    expect(decoded.layers.last.opacity, 0.25);
    expect(decoded.layers.last.applyMask, isFalse);
    expect(decoded.layers.last.properties.parasites.single.data, [0, 255, 42]);
    expect(decoded.channels.single.raster.bytes, [0, 128]);
    expect(decoded.layers.first.mask!.raster.bytes, [0, 128]);
  });

  test('effects retain repeated arguments, operation version, and mask', () {
    final XcfEffect effect = XcfEffect(
      name: 'Brightness',
      operation: 'gegl:brightness-contrast',
      version: 'test',
      properties: [
        XcfProperty(type: 45, data: [1, 2, 3]),
        XcfProperty(type: 45, data: [4, 5, 6]),
      ],
      mask: XcfChannel(
        name: 'Effect mask',
        raster: XcfRaster(width: 2, height: 1, bytesPerPixel: 1, bytes: [255, 128]),
      ),
    );
    final XcfDocument original = _simple();
    final XcfDocument result = XcfCodec.decode(
      XcfCodec.encode(
        original.copyWith(
          version: 22,
          layers: [
            original.layers.single.copyWith(effects: [effect]),
          ],
        ),
      ),
    );
    expect(result.layers.single.effects.single.operation, effect.operation);
    expect(result.layers.single.effects.single.version, 'test');
    expect(result.layers.single.effects.single.properties.map((p) => p.data.toList()).toList(), [
      [1, 2, 3],
      [4, 5, 6],
    ]);
    expect(result.layers.single.effects.single.mask!.raster.bytes, [255, 128]);
  });

  test('standard dart:convert codec and its inverse', () {
    const XcfDocumentCodec codec = XcfDocumentCodec();
    final XcfDocument document = codec.decode(codec.encode(_simple()));
    expect(codec.inverted.encode(codec.inverted.decode(document)).layers.single.name, 'Pixels');
  });

  test('model copies caller-owned mutable values', () {
    final Uint8List samples = Uint8List.fromList([1, 2, 3, 4]);
    final XcfLayer layer = XcfLayer.rgba(name: 'One', width: 1, height: 1, pixels: samples);
    samples[0] = 99;
    expect(layer.raster!.bytes[0], 1);
    expect(() => layer.raster!.bytes[0] = 100, throwsUnsupportedError);
  });

  test('every truncated prefix fails with a format error', () {
    final Uint8List bytes = XcfCodec.encode(_simple());
    for (int end = 0; end < bytes.length; end++) {
      expect(() => XcfCodec.decode(Uint8List.sublistView(bytes, 0, end)), throwsA(isA<XcfFormatException>()), reason: 'prefix $end');
    }
  });

  test('rejects malformed version tags and unsupported development versions', () {
    final Uint8List bytes = XcfCodec.encode(_simple());
    for (final String tag in ['vABC', 'xxxx', 'v004', 'v005', 'v006', 'v027', 'v999']) {
      final Uint8List input = Uint8List.fromList(bytes)..setRange(9, 13, ascii.encode(tag));
      expect(() => XcfCodec.decode(input), throwsA(isA<XcfFormatException>()));
    }
  });

  test('input, decoded sample, metadata, and item budgets are enforced', () {
    final Uint8List bytes = XcfCodec.encode(_simple());
    for (final XcfReadOptions options in [
      const XcfReadOptions(maxInputBytes: 1),
      const XcfReadOptions(maxPixels: 1),
      const XcfReadOptions(maxDecodedBytes: 1),
      const XcfReadOptions(maxMetadataBytes: 0),
      const XcfReadOptions(maxItems: 0),
      const XcfReadOptions(maxProperties: 0),
      const XcfReadOptions(maxStringBytes: 1),
    ]) {
      expect(() => XcfCodec.decode(bytes, options: options), throwsA(isA<XcfFormatException>()));
    }
    expect(() => XcfCodec.encode(_simple(), options: const XcfWriteOptions(maxOutputBytes: 10)), throwsA(isA<XcfFormatException>()));
  });

  test('unsafe 64-bit pointer values are rejected before integer rounding', () {
    final Uint8List bytes = XcfCodec.encode(_simple());
    final int slot = _layerSlot(bytes);
    ByteData.sublistView(bytes).setUint32(slot, 0x200000);
    expect(() => XcfCodec.decode(bytes), throwsA(isA<XcfFormatException>()));
  });

  test('zero first tile pointer means an entirely empty level', () {
    final Uint8List bytes = XcfCodec.encode(_simple());
    final ByteData data = ByteData.sublistView(bytes);
    int cursor = data.getUint32(_layerSlot(bytes) + 4) + 12;
    cursor += 4 + data.getUint32(cursor);
    while (data.getUint32(cursor) != 0) {
      cursor += 8 + data.getUint32(cursor + 4);
    }
    final int hierarchy = data.getUint32(cursor + 8 + 4);
    final int level = data.getUint32(hierarchy + 12 + 4);
    data.setUint32(level + 8, 0);
    data.setUint32(level + 12, 0);
    final Uint8List empty = Uint8List.sublistView(bytes, 0, level + 16);
    expect(XcfCodec.decode(empty).layers.single.raster!.bytes, List.filled(8, 0));
  });

  test('unknown metadata is readable but unsafe relocation is rejected', () {
    final XcfDocument document = _simple().copyWith(
      properties: [
        XcfProperty(type: 1000, data: [1, 2, 3]),
      ],
    );
    expect(() => XcfCodec.encode(document), throwsA(isA<XcfUnsupportedException>()));
  });

  test('floating selections cannot be silently relocated', () {
    final XcfDocument source = _simple();
    final XcfLayer layer = source.layers.single.copyWith(
      properties: [XcfProperty(type: XcfPropertyId.floatingSelection, data: List.filled(8, 0))],
    );
    expect(() => XcfCodec.encode(source.copyWith(layers: [layer])), throwsA(isA<XcfUnsupportedException>()));
  });

  test('orphaned group paths are rejected', () {
    final XcfDocument source = _simple();
    final XcfLayer layer = source.layers.single.copyWith(
      properties: [
        XcfProperty.itemPath([5, 0]),
      ],
    );
    expect(() => XcfCodec.encode(source.copyWith(layers: [layer])), throwsA(isA<XcfFormatException>()));
  });

  test('historical custom-unit lengths are computed from the fields', () {
    final BytesBuilder payload = BytesBuilder();
    payload.add(
      (ByteData(8)
            ..setFloat32(0, 1)
            ..setUint32(4, 2))
          .buffer
          .asUint8List(),
    );
    for (final String value in ['unit', 'u', 'u', 'unit', 'units']) {
      final List<int> encoded = utf8.encode(value);
      payload.add((ByteData(4)..setUint32(0, encoded.length + 1)).buffer.asUint8List());
      payload.add(encoded);
      payload.addByte(0);
    }
    final XcfDocument document = _simple().copyWith(
      properties: [XcfProperty(type: XcfPropertyId.userUnit, data: payload.takeBytes())],
    );
    final Uint8List input = XcfCodec.encode(document);
    ByteData.sublistView(input).setUint32(34, 0xffffffff);
    final XcfDocument decoded = XcfCodec.decode(input);
    expect(decoded.warnings.single, contains('Corrected length'));
    expect(decoded.properties.property(XcfPropertyId.userUnit)!.data, document.properties.single.data);
    expect(XcfCodec.decode(XcfCodec.encode(decoded)).warnings, isEmpty);
  });

  test('historical colormap lengths do not desynchronize the reader', () {
    final XcfDocument document = XcfDocument(
      width: 1,
      height: 1,
      colorMode: XcfColorMode.indexed,
      properties: [
        XcfProperty(type: XcfPropertyId.colormap, data: [0, 0, 0, 2, 10, 20, 30, 40, 50, 60]),
      ],
      layers: [
        XcfLayer(
          name: 'Index',
          width: 1,
          height: 1,
          type: XcfLayerType.indexed,
          raster: XcfRaster(width: 1, height: 1, bytesPerPixel: 1, bytes: [1]),
        ),
      ],
    );
    final Uint8List input = XcfCodec.encode(document);
    ByteData.sublistView(input).setUint32(34, 6);
    final XcfDocument decoded = XcfCodec.decode(input);
    expect(decoded.palette, [10, 20, 30, 40, 50, 60]);
    expect(decoded.layers.single.raster!.bytes, [1]);
    expect(decoded.warnings, hasLength(1));
  });

  test('deterministic malformed-input mutations stay bounded and typed', () {
    final Random random = Random(103);
    final Uint8List source = XcfCodec.encode(_simple());
    for (int i = 0; i < 1000; i++) {
      final Uint8List input = Uint8List.fromList(source);
      for (int mutation = 0; mutation < 1 + i % 4; mutation++) {
        input[random.nextInt(input.length)] = random.nextInt(256);
      }
      try {
        XcfCodec.decode(input, options: const XcfReadOptions(maxPixels: 1024, maxDecodedBytes: 8192, maxMetadataBytes: 8192, maxItems: 100, maxProperties: 100));
      } on Object catch (error) {
        expect(error, isA<XcfFormatException>(), reason: 'mutation $i');
      }
    }
  });
}

XcfDocument _simple() => XcfDocument(
  width: 2,
  height: 1,
  layers: [
    XcfLayer.rgba(name: 'Pixels', width: 2, height: 1, pixels: [200, 30, 10, 0, 20, 80, 100, 255]),
  ],
);

/// Walks only the independently documented header and property envelopes.
int _layerSlot(Uint8List bytes) {
  final ByteData data = ByteData.sublistView(bytes);
  int cursor = 30;
  while (data.getUint32(cursor) != 0) {
    cursor += 8 + data.getUint32(cursor + 4);
  }
  return cursor + 8;
}
