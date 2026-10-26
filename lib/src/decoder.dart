part of 'package:xcfkit/src/codec.dart';

/// Stateful budget and cursor owner for a single decode operation.
final class _Decoder {
  /// Original input retained for bounded views and absolute offsets.
  final XcfInput input;

  /// Caller-selected allocation and structure limits.
  final XcfReadOptions options;

  /// Offsets on the current recursion stack, used to detect cycles.
  final Set<int> _active = {};

  /// Layer-to-mask offsets used to resolve floating-selection attachments.
  final Map<int, int> _layerMasks = {};

  /// Recoverable historical-format discrepancies.
  final List<String> warnings = [];

  /// Header version controlling subsequent field layouts.
  int version = 0;

  /// Cumulative sample bytes admitted so far.
  int decodedBytes = 0;

  /// Cumulative opaque metadata bytes admitted so far.
  int metadataBytes = 0;

  /// Number of followed layer, channel, vector, and effect structures.
  int items = 0;

  /// Number of parsed property envelopes.
  int propertyCount = 0;

  /// Image-wide sample encoding after header validation.
  XcfPrecision precision = XcfPrecision.u8Nonlinear;

  /// Image-wide tile compression after property validation.
  XcfCompression compression = XcfCompression.rle;

  /// Creates isolated state for one decoding operation.
  _Decoder(this.input, this.options, {this.lazy = false});

  /// Defers sample reads while validating metadata and tile pointer tables.
  final bool lazy;

  /// Whether file offsets occupy eight bytes.
  bool get wide => version >= 11;

  /// Reads the root tables and validates the reconstructed layer hierarchy.
  XcfDocument read() {
    if (input.length < 14) {
      throw const XcfFormatException('Truncated XCF header');
    }
    if (input.length > options.maxInputBytes || input.length > 0x1fffffffffffff) {
      throw const XcfFormatException('XCF input exceeds the configured limit');
    }
    final XcfReader reader = XcfReader.input(input);
    if (!XcfCodec.matches(reader.range(0, 14))) {
      throw const XcfFormatException('Invalid XCF signature', offset: 0);
    }
    reader.offset = 9;
    final String tag = ascii.decode(reader.take(4), allowInvalid: true);
    if (reader.u8() != 0) {
      throw const XcfFormatException('Invalid XCF header terminator', offset: 13);
    }
    version = tag == 'file'
        ? 0
        : RegExp(r'^v\d{3}$').hasMatch(tag)
        ? int.parse(tag.substring(1))
        : -1;
    if (version < 0) {
      throw const XcfFormatException('Invalid XCF version tag', offset: 9);
    }
    if (version > 26 || version >= 4 && version <= 6) {
      throw XcfUnsupportedException('Unsupported XCF version $version', offset: 9);
    }
    final int width = reader.u32();
    final int height = reader.u32();
    _geometry(width, height);
    final int mode = reader.u32();
    if (mode >= XcfColorMode.values.length) {
      throw XcfUnsupportedException('Unsupported XCF color model $mode');
    }
    precision = version >= 4 ? XcfPrecision.fromCode(reader.u32()) : XcfPrecision.u8Nonlinear;
    if (version < 12 && precision.bytesPerComponent > 1) {
      throw const XcfUnsupportedException('Development XCF uses ambiguous sample endianness');
    }
    if (mode == 2 && precision.bytesPerComponent != 1) {
      throw const XcfFormatException('Indexed XCF requires 8-bit precision');
    }
    final List<XcfProperty> properties = _properties(reader);
    final XcfProperty? compressionProperty = properties.property(XcfPropertyId.compression);
    if (compressionProperty != null) {
      if (compressionProperty.data.length != 1) {
        throw const XcfFormatException('Invalid XCF compression property');
      }
      final int value = compressionProperty.data.single;
      if (value >= XcfCompression.values.length) {
        throw XcfUnsupportedException('Unsupported XCF compression $value');
      }
      compression = XcfCompression.values[value];
    }
    final List<int> layerOffsets = _pointers(reader);
    final List<int> channelOffsets = _pointers(reader);
    final List<int> vectorOffsets = version >= 18 ? _pointers(reader) : const [];
    final List<XcfLayer> layers = [for (final int offset in layerOffsets) _structure(offset, () => _layer(offset))];
    final List<XcfChannel> channels = [for (final int offset in channelOffsets) _structure(offset, () => _channel(offset))];
    final List<XcfVector> vectors = [for (final int offset in vectorOffsets) _structure(offset, () => _vector(offset))];
    for (final XcfLayer layer in layers) {
      if (layer.type.colorMode.index != mode && layer.properties.property(XcfPropertyId.floatingSelection) == null) {
        throw const XcfFormatException('Layer color model differs from the document');
      }
    }
    final XcfDocument document = XcfDocument(
      version: version,
      width: width,
      height: height,
      colorMode: XcfColorMode.values[mode],
      precision: precision,
      compression: compression,
      layers: layers,
      channels: channels,
      properties: properties,
      vectors: vectors,
      floatingSelection: _floatingSelection(layers, layerOffsets, channelOffsets),
      warnings: warnings,
    );
    document.layerTree;
    document.floatingSelection?.validate(document);
    if (document.colorMode == XcfColorMode.indexed && document.palette.isEmpty) {
      throw const XcfFormatException('Indexed XCF is missing its colormap');
    }
    return document;
  }

