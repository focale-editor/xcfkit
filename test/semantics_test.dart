import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:xcfkit/src/binary.dart';
import 'package:xcfkit/xcfkit.dart';

void main() {
  test('text edits preserve resources and isolate configuration syntax', () {
    const String unknown = r'(color (color "RGBA float" 4 "\000\377\200\001" 0))';
    final XcfText original = XcfText.fromSource('# comment\n(text "ancien")\n(markup "<b>ancien</b>")\n(font "Sans")\n(font-size 12)\n(font-size-unit pixels)\n$unknown');
    const String content = 'Été 😀 "citation" \\ chemin\n(font-size 999)';
    final XcfText edited = original.withText(content).withFontSize(24, unit: 'points');
    expect(edited.text, content);
    expect(edited.markup, isNull);
    expect(edited.fontName, 'Sans');
    expect(edited.fontSize, 24);
    expect(edited.fontSizeUnit, 'points');
    expect(edited.source, contains(unknown));
    expect(edited.source, contains('# comment'));
    expect(XcfText.fromParasite(edited.toParasite()).text, content);
    expect(original.text, 'ancien');
  });

  test('text recognizes modern font resources and octal UTF-8 strings', () {
    final XcfText text = XcfText.fromSource(r'(text "\303\211t\303\251\012") (font "GimpFont" (fullname "Nimbus Sans") (unknown "opaque"))');
    expect(text.text, 'Été\n');
    expect(text.fontName, 'Nimbus Sans');
    final XcfParasite noNull = XcfParasite(name: 'gimp-text-layer', flags: 3, data: utf8.encode(text.source));
    expect(XcfText.fromParasite(noNull).toParasite().data, noNull.data);
    expect(XcfText.fromParasite(noNull).flags, 3);
  });

  test('text parsing has bounded nesting and rejects malformed strings', () {
    for (final String source in ['(text "unterminated)', '(text "x") )', 'text', '(text "x")\u0000', '(text ${'(' * 65}${')' * 65})']) {
      expect(() => XcfText.fromSource(source), throwsA(isA<XcfFormatException>()));
    }
    expect(() => XcfText.fromSource(r'(text "\377")').text, throwsA(isA<XcfFormatException>()));
    expect(() => XcfText.fromSource('(font-size nan)').fontSize, throwsA(isA<XcfFormatException>()));
    expect(() => XcfText.fromSource('(text "x")').withText('\u0000'), throwsArgumentError);
    expect(() => XcfText.fromSource('').withFontSize(12, unit: 'pixels) (evil yes'), throwsArgumentError);
  });

  test('text application replaces the raster, clears modified flag, retains parasites', () {
    final XcfLayer original = _layer().copyWith(
      properties: [
        XcfProperty.integer(type: XcfPropertyId.textLayerFlags, value: 3),
        XcfParasite.toProperty([
          XcfParasite(name: 'other', data: [1, 2, 3]),
        ]),
      ],
    );
    final XcfRaster raster = XcfRaster(width: 2, height: 1, bytesPerPixel: 4, bytes: [1, 2, 3, 4, 5, 6, 7, 8]);
    final XcfLayer edited = original.withText(XcfText.fromSource('(text "new")'), renderedRaster: raster, x: -2);
    expect(edited.width, 2);
    expect(edited.raster, same(raster));
    expect(edited.text!.text, 'new');
    expect(edited.x, -2);
    expect(edited.properties.property(XcfPropertyId.textLayerFlags)!.integer, 1);
    expect(edited.properties.parasites.first.data, [1, 2, 3]);
    expect(() => original.withText(edited.text!, renderedRaster: XcfRaster(width: 1, height: 1, bytesPerPixel: 1, bytes: [0])), throwsArgumentError);
  });

  test('named effect edits retain other arguments and unknown argument kinds', () {
    final XcfEffect original = XcfEffect(
      name: 'Effect',
      operation: 'gegl:example',
      properties: [
        XcfFilterArgument.integer('signed', -17).toProperty(),
        XcfFilterArgument.unsigned('unsigned', 0xffffffff).toProperty(),
        XcfFilterArgument.integer('enum', -1, isEnum: true).toProperty(),
        XcfFilterArgument.boolean('enabled', true).toProperty(),
        XcfFilterArgument.floating('amount', 0.25).toProperty(),
        XcfFilterArgument.string('label', 'Été').toProperty(),
        XcfFilterArgument.string('config', '(opaque yes)', isConfiguration: true).toProperty(),
        XcfFilterArgument(name: 'future', type: 999, data: [1, 2, 3]).toProperty(),
      ],
    );
    final XcfEffect edited = original.withArgument(XcfFilterArgument.floating('amount', -0.5));
    expect(edited.arguments.length, 8);
    expect(edited.argument('amount')!.value, -0.5);
    expect(edited.argument('signed')!.value, -17);
    expect(edited.argument('unsigned')!.value, 0xffffffff);
    expect(edited.argument('enabled')!.value, true);
    expect(edited.argument('label')!.value, 'Été');
    expect(edited.argument('config')!.value, '(opaque yes)');
    expect(edited.argument('future')!.value, isNull);
    expect(edited.argument('future')!.data, [1, 2, 3]);
    expect(original.argument('amount')!.value, 0.25);
    expect(() => XcfFilterArgument.floating('amount', double.infinity), throwsArgumentError);
    expect(() => XcfFilterArgument.integer('amount', 0x80000000), throwsArgumentError);
    expect(() => XcfFilterArgument.fromProperty(XcfProperty(type: 45, data: [0, 0, 0, 0])), throwsA(isA<XcfFormatException>()));
    expect(() => XcfFilterArgument(name: 'amount', type: 3, data: [0]).value, throwsA(isA<XcfFormatException>()));
  });

  test('path geometry keeps extra axes and unknown properties through edits', () {
    final XcfPath original = XcfPath(
      name: 'Path',
      properties: [
        XcfProperty(type: 999, data: [42]),
      ],
      strokes: [
        XcfStroke(
          axes: 6,
          closed: true,
          points: [
            for (final int kind in [1, 0, 1]) XcfControlPoint(type: kind, coordinates: [1, 2, 0.75, 0.5, 0.5, 0.25]),
          ],
        ),
      ],
    );
    final XcfPath decoded = XcfPath.fromVector(original.toVector());
    final XcfStroke stroke = decoded.strokes.single;
    final XcfPath edited = decoded.copyWith(strokes: [stroke.copyWith(points: stroke.points.map((point) => point.withPosition(point.x + 5, point.y - 1)).toList())]);
    final XcfDocument document = XcfDocument(version: 0, width: 1, height: 1, layers: [_layer()]).withPaths([edited]);
    final XcfPath result = XcfCodec.decode(XcfCodec.encode(document)).paths.single;
    expect(document.version, 18);
    expect(result.strokes.single.points.first.coordinates, [6, 1, 0.75, 0.5, 0.5, 0.25]);
    expect(result.properties.single.data, [42]);
    expect(result.strokes.single.closed, isTrue);
    expect(original.strokes.single.points.first.x, 1);
  });

  test('legacy vector conversion preserves selection, metadata and strokes', () {
    final XcfWriter writer = XcfWriter(1024)
      ..u32(1)
      ..u32(0)
      ..u32(1)
      ..string('Legacy')
      ..u32(7)
      ..u32(1)
      ..u32(0)
      ..u32(1)
      ..u32(0)
      ..string('note')
      ..u32(1)
      ..u32(2)
      ..add([8, 9]);
    final XcfDocument document = XcfDocument(
      width: 1,
      height: 1,
      layers: [_layer()],
      properties: [XcfProperty(type: 25, data: writer.finish())],
    );
    final XcfPath path = document.paths.single;
    expect(path.name, 'Legacy');
    expect(path.properties.property(43), isNotNull);
    expect(path.properties.property(20)!.integer, 7);
    expect(path.properties.parasites.single.data, [8, 9]);
    final XcfDocument updated = document.withPaths(document.paths);
    expect(updated.properties.property(25), isNull);
    expect(updated.paths.single.name, 'Legacy');
  });

  test('path decoder rejects invalid layouts, excessive counts and trailing data', () {
    for (final List<int> words in [
      [0, 0, 2, 0], // Unknown vector version.
      [0, 0, 1, 100001], // Excessive strokes.
      [0, 0, 1, 1, 1, 0, 7, 0], // Too many axes.
      [0, 0, 1, 1, 1, 0, 2, 1000001], // Excessive points.
      [0, 0, 1, 0, 42], // Trailing data.
    ]) {
      final XcfWriter writer = XcfWriter(128);
      words.forEach(writer.u32);
      expect(() => XcfPath.fromVector(XcfVector(name: 'Invalid', payload: writer.finish())), throwsA(isA<XcfFormatException>()));
    }
  });

  for (final int version in [0, 10, 13, 26]) {
    for (final XcfDrawableKind kind in XcfDrawableKind.values) {
      test('floating selection reference relocation: v$version ${kind.name}', () {
        final XcfDocument original = _floating(version, kind);
        final XcfDocument decoded = XcfCodec.decode(XcfCodec.encode(original));
        expect(decoded.floatingSelection!.targetKind, kind);
        expect(decoded.floatingSelection!.targetIndex, kind == XcfDrawableKind.channel ? 0 : 1);
        final List<int> previous = decoded.layers.first.properties.property(5)!.data;
        final XcfDocument resized = decoded.copyWith(
          properties: [
            XcfParasite.toProperty([XcfParasite(name: 'padding', data: List.filled(1000, 12))]),
          ],
        );
        final XcfDocument relocated = XcfCodec.decode(XcfCodec.encode(resized));
        expect(relocated.floatingSelection!.targetKind, kind);
        expect(relocated.layers.first.properties.property(5)!.data, isNot(previous));
        expect(relocated.layers.first.raster!.bytes, decoded.layers.first.raster!.bytes);
      });
    }
  }

  test('floating selections reject missing, self and malformed source references', () {
    final XcfDocument original = _floating(13, XcfDrawableKind.layer);
    for (final int index in [-1, 0, 5]) {
      expect(
        () => XcfCodec.encode(
          original.copyWith(
            floatingSelection: XcfFloatingSelection(targetKind: XcfDrawableKind.layer, targetIndex: index),
          ),
        ),
        throwsA(isA<XcfFormatException>()),
      );
    }
    final Uint8List encoded = XcfCodec.encode(original);
    final ByteData data = ByteData.sublistView(encoded);
    int slot = -1;
    for (int i = 0; i < encoded.length - 16; i++) {
      if (data.getUint32(i) == 5 && data.getUint32(i + 4) == 8 && data.getUint32(i + 8) == 0) {
        slot = i + 8;
        break;
      }
    }
    expect(slot, greaterThan(0));
    data.setUint32(slot + 4, 0);
    expect(() => XcfCodec.decode(encoded), throwsA(isA<XcfFormatException>()));
    data.setUint32(slot, 0x200000);
    expect(() => XcfCodec.decode(encoded), throwsA(isA<XcfFormatException>()));
    final XcfDocument removed = XcfCodec.decode(XcfCodec.encode(original)).copyWith(removeFloatingSelection: true);
    expect(removed.layers.first.properties.property(5), isNull);
    expect(XcfCodec.decode(XcfCodec.encode(removed)).floatingSelection, isNull);
  });

  test('floating selection may reference a drawable written before it', () {
    final XcfDocument original = _floating(13, XcfDrawableKind.layer).copyWith(
      floatingSelection: const XcfFloatingSelection(layerIndex: 1, targetKind: XcfDrawableKind.layer, targetIndex: 0),
    );
    final XcfDocument decoded = XcfCodec.decode(XcfCodec.encode(original));
    expect(decoded.floatingSelection!.layerIndex, 1);
    expect(decoded.floatingSelection!.targetIndex, 0);
  });
}

