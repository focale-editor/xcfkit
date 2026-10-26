@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:xcfkit/xcfkit_compression.dart';

import '../tool/write_gradient_edits.dart' as gradient_edits;
import '../tool/write_semantic_edits.dart' as edits;

void main() {
  _referenceTests('test/fixtures/gimp-advanced', 'test/fixtures/gimp-advanced/reference.json');
  _referenceTests('test/fixtures/gimp', 'test/fixtures/gimp/reference.json');
  _referenceTests('test/fixtures/gimp-development', 'test/fixtures/gimp-development/reference.json');
  for (final String name in ['effect-gradient', 'effect-gradient-edited']) {
    test('gradient fields match GIMP resource API: $name', () {
      final XcfDocument document = XcfCodec.decode(File('test/fixtures/gimp-development/$name.xcf').readAsBytesSync());
      final Map<String, Object?> reference = jsonDecode(File('test/fixtures/gimp-development/$name.json').readAsStringSync()) as Map<String, Object?>;
      for (final XcfDocument value in [document, XcfCodec.decode(XcfCodec.encode(document))]) {
        _gradient(value.layers.single.effects.single.argument('gradient')!.value! as XcfGradient, reference);
      }
    });
  }
  test('gradient edits match independent GIMP tool operations', () {
    final Directory directory = Directory.systemTemp.createTempSync('xcfkit-gradient-edits-');
    try {
      gradient_edits.main([directory.path]);
      final XcfDocument document = XcfCodec.decode(File('${directory.path}/effect-gradient-edited.xcf').readAsBytesSync());
      final List<Object?> references = jsonDecode(File('test/fixtures/gimp-development/edits-reference.json').readAsStringSync()) as List<Object?>;
      _compare(document, references.single! as Map<String, Object?>);
      final Map<String, Object?> resource = jsonDecode(File('test/fixtures/gimp-development/effect-gradient-edited.json').readAsStringSync()) as Map<String, Object?>;
      _gradient(document.layers.single.effects.single.argument('gradient')!.value! as XcfGradient, resource);
    } finally {
      directory.deleteSync(recursive: true);
    }
  });
  test('grouped floating selection retains file order and item paths', () {
    final XcfDocument document = XcfCodec.decode(File('test/fixtures/gimp/floating-group-child.xcf').readAsBytesSync());
    final XcfDocument rewritten = XcfCodec.decode(XcfCodec.encode(document));
    for (final XcfDocument value in [document, rewritten]) {
      expect(value.floatingSelection!.layerIndex, 1);
      expect(value.floatingSelection!.targetIndex, 2);
      expect(value.layers[1].itemPath, [0, 0]);
      expect(value.layers[2].itemPath, [0, 1]);
      expect(value.layerTree.single.children.length, 2);
    }
  });
  test('text, path and effect edits match independent GIMP operations', () {
    final Directory directory = Directory.systemTemp.createTempSync('xcfkit-edits-');
    try {
      edits.main([directory.path]);
      final List<Object?> references = jsonDecode(File('test/fixtures/gimp/edits-reference.json').readAsStringSync()) as List<Object?>;
      for (final Object? value in references) {
        final Map<String, Object?> reference = value! as Map<String, Object?>;
        _compare(XcfCodec.decode(File('${directory.path}/${reference['file']}').readAsBytesSync()), reference);
      }
    } finally {
      directory.deleteSync(recursive: true);
    }
  });
  if (Platform.environment['XCF_CORPUS'] == '1') {
    _referenceTests('test/corpus', 'test/corpus/gimp-reference.json');
  }
}

/// Compares encoded metadata with values read from GIMP's authoring resource.
void _gradient(XcfGradient actual, Map<String, Object?> reference) {
  final Map<String, Object?> expected = reference['gradient']! as Map<String, Object?>;
  final List<Object?> segments = expected['segments']! as List<Object?>;
  expect(actual.name, expected['name']);
  expect(actual.segments.length, segments.length);
  for (int i = 0; i < segments.length; i++) {
    final Map<String, Object?> segment = segments[i]! as Map<String, Object?>;
    final XcfGradientSegment value = actual.segments[i];
    expect(value.left, segment['left']);
    expect(value.middle, segment['middle']);
    expect(value.right, segment['right']);
    expect(value.blending, segment['blending']);
    expect(value.coloring, segment['coloring']);
    expect(value.leftColorType, 0);
    expect(value.rightColorType, 0);
    _gradientColor(value.leftColor, segment['left_color']! as Map<String, Object?>, reference['byte_order']! as String);
    _gradientColor(value.rightColor, segment['right_color']! as Map<String, Object?>, reference['byte_order']! as String);
  }
}

