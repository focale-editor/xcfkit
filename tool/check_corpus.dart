import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:xcfkit/xcfkit.dart';

/// Decodes and optionally rebuilds an independently sourced XCF corpus.
Future<void> main(List<String> arguments) async {
  final String root = arguments.where((value) => !value.startsWith('--')).firstOrNull ?? 'test/corpus';
  final bool roundTrip = arguments.contains('--round-trip');
  final bool metadata = arguments.contains('--metadata');
  final String? output = arguments.where((value) => value.startsWith('--output=')).firstOrNull?.substring(9);
  final String reportPath = arguments.where((value) => value.startsWith('--report=')).firstOrNull?.substring(9) ?? 'build/corpus-report.json';
  final Map<String, String> expectedRejections = {
    'gimp-data/icons/Legacy/22/gimp-tool-handle-transform.xcf': 'Truncated XCF header',
    'FHPythonUtils/test_files/64x64_copy.xcf': 'dimensions',
    'FHPythonUtils/test_files/base24copy.xcf': 'Property 7',
  };
  final List<File> files = Directory(root).listSync(recursive: true).whereType<File>().where((file) => file.path.endsWith('.xcf')).toList()..sort((a, b) => a.path.compareTo(b.path));
  final List<Map<String, Object?>> results = [];
  int passed = 0;
  int rejected = 0;
  for (final File file in files) {
    final String relative = file.path.substring(root.length + 1);
    final String? expectedReason = expectedRejections[relative] ?? expectedRejections.entries.where((entry) => file.path.endsWith('/${entry.key}')).firstOrNull?.value;
    try {
      final XcfDocument document = XcfCodec.decode(await file.readAsBytes(), options: const XcfReadOptions(maxDecodedBytes: 1024 * 1024 * 1024));
      if (expectedReason != null) {
        throw StateError('Known corrupt fixture unexpectedly decoded');
      }
      final Map<String, Object?> value = fingerprint(document);
      final Map<String, Object?>? interpreted = metadata ? _metadata(document) : null;
      if (roundTrip) {
        final Uint8List encoded = XcfCodec.encode(document);
        final XcfDocument restored = XcfCodec.decode(encoded, options: const XcfReadOptions(maxDecodedBytes: 1024 * 1024 * 1024));
        if (jsonEncode(fingerprint(restored)) != jsonEncode(value)) {
          throw StateError('Semantic round-trip differs');
        }
        if (metadata && jsonEncode(_metadata(restored)) != jsonEncode(interpreted)) {
          throw StateError('Typed metadata round-trip differs');
        }
        if (output != null) {
          final File destination = File('$output/$relative');
          await destination.parent.create(recursive: true);
          await destination.writeAsBytes(encoded);
        }
      }
      results.add({'file': relative, 'ok': true, ...value, if (metadata) 'interpreted': interpreted, 'warnings': document.warnings});
      passed++;
    } on Object catch (error, stack) {
      final String? reason = expectedReason;
      final bool expected = reason != null && error is XcfFormatException && error.message.contains(reason);
      results.add({'file': relative, 'ok': false, 'expected_rejection': expected, 'error': '$error', 'stack': '$stack'});
      if (expected) {
        rejected++;
      } else {
        stderr.writeln('$relative: $error');
      }
    }
    if (results.length % 50 == 0) {
      stdout.writeln('${results.length}/${files.length} processed, $passed passed');
    }
  }
  final File report = File(reportPath);
  await report.parent.create(recursive: true);
  await report.writeAsString('${const JsonEncoder.withIndent('  ').convert(results)}\n');
  stdout.writeln('$passed decoded, $rejected expected corrupt inputs, ${files.length - passed - rejected} failures (${roundTrip ? 'decode + semantic round-trip' : 'decode'}); ${report.path}');
  if (passed + rejected != files.length) {
    exitCode = 1;
  }
}

