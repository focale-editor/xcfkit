part of 'package:xcfkit/src/codec.dart';

/// Rebuilds all known references instead of retaining source file offsets.
final class _Encoder {
  /// Document whose known file references will be reconstructed.
  final XcfDocument document;

  /// Output limits and optional compression override.
  final XcfWriteOptions options;

  /// Bounded output with relocatable pointer slots.
  late final XcfWriter writer = XcfWriter(options.maxOutputBytes, output: output);

  /// One compression choice used consistently for every tile.
  late final XcfCompression compression = options.compression ?? document.compression;

  /// Pointer slot for the optional floating-selection attachment.
  int? _floatingSlot;

  /// New file offset of the target drawable, once emitted.
  int? _floatingTarget;

  /// Creates a writer for one document.
  _Encoder(this.document, this.options, {this.output});

  /// Optional seekable destination used for progressive output.
  final XcfOutput? output;

  /// Whether this version stores eight-byte pointers.
  bool get wide => document.version >= 11;

  /// Byte width shared by all color and mask components.
  int get componentBytes => document.precision.bytesPerComponent;

  /// Validates feature/version combinations and writes root structure tables.
  void write() {
    final int version = document.version;
    if (version < 0 || version > 26 || version >= 4 && version <= 6) {
      throw XcfUnsupportedException('Cannot write XCF version $version');
    }
    _dimensions(document.width, document.height);
    if (version < 4 && document.precision != XcfPrecision.u8Nonlinear || version < 12 && componentBytes > 1) {
      throw const XcfUnsupportedException('XCF version cannot safely store this precision');
    }
    if (document.colorMode == XcfColorMode.indexed && (componentBytes != 1 || document.palette.isEmpty || document.palette.length > 768 || version == 0)) {
      throw const XcfFormatException('Indexed XCF needs a palette, 8-bit precision, and version 1 or later');
    }
    if (version < 3 && document.layers.any((layer) => layer.isGroup)) {
      throw const XcfUnsupportedException('Layer groups require XCF 3 or later');
    }
    if (version < 8 && compression == XcfCompression.zlib) {
      throw const XcfUnsupportedException('zlib compression requires XCF 8 or later');
    }
    if (version < 18 && document.vectors.isNotEmpty) {
      throw const XcfUnsupportedException('Modern vectors require XCF 18 or later');
    }
    document.layerTree;
    document.floatingSelection?.validate(document);
    writer.add(ascii.encode(version == 0 ? 'gimp xcf file' : 'gimp xcf v${version.toString().padLeft(3, '0')}'));
    writer.u8(0);
    writer.u32(document.width);
    writer.u32(document.height);
    writer.u32(document.colorMode.index);
    if (version >= 4) {
      writer.u32(document.precision.code);
    }
    _properties(document.properties.replacing(XcfProperty(type: XcfPropertyId.compression, data: [compression.index])));
    final List<int> layerSlots = _table(document.layers.length);
    final List<int> channelSlots = _table(document.channels.length);
    final List<int> vectorSlots = version >= 18 ? _table(document.vectors.length) : const [];
    for (int i = 0; i < document.layers.length; i++) {
      writer.patch(layerSlots[i], writer.length, wide);
      _recordTarget(XcfDrawableKind.layer, i);
      _layer(document.layers[i], i);
    }
    for (int i = 0; i < document.channels.length; i++) {
      writer.patch(channelSlots[i], writer.length, wide);
      _recordTarget(XcfDrawableKind.channel, i);
      _channel(document.channels[i], 0);
    }
    for (int i = 0; i < document.vectors.length; i++) {
      final XcfVector vector = document.vectors[i];
      writer.patch(vectorSlots[i], writer.length, wide);
      writer.string(vector.name);
      writer.u32(vector.payload.length);
      writer.add(vector.payload);
    }
    if (_floatingSlot != null) {
      if (_floatingTarget == null) {
        throw const XcfFormatException('Floating selection target was not written');
      }
      writer.patch(_floatingSlot!, _floatingTarget!, wide);
    }
  }

  /// Records the new offset when the requested attachment is encountered.
  void _recordTarget(XcfDrawableKind kind, int index) {
    final XcfFloatingSelection? floating = document.floatingSelection;
    if (floating != null && floating.targetKind == kind && floating.targetIndex == index) {
      _floatingTarget = writer.length;
    }
  }

  /// Rejects dimensions outside GIMP's signed geometry range.
  void _dimensions(int width, int height) {
    if (width <= 0 || height <= 0 || width > 0x7fffffff || height > 0x7fffffff) {
      throw const XcfFormatException('Invalid XCF dimensions');
    }
  }

  /// Reserves a terminated table whose pointers are patched after allocation.
  List<int> _table(int length) {
    final List<int> slots = [for (int i = 0; i < length; i++) writer.slot(wide)];
    writer.slot(wide);
    return slots;
  }

  /// Writes safe property payloads and refuses unresolved source pointers.
  void _properties(List<XcfProperty> properties, {bool floating = false}) {
    if (floating) {
      writer.u32(XcfPropertyId.floatingSelection);
      writer.u32(wide ? 8 : 4);
      _floatingSlot = writer.slot(wide);
    }
    for (final XcfProperty property in properties) {
      if (property.type == XcfPropertyId.floatingSelection) {
        if (floating) {
          continue;
        }
        throw const XcfUnsupportedException('Resolve the floating selection attachment before writing XCF');
      }
      if (property.type > 49) {
        throw XcfUnsupportedException('Cannot safely relocate unknown property ${property.type}');
      }
      if (property.type == XcfPropertyId.vectorLayer && document.version < 24 || (property.type == XcfPropertyId.linkLayer || property.type == XcfPropertyId.transform) && document.version < 25) {
        throw const XcfUnsupportedException('Layer metadata requires a newer XCF version');
      }
      if (property.type == XcfPropertyId.mode && property.integer > 22 && document.version < 9) {
        throw const XcfUnsupportedException('Modern layer modes require XCF 9 or later');
      }
      _validateProperty(property, wide: wide);
      writer.u32(property.type);
      writer.u32(property.data.length);
      writer.add(property.data);
    }
    writer.u32(0);
    writer.u32(0);
  }