/// Compares raw colors; the edited yellow intentionally uses portable u8 data.
void _gradientColor(XcfColor actual, Map<String, Object?> expected, String byteOrder) {
  final String hex = expected['pixel']! as String;
  final Uint8List bytes = Uint8List.fromList([for (int i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)]);
  expect(actual.profile, isEmpty); // All fixture colors use GIMP's sRGB space.
  if (actual.encoding == expected['encoding']) {
    expect(actual.pixel, bytes);
  } else {
    // Both encodings have the same nonlinear transfer curve. No ICC or
    // transfer-function conversion belongs in this test or in XcfKit.
    expect(actual.encoding, "R'G'B'A u8");
    expect(expected['encoding'], "R'G'B'A float");
    expect(bytes.length, 16);
    final ByteData data = ByteData.sublistView(bytes);
    expect(actual.pixel, [for (int i = 0; i < 4; i++) (data.getFloat32(i * 4, byteOrder == 'little' ? Endian.little : Endian.big) * 255).round()]);
  }
}

/// Compares raw samples with values read independently through GIMP/GEGL.
void _referenceTests(String root, String referencePath) {
  final List<Object?> references = jsonDecode(File(referencePath).readAsStringSync()) as List<Object?>;
  for (final Object? raw in references) {
    final Map<String, Object?> reference = (raw as Map<String, Object?>);
    final String name = reference['file']! as String;
    test('GIMP exact samples: $root/$name', () {
      final XcfDocument document = XcfWrappedCodec.decode(File('$root/$name').readAsBytesSync(), options: const XcfReadOptions(maxDecodedBytes: 1024 * 1024 * 1024));
      _compare(document, reference);
      // Offline tests also exercise reconstruction; actual GIMP reopening is
      // separately performed by tool/gimp_reference.py against generated output.
      final XcfDocument rebuilt = XcfCodec.decode(XcfCodec.encode(document), options: const XcfReadOptions(maxDecodedBytes: 1024 * 1024 * 1024));
      _compare(rebuilt, reference);
    });
  }
}

