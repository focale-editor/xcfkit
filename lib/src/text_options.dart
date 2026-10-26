part of 'package:xcfkit/src/text.dart';

/// Configuration names that describe layout rather than text contents.
const List<String> _textOptionNames = [
  'font',
  'font-size',
  'font-size-unit',
  'antialias',
  'hint-style',
  'hinting',
  'kerning',
  'language',
  'base-direction',
  'color',
  'justify',
  'indent',
  'line-spacing',
  'letter-spacing',
  'box-mode',
  'box-width',
  'box-height',
  'box-unit',
  'transformation',
  'offset-x',
  'offset-y',
  'outline',
  'outline-custom-style',
  'outline-pattern',
  'outline-foreground',
  'outline-width',
  'outline-unit',
  'outline-direction',
  'outline-cap-style',
  'outline-join-style',
  'outline-miter-limit',
  'outline-antialias',
  'outline-dash-offset',
  'outline-dash-info',
];

/// A font reference retaining modern resource identifiers and unknown fields.
final class XcfTextFont {
  /// Complete `(font ...)` configuration field, without resolving the resource.
  final String source;

  /// Parsed field owner used for bounded string and token access.
  final XcfText _config;

  /// Parses an existing legacy description or modern GimpFont resource.
  XcfTextFont.fromSource(this.source) : _config = XcfText.fromSource(source) {
    if (_config._fields.length != 1 || _config._field('font') == null) {
      throw const XcfFormatException('Invalid text font resource');
    }
    if (_config._fields.single.children.length >= 2 && _config._fields.single.children[1].children.isEmpty) {
      _config._string(_config._fields.single.children[1]);
    }
  }

  /// Creates a font reference by name; modern resources require XCF 19+.
  factory XcfTextFont.named(String name, {bool modern = true}) {
    if (name.isEmpty) {
      throw ArgumentError.value(name, 'name');
    }
    return XcfTextFont.fromSource(modern ? '(font "GimpFont" (fullname ${_quote(name)}))' : '(font ${_quote(name)})');
  }

  /// Whether the resource uses the GIMP 3 structured font representation.
  bool get isModern => _config._fields.single.children.length == 1 || _config._fields.single.children[1].children.isNotEmpty || _config._string(_config._fields.single.children[1]) == 'GimpFont';

  /// Legacy description or modern full font name.
  String? get name => isModern ? fullName : _config._string(_config._fields.single.children[1]);

  /// Exact full name, family, style and PostScript identifier when present.
  String? get fullName => _string('fullname');

  /// Font family without resolving installed fonts.
  String? get family => _string('family');

  /// Font face style name.
  String? get style => _string('style');

  /// PostScript font identifier.
  String? get postScriptName => _string('psname');

  /// GIMP's font hash used for resource matching.
  String? get hash => _string('fonthash');

  /// Face index within a font collection.
  int? get index => _integer('index');

  /// Fontconfig weight, slant and width values, not CSS values.
  int? get weight => _integer('weight');

  /// Fontconfig slant value.
  int? get slant => _integer('slant');

  /// Fontconfig width value.
  int? get width => _integer('width');

  /// Font revision supplied by the resource.
  int? get version => _integer('fontversion');

  /// Exact resource expression after the field name.
  String get _value {
    final _ConfigNode font = _config._fields.single;
    final String body = source.substring(font.children.first.end, font.end - 1).trim();
    return font.children.length == 1 || font.children[1].children.isNotEmpty ? '"GimpFont" $body' : body;
  }

  /// Inline font resources omit the base field's GimpFont type marker.
  String get _markupSource {
    final _ConfigNode font = _config._fields.single;
    if (font.children.length > 1 && font.children[1].children.isEmpty && _config._string(font.children[1]) == 'GimpFont') {
      return '(font ${source.substring(font.children[1].end, font.end - 1).trim()})';
    }
    return source;
  }

  /// Finds a resource field, retaining last-value-wins semantics.
  _ConfigNode? _field(String name) => _config._fields.single.children.skip(1).where((node) => node.children.isNotEmpty && _config._token(node.children.first) == name).lastOrNull;

