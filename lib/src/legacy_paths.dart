part of 'package:xcfkit/src/paths.dart';

/// Reads old path envelopes without depending on their editor-only state byte.
List<XcfPath> _compatibilityPaths(XcfProperty property) {
  final _PathReader reader = _PathReader(XcfReader(property.data));
  final XcfReader input = reader.input;
  final int selected = input.u32();
  final int count = input.u32();
  if (count > 10000) {
    throw const XcfFormatException('Too many compatibility paths');
  }
  final List<XcfPath> paths = [];
  for (int p = 0; p < count; p++) {
    final String name = input.string(1024 * 1024);
    final int linked = input.u32();
    input.u8(); // Obsolete GIMP 1.x editor state, not geometric information.
    final int closed = input.u32();
    final int length = input.u32();
    final int version = input.u32();
    if (version < 1 || version > 3) {
      throw XcfUnsupportedException('Unsupported compatibility path version $version');
    }
    if (version >= 2 && input.u32() != 1) {
      throw const XcfUnsupportedException('Unsupported compatibility path type');
    }
    final int? tattoo = version == 3 ? input.u32() : null;
    reader.points += length;
    if (closed > 1 || length == 0 || reader.points > 1000000) {
      throw const XcfFormatException('Invalid compatibility path point count');
    }
    input.require(length * 12);
    final List<XcfStroke> strokes = [];
    final List<(int, double, double)> segment = [];
    for (int i = 0; i < length; i++) {
      final int type = input.u32();
      final double x = version == 1 ? input.i32().toDouble() : input.f32();
      final double y = version == 1 ? input.i32().toDouble() : input.f32();
      if (type < 1 || type > 3 || !x.isFinite || !y.isFinite) {
        throw const XcfFormatException('Invalid compatibility path point');
      }
      if (type == 3) {
        strokes.add(_compatibilityStroke(segment, true));
        segment.clear();
      }
      segment.add((type == 3 ? 1 : type, x, y));
    }
    strokes.add(_compatibilityStroke(segment, closed != 0));
    reader.strokeCount += strokes.length;
    if (reader.strokeCount > 100000) {
      throw const XcfFormatException('Too many compatibility strokes');
    }
    paths.add(
      XcfPath(
        name: name,
        strokes: strokes,
        properties: [
          XcfProperty.integer(type: XcfPropertyId.visible, value: 0),
          XcfProperty.integer(type: 9, value: linked),
          if (tattoo != null) XcfProperty.integer(type: XcfPropertyId.tattoo, value: tattoo),
          if (p == selected) XcfProperty(type: 43, data: const []),
        ],
      ),
    );
  }
  reader.finish();
  return List.unmodifiable(paths);
}

/// Rotates a closed stroke's closing handle, or synthesizes an open start handle.
XcfStroke _compatibilityStroke(List<(int, double, double)> points, bool closed) {
  if (points.isEmpty || (points.length + (closed ? 0 : 1)) % 3 != 0) {
    throw const XcfFormatException('Invalid compatibility stroke length');
  }
  for (int i = 0; i < points.length; i++) {
    if (points[i].$1 != (i % 3 == 0 ? 1 : 2)) {
      throw const XcfFormatException('Invalid compatibility anchor ordering');
    }
  }
  final (int, double, double) first = closed ? points.last : points.first;
  return XcfStroke(
    closed: closed,
    points: [
      XcfControlPoint(type: 1, coordinates: [first.$2, first.$3]),
      for (final (int type, double x, double y) in points.take(points.length - (closed ? 1 : 0))) XcfControlPoint(type: type == 1 ? 0 : 1, coordinates: [x, y]),
    ],
  );
}
