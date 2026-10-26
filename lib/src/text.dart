import 'dart:convert';
import 'dart:typed_data';

import 'package:xcfkit/src/color.dart';
import 'package:xcfkit/src/exception.dart';
import 'package:xcfkit/src/model.dart';
import 'package:xcfkit/src/property.dart';
import 'package:xml/xml.dart' show XmlDefaultEntityMapping, XmlException;
import 'package:xml/xml_events.dart';

part 'configuration.dart';
part 'text_content.dart';
part 'text_options.dart';

/// Editable GIMP text configuration, with unknown fields preserved verbatim.
///
/// This describes text without resolving fonts, shaping glyphs or rendering.
/// [options] and [content] expose configuration and styled text respectively.
final class XcfText {
  /// Serialized GimpConfig without the optional final null byte.
  final String source;

  /// Original parasite persistence flags.
  final int flags;

  /// Whether the original parasite included a final null byte.
  final bool nullTerminated;

  /// Parsed field spans, bounded by the configuration scanner.
  final List<_ConfigNode> _fields;

  /// Parses serialized configuration while retaining its exact spelling.
  XcfText.fromSource(this.source, {this.flags = 1, this.nullTerminated = true}) : _fields = _ConfigScanner(source).read();

  /// Decodes the UTF-8 `gimp-text-layer` parasite.
  factory XcfText.fromParasite(XcfParasite parasite) {
    if (parasite.name != 'gimp-text-layer') {
      throw ArgumentError('Not a GIMP text parasite');
    }
    if (parasite.data.length > 16 * 1024 * 1024) {
      throw const XcfFormatException('Text metadata exceeds the limit');
    }
    final bool terminated = parasite.data.isNotEmpty && parasite.data.last == 0;
    try {
      return XcfText.fromSource(utf8.decode(terminated ? parasite.data.sublist(0, parasite.data.length - 1) : parasite.data), flags: parasite.flags, nullTerminated: terminated);
    } on FormatException catch (error) {
      if (error is XcfFormatException) {
        rethrow;
      }
      throw const XcfFormatException('Invalid UTF-8 text configuration');
    }
  }

  /// Plain text when present; styled layers may store only [markup].
  String? get text => _stringField('text');

  /// Pango markup, retaining the original XML spelling.
  String? get markup {
    final _ConfigNode? field = _field('markup');
    if (field == null) {
      return null;
    }
    if (field.children.length < 2) {
      throw const XcfFormatException('Invalid text markup field');
    }
    return _token(field.children[1]) == 'NULL' ? null : _string(field.children[1]);
  }

  /// Layer-wide typography, paragraph, box, transformation and outline options.
  XcfTextOptions get options => XcfTextOptions._(this);

  /// Plain text and UTF-16 style ranges, with nested inline styling retained.
  XcfTextContent get content => _textContent(this);

  /// Font resources referenced by GIMP 3 markup aliases such as `font17`.
  Map<String, XcfTextFont> get markupFonts {
    final Map<String, XcfTextFont> result = {};
    final List<_ConfigNode> nodes = _field('markup')?.children.skip(2).toList() ?? const [];
    for (int i = 0; i < nodes.length; i++) {
      final _ConfigNode node = nodes[i];
      if (node.children.isEmpty && _token(node).startsWith('"')) {
        // Early GIMP 3 records used an alias followed directly by its fields,
        // or by a second string containing the legacy font description.
        final String alias = _string(node);
        final List<String> fields = [];
        if (i + 1 < nodes.length && nodes[i + 1].children.isEmpty) {
          _string(nodes[++i]);
          fields.add(_token(nodes[i]));
        } else {
          while (i + 1 < nodes.length && nodes[i + 1].children.isNotEmpty) {
            fields.add(_token(nodes[++i]));
          }
        }
        result[alias] = XcfTextFont.fromSource('(font ${fields.join(' ')})');
        continue;
      }
      if (node.children.length == 3 && _token(node.children.first) == 'markupfont') {
        final _ConfigNode font = node.children[2];
        if (font.children.isEmpty || _token(font.children.first) != 'font') {
          throw const XcfFormatException('Invalid markup font resource');
        }
        result[_string(node.children[1])] = XcfTextFont.fromSource(_token(font));
      }
    }
    return Map.unmodifiable(result);
  }

