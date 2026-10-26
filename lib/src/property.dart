import 'dart:typed_data';

import 'package:xcfkit/src/binary.dart';
import 'package:xcfkit/src/exception.dart';

/// Frequently used XCF property identifiers; unknown identifiers stay numeric.
abstract final class XcfPropertyId {
  /// Document palette.
  static const int colormap = 1;

  /// Marks the channel storing the active selection.
  static const int selection = 4;

  /// Floating-selection attachment, containing a file pointer.
  static const int floatingSelection = 5;

  /// Integer opacity from 0 through 255.
  static const int opacity = 6;

  /// GIMP layer mode identifier.
  static const int mode = 7;

  /// Visibility flag.
  static const int visible = 8;

  /// Whether the layer mask affects rendering.
  static const int applyMask = 11;

  /// Whether the mask itself is displayed.
  static const int showMask = 13;

  /// Signed horizontal and vertical offsets.
  static const int offsets = 15;

  /// Image-wide tile compression.
  static const int compression = 17;

  /// Document guides with signed positions.
  static const int guides = 18;

  /// Built-in measurement unit.
  static const int unit = 22;

  /// Legacy sample points without a color-pick mode.
  static const int oldSamplePoints = 27;

  /// Modern sample points with mode and reserved fields.
  static const int samplePoints = 39;

  /// Resolution in pixels per inch.
  static const int resolution = 19;

  /// Unique persistent item identifier.
  static const int tattoo = 20;

  /// Named binary metadata records.
  static const int parasites = 21;

  /// Custom measurement unit.
  static const int userUnit = 24;

  /// Compatibility paths using the GIMP 1.x point ordering.
  static const int paths = 23;

  /// Legacy image-wide vector records.
  static const int vectors = 25;

  /// Editable-text flags; text data lives in a parasite.
  static const int textLayerFlags = 26;

  /// Marks a layer group.
  static const int groupItem = 29;

  /// Position in the layer tree.
  static const int itemPath = 30;

  /// Group expansion state.
  static const int groupItemFlags = 31;

  /// Floating-point opacity.
  static const int floatOpacity = 33;

  /// Composite-region policy.
  static const int compositeMode = 35;

  /// Color space used for compositing.
  static const int compositeSpace = 36;

  /// Color space used for blending.
  static const int blendSpace = 37;

  /// One named GEGL argument; multiple records are expected.
  static const int filterArgument = 45;

  /// Vector-layer configuration.
  static const int vectorLayer = 47;

  /// Linked-layer configuration.
  static const int linkLayer = 48;

  /// Layer transformation matrix.
  static const int transform = 49;
}

/// A typed property envelope with its uninterpreted payload preserved.
final class XcfProperty {
  /// Numeric identifier defined by GIMP.
  final int type;

  /// Read-only bytes; properties have no padding.
  final Uint8List data;

  /// Copies a property payload.
  XcfProperty({required this.type, required List<int> data}) : data = Uint8List.fromList(data).asUnmodifiableView() {
    if (type <= 0 || type > 0xffffffff) {
      throw ArgumentError.value(type, 'type');
    }
  }

  /// Creates an unsigned 32-bit property.
  factory XcfProperty.integer({required int type, required int value}) {
    final ByteData data = ByteData(4)..setUint32(0, value);
    return XcfProperty(type: type, data: data.buffer.asUint8List());
  }

  /// Creates a floating-point property.
  factory XcfProperty.floating({required int type, required double value}) {
    final ByteData data = ByteData(4)..setFloat32(0, value);
    return XcfProperty(type: type, data: data.buffer.asUint8List());
  }

  /// Creates signed layer offsets.
  factory XcfProperty.offsets({required int x, required int y}) {
    final ByteData data = ByteData(8)
      ..setInt32(0, x)
      ..setInt32(4, y);
    return XcfProperty(type: XcfPropertyId.offsets, data: data.buffer.asUint8List());
  }

  /// Creates a position in the layer tree.
  factory XcfProperty.itemPath(List<int> indices) {
    final XcfWriter writer = XcfWriter(indices.length * 4);
    for (final int index in indices) {
      if (index < 0 || index > 0xffffffff) {
        throw ArgumentError.value(index, 'indices');
      }
      writer.u32(index);
    }
    return XcfProperty(type: XcfPropertyId.itemPath, data: writer.finish());
  }

  /// Reads an unsigned property value, validating its size.
  int get integer {
    if (data.length != 4) {
      throw XcfFormatException('Property $type requires four bytes');
    }
    return ByteData.sublistView(data).getUint32(0);
  }

  /// Reads a signed property value.
  int get signedInteger {
    if (data.length != 4) {
      throw XcfFormatException('Property $type requires four bytes');
    }
    return ByteData.sublistView(data).getInt32(0);
  }

  /// Reads a floating-point property value.
  double get floating {
    if (data.length != 4) {
      throw XcfFormatException('Property $type requires four bytes');
    }
    return ByteData.sublistView(data).getFloat32(0);
  }
}

/// Accessors which follow GIMP's last-value-wins rule for scalar properties.
extension XcfPropertyAccess on List<XcfProperty> {
  /// Returns the last occurrence of an identifier.
  XcfProperty? property(int type) {
    for (int i = length - 1; i >= 0; i--) {
      if (this[i].type == type) {
        return this[i];
      }
    }
    return null;
  }

  /// Replaces every occurrence of a scalar property with one value.
  List<XcfProperty> replacing(XcfProperty value) => List.unmodifiable([...where((entry) => entry.type != value.type), value]);

  /// Reads named metadata, concatenating property lists and keeping last names.
  List<XcfParasite> get parasites {
    final Map<String, XcfParasite> result = {};
    for (final XcfProperty property in where((value) => value.type == XcfPropertyId.parasites)) {
      final XcfReader reader = XcfReader(property.data);
      while (reader.offset < reader.end) {
        final String name = reader.string(16 * 1024 * 1024);
        final int flags = reader.u32();
        final Uint8List data = reader.take(reader.u32());
        result[name] = XcfParasite(name: name, flags: flags, data: data);
      }
    }
    return List.unmodifiable(result.values);
  }
}

/// Named application metadata, such as an ICC profile or editable text.
final class XcfParasite {
  /// Identifier, for example `icc-profile` or `gimp-text-layer`.
  final String name;

  /// Persistence and undo flags used by GIMP.
  final int flags;

  /// Read-only metadata bytes.
  final Uint8List data;

  /// Copies a named metadata record.
  XcfParasite({required this.name, this.flags = 1, required List<int> data}) : data = Uint8List.fromList(data).asUnmodifiableView();

  /// Encodes records into one property.
  static XcfProperty toProperty(Iterable<XcfParasite> values) {
    final XcfWriter writer = XcfWriter(64 * 1024 * 1024);
    for (final XcfParasite value in values) {
      writer.string(value.name);
      writer.u32(value.flags);
      writer.u32(value.data.length);
      writer.add(value.data);
    }
    return XcfProperty(type: XcfPropertyId.parasites, data: writer.finish());
  }
}