  /// Reads a known resource string.
  String? _string(String name) {
    final _ConfigNode? field = _field(name);
    if (field == null) {
      return null;
    }
    if (field.children.length != 2) {
      throw const XcfFormatException('Invalid font field');
    }
    return _config._string(field.children[1]);
  }

  /// Reads a known resource integer.
  int? _integer(String name) {
    final _ConfigNode? field = _field(name);
    if (field == null) {
      return null;
    }
    final int? value = field.children.length == 2 ? int.tryParse(_config._token(field.children[1])) : null;
    if (value == null) {
      throw const XcfFormatException('Invalid font integer');
    }
    return value;
  }
}

/// A text color in either legacy numeric sRGB or modern encoded form.
final class XcfTextColor {
  /// Exact legacy normalized RGBA components, or null for encoded colors.
  final List<double>? rgba;

  /// Modern color bytes and profile, or null for legacy numeric colors.
  final XcfColor? encoded;

  /// Creates a legacy numeric sRGB color without quantizing its components.
  XcfTextColor.rgba(double red, double green, double blue, [double alpha = 1]) : rgba = List.unmodifiable([red, green, blue, alpha]), encoded = null {
    if (rgba!.any((value) => !value.isFinite)) {
      throw ArgumentError('Non-finite text color');
    }
  }

  /// Creates a modern color; this representation requires XCF 14+.
  const XcfTextColor.encoded(XcfColor color) : encoded = color, rgba = null;

  /// Serializes this color in its own representation without conversion.
  String _serialize() {
    if (rgba case final List<double> values) {
      return '(color-rgba ${values.join(' ')})';
    }
    final XcfColor color = encoded!;
    return '(color ${_quote(color.encoding)} ${color.pixel.length} ${_quoteBytes(color.pixel)} ${color.profile.length}${color.profile.isEmpty ? '' : ' ${_quoteBytes(color.profile)}'})';
  }
}

/// Text-box geometry; dimensions retain their declared GIMP unit.
final class XcfTextBox {
  /// GIMP `dynamic` or `fixed` token, including future values if read.
  final String mode;

  /// Width and height in [unit].
  final double width;

  /// Height in [unit].
  final double height;

  /// GIMP unit identifier, such as `pixels` or `points`.
  final String unit;

  /// Creates box metadata independently of the cached raster's dimensions.
  const XcfTextBox({this.mode = 'dynamic', this.width = 0, this.height = 0, this.unit = 'pixels'});
}

/// Text's 2×2 transformation and separate layout offsets.
final class XcfTextTransform {
  /// Row-major matrix entries, without computing transformed glyph positions.
  final double xx;

  /// First-row shear coefficient.
  final double xy;

  /// Second-row shear coefficient.
  final double yx;

  /// Vertical scale coefficient.
  final double yy;

  /// Layout translations distinct from the layer's image offsets.
  final double offsetX;

  /// Vertical layout translation.
  final double offsetY;

  /// Creates text transformation metadata.
  const XcfTextTransform({this.xx = 1, this.xy = 0, this.yx = 0, this.yy = 1, this.offsetX = 0, this.offsetY = 0});
}

/// Source-preserving text settings; missing fields expose GIMP's defaults.
///
/// Enum-like values remain GIMP tokens so new values can be reported by a host
/// adapter instead of being silently mapped to a different layout policy.
final class XcfTextOptions {
  /// Source configuration containing these fields and any unknown settings.
  final XcfText _text;

  /// Creates default settings that can be customized using [copyWith].
  factory XcfTextOptions() => XcfTextOptions._(XcfText.fromSource(''));

  /// Creates a snapshot tied to immutable source spans.
  const XcfTextOptions._(this._text);

  /// Font metadata, or null if the source delegates to GIMP's default font.
  XcfTextFont? get font {
    final _ConfigNode? field = _text._field('font');
    return field == null ? null : XcfTextFont.fromSource(_text._token(field));
  }

  /// Font size and unit, also used by indent and spacing fields.
  double get fontSize => _text.fontSize ?? 24;

  /// GIMP font-size unit token.
  String get unit => _text.fontSizeUnit ?? 'pixels';

  /// Whether glyph antialiasing is requested.
  bool get antialias => _boolean('antialias', true);

