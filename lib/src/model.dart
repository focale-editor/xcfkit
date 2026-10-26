import 'dart:typed_data';

import 'package:xcfkit/src/exception.dart';
import 'package:xcfkit/src/precision.dart';
import 'package:xcfkit/src/property.dart';

/// An XCF image with a flat, top-first layer list and explicit group paths.
final class XcfDocument {
  /// XCF file version, independent of the GIMP application version.
  final int version;

  /// Canvas width in pixels.
  final int width;

  /// Canvas height in pixels.
  final int height;

  /// Image-wide color model.
  final XcfColorMode colorMode;

  /// Component storage and transfer encoding.
  final XcfPrecision precision;

  /// Compression selected when writing tiles.
  final XcfCompression compression;

  /// Top-first depth-first layer records, including groups.
  final List<XcfLayer> layers;

  /// Saved channels and selections.
  final List<XcfChannel> channels;

  /// Image metadata, including opaque properties.
  final List<XcfProperty> properties;

  /// Self-contained vector records used since XCF 18.
  final List<XcfVector> vectors;

  /// Portable attachment of an optional floating-selection layer.
  final XcfFloatingSelection? floatingSelection;

  /// Compatibility observations made during decoding.
  final List<String> warnings;

  /// Creates a document; XCF 13 supports groups and modern sample storage.
  XcfDocument({
    this.version = 13,
    required this.width,
    required this.height,
    this.colorMode = XcfColorMode.rgb,
    this.precision = XcfPrecision.u8Nonlinear,
    this.compression = XcfCompression.rle,
    required List<XcfLayer> layers,
    List<XcfChannel> channels = const [],
    List<XcfProperty> properties = const [],
    List<XcfVector> vectors = const [],
    this.floatingSelection,
    List<String> warnings = const [],
  }) : layers = List.unmodifiable(layers),
       channels = List.unmodifiable(channels),
       properties = List.unmodifiable(properties),
       vectors = List.unmodifiable(vectors),
       warnings = List.unmodifiable(warnings);

  /// Returns a document with replaced layers and optional metadata or encoding.
  XcfDocument copyWith({
    int? version,
    int? width,
    int? height,
    XcfColorMode? colorMode,
    XcfPrecision? precision,
    XcfCompression? compression,
    List<XcfLayer>? layers,
    List<XcfChannel>? channels,
    List<XcfProperty>? properties,
    List<XcfVector>? vectors,
    XcfFloatingSelection? floatingSelection,
    bool removeFloatingSelection = false,
  }) => XcfDocument(
    version: version ?? this.version,
    width: width ?? this.width,
    height: height ?? this.height,
    colorMode: colorMode ?? this.colorMode,
    precision: precision ?? this.precision,
    compression: compression ?? this.compression,
    layers: removeFloatingSelection
        ? (layers ?? this.layers).map((layer) => layer.copyWith(properties: layer.properties.where((property) => property.type != XcfPropertyId.floatingSelection).toList())).toList()
        : layers ?? this.layers,
    channels: channels ?? this.channels,
    properties: properties ?? this.properties,
    vectors: vectors ?? this.vectors,
    floatingSelection: removeFloatingSelection ? null : floatingSelection ?? this.floatingSelection,
    warnings: warnings,
  );

  /// Attached ICC profile, without interpreting or converting its colors.
  Uint8List? get iccProfile => properties.parasites.where((value) => value.name == 'icc-profile').firstOrNull?.data;

  /// RGB palette bytes, with three components per entry.
  Uint8List get palette {
    final Uint8List? data = properties.property(XcfPropertyId.colormap)?.data;
    if (data == null) {
      return Uint8List(0).asUnmodifiableView();
    }
    if (data.length < 4 || ByteData.sublistView(data).getUint32(0) * 3 != data.length - 4) {
      throw const XcfFormatException('Invalid XCF colormap');
    }
    return Uint8List.sublistView(data, 4).asUnmodifiableView();
  }

