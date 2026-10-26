part of 'package:xcfkit/src/codec.dart';

/// Severity of a static write diagnostic.
enum XcfDiagnosticSeverity {
  /// Writing would lose information, fail validation, or use an unsafe layout.
  error,

  /// Data is retained but may need attention from the host application.
  warning,
}

/// One actionable preflight finding with a stable code and document location.
final class XcfWriteDiagnostic {
  /// Machine-readable category; applications should not parse the message.
  final String code;

  /// Location such as `layers[2].properties[0]`.
  final String path;

  /// Whether this finding blocks a compatible write.
  final XcfDiagnosticSeverity severity;

  /// Human-readable explanation, without a proposed destructive fallback.
  final String message;

  /// Creates one immutable finding.
  const XcfWriteDiagnostic({required this.code, required this.path, required this.severity, required this.message});
}

/// Static compatibility report produced without decoding or compressing pixels.
///
/// A successful report does not validate deferred compressed tiles, resource
/// availability, output I/O, or the exact final compressed size. Those can still
/// fail during writing. Rendering support belongs to the host adapter.
final class XcfWriteReport {
  /// Lowest supported version required by the known features in this document.
  ///
  /// This cannot account for undocumented future fields or exact compressed
  /// pointer positions; a large-output warning recommends wide offsets.
  final int minimumVersion;

  /// Total uncompressed sample bytes, counted without loading lazy rasters.
  final int sampleBytes;

  /// Static findings in deterministic document order.
  final List<XcfWriteDiagnostic> diagnostics;

  /// Captures a completed static inspection.
  XcfWriteReport._(this.minimumVersion, this.sampleBytes, List<XcfWriteDiagnostic> diagnostics) : diagnostics = List.unmodifiable(diagnostics);

  /// Whether no known blocking issue was found by static inspection.
  bool get canWrite => diagnostics.every((value) => value.severity != XcfDiagnosticSeverity.error);
}

/// Visitor collecting independent problems rather than stopping at the first.
final class _Preflight {
  /// Document being inspected.
  final XcfDocument document;

  /// Selected compression and output ceiling.
  final XcfWriteOptions options;

  /// Findings gathered so far.
  final List<XcfWriteDiagnostic> issues = [];

  /// Minimum known feature version.
  int minimumVersion = 0;

  /// Uncompressed sample total.
  int sampleBytes = 0;

  /// Serialized metadata bytes, used as a conservative lower size bound.
  int metadataBytes = 0;

  /// Creates a read-only inspection context.
  _Preflight(this.document, this.options);

  /// Adds a diagnostic with a stable category and location.
  void _issue(String code, String path, String message, {bool warning = false}) =>
      issues.add(XcfWriteDiagnostic(code: code, path: path, message: message, severity: warning ? XcfDiagnosticSeverity.warning : XcfDiagnosticSeverity.error));

  /// Registers a version requirement, reporting it at its source location.
  void _require(int version, String path, String feature) {
    if (version > minimumVersion) {
      minimumVersion = version;
    }
    if (document.version < version) {
      _issue('version.required', path, '$feature requires XCF $version or later');
    }
  }

  /// Converts validation failures into diagnostics while continuing inspection.
  void _check(String code, String path, void Function() inspect) {
    try {
      inspect();
    } on FormatException catch (error) {
      _issue(code, path, error.message);
    } on ArgumentError catch (error) {
      _issue(code, path, error.toString());
    }
  }

  /// Checks signed geometry before it reaches the binary writer.
  void _dimensions(int width, int height, String path) {
    if (width <= 0 || height <= 0 || width > 0x7fffffff || height > 0x7fffffff) {
      _issue('geometry.invalid', path, 'Dimensions must be positive signed 32-bit values');
    }
  }

  /// Checks an encoded UTF-8 field without allocating an encoded string.
  void _string(String value, String path) {
    if (value.contains('\u0000')) {
      _issue('string.embeddedNull', path, 'XCF strings cannot contain an embedded null');
    }
  }

