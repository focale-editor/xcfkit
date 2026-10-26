import 'dart:convert';
import 'dart:typed_data';

import 'package:xcfkit/xcfkit_compression.dart';

import '../test/envelope_fixtures.dart';

/// Runs without dart:io on the VM, JavaScript, or WebAssembly runtime.
void main() {
  int cases = 0;
  for (final XcfPrecision precision in XcfPrecision.values) {
    final Uint8List samples = Uint8List.fromList(List.generate(65 * 3 * 4 * precision.bytesPerComponent, (index) => index % 251));
    for (final XcfCompression compression in XcfCompression.values) {
      final XcfDocument document = XcfDocument(
        width: 65,
        height: 3,
        precision: precision,
        compression: compression,
        layers: [
          XcfLayer(
            name: 'Portable samples',
            width: 65,
            height: 3,
            raster: XcfRaster(width: 65, height: 3, bytesPerPixel: 4 * precision.bytesPerComponent, bytes: samples),
          ),
        ],
      );
      final XcfDocument decoded = XcfCodec.decode(XcfCodec.encode(document));
      final Uint8List actual = decoded.layers.single.raster!.bytes;
      if (actual.length != samples.length) {
        throw StateError('Wrong sample length');
      }
      for (int i = 0; i < samples.length; i++) {
        if (samples[i] != actual[i]) {
          throw StateError('Sample mismatch at $i');
        }
      }
      cases++;
    }
  }
  _storageAndEnvelopes();
  _semantics();
  _textAndResources();
  print('$cases precision/compression cases and semantic editing passed');
}

/// Exercises semantic models and attachment relocation without platform APIs.
void _semantics() {
  final XcfLayer layer = XcfLayer.rgba(name: 'Text', width: 1, height: 1, pixels: [10, 20, 30, 255]);
  final XcfText text = XcfText.fromSource('(text "old") (font "Sans")').withText('Été 😀');
  final XcfEffect effect = XcfEffect(name: 'Effect', operation: 'gegl:brightness-contrast').withArgument(XcfFilterArgument.floating('brightness', 0.25));
  final XcfDocument original =
      XcfDocument(
        version: 22,
        width: 1,
        height: 1,
        layers: [
          layer.withText(text, renderedRaster: layer.raster!).copyWith(effects: [effect]),
          layer,
        ],
        floatingSelection: const XcfFloatingSelection(targetKind: XcfDrawableKind.layer, targetIndex: 1),
      ).withPaths([
        XcfPath(
          name: 'Point',
          strokes: [
            XcfStroke(
              points: [
                for (final int type in [1, 0, 1]) XcfControlPoint(type: type, coordinates: [3, 2]),
              ],
            ),
          ],
        ),
      ]);
  final XcfDocument decoded = XcfCodec.decode(XcfCodec.encode(original));
  if (decoded.layers.first.text!.text != 'Été 😀' ||
      decoded.paths.single.strokes.single.points.first.x != 3 ||
      decoded.floatingSelection!.targetIndex != 1 ||
      decoded.layers.first.effects.single.argument('brightness')!.value != 0.25) {
    throw StateError('Semantic editing did not survive encoding');
  }
}

/// Exercises bounded XML parsing and encoded effect resources on web runtimes.
void _textAndResources() {
  final XcfText text = XcfText.fromSource('(markup "<markup>Été <b>😀</b></markup>")');
  final XcfTextContent content = text.content;
  final XcfText edited = text.withContent(content.copyWith(options: content.options.copyWith(direction: 'rtl', letterSpacing: 1.5)));
  final XcfColor color = XcfFilterArgument.color('color', XcfColor.rgba8(20, 30, 40, 128)).value! as XcfColor;
  final XcfGradient gradient = XcfGradient(
    name: 'Portable',
    segments: [XcfGradientSegment(left: 0, middle: 0.5, right: 1, leftColor: color, rightColor: XcfColor.rgba8(255, 255, 255))],
  );
  final XcfGradient decoded = XcfFilterArgument.gradient('gradient', gradient).value! as XcfGradient;
  if (edited.content.text != 'Été 😀' ||
      edited.content.styleAt(4)!.weight != 'bold' ||
      edited.options.direction != 'rtl' ||
      edited.options.letterSpacing != 1.5 ||
      decoded.segments.single.leftColor.pixel[3] != 128) {
    throw StateError('Text and color metadata did not survive encoding');
  }
}

/// Covers optional codecs and lazy sample reads on JavaScript and Wasm as well.
void _storageAndEnvelopes() {
  final Uint8List raw = base64Decode(envelopeFixtures['raw']!);
  for (final String name in ['xz_crc64', 'xz_sha256', 'xz_concatenated']) {
    final Uint8List decoded = XcfWrappedCodec.unwrap(base64Decode(envelopeFixtures[name]!));
    if (base64Encode(decoded) != base64Encode(raw)) {
      throw StateError('Independent XZ fixture mismatch');
    }
  }
  final XcfDocument lazy = XcfCodec.open(XcfMemoryInput(raw));
  if (!XcfCodec.preflight(lazy).canWrite || lazy.layers.single.raster!.readRegion(x: 0, y: 0, width: 1, height: 1)[3] != 255) {
    throw StateError('Lazy storage mismatch');
  }
  for (final XcfEnvelope envelope in XcfEnvelope.values) {
    if (base64Encode(XcfWrappedCodec.unwrap(XcfWrappedCodec.wrap(raw, envelope: envelope))) != base64Encode(raw)) {
      throw StateError('Envelope mismatch');
    }
  }
}