  /// Reconstructs groups, rejecting missing parents or inconsistent item paths.
  List<XcfLayerNode> get layerTree {
    final List<_NodeBuilder> roots = [];
    final Map<String, _NodeBuilder> byPath = {};
    for (final XcfLayer layer in layers) {
      final List<int> path = layer.itemPath;
      final List<_NodeBuilder> siblings;
      final List<int> actual;
      if (path.length <= 1) {
        siblings = roots;
        actual = [roots.length];
      } else {
        final List<int> parentPath = path.sublist(0, path.length - 1);
        final _NodeBuilder? parent = byPath[parentPath.join('/')];
        if (parent == null || !parent.layer.isGroup) {
          throw const XcfFormatException('Layer group parent is missing');
        }
        siblings = parent.children;
        actual = [...parentPath, siblings.length];
      }
      if (path.isNotEmpty && path.join('/') != actual.join('/')) {
        throw const XcfFormatException('Inconsistent XCF layer item path');
      }
      if (actual.length > 256) {
        throw const XcfFormatException('XCF layer tree is too deep');
      }
      final _NodeBuilder node = _NodeBuilder(layer);
      siblings.add(node);
      byPath[actual.join('/')] = node;
    }
    return List.unmodifiable(roots.map((value) => value.build()));
  }
}

/// Kind of drawable receiving a floating selection.
enum XcfDrawableKind {
  /// An ordinary raster layer.
  layer,

  /// A layer's mask.
  layerMask,

  /// A saved channel or active selection.
  channel,
}

/// Portable attachment of a floating layer, independent of file offsets.
///
/// Update both indices when reordering layers or channels. This stores the
/// attachment only; anchoring requires compositing pixels in the host editor.
final class XcfFloatingSelection {
  /// Floating layer's index in the flat list, possibly inside a group.
  final int layerIndex;

  /// Target drawable category.
  final XcfDrawableKind targetKind;

  /// Index in the document's flat layers or channels list.
  final int targetIndex;

  /// Attaches a layer to an existing drawable; defaults to the first layer.
  const XcfFloatingSelection({this.layerIndex = 0, required this.targetKind, required this.targetIndex});

  /// Validates the association and the floating layer's component layout.
  void validate(XcfDocument document) {
    if (layerIndex < 0 || layerIndex >= document.layers.length || targetIndex < 0) {
      throw const XcfFormatException('Invalid floating selection target');
    }
    final XcfLayer floating = document.layers[layerIndex];
    if (floating.isGroup || floating.mask != null || !floating.type.hasAlpha) {
      throw const XcfFormatException('Invalid floating selection layer');
    }
    if (targetKind == XcfDrawableKind.channel) {
      if (targetIndex >= document.channels.length) {
        throw const XcfFormatException('Missing floating selection channel');
      }
    } else {
      if (targetIndex == layerIndex || targetIndex >= document.layers.length) {
        throw const XcfFormatException('Invalid floating selection layer target');
      }
      final XcfLayer target = document.layers[targetIndex];
      if (targetKind == XcfDrawableKind.layer ? target.isGroup : target.mask == null) {
        throw const XcfFormatException('Missing floating selection drawable');
      }
    }
    final XcfColorMode expected = targetKind == XcfDrawableKind.layer ? document.colorMode : XcfColorMode.grayscale;
    if (floating.type.colorMode != expected) {
      throw const XcfFormatException('Floating selection color model differs from its target');
    }
    for (int i = 0; i < document.layers.length; i++) {
      if (i != layerIndex && document.layers[i].properties.property(XcfPropertyId.floatingSelection) != null) {
        throw const XcfFormatException('Multiple floating selections');
      }
    }
  }
}

/// A rectangular array of interleaved, straight-alpha sample bytes.
final class XcfRaster {
  /// Width in pixels.
  final int width;

  /// Height in pixels.
  final int height;

  /// Byte stride of one pixel, including all its components.
  final int bytesPerPixel;

  /// Owned samples for eager rasters, otherwise null.
  final Uint8List? _bytes;

