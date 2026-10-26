import 'dart:typed_data';

import 'package:xcfkit/src/binary.dart';
import 'package:xcfkit/src/color.dart';
import 'package:xcfkit/src/exception.dart';

/// One segment of a serialized GIMP gradient; no interpolation is performed.
final class XcfGradientSegment {
  /// Normalized start, midpoint and end positions.
  final double left;

  /// Midpoint position controlling the transition.
  final double middle;

  /// End position.
  final double right;

  /// Endpoint colors, with their original encodings and profiles.
  final XcfColor leftColor;

  /// Right endpoint color in its original encoding.
  final XcfColor rightColor;

  /// GIMP interpolation identifier (linear, curved, sine, spherical, step).
  final int blending;

  /// RGB or directional HSV coloring identifier.
  final int coloring;

  /// Fixed/foreground/background endpoint source identifiers.
  final int leftColorType;

  /// Right endpoint's fixed/foreground/background source identifier.
  final int rightColorType;

  /// Creates a finite, ordered segment while retaining numeric enum values.
  XcfGradientSegment({
    required this.left,
    required this.middle,
    required this.right,
    required this.leftColor,
    required this.rightColor,
    this.blending = 0,
    this.coloring = 0,
    this.leftColorType = 0,
    this.rightColorType = 0,
  }) {
    if (![left, middle, right].every((value) => value.isFinite) ||
        left < 0 ||
        left > middle ||
        middle > right ||
        right > 1 ||
        [blending, coloring, leftColorType, rightColorType].any((value) => value < 0 || value > 0xffffffff)) {
      throw ArgumentError('Invalid gradient segment');
    }
  }

  /// Replaces selected segment fields without converting the endpoint colors.
  XcfGradientSegment copyWith({double? left, double? middle, double? right, XcfColor? leftColor, XcfColor? rightColor, int? blending, int? coloring, int? leftColorType, int? rightColorType}) =>
      XcfGradientSegment(
        left: left ?? this.left,
        middle: middle ?? this.middle,
        right: right ?? this.right,
        leftColor: leftColor ?? this.leftColor,
        rightColor: rightColor ?? this.rightColor,
        blending: blending ?? this.blending,
        coloring: coloring ?? this.coloring,
        leftColorType: leftColorType ?? this.leftColorType,
        rightColorType: rightColorType ?? this.rightColorType,
      );
}

/// An embedded gradient argument, independent of GIMP's installed resources.
///
/// Interoperability is tested against GIMP 3.3.1 development builds. GIMP 3.2.2
/// cannot read this argument kind even though the enclosing XCF version is 22.
final class XcfGradient {
  /// Resource name as stored in the argument.
  final String name;

  /// Ordered segments, including dynamic endpoint source identifiers.
  final List<XcfGradientSegment> segments;

  /// Creates an immutable gradient with a bounded segment count.
  XcfGradient({required this.name, required List<XcfGradientSegment> segments}) : segments = List.unmodifiable(segments) {
    if (segments.isEmpty || segments.length > 100000) {
      throw ArgumentError('Invalid gradient segment count');
    }
  }

  /// Replaces the name or segment list.
  XcfGradient copyWith({String? name, List<XcfGradientSegment>? segments}) => XcfGradient(name: name ?? this.name, segments: segments ?? this.segments);

  /// Decodes a version-1 gradient; an empty payload denotes a null resource.
  static XcfGradient? decode(Uint8List bytes) {
    if (bytes.isEmpty) {
      return null;
    }
    if (bytes.length > 64 * 1024 * 1024) {
      throw const XcfFormatException('Gradient metadata exceeds the limit');
    }
    final XcfReader reader = XcfReader(bytes);
    if (reader.u32() != 1) {
      throw const XcfUnsupportedException('Unsupported gradient version');
    }
    final String name = reader.string(1024 * 1024);
    final int count = reader.u32();
    if (count == 0 || count > 100000) {
      throw const XcfFormatException('Invalid gradient segment count');
    }
    final List<XcfGradientSegment> segments = [];
    for (int i = 0; i < count; i++) {
      final double left = reader.f32();
      final double middle = reader.f32();
      final double right = reader.f32();
      final XcfColor? leftColor = readXcfColor(reader);
      final XcfColor? rightColor = readXcfColor(reader);
      if (leftColor == null || rightColor == null) {
        throw const XcfFormatException('Gradient endpoints cannot be null');
      }
      try {
        segments.add(
          XcfGradientSegment(
            left: left,
            middle: middle,
            right: right,
            leftColor: leftColor,
            rightColor: rightColor,
            blending: reader.u32(),
            coloring: reader.u32(),
            leftColorType: reader.u32(),
            rightColorType: reader.u32(),
          ),
        );
      } on ArgumentError {
        throw const XcfFormatException('Invalid gradient segment');
      }
    }
    if (reader.offset != reader.end) {
      throw const XcfFormatException('Trailing gradient metadata');
    }
    return XcfGradient(name: name, segments: segments);
  }

  /// Encodes segment positions as XCF float32 values, retaining color bytes.
  Uint8List encode() {
    final XcfWriter writer = XcfWriter(64 * 1024 * 1024)
      ..u32(1)
      ..string(name)
      ..u32(segments.length);
    for (final XcfGradientSegment segment in segments) {
      writer.f32(segment.left);
      writer.f32(segment.middle);
      writer.f32(segment.right);
      writeXcfColor(writer, segment.leftColor);
      writeXcfColor(writer, segment.rightColor);
      writer.u32(segment.blending);
      writer.u32(segment.coloring);
      writer.u32(segment.leftColorType);
      writer.u32(segment.rightColorType);
    }
    return writer.finish();
  }
}