  /// Hinting token: `none`, `slight`, `medium`, or `full`.
  String get hintStyle {
    final String style = _symbol('hint-style', 'medium');
    return style == 'medium' && !hinting ? 'none' : style;
  }

  /// Legacy hinting flag, retained independently of hint-style.
  bool get hinting => _boolean('hinting', true);

  /// GIMP's kerning flag.
  bool get kerning => _boolean('kerning', false);

  /// Language identifier; missing language is environment-dependent in GIMP.
  String? get language => _text._stringField('language');

  /// Direction token, including GIMP's vertical/upright variants.
  String get direction => _symbol('base-direction', 'ltr');

  /// Paragraph alignment: `left`, `right`, `center`, or `fill`.
  String get justification => _symbol('justify', 'left');

  /// First-line indent in [unit].
  double get indent => _number('indent', 0);

  /// Additional line spacing in [unit], not a line-height ratio.
  double get lineSpacing => _number('line-spacing', 0);

  /// Additional letter spacing in [unit].
  double get letterSpacing => _number('letter-spacing', 0);

  /// Fill color; null means the source does not explicitly store it.
  XcfTextColor? get color => _color('color');

  /// Dynamic or fixed text-box geometry.
  XcfTextBox get box => XcfTextBox(mode: _symbol('box-mode', 'dynamic'), width: _number('box-width', 0), height: _number('box-height', 0), unit: _symbol('box-unit', 'pixels'));

  /// Layout matrix and offsets, independent of the cached pixel rectangle.
  XcfTextTransform get transform {
    final _ConfigNode? field = _text._field('transformation');
    final List<double> matrix;
    if (field == null) {
      matrix = [1, 0, 0, 1];
    } else {
      if (field.children.length != 2) {
        throw const XcfFormatException('Invalid text matrix');
      }
      final List<_ConfigNode> values = field.children[1].children;
      if (values.length != 5 || _text._token(values.first) != 'matrix') {
        throw const XcfFormatException('Invalid text matrix');
      }
      matrix = values.skip(1).map(_numericToken).toList();
    }
    return XcfTextTransform(xx: matrix[0], xy: matrix[1], yx: matrix[2], yy: matrix[3], offsetX: _number('offset-x', 0), offsetY: _number('offset-y', 0));
  }

  /// Text contour settings in GIMP 3.2 and later.
  XcfTextOutline get outline => XcfTextOutline._(this);

  /// Changes only supplied options and retains all other source fields.
  XcfTextOptions copyWith({
    XcfTextFont? font,
    double? fontSize,
    String? unit,
    bool? antialias,
    String? hintStyle,
    bool? hinting,
    bool? kerning,
    String? language,
    String? direction,
    String? justification,
    double? indent,
    double? lineSpacing,
    double? letterSpacing,
    XcfTextColor? color,
    XcfTextBox? box,
    XcfTextTransform? transform,
    XcfTextOutline? outline,
  }) {
    final Map<String, String?> changes = {
      if (font != null) 'font': font._value,
      if (fontSize != null) 'font-size': _finite(fontSize, minimum: 0, maximum: 8192),
      if (unit != null) 'font-size-unit': _identifier(unit),
      if (antialias != null) 'antialias': antialias ? 'yes' : 'no',
      if (hintStyle != null) 'hint-style': _identifier(hintStyle),
      if (hinting != null) 'hinting': hinting ? 'yes' : 'no',
      if (kerning != null) 'kerning': kerning ? 'yes' : 'no',
      if (language != null) 'language': _quote(language),
      if (direction != null) 'base-direction': _identifier(direction),
      if (justification != null) 'justify': _identifier(justification),
      if (indent != null) 'indent': _finite(indent, minimum: -8192, maximum: 8192),
      if (lineSpacing != null) 'line-spacing': _finite(lineSpacing, minimum: -8192, maximum: 8192),
      if (letterSpacing != null) 'letter-spacing': _finite(letterSpacing, minimum: -8192, maximum: 8192),
      if (color != null) 'color': color._serialize(),
      if (box != null) ...{'box-mode': _identifier(box.mode), 'box-unit': _identifier(box.unit), 'box-width': _finite(box.width, minimum: 0), 'box-height': _finite(box.height, minimum: 0)},
      if (transform != null) ...{
        'transformation': '(matrix ${[transform.xx, transform.xy, transform.yx, transform.yy].map(_finite).join(' ')})',
        'offset-x': _finite(transform.offsetX),
        'offset-y': _finite(transform.offsetY),
      },
    };
    if (outline != null) {
      for (final String name in _textOptionNames.where((name) => name == 'outline' || name.startsWith('outline-'))) {
        final _ConfigNode? field = outline._options._text._field(name);
        if (field != null) {
          changes[name] = outline._options._text.source.substring(field.children.first.end, field.end - 1).trim();
        }
      }
    }
    return XcfTextOptions._(_text._replace(changes));
  }