  /// Callback reading one 64-by-64 edge-clipped tile.
  final Uint8List Function(int column, int row)? _tileReader;

  /// Maximum allocation for any lazy region or complete raster read.
  final int _maxReadBytes;

  /// Copies sample bytes, keeping their original precision and hidden RGB.
  XcfRaster({required this.width, required this.height, required this.bytesPerPixel, required List<int> bytes})
    : _bytes = Uint8List.fromList(bytes).asUnmodifiableView(),
      _tileReader = null,
      _maxReadBytes = bytes.length {
    if (width <= 0 || height <= 0 || bytesPerPixel <= 0 || width * height * bytesPerPixel != bytes.length) {
      throw ArgumentError('Raster geometry does not match its sample bytes');
    }
  }

  /// Supplies tiles on demand without retaining decoded samples.
  ///
  /// The callback must return consistent, tightly packed samples in original XCF
  /// byte order. It is called only for tiles intersecting a requested region.
  XcfRaster.tiled({required this.width, required this.height, required this.bytesPerPixel, required Uint8List Function(int column, int row) readTile, int maxReadBytes = 512 * 1024 * 1024})
    : _bytes = null,
      _tileReader = readTile,
      _maxReadBytes = maxReadBytes {
    if (width <= 0 || height <= 0 || width > 0x7fffffff || height > 0x7fffffff || bytesPerPixel <= 0 || bytesPerPixel > 32 || maxReadBytes < 0) {
      throw ArgumentError('Invalid tiled raster geometry or limit');
    }
  }

  /// Whether samples are read on demand rather than held in this raster.
  bool get isLazy => _tileReader != null;

  /// Read-only packed samples; multi-byte components are big-endian.
  ///
  /// For a lazy raster this materializes the whole raster on each access, subject
  /// to the read limit. Prefer [readRegion] for bounded work and cache explicitly
  /// if the host needs to retain a complete raster.
  Uint8List get bytes => _bytes ?? readRegion(x: 0, y: 0, width: width, height: height).asUnmodifiableView();

  /// Copies an exact, tightly packed rectangle without color conversion.
  Uint8List readRegion({required int x, required int y, required int width, required int height}) {
    if (x < 0 || y < 0 || width <= 0 || height <= 0 || width > this.width - x || height > this.height - y) {
      throw RangeError('Raster region is outside the drawable');
    }
    if (width * height > _maxReadBytes ~/ bytesPerPixel) {
      throw const XcfFormatException('Raster read exceeds the configured limit');
    }
    final Uint8List result = Uint8List(width * height * bytesPerPixel);
    final Uint8List? samples = _bytes;
    if (samples != null) {
      for (int row = 0; row < height; row++) {
        result.setRange(row * width * bytesPerPixel, (row + 1) * width * bytesPerPixel, samples, ((y + row) * this.width + x) * bytesPerPixel);
      }
      return result;
    }
    for (int row = y ~/ 64; row <= (y + height - 1) ~/ 64; row++) {
      for (int column = x ~/ 64; column <= (x + width - 1) ~/ 64; column++) {
        final int tileWidth = (this.width - column * 64).clamp(0, 64);
        final int tileHeight = (this.height - row * 64).clamp(0, 64);
        if (tileWidth * tileHeight * bytesPerPixel > _maxReadBytes) {
          throw const XcfFormatException('Raster tile exceeds the configured limit');
        }
        final Uint8List tile = _tileReader!(column, row);
        if (tile.length != tileWidth * tileHeight * bytesPerPixel) {
          throw const XcfFormatException('Tile provider returned an inconsistent sample count');
        }
        final int left = x.clamp(column * 64, column * 64 + tileWidth);
        final int right = (x + width).clamp(column * 64, column * 64 + tileWidth);
        final int top = y.clamp(row * 64, row * 64 + tileHeight);
        final int bottom = (y + height).clamp(row * 64, row * 64 + tileHeight);
        for (int line = top; line < bottom; line++) {
          final int target = ((line - y) * width + left - x) * bytesPerPixel;
          result.setRange(target, target + (right - left) * bytesPerPixel, tile, ((line - row * 64) * tileWidth + left - column * 64) * bytesPerPixel);
        }
      }
    }
    return result;
  }
}