void _compare(XcfDocument document, Map<String, Object?> reference) {
  expect(document.width, reference['width']);
  expect(document.height, reference['height']);
  expect(document.precision.code, reference['precision']);
  final List<Object?> layers = reference['layers']! as List<Object?>;
  expect(document.layers.length, layers.length);
  // GIMP can change order/group membership when loading floating selections.
  // The codec retains file order and paths; tattoos identify the same items.
  final int? floatingIndex = document.floatingSelection?.layerIndex;
  final List<XcfLayer> normalized = floatingIndex != null && floatingIndex != 0
      ? [for (final Object? expected in layers) document.layers.singleWhere((layer) => layer.properties.property(XcfPropertyId.tattoo)?.integer == (expected! as Map<String, Object?>)['tattoo'])]
      : document.layers;
  for (int i = 0; i < layers.length; i++) {
    final Map<String, Object?> expected = layers[i]! as Map<String, Object?>;
    final XcfLayer layer = normalized[i];
    expect(layer.name, expected['name']);
    expect(layer.visible, expected['visible']);
    expect(layer.x, expected['x']);
    expect(layer.y, expected['y']);
    expect(layer.opacity * 100, closeTo((expected['opacity']! as num).toDouble(), 0.00001));
    expect(layer.isGroup, expected['group']);
    final List<Object?> effects = expected['effects']! as List<Object?>;
    expect(layer.effects.length, effects.length);
    for (int e = 0; e < effects.length; e++) {
      final Map<String, Object?> effect = effects[e]! as Map<String, Object?>;
      expect(layer.effects[e].operation, effect['operation']);
      final Map<String, Object?> parameters = effect['parameters']! as Map<String, Object?>;
      for (final XcfFilterArgument argument in layer.effects[e].arguments) {
        if (parameters.containsKey(argument.name) && argument.value is! XcfColor && argument.value is! XcfGradient) {
          expect(argument.value, parameters[argument.name]);
        }
      }
    }
    if (expected['text'] case final Map<String, Object?> text) {
      expect(layer.text!.text, text['text']);
      expect(layer.text!.markup, text['markup']);
      expect(layer.text!.fontSize, text['size']);
      if (text['options'] case final Map<String, Object?> options) {
        final XcfTextOptions actual = layer.text!.options;
        expect(actual.antialias, options['antialias']);
        expect(actual.kerning, options['kerning']);
        expect(actual.language, options['language']);
        expect(actual.indent, options['indent']);
        expect(actual.lineSpacing, options['line_spacing']);
        expect(actual.letterSpacing, options['letter_spacing']);
        expect(['none', 'slight', 'medium', 'full'].indexOf(actual.hintStyle), options['hint']);
        expect(['ltr', 'rtl', 'ttb-rtl', 'ttb-rtl-upright', 'ttb-ltr', 'ttb-ltr-upright'].indexOf(actual.direction), options['direction']);
        expect(['left', 'right', 'center', 'fill'].indexOf(actual.justification), options['justification']);
        expect(['none', 'stroke-only', 'stroke-fill'].indexOf(actual.outline.mode), options['outline']);
        expect(actual.outline.width, options['outline_width']);
        expect(actual.outline.antialias, options['outline_antialias']);
        expect(actual.outline.miterLimit, options['outline_miter']);
        expect(actual.outline.dashOffset, options['outline_dash_offset']);
      }
    }
    if (expected['raster'] case final Map<String, Object?> raster) {
      _raster(layer.raster!, raster);
    }
    if (expected['mask'] case final Map<String, Object?> mask) {
      _raster(layer.mask!.raster, mask);
      expect(layer.applyMask, expected['apply_mask']);
    }
  }
  final List<Object?> channels = reference['channels']! as List<Object?>;
  final List<XcfChannel> savedChannels = document.channels.where((value) => !value.isSelection).toList();
  expect(savedChannels.length, channels.length);
  for (int i = 0; i < channels.length; i++) {
    _raster(savedChannels[i].raster, channels[i]! as Map<String, Object?>);
  }
  for (final XcfChannel selection in document.channels.where((value) => value.isSelection)) {
    _raster(selection.raster, reference['selection']! as Map<String, Object?>);
  }
  if (reference['floating'] case final Map<String, Object?> floating) {
    final XcfFloatingSelection selection = document.floatingSelection!;
    expect(normalized.indexOf(document.layers[selection.layerIndex]), floating['layer_index']);
    expect(selection.targetKind.name, floating['kind']);
    final int normalizedIndex = selection.targetKind == XcfDrawableKind.channel ? selection.targetIndex : normalized.indexOf(document.layers[selection.targetIndex]);
    expect(normalizedIndex, floating['index']);
  }
  final List<Object?> paths = reference['paths']! as List<Object?>;
  {
    final List<XcfPath> decoded = document.paths;
    expect(decoded.length, paths.length);
    for (int i = 0; i < decoded.length; i++) {
      final Map<String, Object?> path = paths[i]! as Map<String, Object?>;
      expect(decoded[i].name, path['name']);
      final List<Object?> strokes = path['strokes']! as List<Object?>;
      expect(decoded[i].strokes.length, strokes.length);
      for (int s = 0; s < strokes.length; s++) {
        final Map<String, Object?> stroke = strokes[s]! as Map<String, Object?>;
        expect(decoded[i].strokes[s].closed, stroke['closed']);
        expect([
          for (final XcfControlPoint point in decoded[i].strokes[s].points) ...[point.x, point.y],
        ], stroke['points']);
      }
    }
  }
}

void _raster(XcfRaster actual, Map<String, Object?> expected) {
  expect(actual.width, expected['width']);
  expect(actual.height, expected['height']);
  expect(actual.bytesPerPixel, expected['bpp']);
  expect(sha256.convert(actual.bytes).toString(), expected['sha256']);
}