  /// Reads a boolean without silently accepting malformed scalar data.
  bool _boolean(String name, bool fallback) {
    final String value = _symbol(name, fallback ? 'yes' : 'no');
    if (value != 'yes' && value != 'no') {
      throw XcfFormatException('Invalid boolean text option $name');
    }
    return value == 'yes';
  }

  /// Reads one unquoted configuration token, retaining unknown enum values.
  String _symbol(String name, String fallback) {
    final _ConfigNode? field = _text._field(name);
    if (field == null) {
      return fallback;
    }
    if (field.children.length != 2) {
      throw XcfFormatException('Invalid text option $name');
    }
    return _text._token(field.children[1]);
  }

  /// Reads one finite scalar.
  double _number(String name, double fallback) {
    final _ConfigNode? field = _text._field(name);
    if (field == null) {
      return fallback;
    }
    if (field.children.length != 2) {
      throw XcfFormatException('Invalid text option $name');
    }
    return _numericToken(field.children[1]);
  }

  /// Validates a finite numeric token.
  double _numericToken(_ConfigNode node) {
    final double? value = double.tryParse(_text._token(node));
    if (value == null || !value.isFinite) {
      throw const XcfFormatException('Invalid numeric text option');
    }
    return value;
  }

  /// Reads both generations of text-color serialization without quantization.
  XcfTextColor? _color(String name) {
    final _ConfigNode? field = _text._field(name);
    if (field == null) {
      return null;
    }
    if (field.children.length != 2) {
      throw const XcfFormatException('Invalid text color');
    }
    final _ConfigNode color = field.children[1];
    if (_text._token(color) == 'NULL') {
      return null;
    }
    final List<_ConfigNode> values = color.children;
    if (values.isEmpty) {
      throw const XcfFormatException('Invalid text color');
    }
    final String kind = _text._token(values.first);
    if (kind == 'color-rgb' || kind == 'color-rgba') {
      if (values.length != (kind == 'color-rgb' ? 4 : 5)) {
        throw const XcfFormatException('Invalid legacy text color');
      }
      return XcfTextColor.rgba(_numericToken(values[1]), _numericToken(values[2]), _numericToken(values[3]), values.length == 5 ? _numericToken(values[4]) : 1);
    }
    if (kind != 'color') {
      throw XcfUnsupportedException('Unsupported text color $kind');
    }
    if (values.length < 5 || values.length > 6) {
      throw const XcfFormatException('Invalid encoded text color');
    }
    final String encoding = _text._string(values[1]);
    final Uint8List pixel = _text._bytes(values[3]);
    final Uint8List profile = values.length == 6 ? _text._bytes(values[5]) : Uint8List(0);
    if (int.tryParse(_text._token(values[2])) != pixel.length || int.tryParse(_text._token(values[4])) != profile.length) {
      throw const XcfFormatException('Invalid text color byte lengths');
    }
    try {
      return XcfTextColor.encoded(XcfColor(encoding: encoding, pixel: pixel, profile: profile));
    } on ArgumentError {
      throw const XcfFormatException('Invalid encoded text color');
    }
  }
}

/// Source-preserving contour metadata; rasterization belongs to the host.
final class XcfTextOutline {
  /// The complete immutable configuration supplying contour fields.
  final XcfTextOptions _options;

  /// Creates default contour settings.
  factory XcfTextOutline() => XcfTextOutline._(XcfTextOptions());

  /// Creates a contour view.
  const XcfTextOutline._(this._options);

