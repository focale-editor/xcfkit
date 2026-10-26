import 'dart:typed_data';

import 'package:xcfkit/src/binary.dart';
import 'package:xcfkit/src/color.dart';
import 'package:xcfkit/src/exception.dart';
import 'package:xcfkit/src/model.dart';
import 'package:xcfkit/src/paths.dart';
import 'package:xcfkit/src/property.dart';

/// Identifier of a GIMP resource; the resource itself is not embedded here.
final class XcfResourceReference {
  /// Resource name.
  final String name;

  /// Collection identifier, often a resource filename.
  final String collection;

  /// Whether GIMP supplies the resource internally.
  final bool internal;

  /// Creates a reference without resolving or opening any external resource.
  XcfResourceReference({required this.name, this.collection = '', this.internal = false}) {
    if (name.isEmpty || name.contains('\u0000') || collection.contains('\u0000')) {
      throw ArgumentError('Invalid resource identifier');
    }
  }
}

/// Vector fill or stroke paint, retaining GIMP's numeric style identifiers.
final class XcfVectorPaint {
  /// Custom style: solid=0, pattern=1; unknown identifiers are preserved.
  final int style;

  /// Whether GIMP antialiases the painted edge.
  final bool antialias;

  /// Paint color, without color conversion.
  final XcfColor? color;

  /// Referenced pattern; its pixels are not embedded by this property.
  final XcfResourceReference? pattern;

  /// Creates fill or stroke paint options.
  XcfVectorPaint({this.style = 0, this.antialias = true, this.color, this.pattern}) {
    _unsigned(style);
  }

  /// Replaces paint fields; explicit flags clear nullable resources.
  XcfVectorPaint copyWith({int? style, bool? antialias, XcfColor? color, XcfResourceReference? pattern, bool clearColor = false, bool clearPattern = false}) => XcfVectorPaint(
    style: style ?? this.style,
    antialias: antialias ?? this.antialias,
    color: clearColor ? null : color ?? this.color,
    pattern: clearPattern ? null : pattern ?? this.pattern,
  );
}

/// Editable XCF 24 vector-layer metadata and its path tattoo reference.
///
/// XcfKit preserves the saved raster and describes paint geometry. Rendering,
/// resolving external patterns and updating that raster belong to the host.
final class XcfVectorLayer {
  /// Whether the saved raster was modified independently of the vector.
  final bool modified;

  /// Persistent identifier of the document path used by this layer.
  final int pathTattoo;

  /// Whether to paint the path interior.
  final bool enableFill;

  /// Whether to paint the path outline.
  final bool enableStroke;

  /// Interior paint options.
  final XcfVectorPaint fill;

  /// Outline paint options.
  final XcfVectorPaint stroke;

  /// Stroke width in the serialized GIMP vector-layer coordinate units.
  final double strokeWidth;

  /// GIMP cap identifier: butt=0, round=1, square=2.
  final int capStyle;

  /// GIMP join identifier: miter=0, round=1, bevel=2.
  final int joinStyle;

  /// Miter limit stored as float32.
  final double miterLimit;

  /// Alternating painted and unpainted dash lengths, as serialized by GIMP.
  final List<double> dashes;

  /// Uninterpreted trailing bytes, retained during typed edits.
  final Uint8List unknownSuffix;

  /// Creates metadata without generating or changing the saved raster.
  XcfVectorLayer({
    required this.pathTattoo,
    required this.fill,
    required this.stroke,
    this.modified = false,
    this.enableFill = true,
    this.enableStroke = false,
    this.strokeWidth = 6,
    this.capStyle = 0,
    this.joinStyle = 0,
    this.miterLimit = 10,
    List<double> dashes = const [],
    List<int> unknownSuffix = const [],
  }) : dashes = List.unmodifiable(dashes),
       unknownSuffix = Uint8List.fromList(unknownSuffix).asUnmodifiableView() {
    _unsigned(pathTattoo);
    _unsigned(capStyle);
    _unsigned(joinStyle);
    if (dashes.length > 100000 || [strokeWidth, miterLimit, ...dashes].any((value) => !value.isFinite || value < 0 || value > 3.4028234663852886e38)) {
      throw ArgumentError('Invalid vector stroke parameters');
    }
  }

  /// Decodes a bounded property, preserving unknown trailing fields.
  factory XcfVectorLayer.fromProperty(XcfProperty property) {
    if (property.type != XcfPropertyId.vectorLayer) {
      throw ArgumentError('Not a vector-layer property');
    }
    final XcfReader reader = XcfReader(property.data);
    final bool modified = reader.u32() != 0;
    final int tattoo = reader.u32();
    final bool fillEnabled = reader.u32() != 0;
    final bool strokeEnabled = reader.u32() != 0;
    final XcfVectorPaint fill = _readPaint(reader);
    final XcfVectorPaint stroke = _readPaint(reader);
    final double width = reader.f32();
    final int cap = reader.u32();
    final int join = reader.u32();
    final double miter = reader.f32();
    final int count = reader.u32();
    if (count > 100000 || count > (reader.end - reader.offset) ~/ 4) {
      throw const XcfFormatException('Invalid vector dash count');
    }
    final List<double> dashes = [for (int i = 0; i < count; i++) reader.f32()];
    try {
      return XcfVectorLayer(
        pathTattoo: tattoo,
        fill: fill,
        stroke: stroke,
        modified: modified,
        enableFill: fillEnabled,
        enableStroke: strokeEnabled,
        strokeWidth: width,
        capStyle: cap,
        joinStyle: join,
        miterLimit: miter,
        dashes: dashes,
        unknownSuffix: reader.take(reader.end - reader.offset),
      );
    } on ArgumentError {
      throw const XcfFormatException('Invalid vector stroke parameters');
    }
  }

