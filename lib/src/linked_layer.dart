import 'package:xcfkit/src/binary.dart';
import 'package:xcfkit/src/exception.dart';
import 'package:xcfkit/src/model.dart';
import 'package:xcfkit/src/property.dart';

/// External-layer metadata, never resolved or opened by XcfKit.
final class XcfLayerLink {
  /// Original path or URI spelling, including relative paths.
  final String source;

  /// GIMP's flags, retained without enabling monitoring or external I/O.
  final int flags;

  /// Natural dimensions of the linked asset before transformation.
  final int width;

  /// Natural height of the linked asset.
  final int height;

  /// Creates link metadata independently of an optional cached raster.
  const XcfLayerLink({required this.source, required this.width, required this.height, this.flags = 0});

  /// Reads the actual payload, including files with repaired envelope lengths.
  factory XcfLayerLink.fromProperty(XcfProperty property) {
    if (property.type != XcfPropertyId.linkLayer) {
      throw ArgumentError('Not a linked-layer property');
    }
    final XcfReader reader = XcfReader(property.data);
    final int flags = reader.u32();
    final String source = reader.string(1024 * 1024);
    final int width = reader.u32();
    final int height = reader.u32();
    if (reader.offset != reader.end || width > 0x7fffffff || height > 0x7fffffff) {
      throw const XcfFormatException('Invalid linked-layer metadata');
    }
    return XcfLayerLink(source: source, flags: flags, width: width, height: height);
  }

  /// Replaces metadata without refreshing pixels or accessing the source.
  XcfLayerLink copyWith({String? source, int? flags, int? width, int? height}) =>
      XcfLayerLink(source: source ?? this.source, flags: flags ?? this.flags, width: width ?? this.width, height: height ?? this.height);

  /// Encodes a corrected self-contained envelope for XCF 25 and later.
  XcfProperty toProperty() {
    if (width < 0 || width > 0x7fffffff || height < 0 || height > 0x7fffffff || flags < 0 || flags > 0xffffffff) {
      throw ArgumentError('Invalid linked-layer metadata');
    }
    final XcfWriter writer = XcfWriter(1024 * 1024 + 16)
      ..u32(flags)
      ..string(source)
      ..u32(width)
      ..u32(height);
    return XcfProperty(type: XcfPropertyId.linkLayer, data: writer.finish());
  }
}

/// A linked layer's transform, retained as metadata without resampling pixels.
final class XcfLayerTransform {
  /// Signed output offsets.
  final int x;

  /// Signed vertical offset.
  final int y;

  /// GIMP interpolation identifier, including unknown future values.
  final int interpolation;

  /// Nine finite float32 coefficients in row-major order.
  final List<double> matrix;

  /// Copies a 3×3 transformation without calculating bounds or invertibility.
  XcfLayerTransform({this.x = 0, this.y = 0, this.interpolation = 0, required List<double> matrix}) : matrix = List.unmodifiable(matrix) {
    if (x < -0x80000000 ||
        x > 0x7fffffff ||
        y < -0x80000000 ||
        y > 0x7fffffff ||
        interpolation < 0 ||
        interpolation > 0xffffffff ||
        matrix.length != 9 ||
        matrix.any((value) => !value.isFinite || value.abs() > 3.4028234663852886e38)) {
      throw ArgumentError('Invalid layer transform');
    }
  }

  /// Decodes the fixed-size XCF transform property.
  factory XcfLayerTransform.fromProperty(XcfProperty property) {
    if (property.type != XcfPropertyId.transform) {
      throw ArgumentError('Not a transform property');
    }
    if (property.data.length != 48) {
      throw const XcfFormatException('Invalid layer transform size');
    }
    final XcfReader reader = XcfReader(property.data);
    try {
      return XcfLayerTransform(x: reader.i32(), y: reader.i32(), interpolation: reader.u32(), matrix: [for (int i = 0; i < 9; i++) reader.f32()]);
    } on ArgumentError {
      throw const XcfFormatException('Invalid layer transform coefficients');
    }
  }

  /// Encodes the transform, preserving numeric interpolation identifiers.
  XcfProperty toProperty() {
    final XcfWriter writer = XcfWriter(48)
      ..u32(x)
      ..u32(y)
      ..u32(interpolation);
    matrix.forEach(writer.f32);
    return XcfProperty(type: XcfPropertyId.transform, data: writer.finish());
  }
}

/// Typed access to link metadata while the layer's raster stays available.
extension XcfLinkedLayerMetadata on XcfLayer {
  /// Original linked source and flags, without any filesystem access.
  XcfLayerLink? get link {
    final XcfProperty? property = properties.property(XcfPropertyId.linkLayer);
    return property == null ? null : XcfLayerLink.fromProperty(property);
  }

  /// Linked-layer transformation, without applying it to the raster cache.
  XcfLayerTransform? get transform {
    final XcfProperty? property = properties.property(XcfPropertyId.transform);
    return property == null ? null : XcfLayerTransform.fromProperty(property);
  }
}