  /// Filled, stroked, or filled-and-stroked token.
  String get mode => _options._symbol('outline', 'none');

  /// Solid color or pattern fill token.
  String get style => _options._symbol('outline-custom-style', 'solid-color');

  /// Referenced pattern name, without loading external resources.
  String? get pattern => _options._text._stringField('outline-pattern');

  /// Outline color in its original representation.
  XcfTextColor? get color => _options._color('outline-foreground');

  /// Width and unit of the outline.
  double get width => _options._number('outline-width', 4);

  /// GIMP outline-width unit token.
  String get unit => _options._symbol('outline-unit', 'pixels');

  /// Inner, outer or centered placement token.
  String get direction => _options._symbol('outline-direction', 'outer');

  /// Line-cap and join tokens.
  String get cap => _options._symbol('outline-cap-style', 'butt');

  /// Line-join token.
  String get join => _options._symbol('outline-join-style', 'miter');

  /// Miter limit.
  double get miterLimit => _options._number('outline-miter-limit', 2);

  /// Whether contour antialiasing is requested.
  bool get antialias => _options._boolean('outline-antialias', true);

  /// Initial offset within the dash pattern.
  double get dashOffset => _options._number('outline-dash-offset', 0);

  /// Original dash lengths, without normalizing or rendering the pattern.
  List<double> get dashes {
    final _ConfigNode? field = _options._text._field('outline-dash-info');
    if (field == null || field.children.length == 2 && _options._text._token(field.children[1]) == 'NULL') {
      return const [];
    }
    if (field.children.length < 2 || int.tryParse(_options._text._token(field.children[1])) != field.children.length - 2) {
      throw const XcfFormatException('Invalid outline dash count');
    }
    return List.unmodifiable(field.children.skip(2).map(_options._numericToken));
  }

  /// Changes selected contour fields without disturbing unknown options.
  XcfTextOutline copyWith({
    String? mode,
    String? style,
    String? pattern,
    bool removePattern = false,
    XcfTextColor? color,
    double? width,
    String? unit,
    String? direction,
    String? cap,
    String? join,
    double? miterLimit,
    bool? antialias,
    double? dashOffset,
    List<double>? dashes,
  }) => XcfTextOutline._(
    XcfTextOptions._(
      _options._text._replace({
        if (mode != null) 'outline': _identifier(mode),
        if (style != null) 'outline-custom-style': _identifier(style),
        if (pattern != null || removePattern) 'outline-pattern': removePattern ? 'NULL' : _quote(pattern!),
        if (color != null) 'outline-foreground': color._serialize(),
        if (width != null) 'outline-width': _finite(width, minimum: 0, maximum: 8192),
        if (unit != null) 'outline-unit': _identifier(unit),
        if (direction != null) 'outline-direction': _identifier(direction),
        if (cap != null) 'outline-cap-style': _identifier(cap),
        if (join != null) 'outline-join-style': _identifier(join),
        if (miterLimit != null) 'outline-miter-limit': _finite(miterLimit, minimum: 0, maximum: 100),
        if (antialias != null) 'outline-antialias': antialias ? 'yes' : 'no',
        if (dashOffset != null) 'outline-dash-offset': _finite(dashOffset, minimum: 0, maximum: 2000),
        if (dashes != null) 'outline-dash-info': '${dashes.length} ${dashes.map((value) => _finite(value, minimum: 0, maximum: 2000)).join(' ')}',
      }),
    ),
  );
}

/// Quotes binary resource bytes using unambiguous three-digit octal escapes.
String _quoteBytes(List<int> bytes) => '"${bytes.map((value) => '\\${value.toRadixString(8).padLeft(3, '0')}').join()}"';

/// Validates configuration symbols before inserting them into source text.
String _identifier(String value) {
  if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9_-]*$').hasMatch(value)) {
    throw ArgumentError.value(value, 'identifier');
  }
  return value;
}

/// Validates caller-supplied numeric settings without clamping silently.
String _finite(double value, {double minimum = -double.maxFinite, double maximum = double.maxFinite}) {
  if (!value.isFinite || value < minimum || value > maximum) {
    throw ArgumentError.value(value, 'value');
  }
  return value.toString();
}