  /// Writes a layer and patches references to newly serialized child data.
  void _layer(XcfLayer layer, int index) {
    _dimensions(layer.width, layer.height);
    final bool floating = index == document.floatingSelection?.layerIndex;
    if (layer.type.colorMode != document.colorMode && !floating) {
      throw const XcfFormatException('Layer color model differs from its document');
    }
    if (layer.raster == null && !layer.isGroup) {
      throw const XcfFormatException('Raster layer has no pixels');
    }
    if (document.version < 20 && layer.effects.isNotEmpty) {
      throw const XcfUnsupportedException('Layer effects require XCF 20 or later');
    }
    writer.u32(layer.width);
    writer.u32(layer.height);
    writer.u32(layer.type.index);
    writer.string(layer.name);
    // GIMP constructs the group when it encounters GROUP_ITEM. A pass-through
    // MODE appearing first would be applied to a raster and silently rejected.
    final XcfProperty? group = layer.properties.property(XcfPropertyId.groupItem);
    _properties([?group, ...layer.properties.where((property) => property.type != XcfPropertyId.groupItem)], floating: floating);
    final int rasterSlot = writer.slot(wide);
    final int maskSlot = writer.slot(wide);
    final List<int> effectSlots = document.version >= 20 ? _table(layer.effects.length) : const [];
    final XcfRaster? raster = layer.raster;
    if (raster != null) {
      if (raster.width != layer.width || raster.height != layer.height || raster.bytesPerPixel != layer.type.components * componentBytes) {
        throw const XcfFormatException('Layer raster layout is inconsistent');
      }
      writer.patch(rasterSlot, writer.length, wide);
      _raster(raster);
    }
    final XcfChannel? mask = layer.mask;
    if (mask != null) {
      writer.patch(maskSlot, writer.length, wide);
      _recordTarget(XcfDrawableKind.layerMask, index);
      _channel(mask, 0);
    }
    for (int i = 0; i < layer.effects.length; i++) {
      writer.patch(effectSlots[i], writer.length, wide);
      _effect(layer.effects[i], 0);
    }
  }

  /// Writes a channel and guards effect/mask recursion.
  void _channel(XcfChannel channel, int depth) {
    if (depth > 64) {
      throw const XcfFormatException('XCF effects are too deeply nested');
    }
    final XcfRaster raster = channel.raster;
    _dimensions(raster.width, raster.height);
    if (raster.bytesPerPixel != componentBytes) {
      throw const XcfFormatException('Channel precision differs from its document');
    }
    if (document.version < 26 && channel.effects.isNotEmpty) {
      throw const XcfUnsupportedException('Channel effects require XCF 26 or later');
    }
    writer.u32(raster.width);
    writer.u32(raster.height);
    writer.string(channel.name);
    _properties(channel.properties);
    final int rasterSlot = writer.slot(wide);
    final List<int> effectSlots = document.version >= 26 ? _table(channel.effects.length) : const [];
    writer.patch(rasterSlot, writer.length, wide);
    _raster(raster);
    for (int i = 0; i < channel.effects.length; i++) {
      writer.patch(effectSlots[i], writer.length, wide);
      _effect(channel.effects[i], depth + 1);
    }
  }

  /// Writes GEGL metadata without executing the operation.
  void _effect(XcfEffect effect, int depth) {
    if (depth > 64) {
      throw const XcfFormatException('XCF effects are too deeply nested');
    }
    if (document.version < 22 && effect.version.isNotEmpty) {
      throw const XcfUnsupportedException('Effect version strings require XCF 22 or later');
    }
    writer.string(effect.name);
    writer.string(effect.icon);
    writer.string(effect.operation);
    if (document.version >= 22) {
      writer.string(effect.version);
    }
    _properties(effect.properties);
    final int maskSlot = writer.slot(wide);
    final XcfChannel? mask = effect.mask;
    if (mask != null) {
      writer.patch(maskSlot, writer.length, wide);
      _channel(mask, depth + 1);
    }
  }

  /// Tiles exact samples and emits one full-resolution hierarchy level.
  void _raster(XcfRaster raster) {
    writer.u32(raster.width);
    writer.u32(raster.height);
    writer.u32(raster.bytesPerPixel);
    final int levelSlot = writer.slot(wide);
    writer.slot(wide);
    writer.patch(levelSlot, writer.length, wide);
    writer.u32(raster.width);
    writer.u32(raster.height);
    final int columns = (raster.width + 63) ~/ 64;
    final int rows = (raster.height + 63) ~/ 64;
    final List<int> tiles = _table(columns * rows);
    for (int i = 0; i < tiles.length; i++) {
      writer.patch(tiles[i], writer.length, wide);
      final int x = (i % columns) * 64;
      final int y = (i ~/ columns) * 64;
      final int width = (raster.width - x).clamp(0, 64);
      final int height = (raster.height - y).clamp(0, 64);
      final Uint8List tile = raster.readRegion(x: x, y: y, width: width, height: height);
      writer.add(encodeXcfTile(tile, raster.bytesPerPixel, compression));
    }
  }
}
