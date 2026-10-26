import 'dart:io';

import 'package:xcfkit/xcfkit.dart';

/// Produces edits for independent comparison with tool/gimp_semantic_edits.py.
void main(List<String> arguments) {
  final String output = arguments.firstOrNull ?? 'build/semantic-edits';
  Directory(output).createSync(recursive: true);
  for (final String name in ['text', 'text-options', 'text-markup', 'modern-path', 'legacy-path', 'compat-paths', 'effect', 'effect-color']) {
    XcfDocument document = _read(name);
    if (name == 'text') {
      final XcfLayer layer = document.layers.single;
      final XcfLayer rendered = _read('text-edited').layers.single;
      document = document.copyWith(
        layers: [layer.withText(layer.text!.withText('Été "X"').withFontSize(20), renderedRaster: rendered.raster!, x: rendered.x, y: rendered.y)],
      );
    } else if (name == 'text-options') {
      final XcfLayer layer = document.layers.single;
      final XcfLayer rendered = _read('text-options-edited').layers.single;
      final XcfText text = layer.text!;
      final XcfTextOptions options = text.options.copyWith(
        font: rendered.text!.options.font,
        justification: 'right',
        letterSpacing: 0.75,
        lineSpacing: 5,
        indent: -1,
      );
      document = document.copyWith(
        layers: [layer.withText(text.withOptions(options), renderedRaster: rendered.raster!, x: rendered.x, y: rendered.y)],
      );
    } else if (name == 'text-markup') {
      final XcfLayer layer = document.layers.single;
      final XcfLayer rendered = _read('text-markup-edited').layers.single;
      final XcfText text = layer.text!;
      final XcfTextContent content = text.content;
      final XcfTextContent edited = content.copyWith(
        styleRuns: [
          for (final XcfTextStyleRun run in content.styleRuns)
            XcfTextStyleRun(
              start: run.start,
              length: run.length,
              style: run.style.foreground == null ? run.style : run.style.copyWith(foreground: '#cc2244'),
            ),
        ],
      );
      document = document.copyWith(
        layers: [layer.withText(text.withContent(edited), renderedRaster: rendered.raster!, x: rendered.x, y: rendered.y)],
      );
    } else if (name.contains('path')) {
      document = document.withPaths([
        for (final XcfPath path in document.paths)
          path.copyWith(
            name: '${path.name} edited',
            strokes: [
              for (final XcfStroke stroke in path.strokes) stroke.copyWith(points: stroke.points.map((point) => point.withPosition(point.x + 3, point.y + 2)).toList()),
            ],
          ),
      ]);
    } else {
      final XcfLayer layer = document.layers.single;
      document = document.copyWith(
        layers: [
          layer.copyWith(
            effects: [layer.effects.single.withArgument(name == 'effect-color' ? XcfFilterArgument.color('value', XcfColor.rgba8(255, 0, 255, 128)) : XcfFilterArgument.floating('brightness', 0.45))],
          ),
        ],
      );
    }
    File('$output/$name.xcf').writeAsBytesSync(XcfCodec.encode(document));
  }
}

/// Reads a checked-in file generated independently with GIMP.
XcfDocument _read(String name) => XcfCodec.decode(File('test/fixtures/gimp/$name.xcf').readAsBytesSync());