  /// Applies known configuration fields, preserving all unrelated source spans.
  XcfText withOptions(XcfTextOptions options) => _replace({
    for (final String name in _textOptionNames)
      if (options._text._field(name) case final _ConfigNode field) name: options._text.source.substring(field.children.first.end, field.end - 1).trim(),
  });

  /// Applies edited styled contents while retaining GIMP markup font resources.
  XcfText withContent(XcfTextContent content) {
    final XcfText updated = withOptions(content.options);
    final String fonts = content.fonts.entries.map((entry) => '(markupfont ${_quote(entry.key)} ${entry.value._markupSource})').join(' ');
    final List<_ConfigNode> previous = _field('markup')?.children.skip(2).toList() ?? const [];
    final bool legacyFonts = previous.isNotEmpty && previous.first.children.isEmpty && _token(previous.first).startsWith('"');
    final String unknown = legacyFonts ? '' : previous.where((node) => node.children.isEmpty || _token(node.children.first) != 'markupfont').map(_token).join(' ');
    return updated._replace({'text': null, 'markup': '${_quote(content.toMarkup())} $fonts $unknown'});
  }

  /// Legacy font description, or the full name of a modern GimpFont resource.
  String? get fontName {
    final _ConfigNode? font = _field('font');
    if (font == null || font.children.length < 2) {
      return null;
    }
    for (final _ConfigNode child in font.children.skip(2)) {
      if (child.children.isNotEmpty && _token(child.children.first) == 'fullname' && child.children.length == 2) {
        return _string(child.children[1]);
      }
    }
    final String name = _string(font.children[1]);
    return name == 'GimpFont' ? null : name;
  }

  /// Font size in [fontSizeUnit], without converting physical units.
  double? get fontSize {
    final _ConfigNode? field = _field('font-size');
    if (field == null) {
      return null;
    }
    final double? value = field.children.length == 2 ? double.tryParse(_token(field.children[1])) : null;
    if (value == null || !value.isFinite || value < 0 || value > 8192) {
      throw const XcfFormatException('Invalid text font size');
    }
    return value;
  }

  /// GIMP unit identifier such as `pixels` or `points`.
  String? get fontSizeUnit {
    final _ConfigNode? field = _field('font-size-unit');
    if (field == null) {
      return null;
    }
    if (field.children.length != 2) {
      throw const XcfFormatException('Invalid font size unit');
    }
    return _token(field.children[1]);
  }

  /// Replaces text and clears Pango markup, keeping the base font and styles.
  XcfText withText(String value) => _replace({'text': _quote(value), 'markup': null});

  /// Replaces font size and optionally its unit, retaining font resources.
  XcfText withFontSize(double value, {String? unit}) {
    if (!value.isFinite || value < 0 || value > 8192 || unit != null && !RegExp(r'^[a-zA-Z][a-zA-Z0-9_-]*$').hasMatch(unit)) {
      throw ArgumentError('Invalid font size or unit');
    }
    return _replace({'font-size': value.toString(), 'font-size-unit': ?unit});
  }

  /// Encodes configuration without normalizing unrelated fields.
  XcfParasite toParasite() => XcfParasite(name: 'gimp-text-layer', flags: flags, data: [...utf8.encode(source), if (nullTerminated) 0]);

  /// Finds the final occurrence, matching GimpConfig assignment order.
  _ConfigNode? _field(String name) => _fields.where((field) => _token(field.children.first) == name).lastOrNull;

  /// Reads the single string value of a known field.
  String? _stringField(String name) {
    final _ConfigNode? field = _field(name);
    if (field == null) {
      return null;
    }
    if (field.children.length != 2) {
      throw XcfFormatException('Invalid text field $name');
    }
    final _ConfigNode value = field.children[1];
    return _token(value) == 'NULL' ? null : _string(value);
  }