  /// Checks property payloads and known version-dependent metadata layouts.
  void _properties(List<XcfProperty> properties, String path, {bool floating = false}) {
    for (int i = 0; i < properties.length; i++) {
      final XcfProperty property = properties[i];
      final String location = '$path[$i]';
      metadataBytes += 8 + property.data.length;
      _check('property.invalid', location, () => _validateProperty(property, wide: document.version >= 11));
      if (property.type > 49) {
        _issue('property.unknownRelocation', location, 'Unknown property ${property.type} may contain file pointers and cannot safely be relocated');
      }
      if (property.type == XcfPropertyId.floatingSelection && !floating) {
        _issue('floating.unresolved', location, 'Resolve the floating-selection attachment before writing');
      }
      if (property.type == XcfPropertyId.vectorLayer) {
        _require(24, location, 'Vector layers');
        _check('vector.invalid', location, () => XcfVectorLayer.fromProperty(property).resolvePath(document));
      }
      if (property.type == XcfPropertyId.linkLayer || property.type == XcfPropertyId.transform) {
        _require(25, location, 'Linked-layer metadata');
      }
      if (property.type == XcfPropertyId.mode && property.data.length == 4 && property.integer > 22) {
        _require(9, location, 'Modern layer modes');
      }
      if (property.type == 40 || property.type == 41) {
        _require(16, location, 'Stored item sets');
      }
      if (property.type == 42 && property.data.length == 4 && property.integer != 0) {
        _require(17, location, 'Visibility locks');
      }
      if ((property.type == XcfPropertyId.blendSpace || property.type == XcfPropertyId.compositeSpace) && property.data.length == 4 && property.signedInteger.abs() == 4) {
        _require(23, location, 'Perceptual RGB blend/composite space');
      }
      if (property.type == XcfPropertyId.mode && property.data.length == 4 && property.integer >= 19 && property.integer <= 22) {
        _require(2, location, 'Extended legacy layer modes');
      }
      if (property.type == XcfPropertyId.vectors) {
        _require(2, location, 'Legacy vector records');
      }
      if (property.type == XcfPropertyId.userUnit) {
        _check('unit.layout', location, () => XcfUserUnit.fromProperty(property, version: document.version));
      }
      if (property.type == XcfPropertyId.filterArgument) {
        _check('effect.argument', location, () {
          final XcfFilterArgument argument = XcfFilterArgument.fromProperty(property);
          if (argument.type == 6) {
            argument.configuration;
          }
          if (argument.type == 0 || argument.type > 9) {
            _issue('effect.opaqueArgument', location, 'Unknown argument kind ${argument.type} is preserved as bytes', warning: true);
          }
        });
      }
      if (property.type == XcfPropertyId.parasites) {
        _check('parasite.invalid', location, () => [property].parasites);
      }
    }
  }

  /// Accounts for raster geometry without reading any sample bytes.
  void _raster(XcfRaster raster, String path) {
    _dimensions(raster.width, raster.height, path);
    sampleBytes += raster.width * raster.height * raster.bytesPerPixel;
  }

  /// Visits a channel and its effects, including nested masks.
  void _channel(XcfChannel channel, String path, int depth) {
    if (depth > 64) {
      _issue('structure.depth', path, 'Effects and masks exceed the writer nesting limit');
      return;
    }
    _string(channel.name, '$path.name');
    _properties(channel.properties, '$path.properties');
    _raster(channel.raster, '$path.raster');
    if (channel.raster.bytesPerPixel != document.precision.bytesPerComponent) {
      _issue('raster.layout', path, 'Channel sample stride differs from document precision');
    }
    if (channel.effects.isNotEmpty) {
      _require(26, '$path.effects', 'Channel effects');
    }
    for (int i = 0; i < channel.effects.length; i++) {
      _effect(channel.effects[i], '$path.effects[$i]', depth + 1);
    }
  }

  /// Visits one effect's strings, configuration and optional mask.
  void _effect(XcfEffect effect, String path, int depth) {
    if (depth > 64) {
      _issue('structure.depth', path, 'Effects and masks exceed the writer nesting limit');
      return;
    }
    _string(effect.name, '$path.name');
    _string(effect.icon, '$path.icon');
    _string(effect.operation, '$path.operation');
    _string(effect.version, '$path.version');
    if (effect.version.isNotEmpty) {
      _require(22, '$path.version', 'Effect version strings');
    }
    _properties(effect.properties, '$path.properties');
    if (effect.mask case final XcfChannel mask) {
      _channel(mask, '$path.mask', depth + 1);
    }
  }