/// Exercises typed metadata access without interpreting rendering semantics.
Map<String, Object?> _metadata(XcfDocument document) => {
  'guides': document.guides.map((guide) => [guide.position, guide.orientation]).toList(),
  'samplePoints': document.samplePoints.map((point) => [point.x, point.y, point.mode, point.reserved1, point.reserved2]).toList(),
  'resolution': document.resolution == null ? null : [document.resolution!.x, document.resolution!.y],
  'unit': document.unitId,
  'userUnit': document.userUnit == null
      ? null
      : [
          document.userUnit!.name,
          document.userUnit!.factor,
          document.userUnit!.digits,
          document.userUnit!.symbol,
          document.userUnit!.abbreviation,
          document.userUnit!.singular,
          document.userUnit!.plural,
        ],
  'grid': document.configuration('gimp-image-grid')?.source,
  'vectors': [
    for (final XcfLayer layer in document.layers)
      if (layer.vectorLayer case final XcfVectorLayer vector)
        [
          vector.pathTattoo,
          vector.modified,
          vector.enableFill,
          vector.enableStroke,
          vector.fill.style,
          vector.stroke.style,
          vector.strokeWidth,
          vector.capStyle,
          vector.joinStyle,
          vector.miterLimit,
          vector.dashes,
          sha256.convert(vector.toProperty().data).toString(),
        ],
  ],
  'texts': [
    for (final XcfLayer layer in document.layers)
      if (layer.text case final XcfText text)
        {
          'text': text.text == null ? null : sha256.convert(utf8.encode(text.text!)).toString(),
          'markup': text.markup == null ? null : sha256.convert(utf8.encode(text.markup!)).toString(),
          'content': sha256.convert(utf8.encode(text.content.text)).toString(),
          'styles': [
            for (final XcfTextStyleRun run in text.content.styleRuns)
              [
                run.start,
                run.length,
                for (final XcfTextSpan span in run.style.spans) [span.name, span.attributes],
              ],
          ],
          'options': [
            text.options.justification,
            text.options.language,
            text.options.direction,
            text.options.antialias,
            text.options.hintStyle,
            text.options.kerning,
            text.options.indent,
            text.options.lineSpacing,
            text.options.letterSpacing,
            text.options.box.mode,
            text.options.box.width,
            text.options.box.height,
            text.options.transform.xx,
            text.options.outline.dashes,
          ],
          'font': text.fontName,
          'size': text.fontSize,
          'unit': text.fontSizeUnit,
        },
  ],
  'paths': [
    for (final XcfPath path in document.paths)
      {
        'name': path.name,
        'strokes': [
          for (final XcfStroke stroke in path.strokes)
            {
              'closed': stroke.closed,
              'points': [
                for (final XcfControlPoint point in stroke.points) [point.type, ...point.coordinates],
              ],
            },
        ],
      },
  ],
  'arguments': [
    for (final XcfLayer layer in document.layers)
      for (final XcfEffect effect in layer.effects)
        for (final XcfFilterArgument argument in effect.arguments) [argument.name, argument.type, _argumentValue(argument.value), if (argument.type == 6) argument.configuration!.names],
  ],
};

/// Makes complex metadata comparable without converting its colors or rendering.
Object? _argumentValue(Object? value) => switch (value) {
  final XcfColor color => {'encoding': color.encoding, 'pixel': color.pixel.toList(), 'profile': sha256.convert(color.profile).toString()},
  final XcfGradient gradient => sha256.convert(gradient.encode()).toString(),
  _ => value,
};

/// Includes exact samples and opaque metadata, excluding source encoding.
Map<String, Object?> fingerprint(XcfDocument document) => {
  'version': document.version,
  'width': document.width,
  'height': document.height,
  'mode': document.colorMode.name,
  'precision': document.precision.name,
  'floating': document.floatingSelection == null ? null : [document.floatingSelection!.layerIndex, document.floatingSelection!.targetKind.name, document.floatingSelection!.targetIndex],
  'properties': _properties(document.properties.where((value) => value.type != XcfPropertyId.compression).toList()),
  'layers': [
    for (final XcfLayer layer in document.layers)
      {
        'name': layer.name,
        'width': layer.width,
        'height': layer.height,
        'type': layer.type.name,
        'pixels': layer.raster == null ? null : sha256.convert(layer.raster!.bytes).toString(),
        'properties': _properties(layer.properties.where((value) => value.type != XcfPropertyId.floatingSelection).toList()),
        'mask': layer.mask == null ? null : _channel(layer.mask!),
        'effects': layer.effects.map(_effect).toList(),
      },
  ],
  'channels': document.channels.map(_channel).toList(),
  'vectors': [
    for (final XcfVector vector in document.vectors) {'name': vector.name, 'payload': sha256.convert(vector.payload).toString()},
  ],
};

List<Object> _properties(List<XcfProperty> values) => [
  for (final XcfProperty value in values) [value.type, sha256.convert(value.data).toString()],
];
Map<String, Object?> _channel(XcfChannel channel) => {
  'name': channel.name,
  'width': channel.raster.width,
  'height': channel.raster.height,
  'pixels': sha256.convert(channel.raster.bytes).toString(),
  'properties': _properties(channel.properties),
  'effects': channel.effects.map(_effect).toList(),
};
Map<String, Object?> _effect(XcfEffect effect) => {
  'name': effect.name,
  'icon': effect.icon,
  'operation': effect.operation,
  'version': effect.version,
  'properties': _properties(effect.properties),
  'mask': effect.mask == null ? null : _channel(effect.mask!),
};
