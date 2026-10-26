part of 'package:xcfkit/src/text.dart';

/// One GimpConfig token or nested list, preserving its exact original spelling.
final class XcfConfigValue {
  /// Configuration owning the source span.
  final XcfText _owner;

  /// Bounded token or list span.
  final _ConfigNode _node;

  /// Wraps a validated token span.
  const XcfConfigValue._(this._owner, this._node);

  /// Parses exactly one value, rejecting trailing expressions and delimiters.
  factory XcfConfigValue.fromSource(String source) {
    final XcfText owner = XcfText.fromSource('(value $source)');
    if (owner._fields.length != 1 || owner._fields.single.children.length != 2) {
      throw const XcfFormatException('Expected exactly one configuration value');
    }
    return XcfConfigValue._(owner, owner._fields.single.children[1]);
  }

  /// Creates a quoted UTF-8 string with escaped delimiters.
  factory XcfConfigValue.string(String value) => XcfConfigValue.fromSource(_quote(value));

  /// Creates a finite numeric token without guessing an enum's meaning.
  factory XcfConfigValue.number(num value) {
    if (!value.isFinite) {
      throw ArgumentError.value(value, 'value');
    }
    return XcfConfigValue.fromSource(value.toString());
  }

  /// Creates one symbolic token, such as `yes`, `smooth`, or `NULL`.
  factory XcfConfigValue.symbol(String value) {
    if (!RegExp(r'^[a-zA-Z_][a-zA-Z0-9_:.-]*$').hasMatch(value)) {
      throw ArgumentError.value(value, 'value');
    }
    return XcfConfigValue.fromSource(value);
  }

  /// Creates a nested list from validated child values.
  factory XcfConfigValue.list(Iterable<XcfConfigValue> children) => XcfConfigValue.fromSource('(${children.map((value) => value.source).join(' ')})');

  /// Original serialized value, including quotes or list delimiters.
  String get source => _owner._token(_node);

  /// Whether this value is a parenthesized list, including an empty list.
  bool get isList => source.startsWith('(');

  /// Whether this value is a C-escaped quoted string.
  bool get isString => source.startsWith('"');

  /// Nested values; empty for a token or an empty list.
  List<XcfConfigValue> get children => List.unmodifiable(_node.children.map((node) => XcfConfigValue._(_owner, node)));

  /// A finite number when the token is numeric, otherwise null.
  num? get number {
    final num? value = num.tryParse(source);
    return value != null && value.isFinite ? value : null;
  }

  /// Decoded binary string bytes; octal escapes need not contain UTF-8.
  Uint8List get stringBytes => _owner._bytes(_node).asUnmodifiableView();

  /// Decoded UTF-8 string, rejecting non-string or binary values.
  String get string => _owner._string(_node);
}

/// Structured GimpConfig with bounded nesting and source-preserving edits.
///
/// Suitable for serialized effect arguments, grid and symmetry parasites. Unknown
/// names and values remain available; this class does not execute configuration.
final class XcfConfiguration {
  /// Shared scanner and lossless source editor.
  final XcfText _parsed;

  /// Parses named fields without interpreting application-specific names.
  XcfConfiguration.fromSource(String source) : _parsed = XcfText.fromSource(source);

  /// Original serialized configuration.
  String get source => _parsed.source;

  /// Field names in source order, including repeated assignments.
  List<String> get names => List.unmodifiable(_parsed._fields.map((field) => _parsed._token(field.children.first)));

  /// Values of a named field; defaults to its last occurrence.
  ///
  /// Specify a zero-based [occurrence] for repeated context-sensitive fields.
  /// GIMP curves, for example, alternate `channel` and `curve` assignments.
  List<XcfConfigValue>? field(String name, {int? occurrence}) {
    final _ConfigNode? node = _field(name, occurrence);
    return node == null ? null : List.unmodifiable(node.children.skip(1).map((child) => XcfConfigValue._(_parsed, child)));
  }

  /// Reads a field containing named subfields, such as a curve or grid section.
  XcfConfiguration? nested(String name, {int? occurrence}) {
    final _ConfigNode? node = _field(name, occurrence);
    return node == null ? null : XcfConfiguration.fromSource(source.substring(node.children.first.end, node.end - 1));
  }

  /// Replaces one nested field, retaining surrounding assignment order.
  XcfConfiguration withNested(String name, XcfConfiguration value, {int? occurrence}) => _withBody(name, '${value.source}\n', occurrence);

  /// Replaces one field in place, or removes it when [values] is null.
  ///
  /// Defaults to the last occurrence; other occurrences, comments and source
  /// spans survive. A missing name is appended when no occurrence was requested.
  /// Preserving order is essential for context-sensitive GEGL configurations.
  XcfConfiguration withField(String name, List<XcfConfigValue>? values, {int? occurrence}) => _withBody(name, values?.map((value) => value.source).join(' '), occurrence);

  /// Replaces one validated field body without discarding nested comments.
  XcfConfiguration _withBody(String name, String? body, int? occurrence) {
    if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9_-]*$').hasMatch(name)) {
      throw ArgumentError.value(name, 'name');
    }
    final _ConfigNode? node = _field(name, occurrence);
    final String replacement = body == null ? '' : '($name $body)';
    return XcfConfiguration.fromSource(node == null ? '$source\n$replacement' : source.replaceRange(node.start, node.end, replacement));
  }

  /// Finds a specific source span without collapsing repeated assignments.
  _ConfigNode? _field(String name, int? occurrence) {
    final List<_ConfigNode> matches = _parsed._fields.where((field) => _parsed._token(field.children.first) == name).toList();
    if (occurrence == null) {
      return matches.lastOrNull;
    }
    return matches[RangeError.checkValidIndex(occurrence, matches, 'occurrence')];
  }

  /// Reads configuration from a named UTF-8 parasite, retaining no hidden state.
  factory XcfConfiguration.fromParasite(XcfParasite parasite) {
    if (parasite.data.length > 16 * 1024 * 1024) {
      throw const XcfFormatException('Configuration parasite exceeds the limit');
    }
    final bool terminated = parasite.data.isNotEmpty && parasite.data.last == 0;
    try {
      return XcfConfiguration.fromSource(utf8.decode(terminated ? parasite.data.sublist(0, parasite.data.length - 1) : parasite.data));
    } on FormatException catch (error) {
      throw XcfFormatException('Invalid configuration parasite: $error');
    }
  }

  /// Replaces an existing parasite's configuration, retaining its name and flags.
  XcfParasite updateParasite(XcfParasite original) =>
      XcfParasite(name: original.name, flags: original.flags, data: [...utf8.encode(source), if (original.data.isNotEmpty && original.data.last == 0) 0]);
}