  /// Inspects the complete document without allocating pixel buffers.
  XcfWriteReport read() {
    final int version = document.version;
    if (version < 0 || version > 26 || version >= 4 && version <= 6) {
      _issue('version.unsupported', 'version', 'XCF version $version is not supported');
    }
    _dimensions(document.width, document.height, 'canvas');
    if (document.precision != XcfPrecision.u8Nonlinear) {
      _require(document.precision.bytesPerComponent > 1 ? 12 : 7, 'precision', 'Selected sample precision');
    }
    if ((options.compression ?? document.compression) == XcfCompression.zlib) {
      _require(8, 'compression', 'Zlib tile compression');
    }
    if (document.colorMode == XcfColorMode.indexed) {
      _require(1, 'colorMode', 'Indexed color');
      _check('palette.invalid', 'properties', () {
        if (document.precision.bytesPerComponent != 1 || document.palette.isEmpty || document.palette.length > 768) {
          throw const XcfFormatException('Indexed color requires an 8-bit precision and a nonempty palette');
        }
      });
    }
    _check('groups.invalid', 'layers', () => document.layerTree);
    _check('floating.invalid', 'floatingSelection', () => document.floatingSelection?.validate(document));
    if (document.layers.where((layer) => layer.properties.property(2) != null).length > 1) {
      _require(14, 'layers', 'Multiple selected layers');
    }
    if (document.channels.where((channel) => channel.properties.property(3) != null).length > 1) {
      _require(16, 'channels', 'Multiple selected channels');
    }
    _properties(document.properties, 'properties');
    _check('resolution.invalid', 'properties', () => document.resolution);
    _check('samples.invalid', 'properties', () => document.samplePoints);
    _check('guides.invalid', 'properties', () {
      for (final XcfGuide guide in document.guides) {
        if (guide.orientation != 1 && guide.orientation != 2) {
          _issue('guide.unknownOrientation', 'properties', 'Guide direction ${guide.orientation} is preserved but ignored by GIMP', warning: true);
        }
        if (guide.position < 0 || guide.position > (guide.orientation == 1 ? document.height : document.width)) {
          _require(15, 'properties', 'Off-canvas guides');
        }
      }
    });
    for (int i = 0; i < document.layers.length; i++) {
      final XcfLayer layer = document.layers[i];
      final String path = 'layers[$i]';
      _dimensions(layer.width, layer.height, path);
      _string(layer.name, '$path.name');
      _properties(layer.properties, '$path.properties', floating: document.floatingSelection?.layerIndex == i);
      if (layer.type.colorMode != document.colorMode && document.floatingSelection?.layerIndex != i) {
        _issue('layer.colorMode', path, 'Layer color model differs from document');
      }
      if (layer.isGroup) {
        _require(3, path, 'Layer groups');
      } else if (layer.raster == null) {
        _issue('raster.missing', path, 'Raster layer has no sample data');
      }
      if (layer.raster case final XcfRaster raster) {
        _raster(raster, '$path.raster');
        if (raster.width != layer.width || raster.height != layer.height || raster.bytesPerPixel != layer.type.components * document.precision.bytesPerComponent) {
          _issue('raster.layout', path, 'Layer sample layout differs from geometry or precision');
        }
      }
      _check('text.invalid', '$path.properties', () {
        final XcfText? text = layer.text;
        if (text?.options.color?.encoded != null) {
          _require(14, '$path.properties', 'Encoded text colors');
        }
        if (text != null && (text.options.font?.isModern == true || text.markupFonts.values.any((font) => font.isModern))) {
          _require(19, '$path.properties', 'Structured font resources');
        }
      });
      if (layer.isGroup && layer.mask != null) {
        _require(13, '$path.mask', 'Group masks');
      }
      if (layer.isGroup &&
          [10, 32].any((type) {
            final XcfProperty? property = layer.properties.property(type);
            return property != null && property.data.length == 4 && property.integer != 0;
          })) {
        _require(17, '$path.properties', 'Group position or alpha locks');
      }
      if (layer.mask case final XcfChannel mask) {
        _channel(mask, '$path.mask', 0);
      }
      if (layer.effects.isNotEmpty) {
        _require(20, '$path.effects', 'Layer effects');
      }
      for (int j = 0; j < layer.effects.length; j++) {
        _effect(layer.effects[j], '$path.effects[$j]', 0);
      }
    }
    for (int i = 0; i < document.channels.length; i++) {
      _channel(document.channels[i], 'channels[$i]', 0);
    }
    if (document.vectors.isNotEmpty) {
      _require(18, 'vectors', 'Modern path records');
    }
    for (int i = 0; i < document.vectors.length; i++) {
      _string(document.vectors[i].name, 'vectors[$i].name');
      metadataBytes += document.vectors[i].payload.length;
      // Keep future vector record versions writable as opaque self-contained
      // records, but make the semantic interpretation limit explicit.
      try {
        XcfPath.fromVector(document.vectors[i]);
      } on FormatException catch (error) {
        _issue('path.opaque', 'vectors[$i]', error.message, warning: true);
      }
    }
    final bool raw = (options.compression ?? document.compression) == XcfCompression.raw;
    if (raw && sampleBytes + metadataBytes > 0xffffffff) {
      _require(11, 'version', 'Output larger than the 32-bit pointer range');
    } else if (version < 11 && sampleBytes * 2 + metadataBytes > 0xffffffff) {
      _issue('size.wideOffsetsRecommended', 'version', 'Compressed size may exceed 32-bit pointers; use XCF 11 or later', warning: true);
    }
    if (options.maxOutputBytes < 0 || metadataBytes + (raw ? sampleBytes : 0) > options.maxOutputBytes) {
      _issue('size.outputLimit', 'output', 'Known output data already exceeds the configured output limit');
    }
    return XcfWriteReport._(minimumVersion, sampleBytes, issues);
  }
}