/// Creates a minimal ordinary pixel layer.
XcfLayer _layer() => XcfLayer.rgba(name: 'Pixels', width: 1, height: 1, pixels: [10, 20, 30, 255]);

/// Exercises attachment to layer, mask and saved channel with correct layouts.
XcfDocument _floating(int version, XcfDrawableKind kind) {
  final XcfChannel channel = XcfChannel(
    name: 'Mask',
    raster: XcfRaster(width: 1, height: 1, bytesPerPixel: 1, bytes: [128]),
  );
  final XcfLayer floating = kind == XcfDrawableKind.layer
      ? _layer()
      : XcfLayer(
          name: 'Floating',
          width: 1,
          height: 1,
          type: XcfLayerType.grayAlpha,
          raster: XcfRaster(width: 1, height: 1, bytesPerPixel: 2, bytes: [64, 255]),
        );
  return XcfDocument(
    version: version,
    width: 1,
    height: 1,
    layers: [
      floating,
      _layer().copyWith(mask: kind == XcfDrawableKind.layerMask ? channel : null),
    ],
    channels: kind == XcfDrawableKind.channel ? [channel] : [],
    floatingSelection: XcfFloatingSelection(targetKind: kind, targetIndex: kind == XcfDrawableKind.channel ? 0 : 1),
  );
}