  /// Resolves the one source pointer into a stable drawable kind and index.
  XcfFloatingSelection? _floatingSelection(List<XcfLayer> layers, List<int> layerOffsets, List<int> channelOffsets) {
    final List<int> indices = [
      for (int i = 0; i < layers.length; i++)
        if (layers[i].properties.property(XcfPropertyId.floatingSelection) != null) i,
    ];
    if (indices.isEmpty) {
      return null;
    }
    if (indices.length != 1) {
      throw const XcfFormatException('Multiple floating selections');
    }
    final int layerIndex = indices.single;
    final XcfReader reader = XcfReader(layers[layerIndex].properties.property(XcfPropertyId.floatingSelection)!.data);
    final int high = wide ? reader.u32() : 0;
    final int low = reader.u32();
    if (high > 0x1fffff) {
      throw const XcfFormatException('Unsafe floating selection pointer');
    }
    final int offset = high * 0x100000000 + low;
    if (offset == 0 || offset >= input.length) {
      throw const XcfFormatException('Floating selection pointer is outside the file');
    }
    final List<XcfFloatingSelection> matches = [
      for (int i = 0; i < layerOffsets.length; i++) ...[
        if (layerOffsets[i] == offset) XcfFloatingSelection(layerIndex: layerIndex, targetKind: XcfDrawableKind.layer, targetIndex: i),
        if (_layerMasks[layerOffsets[i]] == offset) XcfFloatingSelection(layerIndex: layerIndex, targetKind: XcfDrawableKind.layerMask, targetIndex: i),
      ],
      for (int i = 0; i < channelOffsets.length; i++)
        if (channelOffsets[i] == offset) XcfFloatingSelection(layerIndex: layerIndex, targetKind: XcfDrawableKind.channel, targetIndex: i),
    ];
    if (matches.length != 1) {
      throw const XcfFormatException('Unresolved or ambiguous floating selection target');
    }
    return matches.single;
  }

  /// Rejects invalid geometry before multiplying sizes or allocating samples.
  void _geometry(int width, int height) {
    if (width <= 0 || height <= 0 || width > options.maxPixels || height > options.maxPixels ~/ width) {
      throw const XcfFormatException('XCF dimensions exceed the configured limit');
    }
  }

  /// Accounts for nested structures and rejects recursive references.
  T _structure<T>(int offset, T Function() read) {
    if (++items > options.maxItems) {
      throw const XcfFormatException('Too many XCF structures');
    }
    if (_active.length >= options.maxDepth || !_active.add(offset)) {
      throw XcfFormatException('Cyclic or excessively nested XCF structure', offset: offset);
    }
    try {
      return read();
    } finally {
      _active.remove(offset);
    }
  }

  /// Reads a terminated pointer table with a bounded entry count.
  List<int> _pointers(XcfReader reader) {
    final List<int> result = [];
    while (true) {
      final int pointer = reader.pointer(wide);
      if (pointer == 0) {
        return result;
      }
      if (result.length >= options.maxItems) {
        throw XcfFormatException('Too many XCF pointers', offset: reader.offset);
      }
      result.add(pointer);
    }
  }

  /// Admits one metadata payload against the cumulative budget.
  void _metadata(int length) {
    if (length < 0 || length > options.maxMetadataBytes - metadataBytes) {
      throw const XcfFormatException('XCF metadata exceeds the configured limit');
    }
    metadataBytes += length;
  }

