import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:xcfkit/xcfkit.dart';

/// Writes new documents for independent reopening in GIMP, covering all encodings.
Future<void> main() async {
  final Directory directory = Directory('build/interop');
  await directory.create(recursive: true);
  final List<Object> expected = [];
  for (final XcfPrecision precision in XcfPrecision.values) {
    final ByteData samples = ByteData(67 * 65 * 4 * precision.bytesPerComponent);
    for (int i = 0; i < 67 * 65 * 4; i++) {
      final int offset = i * precision.bytesPerComponent;
      final double value = i % 4 == 3 ? 1 : (i % 5) / 4;
      if (!precision.isFloatingPoint) {
        switch (precision.bytesPerComponent) {
          case 1:
            samples.setUint8(offset, (value * 255).round());
          case 2:
            samples.setUint16(offset, (value * 65535).round());
          case 4:
            samples.setUint32(offset, (value * 4294967295).round());
        }
      } else {
        switch (precision.bytesPerComponent) {
          case 2:
            samples.setUint16(offset, i % 4 == 3 ? 0x3c00 : [0, 0x3800, 0x3c00, 0x4000][i % 4]);
          case 4:
            samples.setFloat32(offset, value);
          case 8:
            samples.setFloat64(offset, value);
        }
      }
    }
    for (final XcfCompression compression in XcfCompression.values) {
      final String name = '${precision.name}-${compression.name}.xcf';
      final XcfDocument document = XcfDocument(
        width: 67,
        height: 65,
        precision: precision,
        compression: compression,
        layers: [
          XcfLayer(
            name: 'New samples',
            width: 67,
            height: 65,
            raster: XcfRaster(width: 67, height: 65, bytesPerPixel: 4 * precision.bytesPerComponent, bytes: samples.buffer.asUint8List()),
          ),
        ],
      );
      await File('${directory.path}/$name').writeAsBytes(XcfCodec.encode(document));
      expected.add({'file': name, 'precision': precision.code, 'sha256': sha256.convert(samples.buffer.asUint8List()).toString()});
    }
  }
  await File('${directory.path}/expected.json').writeAsString('${const JsonEncoder.withIndent('  ').convert(expected)}\n');
  stdout.writeln('Wrote ${expected.length} independent encoder fixtures.');
}
