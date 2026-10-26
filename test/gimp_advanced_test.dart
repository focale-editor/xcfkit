@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:xcfkit/xcfkit_compression.dart';

import '../tool/write_advanced_edits.dart' as edits;

void main() {
  const String root = 'test/fixtures/gimp-advanced';
  final List<Object?> references = jsonDecode(File('$root/reference.json').readAsStringSync()) as List<Object?>;
  for (final Object? raw in references) {
    final Map<String, Object?> reference = raw! as Map<String, Object?>;
    test('advanced metadata matches independent GIMP APIs: ${reference['file']}', () {
      expect(reference['ok'], isTrue);
      expect(reference['equal_to_original'], isTrue);
      final XcfDocument document = XcfWrappedCodec.decode(File('$root/${reference['file']}').readAsBytesSync());
      for (final XcfDocument value in [document, XcfCodec.decode(XcfCodec.encode(document))]) {
        _compareMetadata(value, reference);
        expect(XcfCodec.preflight(value).canWrite, isTrue);
      }
    });
  }
  test('vector and curve edits match independently authored GIMP metadata', () {
    final Directory directory = Directory.systemTemp.createTempSync('xcfkit-advanced-edits-');
    try {
      edits.main([directory.path]);
      final List<Object?> expected = jsonDecode(File('$root/edits-reference.json').readAsStringSync()) as List<Object?>;
      for (final Object? raw in expected) {
        final Map<String, Object?> reference = raw! as Map<String, Object?>;
        expect(reference['equal_to_original'], isTrue);
        final XcfDocument document = XcfCodec.decode(File('${directory.path}/edits/${reference['file']}').readAsBytesSync());
        _compareMetadata(document, reference);
        final XcfDocument target = XcfCodec.decode(File('$root/${reference['file']}').readAsBytesSync());
        expect(document.layers.single.raster!.bytes, target.layers.single.raster!.bytes);
        if (reference['file'] == 'curves-edited.xcf') {
          final XcfConfiguration actual = document.layers.single.effects.single.argument('config')!.configuration!;
          final XcfConfiguration original = target.layers.single.effects.single.argument('config')!.configuration!;
          expect(actual.names, original.names);
          for (int i = 0; i < actual.names.where((name) => name == 'curve').length; i++) {
            final XcfCurve curve = XcfCurve(actual.nested('curve', occurrence: i)!);
            final XcfCurve expectedCurve = XcfCurve(original.nested('curve', occurrence: i)!);
            expect(curve.samples, expectedCurve.samples);
            expect(curve.points.map((point) => [point.x, point.y, point.type]), expectedCurve.points.map((point) => [point.x, point.y, point.type]));
          }
        }
      }
    } finally {
      directory.deleteSync(recursive: true);
    }
  });

  test('real compressed GIMP fixtures enforce checksums, size and XZ dictionary limits', () {
    for (final String extension in ['gz', 'bz2', 'xz']) {
      final Uint8List bytes = File('$root/document-metadata.xcf.$extension').readAsBytesSync();
      expect(XcfWrappedCodec.unwrap(bytes), File('$root/document-metadata.xcf').readAsBytesSync());
      expect(() => XcfWrappedCodec.unwrap(bytes, maxOutputBytes: 100), throwsA(isA<XcfFormatException>()));
    }
    expect(() => XcfWrappedCodec.unwrap(File('$root/document-metadata.xcf.xz').readAsBytesSync(), maxDictionaryBytes: 1024), throwsA(isA<XcfFormatException>()));
  });
}

/// Compares only values GIMP exposes independently of the XCF parser.
void _compareMetadata(XcfDocument document, Map<String, Object?> reference) {
  final Map<String, Object?> metadata = reference['document_metadata']! as Map<String, Object?>;
  final List<Object?> guides = metadata['guides']! as List<Object?>;
  expect(
    document.guides.map((guide) => [guide.position, guide.orientation - 1]),
    guides.map((guide) {
      final Map<String, Object?> value = guide! as Map<String, Object?>;
      return [value['position'], value['orientation']];
    }),
  );
  expect(document.samplePoints.map((point) => [point.x, point.y]), metadata['sample_points']);
  if (document.resolution case final XcfResolution resolution) {
    final List<Object?> expected = metadata['resolution']! as List<Object?>;
    expect([resolution.x, resolution.y], expected.sublist(1));
  }
  if (document.userUnit case final XcfUserUnit unit) {
    final Map<String, Object?> expected = metadata['unit']! as Map<String, Object?>;
    expect([unit.name, unit.factor, unit.digits, unit.symbol, unit.abbreviation], [expected['name'], expected['factor'], expected['digits'], expected['symbol'], expected['abbreviation']]);
  }
  final List<Object?> layers = reference['layers']! as List<Object?>;
  for (int i = 0; i < document.layers.length; i++) {
    final XcfLayer layer = document.layers[i];
    final Map<String, Object?> expected = layers[i]! as Map<String, Object?>;
    if (expected['vector'] case final Map<String, Object?> vector) {
      final XcfVectorLayer actual = layer.vectorLayer!;
      expect(actual.pathTattoo, vector['path_tattoo']);
      expect(actual.resolvePath(document).properties.property(XcfPropertyId.tattoo)!.integer, actual.pathTattoo);
      expect(
        [actual.enableFill, actual.enableStroke, actual.strokeWidth, actual.capStyle, actual.joinStyle, actual.miterLimit],
        [vector['fill'], vector['stroke'], vector['width'], vector['cap'], vector['join'], vector['miter']],
      );
      expect(actual.dashes, (vector['dashes']! as List<Object?>)[1]);
      for (final (String name, XcfColor? color) in [('fill_color_bytes', actual.fill.color), ('stroke_color_bytes', actual.stroke.color)]) {
        if (vector[name] case final Map<String, Object?> encoded) {
          expect(color!.encoding, encoded['encoding']);
          final String hex = encoded['pixel']! as String;
          final Uint8List bytes = Uint8List.fromList([for (int offset = 0; offset < hex.length; offset += 2) int.parse(hex.substring(offset, offset + 2), radix: 16)]);
          expect(color.encoding, "R'G'B'A float");
          // GIMP's color API converts the reloaded color through Babl, introducing
          // sub-micro-unit rounding. Raw metadata round-trips stay byte exact.
          final ByteData actual = ByteData.sublistView(color.pixel);
          final ByteData expected = ByteData.sublistView(bytes);
          for (int component = 0; component < 4; component++) {
            expect(actual.getFloat32(component * 4, Endian.little), closeTo(expected.getFloat32(component * 4, Endian.little), 0.000001));
          }
        }
      }
    }
    final List<Object?> effects = expected['effects']! as List<Object?>;
    for (int j = 0; j < layer.effects.length; j++) {
      final Map<String, Object?> effect = effects[j]! as Map<String, Object?>;
      if (effect['curve'] case final Map<String, Object?> expectedCurve) {
        // These fixtures author the value channel, the first curve occurrence.
        final XcfCurve curve = XcfCurve(layer.effects[j].argument('config')!.configuration!.nested('curve', occurrence: 0)!);
        expect(curve.points.map((point) => [point.x, point.y]), expectedCurve['points']);
        expect(curve.points.map((point) => point.type == 'smooth' ? 0 : 1), expectedCurve['types']);
        if (expectedCurve['samples'] != null) {
          expect(curve.samples, expectedCurve['samples']);
        }
      }
    }
  }
}