  /// Reads properties while correcting documented historical length bugs.
  List<XcfProperty> _properties(XcfReader reader) {
    final List<XcfProperty> result = [];
    while (true) {
      final int type = reader.u32();
      final int declared = reader.u32();
      if (type == 0) {
        if (declared != 0) {
          throw XcfFormatException('Nonempty XCF property terminator', offset: reader.offset - 8);
        }
        return result;
      }
      if (++propertyCount > options.maxProperties) {
        throw const XcfFormatException('Too many XCF properties');
      }
      final int start = reader.offset;
      if (type == XcfPropertyId.colormap) {
        final int colors = reader.u32();
        if (colors > 256) {
          throw XcfFormatException('XCF colormap exceeds 256 entries', offset: start);
        }
        reader.take(colors * 3);
      } else if (type == XcfPropertyId.userUnit) {
        reader.take(8);
        for (int i = 0; i < (version >= 21 ? 3 : 5); i++) {
          reader.string(options.maxStringBytes);
        }
      } else if (type == XcfPropertyId.linkLayer) {
        // GIMP 3.2 undercounts nonempty paths by their four-byte string prefix.
        if (declared > options.maxMetadataBytes - metadataBytes) {
          throw const XcfFormatException('XCF property exceeds the configured limit');
        }
        reader.u32();
        final String source = reader.string(options.maxStringBytes);
        reader.take(8);
        final int known = reader.offset - start;
        if (declared >= known) {
          // Keep future suffix fields opaque, as for other property payloads.
          reader.take(declared - known);
        } else if (source.isEmpty || declared != known - 4) {
          throw XcfFormatException('Invalid linked-layer property length', offset: start);
        }
      } else {
        if (declared > options.maxMetadataBytes - metadataBytes) {
          throw const XcfFormatException('XCF property exceeds the configured limit');
        }
        reader.take(declared);
      }
      final int actual = reader.offset - start;
      _metadata(actual);
      if (actual != declared) {
        warnings.add('Corrected length of property $type at ${start - 8}: $declared to $actual');
      }
      final XcfProperty property = XcfProperty(type: type, data: reader.range(start, reader.offset - start));
      _validateProperty(property, wide: wide);
      result.add(property);
    }
  }

  /// Reads a layer and follows its raster, mask, and effect references.
  XcfLayer _layer(int offset) {
    final XcfReader reader = XcfReader.input(input, offset: offset);
    final int width = reader.u32();
    final int height = reader.u32();
    _geometry(width, height);
    final int type = reader.u32();
    if (type >= XcfLayerType.values.length) {
      throw XcfUnsupportedException('Unsupported XCF layer type $type', offset: offset);
    }
    final String name = reader.string(options.maxStringBytes);
    final List<XcfProperty> properties = _properties(reader);
    final int rasterOffset = reader.pointer(wide);
    final int maskOffset = reader.pointer(wide);
    _layerMasks[offset] = maskOffset;
    final List<int> effectOffsets = version >= 20 ? _pointers(reader) : const [];
    final XcfLayerType layout = XcfLayerType.values[type];
    if (rasterOffset == 0 && properties.property(XcfPropertyId.groupItem) == null) {
      throw XcfFormatException('Raster layer has no pixel hierarchy', offset: offset);
    }
    final XcfRaster? raster = rasterOffset == 0 ? null : _raster(rasterOffset, width, height, layout.components * precision.bytesPerComponent);
    final XcfChannel? mask = maskOffset == 0 ? null : _structure(maskOffset, () => _channel(maskOffset));
    return XcfLayer(
      name: name,
      width: width,
      height: height,
      type: layout,
      raster: raster,
      mask: mask,
      properties: properties,
      effects: [for (final int effect in effectOffsets) _structure(effect, () => _effect(effect))],
    );
  }

  /// Reads channel samples and version-dependent live effects.
  XcfChannel _channel(int offset) {
    final XcfReader reader = XcfReader.input(input, offset: offset);
    final int width = reader.u32();
    final int height = reader.u32();
    _geometry(width, height);
    final String name = reader.string(options.maxStringBytes);
    final List<XcfProperty> properties = _properties(reader);
    final int rasterOffset = reader.pointer(wide);
    final List<int> effects = version >= 26 ? _pointers(reader) : const [];
    if (rasterOffset == 0) {
      throw XcfFormatException('Channel has no pixel hierarchy', offset: offset);
    }
    return XcfChannel(
      name: name,
      raster: _raster(rasterOffset, width, height, precision.bytesPerComponent),
      properties: properties,
      effects: [for (final int effect in effects) _structure(effect, () => _effect(effect))],
    );
  }

