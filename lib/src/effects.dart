import 'dart:typed_data';

import 'package:xcfkit/src/binary.dart';
import 'package:xcfkit/src/color.dart';
import 'package:xcfkit/src/exception.dart';
import 'package:xcfkit/src/gradient.dart';
import 'package:xcfkit/src/model.dart';
import 'package:xcfkit/src/property.dart';
import 'package:xcfkit/src/text.dart' show XcfConfiguration;

/// A GEGL argument with its original type and bytes retained.
///
/// GIMP stores floating arguments as float32, including GEGL double parameters.
/// Color and gradient metadata is typed; future kinds retain their raw payloads.
final class XcfFilterArgument {
  /// GEGL configuration property name.
  final String name;

  /// XCF argument kind: int=1, bool=2, float=3, string=4, enum=5,
  /// serialized configuration=6, unsigned int=7, color=8, gradient=9.
  final int type;

  /// Argument data after the name and type, copied and read-only.
  final Uint8List data;

  /// Creates a raw argument, including types not interpreted by this library.
  XcfFilterArgument({required this.name, required this.type, required List<int> data}) : data = Uint8List.fromList(data).asUnmodifiableView() {
    if (name.isEmpty || name.contains('\u0000') || type < 0 || type > 0xffffffff) {
      throw ArgumentError('Invalid filter argument name or type');
    }
  }

  /// Creates a signed integer or enum argument.
  factory XcfFilterArgument.integer(String name, int value, {bool isEnum = false}) {
    if (value < -0x80000000 || value > 0x7fffffff) {
      throw ArgumentError.value(value, 'value');
    }
    return XcfFilterArgument(name: name, type: isEnum ? 5 : 1, data: (XcfWriter(4)..u32(value)).finish());
  }

  /// Creates an unsigned integer argument.
  factory XcfFilterArgument.unsigned(String name, int value) {
    if (value < 0 || value > 0xffffffff) {
      throw ArgumentError.value(value, 'value');
    }
    return XcfFilterArgument(name: name, type: 7, data: (XcfWriter(4)..u32(value)).finish());
  }

  /// Creates a boolean argument.
  factory XcfFilterArgument.boolean(String name, bool value) => XcfFilterArgument(name: name, type: 2, data: (XcfWriter(4)..u32(value ? 1 : 0)).finish());

  /// Creates a finite float32 argument.
  factory XcfFilterArgument.floating(String name, double value) {
    if (!value.isFinite || value.abs() > 3.4028234663852886e38) {
      throw ArgumentError.value(value, 'value');
    }
    return XcfFilterArgument(name: name, type: 3, data: (XcfWriter(4)..f32(value)).finish());
  }

  /// Creates a string or serialized GimpConfig argument.
  factory XcfFilterArgument.string(String name, String value, {bool isConfiguration = false}) =>
      XcfFilterArgument(name: name, type: isConfiguration ? 6 : 4, data: (XcfWriter(16 * 1024 * 1024)..string(value)).finish());

  /// Creates a color argument without converting its Babl encoding or profile.
  factory XcfFilterArgument.color(String name, XcfColor? value) {
    final XcfWriter writer = XcfWriter(32 * 1024 * 1024);
    writeXcfColor(writer, value);
    return XcfFilterArgument(name: name, type: 8, data: writer.finish());
  }

  /// Creates an embedded gradient argument, or the legacy empty null value.
  factory XcfFilterArgument.gradient(String name, XcfGradient? value) => XcfFilterArgument(name: name, type: 9, data: value?.encode() ?? const []);

  /// Reads an argument envelope, leaving unknown kinds opaque.
  factory XcfFilterArgument.fromProperty(XcfProperty property) {
    if (property.type != XcfPropertyId.filterArgument) {
      throw ArgumentError('Not a filter argument');
    }
    final XcfReader reader = XcfReader(property.data);
    final String name = reader.string(1024 * 1024);
    final int type = reader.u32();
    if (name.isEmpty || name.contains('\u0000')) {
      throw const XcfFormatException('Invalid filter argument name');
    }
    final XcfFilterArgument result = XcfFilterArgument(name: name, type: type, data: reader.take(reader.end - reader.offset));
    result.value;
    return result;
  }

  /// Scalar, [XcfColor] or [XcfGradient] value; null for null/unknown kinds.
  Object? get value {
    if (type == 9) {
      return XcfGradient.decode(data);
    }
    if (type < 1 || type > 8) {
      return null;
    }
    final XcfReader reader = XcfReader(data);
    final Object? value = switch (type) {
      1 || 5 => reader.i32(),
      2 => reader.u32() != 0,
      3 => reader.f32(),
      4 || 6 => reader.string(16 * 1024 * 1024),
      8 => readXcfColor(reader, allowEmptyNull: true),
      _ => reader.u32(),
    };
    if (reader.offset != reader.end) {
      throw const XcfFormatException('Trailing filter argument data');
    }
    return value;
  }

  /// Structured configuration for kind 6, leaving [value] backward compatible.
  XcfConfiguration? get configuration => type == 6 ? XcfConfiguration.fromSource(value! as String) : null;

  /// Creates a serialized configuration argument from a structured edit.
  factory XcfFilterArgument.configuration(String name, XcfConfiguration value) => XcfFilterArgument.string(name, value.source, isConfiguration: true);

  /// Encodes this named argument into a repeated property record.
  XcfProperty toProperty() {
    value;
    final XcfWriter writer = XcfWriter(64 * 1024 * 1024)
      ..string(name)
      ..u32(type)
      ..add(data);
    return XcfProperty(type: XcfPropertyId.filterArgument, data: writer.finish());
  }
}

/// Named argument access without losing opaque effect properties.
extension XcfEffectArguments on XcfEffect {
  /// Arguments in source order, including unknown types.
  List<XcfFilterArgument> get arguments => List.unmodifiable(properties.where((value) => value.type == XcfPropertyId.filterArgument).map(XcfFilterArgument.fromProperty));

  /// Finds the last argument with this GEGL name.
  XcfFilterArgument? argument(String name) => arguments.where((value) => value.name == name).lastOrNull;

  /// Replaces only this name; other repeated argument properties survive.
  XcfEffect withArgument(XcfFilterArgument argument) => copyWith(
    properties: [
      for (final XcfProperty property in properties)
        if (property.type != XcfPropertyId.filterArgument || XcfFilterArgument.fromProperty(property).name != argument.name) property,
      argument.toProperty(),
    ],
  );
}