  /// Returns an untouched token span.
  String _token(_ConfigNode node) => source.substring(node.start, node.end);

  /// Decodes GimpConfig's C escapes, including UTF-8 byte octal escapes.
  String _string(_ConfigNode node) {
    try {
      return utf8.decode(_bytes(node));
    } on FormatException catch (error) {
      if (error is XcfFormatException) {
        rethrow;
      }
      throw const XcfFormatException('Invalid escaped UTF-8 text');
    }
  }

  /// Decodes binary configuration strings without assuming their contents are UTF-8.
  Uint8List _bytes(_ConfigNode node) {
    final String token = _token(node);
    if (!token.startsWith('"')) {
      throw const XcfFormatException('Expected a quoted text value');
    }
    final List<int> bytes = [];
    int start = 1;
    for (int i = 1; i < token.length - 1; i++) {
      if (token.codeUnitAt(i) != 92) {
        continue;
      }
      bytes.addAll(utf8.encode(token.substring(start, i)));
      i++;
      final String escaped = token[i];
      if (RegExp(r'[0-7]').hasMatch(escaped)) {
        int end = i + 1;
        while (end < token.length - 1 && end < i + 3 && RegExp(r'[0-7]').hasMatch(token[end])) {
          end++;
        }
        final int value = int.parse(token.substring(i, end), radix: 8);
        if (value > 255) {
          throw const XcfFormatException('Invalid octal text escape');
        }
        bytes.add(value);
        i = end - 1;
      } else {
        final int? value = {'n': 10, 'r': 13, 't': 9, 'b': 8, 'f': 12, 'v': 11, 'a': 7, '\\': 92, '"': 34}[escaped];
        if (value == null) {
          throw const XcfFormatException('Unknown text escape');
        }
        bytes.add(value);
      }
      start = i + 1;
    }
    bytes.addAll(utf8.encode(token.substring(start, token.length - 1)));
    return Uint8List.fromList(bytes);
  }

  /// Changes complete named fields while retaining all other source spans.
  XcfText _replace(Map<String, String?> changes) {
    final StringBuffer output = StringBuffer();
    int position = 0;
    for (final _ConfigNode field in _fields) {
      if (!changes.containsKey(_token(field.children.first))) {
        continue;
      }
      output.write(source.substring(position, field.start));
      position = field.end;
    }
    output.write(source.substring(position));
    for (final MapEntry<String, String?> change in changes.entries) {
      if (change.value != null) {
        output.write('\n(${change.key} ${change.value})\n');
      }
    }
    return XcfText.fromSource(output.toString(), flags: flags, nullTerminated: nullTerminated);
  }
}

/// Text access and cache-aware editing for raster layers.
extension XcfLayerText on XcfLayer {
  /// Editable text metadata, if this layer carries GIMP's text parasite.
  XcfText? get text {
    final XcfParasite? parasite = properties.parasites.where((value) => value.name == 'gimp-text-layer').firstOrNull;
    return parasite == null ? null : XcfText.fromParasite(parasite);
  }

  /// Applies text and its caller-rendered sample cache together.
  ///
  /// The raster must use this layer's component layout and original precision.
  /// Offsets can be updated for changed font metrics. GIMP's modified-pixels
  /// flag is cleared; this does not perform text layout or validate the rendering.
  XcfLayer withText(XcfText text, {required XcfRaster renderedRaster, int? x, int? y}) {
    if (isGroup || raster == null || renderedRaster.bytesPerPixel != raster!.bytesPerPixel) {
      throw ArgumentError('Text needs a raster with the original pixel layout');
    }
    List<XcfProperty> metadata = properties.replacing(
      XcfParasite.toProperty([
        ...properties.parasites.where((value) => value.name != 'gimp-text-layer'),
        text.toParasite(),
      ]),
    );
    metadata = metadata.replacing(XcfProperty.integer(type: XcfPropertyId.textLayerFlags, value: (properties.property(XcfPropertyId.textLayerFlags)?.integer ?? 0) & ~2));
    if (x != null || y != null) {
      metadata = metadata.replacing(XcfProperty.offsets(x: x ?? this.x, y: y ?? this.y));
    }
    return copyWith(width: renderedRaster.width, height: renderedRaster.height, raster: renderedRaster, properties: metadata);
  }
}

