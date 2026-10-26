import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:xcfkit/src/binary.dart';
import 'package:xcfkit/xcfkit.dart';

void main() {
  for (final int version in [1, 2, 3]) {
    test('compatibility path version $version: open/closed strokes and selection', () {
      final XcfDocument document = _compatibility(version);
      final XcfPath path = document.paths.single;
      expect(path.properties.property(43), isNotNull);
      expect(path.strokes.length, 2);
      expect(path.strokes.first.closed, isTrue);
      expect(path.strokes.last.closed, isFalse);
      expect(path.strokes.first.points.map((point) => [point.x, point.y]), [
        [7, 8],
        [1, 2],
        [3, 4],
      ]);
      expect(path.strokes.last.points.map((point) => [point.x, point.y]), [
        [10, 11],
        [10, 11],
        [12, 13],
      ]);
      final XcfDocument rewritten = XcfCodec.decode(XcfCodec.encode(document.withPaths(document.paths)));
      expect(rewritten.paths.single.strokes.last.points[1].x, 10);
      expect(rewritten.properties.property(XcfPropertyId.paths), isNull);
    });
  }

  test('compatibility paths reject every truncated prefix and invalid counts', () {
    final XcfDocument document = _compatibility(3);
    final Uint8List data = document.properties.single.data;
    for (int length = 0; length < data.length; length++) {
      expect(() => document.copyWith(properties: [XcfProperty(type: 23, data: data.sublist(0, length))]).paths, throwsA(isA<XcfFormatException>()));
    }
    final Uint8List invalid = Uint8List.fromList(data);
    ByteData.sublistView(invalid).setUint32(4, 0xffffffff);
    expect(() => document.copyWith(properties: [XcfProperty(type: 23, data: invalid)]).paths, throwsA(isA<XcfFormatException>()));
  });

  test('color arguments retain arbitrary encodings, profiles and both null forms', () {
    final XcfColor color = XcfColor(encoding: 'CMYKA double', pixel: List.generate(40, (index) => index), profile: [0, 255, 3, 4]);
    final XcfFilterArgument decoded = XcfFilterArgument.fromProperty(XcfFilterArgument.color('color', color).toProperty());
    final XcfColor value = decoded.value! as XcfColor;
    expect(value.encoding, color.encoding);
    expect(value.pixel, color.pixel);
    expect(value.profile, color.profile);
    expect(() => value.pixel[0] = 10, throwsUnsupportedError);
    expect(XcfFilterArgument(name: 'null', type: 8, data: []).value, isNull);
    expect(XcfFilterArgument.color('null', null).value, isNull);
    for (int i = 1; i < decoded.data.length; i++) {
      expect(() => XcfFilterArgument(name: 'color', type: 8, data: decoded.data.sublist(0, i)).value, throwsA(isA<XcfFormatException>()));
    }
  });

  test('gradient arguments expose all segment fields without rendering them', () {
    final XcfGradient gradient = XcfGradient(
      name: 'Procedural',
      segments: [
        XcfGradientSegment(
          left: 0,
          middle: 0.25,
          right: 1,
          leftColor: XcfColor.rgba8(255, 0, 0),
          rightColor: XcfColor.rgba8(0, 0, 255, 128),
          blending: 2,
          coloring: 1,
          leftColorType: 1,
          rightColorType: 4,
        ),
      ],
    );
    final XcfGradient result = XcfFilterArgument.fromProperty(XcfFilterArgument.gradient('gradient', gradient).toProperty()).value! as XcfGradient;
    expect(result.segments.single.middle, 0.25);
    expect(result.segments.single.blending, 2);
    expect(result.segments.single.coloring, 1);
    expect(result.segments.single.rightColorType, 4);
    expect(result.segments.single.rightColor.pixel, [0, 0, 255, 128]);
    expect(result.encode(), gradient.encode());
    final Uint8List bytes = gradient.encode();
    for (int i = 1; i < bytes.length; i++) {
      expect(() => XcfGradient.decode(bytes.sublist(0, i)), throwsA(isA<XcfFormatException>()));
    }
    expect(XcfGradient.decode(Uint8List(0)), isNull);
    expect(() => XcfGradientSegment(left: 0.5, middle: 0.25, right: 1, leftColor: XcfColor.rgba8(0, 0, 0), rightColor: XcfColor.rgba8(255, 255, 255)), throwsArgumentError);
  });

  test('text options edit layout, fonts, colors and contours while retaining unknown data', () {
    final XcfText original = XcfText.fromSource('(text "X") (font "Sans") (unknown (binary "\\377"))');
    final XcfTextOptions options = original.options.copyWith(
      font: XcfTextFont.named('Nimbus Roman'),
      fontSize: 23.5,
      unit: 'points',
      antialias: false,
      hintStyle: 'full',
      kerning: true,
      language: 'fr',
      direction: 'ttb-rtl-upright',
      justification: 'fill',
      indent: -2,
      lineSpacing: 3.5,
      letterSpacing: 1.25,
      color: XcfTextColor.rgba(0.123456789, 0.5, 0.8, 0.75),
      box: const XcfTextBox(mode: 'fixed', width: 120, height: 80, unit: 'pixels'),
      transform: const XcfTextTransform(xx: 2, xy: 0.5, offsetX: -3, offsetY: 4),
      outline: original.options.outline.copyWith(
        mode: 'stroke-fill',
        width: 2,
        color: XcfTextColor.encoded(XcfColor.rgba8(20, 30, 40, 128)),
        direction: 'inner',
        cap: 'round',
        join: 'bevel',
        antialias: false,
        miterLimit: 4,
        dashOffset: 2,
        dashes: [1, 2, 3],
      ),
    );
    final XcfText edited = original.withOptions(options);
    final XcfTextOptions result = XcfText.fromParasite(edited.toParasite()).options;
    expect(result.font!.fullName, 'Nimbus Roman');
    expect(result.fontSize, 23.5);
    expect(result.unit, 'points');
    expect(result.antialias, isFalse);
    expect(result.hintStyle, 'full');
    expect(result.kerning, isTrue);
    expect(result.language, 'fr');
    expect(result.direction, 'ttb-rtl-upright');
    expect(result.justification, 'fill');
    expect(result.indent, -2);
    expect(result.lineSpacing, 3.5);
    expect(result.letterSpacing, 1.25);
    expect(result.box.width, 120);
    expect(result.box.mode, 'fixed');
    expect(result.transform.xy, 0.5);
    expect(result.transform.offsetY, 4);
    expect(result.color!.rgba, [0.123456789, 0.5, 0.8, 0.75]);
    expect(result.outline.color!.encoded!.pixel, [20, 30, 40, 128]);
    expect(result.outline.dashes, [1, 2, 3]);
    expect(result.outline.mode, 'stroke-fill');
    expect(edited.source, contains('(unknown (binary "\\377"))'));
    expect(edited.text, original.text);
    expect(original.fontName, 'Sans');
  });

  test('font resources and encoded text colors preserve private metadata', () {
    final XcfText text = XcfText.fromSource(r'''(font "GimpFont" (fullname "Known") (family "Family") (weight 80) (custom "future"))
      (color (color "opaque" 2 "\000\377" 2 "\200\100"))''');
    expect(text.options.font!.weight, 80);
    expect(text.options.font!.family, 'Family');
    expect(text.options.color!.encoded!.pixel, [0, 255]);
    expect(text.options.color!.encoded!.profile, [128, 64]);
    expect(text.withOptions(text.options.copyWith(letterSpacing: 1)).source, contains('(custom "future")'));
    expect(text.withOptions(text.options).options.color!.encoded!.profile, [128, 64]);
    final XcfText withDefaultFont = XcfText.fromSource('(markup "x" (markupfont "font" (font)))');
    expect(withDefaultFont.markupFonts['font']!.isModern, isTrue);
    expect(withDefaultFont.withContent(withDefaultFont.content).markupFonts['font']!.name, isNull);
    expect(XcfText.fromSource('(hint-style medium) (hinting no)').options.hintStyle, 'none');
    expect(XcfText.fromSource('(hint-style full) (hinting no)').options.hintStyle, 'full');
    expect(XcfText.fromSource('(outline-dash-info NULL)').options.outline.dashes, isEmpty);
    final XcfText early = XcfText.fromSource('(markup "x" "a" (fullname "Modern") (custom "opaque") "b" "Legacy")');
    expect(early.markupFonts['a']!.name, 'Modern');
    expect(early.markupFonts['b']!.name, 'Legacy');
    final XcfText rewritten = early.withContent(early.content);
    expect(rewritten.markupFonts['a']!.source, contains('(custom "opaque")'));
    expect(rewritten.markupFonts['b']!.name, 'Legacy');
  });

  test('Pango styles preserve nested relative sizes, Unicode ranges and font aliases', () {
    const String markup = '<markup>Été <span font="font7" size="larger" unknown="opaque"><b>😀 &amp; </b><big><i>سلام</i></big></span></markup>';
    final XcfText text = XcfText.fromSource('(markup ${jsonEncode(markup)} (markupfont "font7" (font "GimpFont" (fullname "Resource"))))');
    final XcfTextContent content = text.content;
    expect(content.text, 'Été 😀 & سلام');
    expect(content.styleAt(4)!.weight, 'bold');
    expect(content.fontAt(4)!.name, 'Resource');
    expect(content.styleAt(9)!.slant, 'italic');
    expect(content.styleAt(9)!.spans.map((span) => span.name), ['span', 'big', 'i']);
    expect(content.toMarkup(), markup);
    final XcfTextContent updated = content.copyWith(
      styleRuns: [
        for (final XcfTextStyleRun run in content.styleRuns)
          XcfTextStyleRun(
            start: run.start,
            length: run.length,
            style: run.style.copyWith(underline: 'double', strikethrough: true),
          ),
      ],
    );
    final XcfText roundTrip = XcfText.fromParasite(text.withContent(updated).toParasite());
    expect(roundTrip.content.text, content.text);
    expect(roundTrip.content.styleAt(4)!.underline, 'double');
    expect(roundTrip.content.styleAt(4)!.strikethrough, isTrue);
    expect(roundTrip.content.styleAt(4)!.spans[0].attributes['unknown'], 'opaque');
    expect(roundTrip.markupFonts['font7']!.name, 'Resource');
    expect(
      () => XcfTextContent(
        text: '😀',
        styleRuns: [XcfTextStyleRun(start: 0, length: 1, style: XcfTextStyle())],
      ),
      throwsArgumentError,
    );
  });

  test('markup parser rejects declarations, broken nesting and excessive depth', () {
    for (final String markup in ['<b>x</i>', '<!DOCTYPE markup [<!ENTITY x "expanded">]><markup>&x;</markup>', '<span size="2" size="3">x</span>', '${'<b>' * 70}x${'</b>' * 70}', '&missing;']) {
      expect(() => XcfText.fromSource('(markup ${jsonEncode(markup)})').content, throwsA(isA<XcfFormatException>()), reason: markup);
    }
    expect(() => XcfText.fromSource('(color (color "RGBA" 4 "x" 0))').options.color, throwsA(isA<XcfFormatException>()));
    expect(() => XcfText.fromSource('(outline-dash-info 2 1)').options.outline.dashes, throwsA(isA<XcfFormatException>()));
    expect(() => XcfTextOptions().copyWith(direction: 'ltr) (injected yes'), throwsArgumentError);
    expect(() => XcfTextOptions().copyWith(fontSize: double.infinity), throwsArgumentError);
    for (final String invalid in ['\u0000', String.fromCharCode(0xd800), '\uffff']) {
      expect(() => XcfTextContent(text: invalid), throwsArgumentError);
      expect(() => XcfTextSpan(attributes: {'unknown': invalid}), throwsArgumentError);
    }
    expect(() => XcfTextStyle(spans: List.generate(64, (_) => XcfTextSpan())), throwsArgumentError);
  });

  test('linked layer metadata tolerates only the documented short envelope', () {
    final XcfProperty link = const XcfLayerLink(source: 'relative.xcf', width: 96, height: 64, flags: 5).toProperty();
    final XcfLayerTransform transform = XcfLayerTransform(x: -3, y: 4, interpolation: 99, matrix: [1, 0.25, 3, 0, 1, -2, 0, 0, 1]);
    final XcfDocument document = XcfDocument(
      version: 25,
      width: 1,
      height: 1,
      layers: [
        XcfLayer.rgba(name: 'Linked', width: 1, height: 1, pixels: [1, 2, 3, 255]).copyWith(properties: [link, transform.toProperty()]),
      ],
    );
    final Uint8List bytes = XcfCodec.encode(document);
    final ByteData data = ByteData.sublistView(bytes);
    final int offset = Iterable<int>.generate(bytes.length - 8).singleWhere((i) => data.getUint32(i) == 48 && data.getUint32(i + 4) == link.data.length);
    data.setUint32(offset + 4, link.data.length - 4);
    final XcfDocument repaired = XcfCodec.decode(bytes);
    expect(repaired.warnings.single, contains('Corrected length of property 48'));
    expect(repaired.layers.single.link!.source, 'relative.xcf');
    expect(repaired.layers.single.link!.flags, 5);
    expect(repaired.layers.single.transform!.matrix, transform.matrix);
    expect(repaired.layers.single.transform!.x, -3);
    expect(XcfCodec.decode(XcfCodec.encode(repaired)).warnings, isEmpty);
    data.setUint32(offset + 4, link.data.length - 1);
    expect(() => XcfCodec.decode(bytes), throwsA(isA<XcfFormatException>()));
    final XcfProperty extended = XcfProperty(type: 48, data: [...link.data, 1, 2, 3, 4]);
    final XcfDocument future = document.copyWith(
      layers: [
        document.layers.single.copyWith(properties: [extended]),
      ],
    );
    final XcfDocument preserved = XcfCodec.decode(XcfCodec.encode(future));
    expect(preserved.layers.single.properties.single.data, extended.data);
    expect(() => preserved.layers.single.link, throwsA(isA<XcfFormatException>()));
    for (int i = 0; i < link.data.length; i++) {
      expect(() => XcfLayerLink.fromProperty(XcfProperty(type: 48, data: link.data.sublist(0, i))), throwsA(isA<XcfFormatException>()));
    }
  });

  test('XCF strings reject embedded nulls on both read and write', () {
    expect(() => XcfReader(Uint8List.fromList([0, 0, 0, 4, 65, 0, 66, 0])).string(64), throwsA(isA<XcfFormatException>()));
    expect(() => XcfWriter(64).string('A\u0000B'), throwsA(isA<XcfFormatException>()));
  });
}

/// Builds a literal old path envelope independently of the modern path encoder.
XcfDocument _compatibility(int version) {
  final XcfWriter writer = XcfWriter(1024)
    ..u32(0)
    ..u32(1)
    ..string('Old path')
    ..u32(1)
    ..u8(2)
    ..u32(0)
    ..u32(5)
    ..u32(version);
  if (version >= 2) {
    writer.u32(1);
  }
  if (version == 3) {
    writer.u32(7);
  }
  for (final (int kind, int x, int y) in [(1, 1, 2), (2, 3, 4), (2, 7, 8), (3, 10, 11), (2, 12, 13)]) {
    writer.u32(kind);
    if (version == 1) {
      writer.u32(x);
      writer.u32(y);
    } else {
      writer.f32(x.toDouble());
      writer.f32(y.toDouble());
    }
  }
  return XcfDocument(
    width: 1,
    height: 1,
    layers: [
      XcfLayer.rgba(name: 'Pixel', width: 1, height: 1, pixels: [0, 0, 0, 255]),
    ],
    properties: [XcfProperty(type: 23, data: writer.finish())],
  );
}
