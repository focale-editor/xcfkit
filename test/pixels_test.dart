import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:xcfkit/xcfkit.dart';

void main() {
  test('sample access preserves native precision, HDR and special half values', () {
    final ByteData bytes = ByteData(12);
    bytes.setUint32(1, 0x12345678);
    expect(XcfPixels.readSample(bytes, 1, XcfPrecision.u32Nonlinear), 0x12345678 / 4294967295);
    bytes.setFloat64(1, -12.125);
    expect(XcfPixels.readSample(bytes, 1, XcfPrecision.doubleLinear), -12.125);
    bytes.setFloat32(1, 8.5);
    expect(XcfPixels.readSample(bytes, 1, XcfPrecision.floatLinear), 8.5);
    for (final (int, double) sample in [(0x0001, 1 / 16777216), (0x3c00, 1), (0xc000, -2), (0x7c00, double.infinity)]) {
      bytes.setUint16(1, sample.$1);
      expect(XcfPixels.readSample(bytes, 1, XcfPrecision.halfLinear), sample.$2);
    }
    bytes.setUint16(1, 0x7e00);
    expect(XcfPixels.readSample(bytes, 1, XcfPrecision.halfLinear).isNaN, isTrue);
    expect(() => XcfPixels.readSample(bytes, 11, XcfPrecision.u16Linear), throwsRangeError);
  });
  test('group marker precedes pass-through mode for GIMP loading', () {
    final XcfDocument source = XcfDocument(
      width: 1,
      height: 1,
      layers: [
        XcfLayer(
          name: 'Group',
          width: 1,
          height: 1,
          properties: [
            XcfProperty.integer(type: XcfPropertyId.mode, value: 61),
            XcfProperty(type: XcfPropertyId.groupItem, data: []),
          ],
        ),
      ],
    );
    final XcfLayer group = XcfCodec.decode(XcfCodec.encode(source)).layers.single;
    expect(group.properties.first.type, XcfPropertyId.groupItem);
    expect(group.mode, 61);
  });
  test('RGBA preview preserves hidden RGB and straight alpha', () {
    final XcfLayer layer = XcfLayer.rgba(name: 'Layer', width: 1, height: 1, pixels: [210, 30, 80, 0]);
    expect(XcfPixels.rgba8(XcfDocument(width: 1, height: 1, layers: [layer]), layer), [210, 30, 80, 0]);
  });
  test('indexed pixels use the shared palette', () {
    final XcfLayer layer = XcfLayer(
      name: 'Indexed',
      width: 2,
      height: 1,
      type: XcfLayerType.indexedAlpha,
      raster: XcfRaster(width: 2, height: 1, bytesPerPixel: 2, bytes: [1, 128, 0, 255]),
    );
    final XcfDocument document = XcfDocument(
      width: 2,
      height: 1,
      colorMode: XcfColorMode.indexed,
      layers: [layer],
      properties: [
        XcfProperty(type: XcfPropertyId.colormap, data: [0, 0, 0, 2, 10, 20, 30, 100, 150, 200]),
      ],
    );
    expect(XcfPixels.rgba8(document, layer), [100, 150, 200, 128, 10, 20, 30, 255]);
  });
  test('16-bit gray is read big-endian', () {
    final XcfLayer layer = XcfLayer(
      name: 'Gray',
      width: 1,
      height: 1,
      type: XcfLayerType.grayAlpha,
      raster: XcfRaster(width: 1, height: 1, bytesPerPixel: 4, bytes: [128, 0, 255, 255]),
    );
    expect(XcfPixels.rgba8(XcfDocument(width: 1, height: 1, colorMode: XcfColorMode.grayscale, precision: XcfPrecision.u16Nonlinear, layers: [layer]), layer), [128, 128, 128, 255]);
  });
  test('floating preview clamps HDR while original samples stay untouched', () {
    final ByteData samples = ByteData(16)
      ..setFloat32(0, 2)
      ..setFloat32(4, -0.5)
      ..setFloat32(8, 0.25)
      ..setFloat32(12, 1);
    final XcfLayer layer = XcfLayer(
      name: 'HDR',
      width: 1,
      height: 1,
      raster: XcfRaster(width: 1, height: 1, bytesPerPixel: 16, bytes: samples.buffer.asUint8List()),
    );
    expect(XcfPixels.rgba8(XcfDocument(width: 1, height: 1, precision: XcfPrecision.floatLinear, layers: [layer]), layer), [255, 0, 64, 255]);
    expect(ByteData.sublistView(layer.raster!.bytes).getFloat32(0), 2);
  });
}