/// Escapes text without allowing it to introduce configuration expressions.
String _quote(String value) {
  if (value.contains('\u0000')) {
    throw ArgumentError('GIMP text cannot contain null characters');
  }
  final StringBuffer result = StringBuffer('"');
  for (final int rune in value.runes) {
    if (rune == 92 || rune == 34) {
      result.write('\\${String.fromCharCode(rune)}');
    } else if (rune < 32 || rune == 127) {
      result.write('\\${rune.toRadixString(8).padLeft(3, '0')}');
    } else {
      result.writeCharCode(rune);
    }
  }
  return '$result"';
}

/// Source spans for lists and tokens; binary strings need not be interpreted.
final class _ConfigNode {
  /// Inclusive character offset.
  final int start;

  /// Exclusive character offset.
  final int end;

  /// Nested expressions, empty for tokens.
  final List<_ConfigNode> children;

  /// Retains a token or list without copying its source.
  const _ConfigNode(this.start, this.end, [this.children = const []]);
}

/// Bounded scanner for GimpConfig's parenthesized fields and quoted strings.
final class _ConfigScanner {
  /// Unmodified serialized configuration.
  final String source;

  /// Current character offset.
  int position = 0;

  /// Total token and list count.
  int nodes = 0;

  /// Starts a scan, limiting work even for manually supplied configurations.
  _ConfigScanner(this.source) {
    if (source.length > 16 * 1024 * 1024 || source.contains('\u0000')) {
      throw const XcfFormatException('Invalid or oversized text configuration');
    }
  }

  /// Reads named top-level lists and validates balanced nested syntax.
  List<_ConfigNode> read() {
    final List<_ConfigNode> result = [];
    _space();
    while (position < source.length) {
      final _ConfigNode node = _node(0);
      if (node.children.isEmpty || !RegExp(r'^[a-zA-Z][a-zA-Z0-9_-]*$').hasMatch(source.substring(node.children.first.start, node.children.first.end))) {
        throw const XcfFormatException('Expected a named text configuration field');
      }
      result.add(node);
      _space();
    }
    return List.unmodifiable(result);
  }

  /// Skips whitespace and GimpConfig line comments.
  void _space() {
    while (position < source.length) {
      if (source.codeUnitAt(position) <= 32) {
        position++;
      } else if (source[position] == '#') {
        while (position < source.length && source[position] != '\n') {
          position++;
        }
      } else {
        break;
      }
    }
  }

  /// Reads one list or token without interpreting opaque resource strings.
  _ConfigNode _node(int depth) {
    if (++nodes > 100000 || depth > 64 || position >= source.length) {
      throw const XcfFormatException('Invalid or excessive text nesting');
    }
    final int start = position++;
    final String first = source[start];
    if (first == '(') {
      final List<_ConfigNode> children = [];
      _space();
      while (position < source.length && source[position] != ')') {
        children.add(_node(depth + 1));
        _space();
      }
      if (position == source.length) {
        throw const XcfFormatException('Unclosed text configuration list');
      }
      return _ConfigNode(start, ++position, children);
    }
    if (first == '"') {
      while (position < source.length) {
        final String character = source[position++];
        if (character == '"') {
          return _ConfigNode(start, position);
        }
        if (character == '\\') {
          position++;
        }
      }
      throw const XcfFormatException('Unclosed text configuration string');
    }
    if (first == ')') {
      throw const XcfFormatException('Unexpected text configuration delimiter');
    }
    while (position < source.length && source.codeUnitAt(position) > 32 && !'()"#'.contains(source[position])) {
      position++;
    }
    return _ConfigNode(start, position);
  }
}