/// One layer or group; original metadata remains available in [properties].
final class XcfLayer {
  /// Name shown in the layer panel.
  final String name;

  /// Layer width in pixels, including pixels outside the canvas.
  final int width;

  /// Layer height in pixels.
  final int height;

  /// Component layout.
  final XcfLayerType type;

  /// Pixel samples; groups may omit their cached raster.
  final XcfRaster? raster;

  /// Optional layer or group mask.
  final XcfChannel? mask;

  /// Properties in source order.
  final List<XcfProperty> properties;

  /// Non-destructive effects, preserved without running GEGL.
  final List<XcfEffect> effects;

  /// Creates a layer record.
  XcfLayer({
    required this.name,
    required this.width,
    required this.height,
    this.type = XcfLayerType.rgba,
    this.raster,
    this.mask,
    List<XcfProperty> properties = const [],
    List<XcfEffect> effects = const [],
  }) : properties = List.unmodifiable(properties),
       effects = List.unmodifiable(effects);

  /// Creates a conventional RGBA8 layer with explicit position and opacity.
  factory XcfLayer.rgba({required String name, required int width, required int height, required List<int> pixels, int x = 0, int y = 0, bool visible = true, double opacity = 1}) {
    if (!opacity.isFinite || opacity < 0 || opacity > 1) {
      throw ArgumentError.value(opacity, 'opacity');
    }
    return XcfLayer(
      name: name,
      width: width,
      height: height,
      raster: XcfRaster(width: width, height: height, bytesPerPixel: 4, bytes: pixels),
      properties: [
        XcfProperty.offsets(x: x, y: y),
        XcfProperty.integer(type: XcfPropertyId.visible, value: visible ? 1 : 0),
        XcfProperty.integer(type: XcfPropertyId.opacity, value: (opacity * 255).round()),
        XcfProperty.floating(type: XcfPropertyId.floatOpacity, value: opacity),
      ],
    );
  }

  /// Returns a modified record; explicit flags remove a mask or cached raster.
  XcfLayer copyWith({
    String? name,
    int? width,
    int? height,
    XcfLayerType? type,
    XcfRaster? raster,
    bool removeRaster = false,
    XcfChannel? mask,
    bool removeMask = false,
    List<XcfProperty>? properties,
    List<XcfEffect>? effects,
  }) => XcfLayer(
    name: name ?? this.name,
    width: width ?? this.width,
    height: height ?? this.height,
    type: type ?? this.type,
    raster: removeRaster ? null : raster ?? this.raster,
    mask: removeMask ? null : mask ?? this.mask,
    properties: properties ?? this.properties,
    effects: effects ?? this.effects,
  );

  /// Whether the record is a layer group.
  bool get isGroup => properties.property(XcfPropertyId.groupItem) != null;

  /// Whether the layer is visible.
  bool get visible => (properties.property(XcfPropertyId.visible)?.integer ?? 1) != 0;

  /// Overall opacity, preferring the floating-point field when available.
  double get opacity => properties.property(XcfPropertyId.floatOpacity)?.floating ?? (properties.property(XcfPropertyId.opacity)?.integer ?? 255) / 255;

  /// GIMP mode identifier; no Photoshop-mode equivalence is assumed.
  int get mode => properties.property(XcfPropertyId.mode)?.integer ?? 0;

  /// Whether the attached mask should affect rendering.
  bool get applyMask => mask != null && (properties.property(XcfPropertyId.applyMask)?.integer ?? 1) != 0;

  /// Whether GIMP displays the mask instead of the layer.
  bool get showMask => mask != null && (properties.property(XcfPropertyId.showMask)?.integer ?? 0) != 0;

  /// Horizontal canvas offset.
  int get x => _offset(0);

  /// Vertical canvas offset.
  int get y => _offset(4);

