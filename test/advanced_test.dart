import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:xcfkit/xcfkit.dart';

/// A small document with varied samples and clipped edge tiles.
XcfDocument _document({int version = 24, XcfCompression compression = XcfCompression.rle}) => XcfDocument(
  width: 130,
  height: 70,
  version: version,
  compression: compression,
  layers: [XcfLayer.rgba(name: 'Tiles', width: 130, height: 70, pixels: List.generate(130 * 70 * 4, (index) => index * 47 % 256))],
);

void main() {
  for (final XcfCompression compression in XcfCompression.values) {
    test('lazy region and progressive output match eager samples: $compression', () {
      final XcfDocument original = _document(compression: compression);
      final Uint8List encoded = XcfCodec.encode(original);
      final _CountingInput input = _CountingInput(encoded);
      final XcfDocument lazy = XcfCodec.open(input);
      expect(lazy.layers.single.raster!.isLazy, isTrue);
      expect(input.total, lessThan(encoded.length));
      final int before = input.total;
      final XcfRaster raster = lazy.layers.single.raster!;
      expect(raster.readRegion(x: 63, y: 63, width: 67, height: 7), original.layers.single.raster!.readRegion(x: 63, y: 63, width: 67, height: 7));
      expect(input.total, greaterThan(before));
      final _MemoryOutput output = _MemoryOutput();
      final int length = XcfCodec.encodeTo(lazy, output);
      expect(output.bytes(length), encoded);
      expect(output.largestWrite, lessThanOrEqualTo(64 * 64 * 4 * 2 + 1024));
      expect(raster.bytes, original.layers.single.raster!.bytes);
    });
  }

  test('lazy indexing does not read tile bytes and preflight does not load samples', () {
    final XcfDocument original = _document(compression: XcfCompression.raw);
    final Uint8List bytes = XcfCodec.encode(original);
    final _CountingInput input = _CountingInput(bytes);
    final XcfDocument lazy = XcfCodec.open(input, options: const XcfReadOptions(maxDecodedBytes: 64 * 64 * 4));
    expect(input.total, lessThan(1024));
    final int before = input.total;
    expect(XcfCodec.preflight(lazy).canWrite, isTrue);
    expect(input.total, before);
    expect(lazy.layers.single.raster!.readRegion(x: 128, y: 64, width: 2, height: 6), original.layers.single.raster!.readRegion(x: 128, y: 64, width: 2, height: 6));
    expect(() => lazy.layers.single.raster!.bytes, throwsA(isA<XcfFormatException>()));
    expect(() => XcfCodec.decode(bytes, options: const XcfReadOptions(maxDecodedBytes: 64 * 64 * 4)), throwsA(isA<XcfFormatException>()));
  });

  test('corrupt lazy tiles fail when requested, not while indexing', () {
    final Uint8List bytes = XcfCodec.encode(_document(compression: XcfCompression.zlib));
    bytes[bytes.length - 1] ^= 255;
    final XcfDocument lazy = XcfCodec.open(XcfMemoryInput(bytes));
    expect(() => lazy.layers.single.raster!.readRegion(x: 129, y: 69, width: 1, height: 1), throwsA(isA<XcfFormatException>()));
  });

  test('lazy source short reads, bounds and tile-provider size are checked', () {
    expect(() => XcfCodec.open(_ShortInput()), throwsA(isA<XcfFormatException>()));
    final XcfRaster raster = XcfRaster.tiled(width: 64, height: 64, bytesPerPixel: 4, readTile: (_, _) => Uint8List(1));
    expect(() => raster.readRegion(x: -1, y: 0, width: 1, height: 1), throwsRangeError);
    expect(() => raster.readRegion(x: 63, y: 63, width: 2, height: 2), throwsRangeError);
    expect(() => raster.bytes, throwsA(isA<XcfFormatException>()));
  });

  test('write and index budgets apply with external storage', () {
    expect(() => XcfCodec.encodeTo(_document(), _MemoryOutput(), options: const XcfWriteOptions(maxOutputBytes: 64)), throwsA(isA<XcfFormatException>()));
    final Uint8List bytes = XcfCodec.encode(_document());
    expect(() => XcfCodec.open(XcfMemoryInput(bytes), options: const XcfReadOptions(maxMetadataBytes: 32)), throwsA(isA<XcfFormatException>()));
  });

  test('vector-layer fields, patterns and unknown suffix survive edits', () {
    final XcfVectorLayer vector = XcfVectorLayer(
      pathTattoo: 314,
      fill: XcfVectorPaint(
        color: XcfColor.rgba8(10, 20, 30),
        pattern: XcfResourceReference(name: 'pattern', collection: 'set.pat'),
      ),
      stroke: XcfVectorPaint(style: 9),
      enableStroke: true,
      dashes: [1.5, 2],
      unknownSuffix: [254, 0, 12],
    );
    final XcfVectorLayer decoded = XcfVectorLayer.fromProperty(vector.toProperty());
    expect(decoded.fill.pattern!.collection, 'set.pat');
    expect(decoded.stroke.style, 9);
    expect(decoded.dashes, [1.5, 2]);
    final XcfVectorLayer edited = decoded.copyWith(strokeWidth: 4.5, fill: decoded.fill.copyWith(color: XcfColor.rgba8(1, 2, 3)));
    expect(XcfVectorLayer.fromProperty(edited.toProperty()).unknownSuffix, [254, 0, 12]);
    expect(() => XcfVectorLayer.fromProperty(XcfProperty(type: 47, data: [0])), throwsA(isA<XcfFormatException>()));
    expect(() => vector.resolvePath(_document()), throwsA(isA<XcfFormatException>()));
    final XcfDocument document = _document().withPaths([
      XcfPath(name: 'Shape', properties: [XcfProperty.integer(type: 20, value: 314)]),
    ]);
    expect(vector.resolvePath(document).name, 'Shape');
    expect(() => vector.resolvePath(document.withPaths([...document.paths, ...document.paths])), throwsA(isA<XcfFormatException>()));
  });

  test('metadata edits retain opaque parasites and reserved sample words', () {
    final XcfDocument document = _document()
        .copyWith(
          properties: [
            XcfParasite.toProperty([
              XcfParasite(name: 'unknown', flags: 7, data: [0, 255, 0]),
            ]),
          ],
        )
        .withGuides([XcfGuide(position: -5, orientation: 1), XcfGuide(position: 50, orientation: 2)])
        .withSamplePoints([XcfSamplePoint(x: 12, y: 34, mode: 4, reserved1: 8, reserved2: 9)])
        .withResolution(XcfResolution(144, 288))
        .withUserUnit(XcfUserUnit(factor: 7.5, digits: 3, name: 'kit', symbol: 'k', abbreviation: 'kit'));
    final XcfDocument decoded = XcfCodec.decode(XcfCodec.encode(document));
    expect(decoded.guides.first.position, -5);
    expect(decoded.samplePoints.single.reserved2, 9);
    expect(decoded.resolution!.y, 288);
    expect(decoded.userUnit!.factor, 7.5);
    expect(decoded.properties.parasites.single.data, [0, 255, 0]);
    expect(decoded.withUnitId(2).userUnit, isNull);
    expect(() => decoded.withSamplePoints(decoded.samplePoints, legacy: true), throwsArgumentError);
    expect(decoded.withSamplePoints([XcfSamplePoint(x: 1, y: 2)], legacy: true).samplePoints.single.mode, 0);
  });

  test('custom units retain pre-21 labels and diagnose incompatible version edits', () {
    final XcfDocument old = _document(version: 20).withUserUnit(XcfUserUnit(factor: 10, digits: 2, name: 'id', symbol: 'u', abbreviation: 'ab', singular: 'unit', plural: 'units'));
    expect(XcfCodec.decode(XcfCodec.encode(old)).userUnit!.plural, 'units');
    final XcfDocument incompatible = old.copyWith(version: 24);
    expect(XcfCodec.preflight(incompatible).diagnostics.any((issue) => issue.code == 'unit.layout'), isTrue);
    expect(XcfCodec.preflight(incompatible.withUserUnit(old.userUnit!)).canWrite, isTrue);
  });

  test('configuration preserves comments, unknown expressions and binary strings', () {
    final XcfConfiguration config = XcfConfiguration.fromSource('# comment\n(known 1)\n(future (deep "\\000\\377") ())\n(known 2)');
    expect(config.field('known')!.single.number, 2);
    expect(config.field('future')!.first.children.last.stringBytes, [0, 255]);
    final XcfConfiguration edited = config.withField('known', [XcfConfigValue.number(7)]);
    expect(edited.source, contains('# comment'));
    expect(edited.source, contains('(future (deep "\\000\\377") ())'));
    expect(edited.names.where((name) => name == 'known').length, 2);
    expect(edited.field('known', occurrence: 0)!.single.number, 1);
    expect(() => config.withField('x) (inject', []), throwsArgumentError);
    expect(() => XcfConfigValue.fromSource('1) (injected 2'), throwsA(isA<XcfFormatException>()));
    expect(() => XcfConfiguration.fromSource('(x ${'(' * 70}0${')' * 70})'), throwsA(isA<XcfFormatException>()));
    final XcfFilterArgument argument = XcfFilterArgument.configuration('config', edited);
    expect(argument.value, edited.source);
    expect(argument.configuration!.field('known')!.single.number, 7);
  });

  test('context-sensitive repeated fields retain their channel assignment order', () {
    final XcfConfiguration config = XcfConfiguration.fromSource('(channel value) (curve (points 4 0 0 1 1)) (channel red) (curve (points 4 0 0 1 1))');
    final XcfConfiguration first = config.nested('curve', occurrence: 0)!.withField('points', [
      XcfConfigValue.number(4),
      XcfConfigValue.number(0),
      XcfConfigValue.number(0),
      XcfConfigValue.number(1),
      XcfConfigValue.number(0.5),
    ]);
    final XcfConfiguration changed = config.withNested('curve', first, occurrence: 0);
    expect(changed.nested('curve', occurrence: 0)!.field('points')!.last.number, 0.5);
    expect(changed.source, contains('(channel red) (curve (points 4 0 0 1 1))'));
    expect(changed.names, ['channel', 'curve', 'channel', 'curve']);
    expect(changed.nested('curve', occurrence: 1)!.source.trim(), '(points 4 0 0 1 1)');
    expect(() => changed.field('curve', occurrence: 2), throwsRangeError);
    final XcfConfiguration commented = XcfConfiguration.fromSource('(curve # retained comment\n (future 1) # retained tail\n)');
    final XcfConfiguration nested = commented.nested('curve')!.withField('future', [XcfConfigValue.number(2)]);
    final String result = commented.withNested('curve', nested).source;
    expect(result, contains('# retained comment'));
    expect(result, contains('# retained tail'));
  });

  test('curve edits require explicit samples and preserve unknown fields', () {
    final XcfConfiguration config = XcfConfiguration.fromSource('(curve (curve-type smooth) (points 4 0 0 1 1) (point-types 2 smooth corner) (n-samples 2) (samples 2 0 1) (future "keep"))');
    final XcfCurve curve = XcfCurve(config.nested('curve')!);
    expect(curve.points.last.type, 'corner');
    final XcfCurve edited = curve.withPoints([XcfCurvePoint(0, 0), XcfCurvePoint(1, 0.5)], samples: [0, 0.5]);
    expect(edited.samples, [0, 0.5]);
    expect(config.withNested('curve', edited.configuration).source, contains('(future "keep")'));
    expect(() => XcfCurve(XcfConfiguration.fromSource('(curve-type smooth) (points 5 0 0)')), throwsA(isA<XcfFormatException>()));
    expect(() => curve.withPoints([], samples: [double.nan, 1]), throwsArgumentError);
  });

  test('configuration parasites retain flags and optional trailing null', () {
    final XcfDocument d = _document().copyWith(
      properties: [
        XcfParasite.toProperty([XcfParasite(name: 'gimp-image-grid', flags: 3, data: '(xspacing 10)'.codeUnits)]),
      ],
    );
    final XcfDocument edited = d.withConfiguration('gimp-image-grid', d.configuration('gimp-image-grid')!.withField('xspacing', [XcfConfigValue.number(20)]));
    expect(edited.properties.parasites.single.flags, 3);
    expect(edited.properties.parasites.single.data.last, isNot(0));
    expect(edited.configuration('gimp-image-grid')!.field('xspacing')!.single.number, 20);
  });

  test('preflight collects independent errors and minimum version without pixels', () {
    final XcfDocument document = XcfDocument(
      version: 3,
      width: 1,
      height: 1,
      precision: XcfPrecision.fromCode(250),
      compression: XcfCompression.zlib,
      layers: [
        XcfLayer(
          name: 'bad\u0000name',
          width: 0,
          height: 2,
          properties: [
            XcfProperty(type: 100, data: [1]),
            XcfProperty(type: 47, data: [0]),
          ],
          effects: [XcfEffect(name: 'Effect', operation: 'gimp:curves', version: '1')],
        ),
      ],
    );
    final XcfWriteReport report = XcfCodec.preflight(document);
    expect(report.canWrite, isFalse);
    expect(report.minimumVersion, 24);
    expect(
      report.diagnostics.map((value) => value.code),
      containsAll(['version.required', 'geometry.invalid', 'raster.missing', 'string.embeddedNull', 'property.unknownRelocation', 'vector.invalid']),
    );
    expect(report.diagnostics.any((value) => value.path == 'layers[0].properties[0]'), isTrue);
  });

  test('preflight identifies off-canvas guides and known output-size failure', () {
    expect(XcfCodec.preflight(_document(version: 3).withGuides([XcfGuide(position: -1, orientation: 1)])).minimumVersion, 15);
    expect(XcfCodec.preflight(_document(compression: XcfCompression.raw), options: const XcfWriteOptions(maxOutputBytes: 200)).diagnostics.map((issue) => issue.code), contains('size.outputLimit'));
  });
}

