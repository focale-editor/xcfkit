import 'package:xcfkit/src/exception.dart';

/// Storage of each color or alpha component, independent of its color profile.
enum XcfPrecision {
  /// Unsigned 8-bit linear samples.
  u8Linear(100, 1),

  /// Unsigned 8-bit samples using the profile's transfer curve.
  u8Nonlinear(150, 1),

  /// Unsigned 8-bit perceptual samples.
  u8Perceptual(175, 1),

  /// Unsigned 16-bit linear samples.
  u16Linear(200, 2),

  /// Unsigned 16-bit samples using the profile's transfer curve.
  u16Nonlinear(250, 2),

  /// Unsigned 16-bit perceptual samples.
  u16Perceptual(275, 2),

  /// Unsigned 32-bit linear samples.
  u32Linear(300, 4),

  /// Unsigned 32-bit samples using the profile's transfer curve.
  u32Nonlinear(350, 4),

  /// Unsigned 32-bit perceptual samples.
  u32Perceptual(375, 4),

  /// IEEE 754 binary16 linear samples.
  halfLinear(500, 2),

  /// IEEE 754 binary16 samples using the profile's transfer curve.
  halfNonlinear(550, 2),

  /// IEEE 754 binary16 perceptual samples.
  halfPerceptual(575, 2),

  /// IEEE 754 binary32 linear samples.
  floatLinear(600, 4),

  /// IEEE 754 binary32 samples using the profile's transfer curve.
  floatNonlinear(650, 4),

  /// IEEE 754 binary32 perceptual samples.
  floatPerceptual(675, 4),

  /// IEEE 754 binary64 linear samples.
  doubleLinear(700, 8),

  /// IEEE 754 binary64 samples using the profile's transfer curve.
  doubleNonlinear(750, 8),

  /// IEEE 754 binary64 perceptual samples.
  doublePerceptual(775, 8);

  /// Numeric identifier used by XCF version 7 and later.
  final int code;

  /// Number of bytes occupied by a component.
  final int bytesPerComponent;
  const XcfPrecision(this.code, this.bytesPerComponent);

  /// Whether samples use IEEE 754 floating-point storage.
  bool get isFloatingPoint => code >= 500;

  /// Whether color components encode linear light.
  bool get isLinear => code % 100 == 0;

  /// Looks up a documented precision identifier.
  static XcfPrecision fromCode(int code) => values.where((value) => value.code == code).firstOrNull ?? (throw XcfUnsupportedException('Unsupported XCF precision $code'));
}

/// Image-wide color model.
enum XcfColorMode {
  /// Red, green, and blue components.
  rgb,

  /// One gray component.
  grayscale,

  /// An 8-bit index into the document palette.
  indexed,
}

/// Per-layer component layout; samples are interleaved, alpha is last.
enum XcfLayerType {
  /// Three RGB components.
  rgb(3, XcfColorMode.rgb, false),

  /// Three RGB components and straight alpha.
  rgba(4, XcfColorMode.rgb, true),

  /// One gray component.
  gray(1, XcfColorMode.grayscale, false),

  /// One gray component and straight alpha.
  grayAlpha(2, XcfColorMode.grayscale, true),

  /// One palette index.
  indexed(1, XcfColorMode.indexed, false),

  /// One palette index and straight alpha.
  indexedAlpha(2, XcfColorMode.indexed, true);

  /// Number of components per pixel.
  final int components;

  /// Color model of the layer.
  final XcfColorMode colorMode;

  /// Whether the last component is alpha.
  final bool hasAlpha;
  const XcfLayerType(this.components, this.colorMode, this.hasAlpha);
}

/// Compression applied independently to each pixel tile.
enum XcfCompression {
  /// Uncompressed interleaved samples.
  raw,

  /// XCF run-length compression, byte plane by byte plane.
  rle,

  /// A zlib stream for each tile.
  zlib,
}
