import 'package:xcfkit/src/binary.dart';
import 'package:xcfkit/src/exception.dart';
import 'package:xcfkit/src/model.dart';
import 'package:xcfkit/src/property.dart';

part 'legacy_paths.dart';

/// A path control point, including optional tablet axes.
final class XcfControlPoint {
  /// GIMP anchor kind (0 for an anchor, 1 for a control handle).
  final int type;

  /// Coordinates in XCF order: x, y, pressure, x tilt, y tilt, wheel.
  final List<double> coordinates;

  /// Copies two to six finite float32 coordinates.
  XcfControlPoint({required this.type, required List<double> coordinates}) : coordinates = List.unmodifiable(coordinates) {
    if (type != 0 && type != 1 || coordinates.length < 2 || coordinates.length > 6 || coordinates.any((value) => !value.isFinite || value.abs() > 3.4028234663852886e38)) {
      throw ArgumentError('Invalid path control point');
    }
  }

  /// Horizontal image coordinate.
  double get x => coordinates[0];

  /// Vertical image coordinate.
  double get y => coordinates[1];

  /// Moves this point while preserving tablet axes and its anchor kind.
  XcfControlPoint withPosition(double x, double y) => XcfControlPoint(type: type, coordinates: [x, y, ...coordinates.skip(2)]);
}

/// An ordered Bézier stroke with explicit anchor and handle records.
final class XcfStroke {
  /// Whether the final anchor connects to the first.
  final bool closed;

  /// Number of coordinate axes stored for each point.
  final int axes;

  /// GIMP order: incoming handle, anchor, outgoing handle for each node.
  final List<XcfControlPoint> points;

  /// Creates a stroke; all points must have the same axis count.
  XcfStroke({this.closed = false, this.axes = 2, required List<XcfControlPoint> points}) : points = List.unmodifiable(points) {
    if (axes < 2 || axes > 6 || points.length % 3 != 0 || points.any((value) => value.coordinates.length != axes)) {
      throw ArgumentError('Invalid Bézier stroke layout');
    }
    for (int i = 0; i < points.length; i++) {
      if (points[i].type != (i % 3 == 1 ? 0 : 1)) {
        throw ArgumentError('Invalid Bézier anchor order');
      }
    }
  }

  /// Replaces geometry or closure while preserving the other stroke fields.
  XcfStroke copyWith({bool? closed, List<XcfControlPoint>? points}) => XcfStroke(closed: closed ?? this.closed, axes: axes, points: points ?? this.points);
}

/// Editable path geometry with uninterpreted item metadata retained.
final class XcfPath {
  /// Name shown in GIMP's paths panel.
  final String name;

  /// Path properties, including visibility, tattoo and parasites.
  final List<XcfProperty> properties;

  /// Ordered Bézier strokes.
  final List<XcfStroke> strokes;

  /// Creates a path independently of an image's XCF version.
  XcfPath({required this.name, List<XcfProperty> properties = const [], List<XcfStroke> strokes = const []}) : properties = List.unmodifiable(properties), strokes = List.unmodifiable(strokes);

  /// Decodes a modern vector record with bounded counts and coordinates.
  factory XcfPath.fromVector(XcfVector vector) {
    final _PathReader reader = _PathReader(XcfReader(vector.payload));
    final List<XcfProperty> properties = [];
    while (true) {
      final int type = reader.input.u32();
      final int size = reader.input.u32();
      if (type == 0) {
        if (size != 0) {
          throw const XcfFormatException('Invalid path property terminator');
        }
        break;
      }
      if (properties.length >= 100000) {
        throw const XcfFormatException('Too many path properties');
      }
      properties.add(XcfProperty(type: type, data: reader.input.take(size)));
    }
    if (reader.input.u32() != 1) {
      throw const XcfUnsupportedException('Unsupported path version');
    }
    final List<XcfStroke> strokes = reader.strokes(reader.input.u32());
    reader.finish();
    return XcfPath(name: vector.name, properties: properties, strokes: strokes);
  }

  /// Replaces path geometry or metadata.
  XcfPath copyWith({String? name, List<XcfProperty>? properties, List<XcfStroke>? strokes}) =>
      XcfPath(name: name ?? this.name, properties: properties ?? this.properties, strokes: strokes ?? this.strokes);

  /// Encodes the self-contained payload used by XCF 18 and later.
  XcfVector toVector() {
    final XcfWriter writer = XcfWriter(64 * 1024 * 1024);
    for (final XcfProperty property in properties) {
      writer.u32(property.type);
      writer.u32(property.data.length);
      writer.add(property.data);
    }
    writer.u32(0);
    writer.u32(0);
    writer.u32(1);
    writer.u32(strokes.length);
    for (final XcfStroke stroke in strokes) {
      writer.u32(1);
      writer.u32(stroke.closed ? 1 : 0);
      writer.u32(stroke.axes);
      writer.u32(stroke.points.length);
      for (final XcfControlPoint point in stroke.points) {
        writer.u32(point.type);
        point.coordinates.forEach(writer.f32);
      }
    }
    return XcfVector(name: name, payload: writer.finish());
  }
}