/// Counts exact requested bytes without prefetching sample data.
final class _CountingInput implements XcfInput {
  /// Encoded backing bytes.
  final Uint8List bytes;

  /// Cumulative requested range sizes.
  int total = 0;

  /// Wraps an encoded file.
  _CountingInput(this.bytes);

  @override
  int get length => bytes.length;

  @override
  Uint8List read(int offset, int count) {
    total += count;
    return Uint8List.sublistView(bytes, offset, offset + count);
  }
}

/// Deliberately violates the source contract to verify short-read handling.
final class _ShortInput implements XcfInput {
  @override
  int get length => 100;

  @override
  Uint8List read(int offset, int count) => Uint8List(count - 1);
}

/// Test destination that applies pointer patches to an owned byte array.
final class _MemoryOutput implements XcfOutput {
  /// Backing test allocation, deliberately much smaller than production limits.
  final Uint8List _bytes = Uint8List(1024 * 1024);

  /// Largest individual write, including tile chunks.
  int largestWrite = 0;

  @override
  void write(int offset, Uint8List bytes) {
    if (bytes.length > largestWrite) {
      largestWrite = bytes.length;
    }
    _bytes.setRange(offset, offset + bytes.length, bytes);
  }

  /// Returns only the declared encoded length.
  Uint8List bytes(int length) => Uint8List.sublistView(_bytes, 0, length);
}
