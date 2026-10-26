import 'package:xcfkit/src/binary.dart';
import 'package:xcfkit/src/exception.dart';
import 'package:xcfkit/src/model.dart';
import 'package:xcfkit/src/property.dart';
import 'package:xcfkit/src/text.dart' show XcfConfiguration;

/// A document guide, including off-canvas positions and unknown orientations.
final class XcfGuide {
  /// Signed image coordinate.
  final int position;

  /// XCF direction: horizontal=1, vertical=2.
  final int orientation;

  /// Creates a guide without clamping it to the canvas.
  XcfGuide({required this.position, required this.orientation}) {
    if (position < -0x80000000 || position > 0x7fffffff || orientation < 0 || orientation > 255) {
      throw ArgumentError('Invalid guide');
    }
  }
}

/// Color sampling marker, retaining future sampling modes and reserved words.
final class XcfSamplePoint {
  /// Horizontal image coordinate.
  final int x;

  /// Vertical image coordinate.
  final int y;

  /// GIMP color-pick mode, zero for the native pixel value.
  final int mode;

  /// First reserved word, preserved rather than reset during edits.
  final int reserved1;

  /// Second reserved word.
  final int reserved2;

  /// Creates a sampling marker without executing color conversion.
  XcfSamplePoint({required this.x, required this.y, this.mode = 0, this.reserved1 = 0, this.reserved2 = 0}) {
    if ([x, y].any((value) => value < -0x80000000 || value > 0x7fffffff) || [mode, reserved1, reserved2].any((value) => value < 0 || value > 0xffffffff)) {
      throw ArgumentError('Invalid sample point');
    }
  }
}

/// Independent horizontal and vertical print resolution in pixels per inch.
final class XcfResolution {
  /// Horizontal pixels per inch.
  final double x;

  /// Vertical pixels per inch.
  final double y;

  /// Creates a positive finite float32 resolution.
  XcfResolution(this.x, this.y) {
    if ([x, y].any((value) => !value.isFinite || value <= 0 || value > 3.4028234663852886e38)) {
      throw ArgumentError('Invalid image resolution');
    }
  }
}

/// Custom physical unit, including pre-XCF-21 singular and plural labels.
final class XcfUserUnit {
  /// Number of these units per inch.
  final double factor;

  /// Display precision requested by GIMP.
  final int digits;

  /// Unit name or legacy identifier.
  final String name;

  /// Unit symbol.
  final String symbol;

  /// Abbreviated name.
  final String abbreviation;

  /// Historical singular label, absent in XCF 21 and later.
  final String? singular;

  /// Historical plural label, absent in XCF 21 and later.
  final String? plural;

  /// Creates a unit definition without converting coordinates.
  XcfUserUnit({required this.factor, required this.digits, required this.name, required this.symbol, required this.abbreviation, this.singular, this.plural}) {
    if (!factor.isFinite ||
        factor <= 0 ||
        factor > 3.4028234663852886e38 ||
        digits < 0 ||
        digits > 0xffffffff ||
        [name, symbol, abbreviation, ?singular, ?plural].any((value) => value.contains('\u0000'))) {
      throw ArgumentError('Invalid custom unit');
    }
  }

  /// Reads the version-dependent string count and rejects unrecognized suffixes.
  factory XcfUserUnit.fromProperty(XcfProperty property, {required int version}) {
    if (property.type != XcfPropertyId.userUnit) {
      throw ArgumentError('Not a custom-unit property');
    }
    final XcfReader reader = XcfReader(property.data);
    final double factor = reader.f32();
    final int digits = reader.u32();
    final List<String> names = [for (int i = 0; i < (version >= 21 ? 3 : 5); i++) reader.string(1024 * 1024)];
    if (reader.offset != reader.end) {
      throw const XcfFormatException('Custom-unit layout does not match the XCF version');
    }
    try {
      return XcfUserUnit(factor: factor, digits: digits, name: names[0], symbol: names[1], abbreviation: names[2], singular: version < 21 ? names[3] : null, plural: version < 21 ? names[4] : null);
    } on ArgumentError {
      throw const XcfFormatException('Invalid custom-unit values');
    }
  }

  /// Serializes labels for a selected XCF version, filling legacy labels by name.
  XcfProperty toProperty({required int version}) {
    final XcfWriter writer = XcfWriter(8 * 1024 * 1024)
      ..f32(factor)
      ..u32(digits)
      ..string(name)
      ..string(symbol)
      ..string(abbreviation);
    if (version < 21) {
      writer
        ..string(singular ?? name)
        ..string(plural ?? name);
    }
    return XcfProperty(type: XcfPropertyId.userUnit, data: writer.finish());
  }
}

/// Typed document metadata with raw property preservation for unrelated fields.
extension XcfDocumentMetadata on XcfDocument {
  /// Guides in source order; unknown directions are retained numerically.
  List<XcfGuide> get guides {
    final XcfProperty? property = properties.property(XcfPropertyId.guides);
    if (property == null) {
      return const [];
    }
    if (property.data.length % 5 != 0) {
      throw const XcfFormatException('Invalid guide payload');
    }
    final XcfReader reader = XcfReader(property.data);
    return List.unmodifiable([for (; reader.offset < reader.end;) XcfGuide(position: reader.i32(), orientation: reader.u8())]);
  }

