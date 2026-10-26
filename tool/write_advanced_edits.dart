import 'dart:io';
import 'dart:typed_data';

import 'package:xcfkit/xcfkit_compression.dart';
import 'package:xcfkit/xcfkit_io.dart';

/// Rewrites independent fixtures and applies one vector and one curve edit.
void main(List<String> arguments) {
  final String root = arguments.isEmpty ? 'build/advanced' : arguments.first;
  final Directory rewrites = Directory('$root/rewrites')..createSync(recursive: true);
  final Directory edits = Directory('$root/edits')..createSync(recursive: true);
  const String fixtures = 'test/fixtures/gimp-advanced';
  for (final File source in Directory(fixtures).listSync().whereType<File>()) {
    final String name = source.uri.pathSegments.last;
    final RandomAccessFile probe = source.openSync();
    final XcfEnvelope? envelope;
    try {
      envelope = XcfWrappedCodec.detect(probe.readSync(14));
    } finally {
      probe.closeSync();
    }
    if (envelope == null) {
      continue;
    }
    if (envelope == XcfEnvelope.none) {
      final XcfFileInput input = XcfFileInput(source.path);
      final XcfFileOutput output = XcfFileOutput('${rewrites.path}/$name');
      int? length;
      try {
        length = XcfCodec.encodeTo(XcfCodec.open(input), output);
      } finally {
        input.close();
        output.close(length: length);
      }
    } else {
      final XcfDocument document = XcfWrappedCodec.decode(source.readAsBytesSync());
      File('${rewrites.path}/$name').writeAsBytesSync(XcfWrappedCodec.encode(document, envelope: envelope));
    }
  }
  final XcfDocument vector = XcfCodec.decode(File('$fixtures/vector.xcf').readAsBytesSync());
  final XcfDocument vectorReference = XcfCodec.decode(File('$fixtures/vector-edited.xcf').readAsBytesSync());
  final XcfLayer original = vector.layers.single;
  final XcfLayer rendered = vectorReference.layers.single;
  // GIMP supplies the independently rendered target cache. The kit edits only
  // the parameters and copies that cache in the original sample layout.
  final XcfLayer layer = original.withVectorLayer(
    original.vectorLayer!.copyWith(strokeWidth: 4.5, fill: original.vectorLayer!.fill.copyWith(color: rendered.vectorLayer!.fill.color)),
    renderedRaster: rendered.raster!,
    x: rendered.x,
    y: rendered.y,
  );
  File('${edits.path}/vector-edited.xcf').writeAsBytesSync(XcfCodec.encode(vector.copyWith(layers: [layer])));

  final File curveReferenceFile = File('$fixtures/curves-edited.xcf');
  if (curveReferenceFile.existsSync()) {
    final XcfDocument curves = XcfCodec.decode(File('$fixtures/curves.xcf').readAsBytesSync());
    final XcfDocument target = XcfCodec.decode(curveReferenceFile.readAsBytesSync());
    final XcfEffect effect = curves.layers.single.effects.single;
    final XcfConfiguration config = effect.argument('config')!.configuration!;
    final XcfCurve curve = XcfCurve(config.nested('curve', occurrence: 0)!);
    final XcfCurve reference = XcfCurve(target.layers.single.effects.single.argument('config')!.configuration!.nested('curve', occurrence: 0)!);
    final XcfCurve updated = curve.withPoints([XcfCurvePoint(0, 0), XcfCurvePoint(0.25, 0.6), XcfCurvePoint(0.75, 0.8), XcfCurvePoint(1, 1)], samples: reference.samples);
    final XcfEffect edited = effect.withArgument(XcfFilterArgument.configuration('config', config.withNested('curve', updated.configuration, occurrence: 0)));
    final Uint8List bytes = XcfCodec.encode(
      curves.copyWith(
        layers: [
          curves.layers.single.copyWith(effects: [edited]),
        ],
      ),
    );
    File('${edits.path}/curves-edited.xcf').writeAsBytesSync(bytes);
  }
}