/// Typed access to all three generations of XCF vector paths.
extension XcfDocumentPaths on XcfDocument {
  /// Decodes modern vectors, PROP_VECTORS, or compatibility PROP_PATHS.
  List<XcfPath> get paths {
    if (vectors.isNotEmpty) {
      return List.unmodifiable(vectors.map(XcfPath.fromVector));
    }
    final XcfProperty? legacy = properties.property(XcfPropertyId.vectors);
    if (legacy == null) {
      final XcfProperty? compatibility = properties.property(XcfPropertyId.paths);
      return compatibility == null ? const [] : _compatibilityPaths(compatibility);
    }
    final _PathReader reader = _PathReader(XcfReader(legacy.data));
    if (reader.input.u32() != 1) {
      throw const XcfUnsupportedException('Unsupported legacy vector version');
    }
    final int selected = reader.input.u32();
    final int count = reader.input.u32();
    if (count > 10000) {
      throw const XcfFormatException('Too many paths');
    }
    final List<XcfPath> result = [];
    for (int i = 0; i < count; i++) {
      final String name = reader.input.string(1024 * 1024);
      final List<XcfProperty> metadata = [
        XcfProperty.integer(type: XcfPropertyId.tattoo, value: reader.input.u32()),
        XcfProperty.integer(type: XcfPropertyId.visible, value: reader.input.u32()),
        XcfProperty.integer(type: 9, value: reader.input.u32()),
        if (i == selected) XcfProperty(type: 43, data: const []),
      ];
      final int parasites = reader.input.u32();
      final int strokes = reader.input.u32();
      if (parasites > 100000) {
        throw const XcfFormatException('Too many path parasites');
      }
      final List<XcfParasite> records = [];
      for (int p = 0; p < parasites; p++) {
        records.add(XcfParasite(name: reader.input.string(1024 * 1024), flags: reader.input.u32(), data: reader.input.take(reader.input.u32())));
      }
      if (records.isNotEmpty) {
        metadata.add(XcfParasite.toProperty(records));
      }
      result.add(XcfPath(name: name, properties: metadata, strokes: reader.strokes(strokes)));
    }
    reader.finish();
    return List.unmodifiable(result);
  }

  /// Replaces all paths, upgrading to XCF 18 when needed.
  ///
  /// Legacy vector properties are removed because modern records supersede them.
  /// All three source representations are normalized to modern float32 points.
  XcfDocument withPaths(List<XcfPath> paths) => copyWith(
    version: version < 18 ? 18 : version,
    properties: properties.where((value) => value.type != 23 && value.type != XcfPropertyId.vectors).toList(),
    vectors: paths.map((value) => value.toVector()).toList(),
  );
}

/// Bounded state shared by every stroke in one vector property.
final class _PathReader {
  /// Byte cursor for this vector payload.
  final XcfReader input;

  /// Cumulative point count, limited before allocating point objects.
  int points = 0;

  /// Cumulative stroke count.
  int strokeCount = 0;

  /// Admits one metadata blob within the semantic decoder's byte budget.
  _PathReader(this.input) {
    if (input.end > 64 * 1024 * 1024) {
      throw const XcfFormatException('Path metadata exceeds the limit');
    }
  }

  /// Reads a bounded stroke list and translates validation failures.
  List<XcfStroke> strokes(int count) {
    strokeCount += count;
    if (strokeCount > 100000) {
      throw const XcfFormatException('Too many path strokes');
    }
    final List<XcfStroke> result = [];
    for (int i = 0; i < count; i++) {
      if (input.u32() != 1) {
        throw const XcfUnsupportedException('Unsupported path stroke type');
      }
      final int closed = input.u32();
      final int axes = input.u32();
      final int length = input.u32();
      points += length;
      if (closed > 1 || axes < 2 || axes > 6 || points > 1000000) {
        throw const XcfFormatException('Invalid path stroke geometry');
      }
      input.require(length * (axes + 1) * 4);
      try {
        result.add(
          XcfStroke(
            closed: closed != 0,
            axes: axes,
            points: [
              for (int p = 0; p < length; p++) XcfControlPoint(type: input.u32(), coordinates: [for (int a = 0; a < axes; a++) input.f32()]),
            ],
          ),
        );
      } on ArgumentError {
        throw const XcfFormatException('Invalid path control points');
      }
    }
    return List.unmodifiable(result);
  }

  /// Rejects unexplained trailing bytes rather than discarding them on edits.
  void finish() {
    if (input.offset != input.end) {
      throw const XcfFormatException('Trailing path data');
    }
  }
}