  /// Replaces vector fields while retaining unknown suffix bytes.
  XcfVectorLayer copyWith({
    bool? modified,
    int? pathTattoo,
    bool? enableFill,
    bool? enableStroke,
    XcfVectorPaint? fill,
    XcfVectorPaint? stroke,
    double? strokeWidth,
    int? capStyle,
    int? joinStyle,
    double? miterLimit,
    List<double>? dashes,
  }) => XcfVectorLayer(
    pathTattoo: pathTattoo ?? this.pathTattoo,
    fill: fill ?? this.fill,
    stroke: stroke ?? this.stroke,
    modified: modified ?? this.modified,
    enableFill: enableFill ?? this.enableFill,
    enableStroke: enableStroke ?? this.enableStroke,
    strokeWidth: strokeWidth ?? this.strokeWidth,
    capStyle: capStyle ?? this.capStyle,
    joinStyle: joinStyle ?? this.joinStyle,
    miterLimit: miterLimit ?? this.miterLimit,
    dashes: dashes ?? this.dashes,
    unknownSuffix: unknownSuffix,
  );

  /// Resolves exactly one document path, rejecting missing or ambiguous tattoos.
  XcfPath resolvePath(XcfDocument document) {
    final List<XcfPath> matches = document.paths.where((path) => path.properties.property(XcfPropertyId.tattoo)?.integer == pathTattoo).toList();
    if (pathTattoo == 0 || matches.length != 1) {
      throw const XcfFormatException('Unresolved or ambiguous vector-layer path tattoo');
    }
    return matches.single;
  }

  /// Encodes known fields and copies the unknown suffix unchanged.
  XcfProperty toProperty() {
    final XcfWriter writer = XcfWriter(64 * 1024 * 1024)
      ..u32(modified ? 1 : 0)
      ..u32(pathTattoo)
      ..u32(enableFill ? 1 : 0)
      ..u32(enableStroke ? 1 : 0);
    _writePaint(writer, fill);
    _writePaint(writer, stroke);
    writer
      ..f32(strokeWidth)
      ..u32(capStyle)
      ..u32(joinStyle)
      ..f32(miterLimit)
      ..u32(dashes.length);
    dashes.forEach(writer.f32);
    writer.add(unknownSuffix);
    return XcfProperty(type: XcfPropertyId.vectorLayer, data: writer.finish());
  }
}

/// Typed access to vector metadata alongside the independent saved raster.
extension XcfLayerVector on XcfLayer {
  /// Vector-layer parameters, if present.
  XcfVectorLayer? get vectorLayer {
    final XcfProperty? property = properties.property(XcfPropertyId.vectorLayer);
    return property == null ? null : XcfVectorLayer.fromProperty(property);
  }

  /// Applies metadata with an explicit, caller-updated raster cache.
  XcfLayer withVectorLayer(XcfVectorLayer value, {required XcfRaster renderedRaster, int? x, int? y}) {
    if (isGroup || raster == null || renderedRaster.bytesPerPixel != raster!.bytesPerPixel) {
      throw ArgumentError('Vector layer requires its original pixel layout');
    }
    List<XcfProperty> metadata = properties.replacing(value.toProperty());
    if (x != null || y != null) {
      metadata = metadata.replacing(XcfProperty.offsets(x: x ?? this.x, y: y ?? this.y));
    }
    return copyWith(width: renderedRaster.width, height: renderedRaster.height, raster: renderedRaster, properties: metadata);
  }
}

/// Checks numeric identifiers without restricting future enum values.
void _unsigned(int value) {
  if (value < 0 || value > 0xffffffff) {
    throw ArgumentError('Invalid vector identifier');
  }
}

/// Reads paint and its optional external pattern resource reference.
XcfVectorPaint _readPaint(XcfReader reader) {
  final int style = reader.u32();
  final bool antialias = reader.u32() != 0;
  final XcfColor? color = readXcfColor(reader);
  final String name = reader.string(1024 * 1024);
  final XcfResourceReference? pattern = name.isEmpty ? null : XcfResourceReference(name: name, collection: reader.string(1024 * 1024), internal: reader.u32() != 0);
  return XcfVectorPaint(style: style, antialias: antialias, color: color, pattern: pattern);
}

/// Writes paint without attempting to resolve its pattern resource.
void _writePaint(XcfWriter writer, XcfVectorPaint value) {
  writer
    ..u32(value.style)
    ..u32(value.antialias ? 1 : 0);
  writeXcfColor(writer, value.color);
  writer.string(value.pattern?.name ?? '');
  if (value.pattern case final XcfResourceReference pattern) {
    writer
      ..string(pattern.collection)
      ..u32(pattern.internal ? 1 : 0);
  }
}
