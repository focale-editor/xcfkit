import 'dart:typed_data';

import 'package:xcfkit/src/binary.dart';
import 'package:xcfkit/src/exception.dart';

/// A serialized GIMP color retaining its Babl encoding, pixel and ICC profile.
///
/// No color conversion is performed. Unlike raster tiles, floating color bytes
/// originate in Babl's native encoding; they are preserved without guessing the
/// writer's byte order. [rgba8] creates an endian-independent representation.
final class XcfColor {
  /// Babl pixel encoding, for example `R'G'B'A u8` or `RGBA float`.
  final String encoding;

  /// Exact encoded pixel, including alpha when the encoding has it.
  final Uint8List pixel;

  /// Embedded ICC bytes; empty means GIMP's default sRGB space.
  final Uint8List profile;

  /// Creates a color while retaining encodings unknown to the host editor.
  XcfColor({required this.encoding, required List<int> pixel, List<int> profile = const []})
    : pixel = Uint8List.fromList(pixel).asUnmodifiableView(),
      profile = Uint8List.fromList(profile).asUnmodifiableView() {
    if (encoding.isEmpty || encoding.contains('\u0000') || encoding.length > 1024 || pixel.isEmpty || pixel.length > 4096 || profile.length > 16 * 1024 * 1024) {
      throw ArgumentError('Invalid or oversized serialized color');
    }
  }

  /// Creates a straight-alpha, nonlinear sRGB color with byte components.
  factory XcfColor.rgba8(int red, int green, int blue, [int alpha = 255]) {
    if ([red, green, blue, alpha].any((value) => value < 0 || value > 255)) {
      throw ArgumentError('Color components must be bytes');
    }
    return XcfColor(encoding: "R'G'B'A u8", pixel: [red, green, blue, alpha]);
  }

  /// Replaces color data without interpreting or converting it.
  XcfColor copyWith({String? encoding, List<int>? pixel, List<int>? profile}) => XcfColor(encoding: encoding ?? this.encoding, pixel: pixel ?? this.pixel, profile: profile ?? this.profile);
}

/// Reads a color inside a bounded metadata payload; old empty nulls are optional.
XcfColor? readXcfColor(XcfReader reader, {bool allowEmptyNull = false}) {
  if (allowEmptyNull && reader.offset == reader.end) {
    return null;
  }
  final String encoding = reader.string(1024);
  if (encoding.isEmpty) {
    return null;
  }
  final int size = reader.u32();
  if (size == 0 || size > 4096) {
    throw const XcfFormatException('Invalid serialized color pixel size');
  }
  final Uint8List pixel = reader.take(size);
  final int profileSize = reader.u32();
  if (profileSize > 16 * 1024 * 1024) {
    throw const XcfFormatException('Color profile exceeds the limit');
  }
  return XcfColor(encoding: encoding, pixel: pixel, profile: reader.take(profileSize));
}

/// Writes color metadata; null uses the explicit empty-string representation.
void writeXcfColor(XcfWriter writer, XcfColor? color) {
  writer.string(color?.encoding ?? '');
  if (color != null) {
    writer.u32(color.pixel.length);
    writer.add(color.pixel);
    writer.u32(color.profile.length);
    writer.add(color.profile);
  }
}
