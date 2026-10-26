import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:xcfkit/xcfkit_compression.dart';

import 'envelope_fixtures.dart';

void main() {
  for (final String name in ['xz_crc64', 'xz_sha256', 'xz_concatenated']) {
    test('independent liblzma checksum and stream fixture: $name', () {
      final Uint8List bytes = base64Decode(envelopeFixtures[name]!);
      expect(XcfWrappedCodec.unwrap(bytes), base64Decode(envelopeFixtures['raw']!));
      if (name != 'xz_concatenated') {
        final int indexLength = (ByteData.sublistView(bytes).getUint32(bytes.length - 8, Endian.little) + 1) * 4;
        bytes[bytes.length - 12 - indexLength - 1] ^= 1;
        expect(() => XcfWrappedCodec.unwrap(bytes), throwsA(isA<XcfFormatException>()));
      }
    });
  }
  final XcfDocument document = XcfDocument(
    width: 8,
    height: 7,
    layers: [XcfLayer.rgba(name: 'Envelope', width: 8, height: 7, pixels: List.generate(8 * 7 * 4, (index) => index % 256))],
  );
  final Uint8List raw = XcfCodec.encode(document);
  for (final XcfEnvelope envelope in XcfEnvelope.values) {
    test('envelope detection and sample round-trip: $envelope', () {
      final Uint8List bytes = XcfWrappedCodec.encode(document, envelope: envelope);
      expect(XcfWrappedCodec.detect(bytes), envelope);
      expect(XcfWrappedCodec.unwrap(bytes), raw);
      expect(XcfWrappedCodec.decode(bytes).layers.single.raster!.bytes, document.layers.single.raster!.bytes);
    });
    test('envelope input, expansion and write limits: $envelope', () {
      final Uint8List bytes = XcfWrappedCodec.wrap(raw, envelope: envelope);
      expect(() => XcfWrappedCodec.unwrap(bytes, maxInputBytes: 5), throwsA(isA<XcfFormatException>()));
      expect(() => XcfWrappedCodec.unwrap(bytes, maxOutputBytes: 10), throwsA(isA<XcfFormatException>()));
      expect(() => XcfWrappedCodec.wrap(raw, envelope: envelope, maxOutputBytes: 10), throwsA(isA<XcfFormatException>()));
    });
    if (envelope != XcfEnvelope.none) {
      test('envelope rejects truncation and checksum damage: $envelope', () {
        final Uint8List bytes = XcfWrappedCodec.wrap(raw, envelope: envelope);
        expect(() => XcfWrappedCodec.unwrap(Uint8List.sublistView(bytes, 0, bytes.length - 6)), throwsA(isA<XcfFormatException>()));
        bytes[bytes.length ~/ 2] ^= 127;
        expect(() => XcfWrappedCodec.unwrap(bytes), throwsA(isA<XcfFormatException>()));
      });
    }
  }
  test('unrelated signatures and nested envelopes are rejected', () {
    expect(XcfWrappedCodec.detect([1, 2, 3]), isNull);
    expect(() => XcfWrappedCodec.decode(Uint8List.fromList([1, 2, 3])), throwsA(isA<XcfUnsupportedException>()));
    expect(() => XcfWrappedCodec.wrap(XcfWrappedCodec.wrap(raw, envelope: XcfEnvelope.gzip), envelope: XcfEnvelope.gzip), throwsA(isA<XcfFormatException>()));
  });
}
