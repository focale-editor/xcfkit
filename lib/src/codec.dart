import 'dart:convert';
import 'dart:typed_data';

import 'package:xcfkit/src/binary.dart';
import 'package:xcfkit/src/compression.dart';
import 'package:xcfkit/src/document_metadata.dart';
import 'package:xcfkit/src/effects.dart';
import 'package:xcfkit/src/exception.dart';
import 'package:xcfkit/src/model.dart';
import 'package:xcfkit/src/paths.dart';
import 'package:xcfkit/src/precision.dart';
import 'package:xcfkit/src/property.dart';
import 'package:xcfkit/src/storage.dart';
import 'package:xcfkit/src/text.dart';
import 'package:xcfkit/src/vector_layer.dart';

part 'decoder.dart';
part 'encoder.dart';
part 'preflight.dart';

/// Resource limits applied before allocating buffers or following structures.
final class XcfReadOptions {
  /// Maximum encoded file size.
  final int maxInputBytes;

  /// Maximum number of pixels in any drawable or canvas.
  final int maxPixels;

  /// Cumulative eager sample budget; per-request allocation ceiling in lazy mode.
  final int maxDecodedBytes;

  /// Cumulative property and vector payload budget.
  final int maxMetadataBytes;

  /// Maximum bytes in one UTF-8 string.
  final int maxStringBytes;

  /// Maximum number of layers, channels, effects, and vectors in total.
  final int maxItems;

  /// Maximum number of properties in total.
  final int maxProperties;

  /// Maximum nesting of effect masks and their effects.
  final int maxDepth;

  /// Creates conservative defaults suitable for untrusted documents.
  const XcfReadOptions({
    this.maxInputBytes = 512 * 1024 * 1024,
    this.maxPixels = 100000000,
    this.maxDecodedBytes = 512 * 1024 * 1024,
    this.maxMetadataBytes = 64 * 1024 * 1024,
    this.maxStringBytes = 1024 * 1024,
    this.maxItems = 10000,
    this.maxProperties = 100000,
    this.maxDepth = 64,
  });
}

/// Configuration for a complete in-memory XCF write.
final class XcfWriteOptions {
  /// Overrides the document's compression without changing its metadata.
  final XcfCompression? compression;

  /// Maximum encoded output size.
  final int maxOutputBytes;

  /// Creates bounded output options.
  const XcfWriteOptions({this.compression, this.maxOutputBytes = 512 * 1024 * 1024});
}

/// Reads and writes complete XCF documents, including original sample values.
abstract final class XcfCodec {
  /// Reports all known static write problems without loading lazy pixels.
  static XcfWriteReport preflight(XcfDocument document, {XcfWriteOptions options = const XcfWriteOptions()}) => _Preflight(document, options).read();

  /// Tests the XCF magic bytes without trusting a filename extension.
  static bool matches(List<int> bytes) => bytes.length >= 14 && ascii.decode(bytes.take(9).toList(), allowInvalid: true) == 'gimp xcf ';

  /// Decodes a layered XCF stream; unsupported features fail explicitly.
  static XcfDocument decode(Uint8List bytes, {XcfReadOptions options = const XcfReadOptions()}) => _Decoder(XcfMemoryInput(bytes), options).read();

  /// Rebuilds file pointers and tile data, preserving self-contained metadata.
  static Uint8List encode(XcfDocument document, {XcfWriteOptions options = const XcfWriteOptions()}) {
    final _Encoder encoder = _Encoder(document, options);
    encoder.write();
    return encoder.writer.finish();
  }

  /// Reads metadata and tile tables without decoding samples.
  ///
  /// The source remains caller-owned. Keep it open and unchanged until all lazy
  /// rasters have been consumed. Corrupt compressed tiles fail when requested.
  static XcfDocument open(XcfInput input, {XcfReadOptions options = const XcfReadOptions()}) => _Decoder(input, options, lazy: true).read();

  /// Writes one tile at a time to a seekable destination, returning its length.
  ///
  /// Supports lazy input rasters without materializing them. This synchronous
  /// operation can run in an isolate for UI applications. The output must not
  /// overwrite the source of any lazy raster in [document].
  static int encodeTo(XcfDocument document, XcfOutput output, {XcfWriteOptions options = const XcfWriteOptions()}) {
    final _Encoder encoder = _Encoder(document, options, output: output);
    encoder.write();
    return encoder.writer.length;
  }
}

/// A standard `dart:convert` codec with document-to-byte encoding direction.
final class XcfDocumentCodec extends Codec<XcfDocument, List<int>> {
  /// Options used by the decoder.
  final XcfReadOptions readOptions;

  /// Options used by the encoder.
  final XcfWriteOptions writeOptions;

  /// Creates a reusable XCF codec.
  const XcfDocumentCodec({this.readOptions = const XcfReadOptions(), this.writeOptions = const XcfWriteOptions()});
  @override
  Converter<List<int>, XcfDocument> get decoder => _DocumentDecoder(readOptions);
  @override
  Converter<XcfDocument, List<int>> get encoder => _DocumentEncoder(writeOptions);
}

/// Adapts bounded decoding to the dart:convert interface.
final class _DocumentDecoder extends Converter<List<int>, XcfDocument> {
  /// Limits applied before copying generic byte lists.
  final XcfReadOptions options;

  /// Creates an immutable decoder configuration.
  const _DocumentDecoder(this.options);
  @override
  XcfDocument convert(List<int> input) {
    if (input.length > options.maxInputBytes) {
      throw const XcfFormatException('XCF input exceeds the configured limit');
    }
    return XcfCodec.decode(input is Uint8List ? input : Uint8List.fromList(input), options: options);
  }
}

/// Adapts bounded encoding to the dart:convert interface.
final class _DocumentEncoder extends Converter<XcfDocument, List<int>> {
  /// Output policy used for each conversion.
  final XcfWriteOptions options;

  /// Creates an immutable encoder configuration.
  const _DocumentEncoder(this.options);
  @override
  Uint8List convert(XcfDocument input) => XcfCodec.encode(input, options: options);
}

/// Checks shared scalar payload invariants before reading or writing metadata.
void _validateProperty(XcfProperty property, {required bool wide}) {
  final int? expected = switch (property.type) {
    2 || 3 || 4 || 29 || 43 => 0,
    5 => wide ? 8 : 4,
    6 || 7 || 8 || 9 || 10 || 11 || 12 || 13 || 14 || 20 || 22 || 26 || 28 || 31 || 32 || 33 || 34 || 35 || 36 || 37 || 41 || 42 || 44 || 46 => 4,
    15 || 19 => 8,
    16 => 3,
    17 => 1,
    49 => 48,
    _ => null,
  };
  if (expected != null && property.data.length != expected) {
    throw XcfFormatException('Property ${property.type} needs $expected bytes');
  }
  if (property.type == XcfPropertyId.itemPath && (property.data.length % 4 != 0 || property.data.length > 1024)) {
    throw const XcfFormatException('Invalid XCF group path');
  }
  if (property.type == XcfPropertyId.floatOpacity && (!property.floating.isFinite || property.floating < 0 || property.floating > 1)) {
    throw const XcfFormatException('Invalid XCF opacity');
  }
  if (property.type == XcfPropertyId.opacity && property.integer > 255) {
    throw const XcfFormatException('Invalid XCF integer opacity');
  }
}