  /// Retains GEGL identification, arguments, and optional effect mask.
  XcfEffect _effect(int offset) {
    final XcfReader reader = XcfReader.input(input, offset: offset);
    final String name = reader.string(options.maxStringBytes);
    final String icon = reader.string(options.maxStringBytes);
    final String operation = reader.string(options.maxStringBytes);
    final String operationVersion = version >= 22 ? reader.string(options.maxStringBytes) : '';
    final List<XcfProperty> properties = _properties(reader);
    final int mask = reader.pointer(wide);
    return XcfEffect(name: name, icon: icon, operation: operation, version: operationVersion, properties: properties, mask: mask == 0 ? null : _structure(mask, () => _channel(mask)));
  }

  /// Copies a length-bounded vector record without external pointers.
  XcfVector _vector(int offset) {
    final XcfReader reader = XcfReader.input(input, offset: offset);
    final String name = reader.string(options.maxStringBytes);
    final int length = reader.u32();
    _metadata(length);
    return XcfVector(name: name, payload: reader.take(length));
  }

  /// Reassembles the full-resolution tile grid without altering sample bits.
  XcfRaster _raster(int offset, int width, int height, int stride) {
    final int size = width * height * stride;
    if (!lazy && size > options.maxDecodedBytes - decodedBytes) {
      throw const XcfFormatException('XCF sample data exceeds the configured limit');
    }
    decodedBytes += size;
    final XcfReader hierarchy = XcfReader.input(input, offset: offset);
    if (hierarchy.u32() != width || hierarchy.u32() != height || hierarchy.u32() != stride) {
      throw XcfFormatException('Inconsistent XCF pixel hierarchy', offset: offset);
    }
    final int levelOffset = hierarchy.pointer(wide);
    if (levelOffset == 0) {
      throw XcfFormatException('Missing XCF full-resolution level', offset: offset);
    }
    final XcfReader level = XcfReader.input(input, offset: levelOffset);
    if (level.u32() != width || level.u32() != height) {
      throw XcfFormatException('Inconsistent XCF level dimensions', offset: levelOffset);
    }
    final int columns = (width + 63) ~/ 64;
    final int rows = (height + 63) ~/ 64;
    final int firstTile = level.pointer(wide);
    // GIMP also accepts an entirely empty level represented by just one zero.
    if (firstTile == 0) {
      return lazy
          ? XcfRaster.tiled(
              width: width,
              height: height,
              bytesPerPixel: stride,
              maxReadBytes: options.maxDecodedBytes,
              readTile: (column, row) => Uint8List((width - column * 64).clamp(0, 64) * (height - row * 64).clamp(0, 64) * stride),
            )
          : XcfRaster(width: width, height: height, bytesPerPixel: stride, bytes: Uint8List(size));
    }
    // Account for retained tile indices independently of decoded sample bytes.
    _metadata(columns * rows * 8);
    level.require(columns * rows * (wide ? 8 : 4));
    final List<int> offsets = [firstTile, for (int i = 1; i < columns * rows; i++) level.pointer(wide)];
    if (level.pointer(wide) != 0 || offsets.any((value) => value == 0)) {
      throw const XcfFormatException('Invalid XCF tile table');
    }
    for (int i = 0; i < offsets.length; i++) {
      final int next = i + 1 < offsets.length ? offsets[i + 1] : input.length;
      if (next <= offsets[i]) {
        throw XcfFormatException('XCF tile pointers are not increasing', offset: offsets[i]);
      }
    }
    final XcfRaster tiled = XcfRaster.tiled(
      width: width,
      height: height,
      bytesPerPixel: stride,
      maxReadBytes: options.maxDecodedBytes,
      readTile: (column, row) {
        final int index = row * columns + column;
        final int tileWidth = (width - column * 64).clamp(0, 64);
        final int tileHeight = (height - row * 64).clamp(0, 64);
        final int tileSize = tileWidth * tileHeight * stride;
        final int next = index + 1 < offsets.length ? offsets[index + 1] : input.length;
        final int end = (offsets[index] + tileSize * 2 + 1024).clamp(0, next);
        // One bounded read also avoids byte-by-byte I/O during RLE expansion.
        final XcfReader tileReader = XcfReader(XcfReader.input(input).range(offsets[index], end - offsets[index]));
        return decodeXcfTile(tileReader, tileWidth * tileHeight, stride, compression);
      },
    );
    return lazy ? tiled : XcfRaster(width: width, height: height, bytesPerPixel: stride, bytes: tiled.bytes);
  }
}