  /// Reads one signed coordinate from the validated offsets property.
  int _offset(int offset) {
    final Uint8List? data = properties.property(XcfPropertyId.offsets)?.data;
    if (data == null) {
      return 0;
    }
    if (data.length != 8) {
      throw const XcfFormatException('Invalid layer offsets');
    }
    return ByteData.sublistView(data).getInt32(offset);
  }

  /// Zero-based positions from the root group down to this layer.
  List<int> get itemPath {
    final Uint8List? data = properties.property(XcfPropertyId.itemPath)?.data;
    if (data == null) {
      return const [];
    }
    if (data.length % 4 != 0 || data.length > 1024) {
      throw const XcfFormatException('Invalid XCF item path');
    }
    final ByteData view = ByteData.sublistView(data);
    return List.unmodifiable([for (int i = 0; i < data.length; i += 4) view.getUint32(i)]);
  }
}

/// A saved channel, selection, layer mask, or effect mask.
final class XcfChannel {
  /// Channel name.
  final String name;

  /// Single-component pixel samples.
  final XcfRaster raster;

  /// Channel properties.
  final List<XcfProperty> properties;

  /// Channel effects, supported by XCF 26 and later.
  final List<XcfEffect> effects;

  /// Creates a channel.
  XcfChannel({required this.name, required this.raster, List<XcfProperty> properties = const [], List<XcfEffect> effects = const []})
    : properties = List.unmodifiable(properties),
      effects = List.unmodifiable(effects);

  /// Whether this record is the active selection instead of a saved channel.
  bool get isSelection => properties.property(XcfPropertyId.selection) != null;
}

/// A serialized GEGL effect and its arguments, without a rendering engine.
final class XcfEffect {
  /// User-facing effect name.
  final String name;

  /// Icon identifier.
  final String icon;

  /// GEGL operation identifier.
  final String operation;

  /// GEGL operation version string, present since XCF 22.
  final String version;

  /// Effect properties, including repeated argument records.
  final List<XcfProperty> properties;

  /// Optional effect mask.
  final XcfChannel? mask;

  /// Creates an effect record.
  XcfEffect({required this.name, this.icon = '', required this.operation, this.version = '', List<XcfProperty> properties = const [], this.mask}) : properties = List.unmodifiable(properties);

  /// Replaces effect metadata without executing the operation.
  XcfEffect copyWith({String? name, String? icon, String? operation, String? version, List<XcfProperty>? properties, XcfChannel? mask, bool removeMask = false}) => XcfEffect(
    name: name ?? this.name,
    icon: icon ?? this.icon,
    operation: operation ?? this.operation,
    version: version ?? this.version,
    properties: properties ?? this.properties,
    mask: removeMask ? null : mask ?? this.mask,
  );
}

/// A self-contained modern vector payload, preserved without interpretation.
final class XcfVector {
  /// Path name.
  final String name;

  /// Vector properties, stroke version, and stroke data without file pointers.
  final Uint8List payload;

  /// Copies an opaque vector record.
  XcfVector({required this.name, required List<int> payload}) : payload = Uint8List.fromList(payload).asUnmodifiableView();
}

/// One node of a reconstructed layer tree.
final class XcfLayerNode {
  /// The layer or group represented by this node.
  final XcfLayer layer;

  /// Children in top-first order.
  final List<XcfLayerNode> children;

  /// Creates an immutable layer-tree node.
  XcfLayerNode({required this.layer, List<XcfLayerNode> children = const []}) : children = List.unmodifiable(children);
}

/// Mutable construction state used only while assembling a validated tree.
final class _NodeBuilder {
  /// Layer whose descendants are being assembled.
  final XcfLayer layer;

  /// Children accumulated in source order.
  final List<_NodeBuilder> children = [];

  /// Starts an empty tree node.
  _NodeBuilder(this.layer);

  /// Freezes the bounded subtree into public immutable nodes.
  XcfLayerNode build() => XcfLayerNode(layer: layer, children: children.map((value) => value.build()).toList());
}
