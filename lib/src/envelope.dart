/// Optional whole-file envelopes, separate from XCF's per-tile compression.
///
/// Importing `xcfkit.dart` alone does not pull these envelope codecs into a build.
/// This convenience API is bounded but in-memory; unwrap large files to a
/// temporary seekable file before opening them lazily.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:xcfkit/src/codec.dart';
import 'package:xcfkit/src/exception.dart';
import 'package:xcfkit/src/model.dart';
import 'package:zcodec/zcodec.dart' as z;

/// Optional outer envelope, identified by signature rather than filename.
enum XcfEnvelope {
  /// Ordinary, directly seekable XCF.
  none,

  /// GZIP/DEFLATE (`.xcf.gz`).
  gzip,

  /// BZIP2 (`.xcf.bz2`).
  bzip2,

  /// XZ/LZMA2 (`.xcf.xz`).
  xz,
}

/// Bounded, checksum-verified whole-file XCF envelope support.
abstract final class XcfWrappedCodec {
  /// Identifies a supported signature, or returns null for an unrelated file.
  static XcfEnvelope? detect(List<int> bytes) {
    if (XcfCodec.matches(bytes)) {
      return XcfEnvelope.none;
    }
    if (_prefix(bytes, [31, 139])) {
      return XcfEnvelope.gzip;
    }
    if (_prefix(bytes, [66, 90, 104])) {
      return XcfEnvelope.bzip2;
    }
    if (_prefix(bytes, [253, 55, 122, 88, 90, 0])) {
      return XcfEnvelope.xz;
    }
    return null;
  }

  /// Removes one envelope with size and dictionary limits, then decodes XCF.
  static XcfDocument decode(Uint8List bytes, {XcfReadOptions options = const XcfReadOptions(), int maxDictionaryBytes = 64 * 1024 * 1024}) => XcfCodec.decode(
    unwrap(bytes, maxInputBytes: options.maxInputBytes, maxOutputBytes: options.maxInputBytes, maxDictionaryBytes: maxDictionaryBytes),
    options: options,
  );

  /// Returns raw XCF bytes, rejecting partial output, bad checksums and nesting.
  static Uint8List unwrap(Uint8List bytes, {int maxInputBytes = 512 * 1024 * 1024, int maxOutputBytes = 512 * 1024 * 1024, int maxDictionaryBytes = 64 * 1024 * 1024}) {
    if (maxInputBytes < 0 || maxOutputBytes < 0 || maxDictionaryBytes < 0) {
      throw ArgumentError('Envelope limits must be nonnegative');
    }
    if (bytes.length > maxInputBytes) {
      throw const XcfFormatException('Compressed XCF input exceeds the configured limit');
    }
    final XcfEnvelope? envelope = detect(bytes);
    try {
      final Uint8List result;
      switch (envelope) {
        case XcfEnvelope.none:
          result = bytes;
        case XcfEnvelope.gzip:
          result = z.GzipDecoder(maxOutputBytes: maxOutputBytes).convert(bytes);
        case XcfEnvelope.bzip2:
          result = z.Bzip2Decoder(maxInputBytes: maxInputBytes, maxOutputBytes: maxOutputBytes).convert(bytes);
        case XcfEnvelope.xz:
          result = z.XzDecoder(maxInputBytes: maxInputBytes, maxOutputBytes: maxOutputBytes, maxDictionaryBytes: maxDictionaryBytes).convert(bytes);
        case null:
          throw const XcfUnsupportedException('Unrecognized XCF envelope');
      }
      if (result.length > maxOutputBytes) {
        throw const XcfFormatException('Expanded XCF exceeds the configured limit');
      }
      if (!XcfCodec.matches(result)) {
        throw const XcfFormatException('Envelope does not contain a plain XCF document');
      }
      return result;
    } on z.ZCodecException catch (error) {
      throw XcfFormatException('Invalid XCF envelope: $error');
    } on RangeError catch (error) {
      throw XcfFormatException('Truncated XCF envelope: $error');
    }
  }

  /// Encodes a document with a selected outer envelope and a bounded output.
  ///
  /// All three compressed envelopes use ZCodec; XZ uses genuine LZMA2
  /// compression and stores chunks only when compression would expand them.
  static Uint8List encode(XcfDocument document, {XcfEnvelope envelope = XcfEnvelope.none, XcfWriteOptions options = const XcfWriteOptions()}) => wrap(
    XcfCodec.encode(document, options: options),
    envelope: envelope,
    maxOutputBytes: options.maxOutputBytes,
  );

  /// Wraps raw XCF bytes; inner tile compression and metadata stay unchanged.
  static Uint8List wrap(Uint8List bytes, {required XcfEnvelope envelope, int maxOutputBytes = 512 * 1024 * 1024}) {
    if (maxOutputBytes < 0) {
      throw ArgumentError.value(maxOutputBytes, 'maxOutputBytes');
    }
    if (!XcfCodec.matches(bytes)) {
      throw const XcfFormatException('Only plain XCF bytes can be wrapped');
    }
    final _EnvelopeSink output = _EnvelopeSink(maxOutputBytes);
    final z.ByteEncoder? encoder = switch (envelope) {
      XcfEnvelope.none => null,
      XcfEnvelope.gzip => const z.GzipEncoder(),
      XcfEnvelope.bzip2 => const z.Bzip2Encoder(),
      XcfEnvelope.xz => const z.XzEncoder(check: z.XzCheck.crc32),
    };
    try {
      if (encoder == null) {
        output.add(bytes);
      } else {
        final ByteConversionSink sink = encoder.startChunkedConversion(output);
        sink
          ..add(bytes)
          ..close();
      }
    } on z.ZCodecException catch (error) {
      throw XcfFormatException('Cannot encode XCF envelope: $error');
    }
    return output.bytes.takeBytes();
  }
}

/// Tests a small fixed signature without allocating an input copy.
bool _prefix(List<int> bytes, List<int> prefix) {
  if (bytes.length < prefix.length) {
    return false;
  }
  for (int i = 0; i < prefix.length; i++) {
    if (bytes[i] != prefix[i]) {
      return false;
    }
  }
  return true;
}

/// Bounded sink shared by all optional envelope encoders.
final class _EnvelopeSink implements Sink<List<int>> {
  /// Maximum encoded output size.
  final int limit;

  /// Owned accumulated output bytes.
  final BytesBuilder bytes = BytesBuilder();

  /// Creates a sink with a cumulative encoded-byte ceiling.
  _EnvelopeSink(this.limit);

  @override
  void add(List<int> data) {
    if (data.length > limit - bytes.length) {
      throw const XcfFormatException('Wrapped XCF output exceeds the configured limit');
    }
    bytes.add(data);
  }

  @override
  void close() {}
}