  /// Replaces guides without silently upgrading the selected format version.
  XcfDocument withGuides(List<XcfGuide> values) {
    final XcfWriter writer = XcfWriter(values.length * 5);
    for (final XcfGuide value in values) {
      writer
        ..u32(value.position)
        ..u8(value.orientation);
    }
    return copyWith(
      properties: properties.replacing(XcfProperty(type: XcfPropertyId.guides, data: writer.finish())),
    );
  }

  /// Sampling markers; modern properties take precedence over legacy records.
  List<XcfSamplePoint> get samplePoints {
    final XcfProperty? property = properties.property(XcfPropertyId.samplePoints) ?? properties.property(XcfPropertyId.oldSamplePoints);
    if (property == null) {
      return const [];
    }
    final bool modern = property.type == XcfPropertyId.samplePoints;
    if (property.data.length % (modern ? 20 : 8) != 0) {
      throw const XcfFormatException('Invalid sample-point payload');
    }
    final XcfReader reader = XcfReader(property.data);
    return List.unmodifiable([
      for (; reader.offset < reader.end;) XcfSamplePoint(x: reader.i32(), y: reader.i32(), mode: modern ? reader.u32() : 0, reserved1: modern ? reader.u32() : 0, reserved2: modern ? reader.u32() : 0),
    ]);
  }

  /// Writes modern sample points, or legacy pairs with an explicit loss check.
  XcfDocument withSamplePoints(List<XcfSamplePoint> values, {bool legacy = false}) {
    final XcfWriter writer = XcfWriter(values.length * (legacy ? 8 : 20));
    for (final XcfSamplePoint value in values) {
      if (legacy && (value.mode != 0 || value.reserved1 != 0 || value.reserved2 != 0)) {
        throw ArgumentError('Legacy sample points cannot retain modes or reserved words');
      }
      writer
        ..u32(value.x)
        ..u32(value.y);
      if (!legacy) {
        writer
          ..u32(value.mode)
          ..u32(value.reserved1)
          ..u32(value.reserved2);
      }
    }
    return copyWith(
      properties: [
        ...properties.where((property) => property.type != XcfPropertyId.samplePoints && property.type != XcfPropertyId.oldSamplePoints),
        XcfProperty(type: legacy ? XcfPropertyId.oldSamplePoints : XcfPropertyId.samplePoints, data: writer.finish()),
      ],
    );
  }

  /// Saved print resolution, or null when the property is absent.
  XcfResolution? get resolution {
    final XcfProperty? property = properties.property(XcfPropertyId.resolution);
    if (property == null) {
      return null;
    }
    final XcfReader reader = XcfReader(property.data);
    final double x = reader.f32();
    final double y = reader.f32();
    if (reader.offset != reader.end) {
      throw const XcfFormatException('Invalid resolution payload');
    }
    try {
      return XcfResolution(x, y);
    } on ArgumentError {
      throw const XcfFormatException('Invalid resolution values');
    }
  }

  /// Replaces horizontal and vertical resolution.
  XcfDocument withResolution(XcfResolution value) => copyWith(
    properties: properties.replacing(
      XcfProperty(
        type: XcfPropertyId.resolution,
        data:
            (XcfWriter(8)
                  ..f32(value.x)
                  ..f32(value.y))
                .finish(),
      ),
    ),
  );

  /// Built-in numeric unit identifier; custom units are exposed separately.
  int? get unitId => properties.property(XcfPropertyId.unit)?.integer;

  /// Custom unit with a layout determined by this document's version.
  XcfUserUnit? get userUnit {
    final XcfProperty? property = properties.property(XcfPropertyId.userUnit);
    return property == null ? null : XcfUserUnit.fromProperty(property, version: version);
  }

  /// Sets a built-in unit and removes any custom-unit definition.
  XcfDocument withUnitId(int value) {
    if (value < 0 || value > 0xffffffff) {
      throw ArgumentError.value(value, 'value');
    }
    return copyWith(
      properties: properties.where((property) => property.type != XcfPropertyId.userUnit).toList().replacing(XcfProperty.integer(type: XcfPropertyId.unit, value: value)),
    );
  }

  /// Sets a custom unit using this document's format version.
  XcfDocument withUserUnit(XcfUserUnit value) => copyWith(properties: properties.where((property) => property.type != XcfPropertyId.unit).toList().replacing(value.toProperty(version: version)));

  /// Reads a named configuration parasite, for example `gimp-image-grid`.
  XcfConfiguration? configuration(String name) {
    final XcfParasite? value = properties.parasites.where((parasite) => parasite.name == name).lastOrNull;
    return value == null ? null : XcfConfiguration.fromParasite(value);
  }

  /// Replaces a configuration while retaining its parasite flags and terminator.
  XcfDocument withConfiguration(String name, XcfConfiguration value) {
    final List<XcfParasite> parasites = properties.parasites;
    final XcfParasite original = parasites.where((parasite) => parasite.name == name).lastOrNull ?? XcfParasite(name: name, data: [0]);
    return copyWith(
      properties: properties.replacing(
        XcfParasite.toProperty([
          ...parasites.where((parasite) => parasite.name != name),
          value.updateParasite(original),
        ]),
      ),
    );
  }
}
