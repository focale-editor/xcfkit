import 'package:xcfkit/src/exception.dart';
import 'package:xcfkit/src/text.dart';

/// One serialized curve control point, including inactive legacy points.
final class XcfCurvePoint {
  /// Normalized input coordinate; -1 represents an inactive legacy point.
  final double x;

  /// Normalized output coordinate; -1 represents an inactive legacy point.
  final double y;

  /// GIMP point type token, usually `smooth` or `corner`.
  final String type;

  /// Creates curve metadata without evaluating interpolation.
  XcfCurvePoint(this.x, this.y, {this.type = 'smooth'}) {
    if ([x, y].any((value) => !value.isFinite || value < -1 || value > 1)) {
      throw ArgumentError('Invalid curve coordinates');
    }
    XcfConfigValue.symbol(type);
  }
}

/// Typed GimpCurve configuration with control points and its saved sample table.
///
/// XcfKit does not interpolate curves. Editing control points requires a sample
/// table supplied by the host, so serialized editable data and samples agree.
final class XcfCurve {
  /// Original configuration, including fields unknown to this library.
  final XcfConfiguration configuration;

  /// Wraps and validates the known fields of a serialized curve.
  XcfCurve(this.configuration) {
    type;
    points;
    samples;
  }

  /// GIMP interpolation mode token, normally `smooth` or `free`.
  String get type {
    final List<XcfConfigValue>? values = configuration.field('curve-type');
    if (values == null || values.length != 1 || values.single.isList || values.single.isString) {
      throw const XcfFormatException('Invalid curve type');
    }
    return values.single.source;
  }

  /// Ordered editable points, including any -1 inactive entries.
  List<XcfCurvePoint> get points {
    final List<XcfConfigValue> values = _array('points');
    final List<XcfConfigValue>? types = configuration.field('point-types') == null ? null : _array('point-types');
    if (values.length.isOdd || types != null && types.length != values.length ~/ 2) {
      throw const XcfFormatException('Curve point arrays have inconsistent lengths');
    }
    try {
      return List.unmodifiable([
        for (int i = 0; i < values.length; i += 2) XcfCurvePoint(_number(values[i]), _number(values[i + 1]), type: types?[i ~/ 2].source ?? 'smooth'),
      ]);
    } on ArgumentError {
      throw const XcfFormatException('Invalid curve point');
    }
  }

  /// Saved output lookup values, without interpolation or color conversion.
  List<double> get samples {
    final List<double> result = _array('samples').map(_number).toList();
    final List<XcfConfigValue>? count = configuration.field('n-samples');
    if (result.length < 2 || count == null || count.length != 1 || count.single.number != result.length || result.any((value) => value < 0 || value > 1)) {
      throw const XcfFormatException('Invalid curve sample table');
    }
    return List.unmodifiable(result);
  }

  /// Replaces points and their caller-computed table, retaining unknown fields.
  XcfCurve withPoints(List<XcfCurvePoint> points, {required List<double> samples, String? type}) {
    if (points.length > 10000 || samples.length < 2 || samples.length > 65536 || samples.any((value) => !value.isFinite || value < 0 || value > 1)) {
      throw ArgumentError('Invalid curve points or samples');
    }
    XcfConfiguration updated = configuration
        .withField('points', [
          XcfConfigValue.number(points.length * 2),
          for (final XcfCurvePoint point in points) ...[XcfConfigValue.number(point.x), XcfConfigValue.number(point.y)],
        ])
        .withField('point-types', [XcfConfigValue.number(points.length), for (final XcfCurvePoint point in points) XcfConfigValue.symbol(point.type)])
        .withField('n-samples', [XcfConfigValue.number(samples.length)])
        .withField('samples', [XcfConfigValue.number(samples.length), ...samples.map(XcfConfigValue.number)]);
    if (configuration.field('n-points') != null) {
      updated = updated.withField('n-points', [XcfConfigValue.number(points.length)]);
    }
    if (type != null) {
      updated = updated.withField('curve-type', [XcfConfigValue.symbol(type)]);
    }
    return XcfCurve(updated);
  }

  /// Reads a count-prefixed value array with an explicit count ceiling.
  List<XcfConfigValue> _array(String name) {
    final List<XcfConfigValue>? values = configuration.field(name);
    if (values == null || values.isEmpty || values.first.number != values.length - 1 || values.length > 65537) {
      throw XcfFormatException('Invalid curve $name array');
    }
    return values.sublist(1);
  }

  /// Requires a finite numeric token.
  static double _number(XcfConfigValue value) {
    final num? number = value.number;
    if (number == null) {
      throw const XcfFormatException('Expected a numeric curve value');
    }
    return number.toDouble();
  }
}
