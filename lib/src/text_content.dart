part of 'package:xcfkit/src/text.dart';

/// One inline Pango element, retaining attributes unknown to the host adapter.
final class XcfTextSpan {
  /// Original element name, usually `span`, `b`, `i`, `u`, `s`, or `tt`.
  final String name;

  /// Attributes in source order; values have XML entities decoded.
  final Map<String, String> attributes;

  /// Creates an immutable span without interpreting its layout semantics.
  XcfTextSpan({this.name = 'span', Map<String, String> attributes = const {}}) : attributes = Map.unmodifiable(attributes) {
    if (!_xmlName.hasMatch(name) || attributes.length > 1000 || attributes.keys.any((name) => !_xmlName.hasMatch(name))) {
      throw ArgumentError('Invalid markup name');
    }
    attributes.values.forEach(_validateXmlCharacters);
  }
}

/// An inline style with its full outer-to-inner nesting retained.
///
/// Getters expose the innermost explicit setting. Relative sizes and shorthand
/// font descriptions remain unresolved; [spans] retains their full context.
final class XcfTextStyle {
  /// Original nested elements, needed for relative size/rise interpretation.
  final List<XcfTextSpan> spans;

  /// Creates a style without font lookup or glyph layout.
  XcfTextStyle({List<XcfTextSpan> spans = const []}) : spans = List.unmodifiable(spans) {
    if (spans.length > 63) {
      throw ArgumentError('Too many nested text spans');
    }
  }

  /// Font description or GIMP markup font alias.
  String? get font => _attribute(['font', 'font_desc']);

  /// Explicit family, or monospace from the `tt` convenience tag.
  String? get family => _attribute(['font_family', 'face'], shorthand: {'tt': 'monospace'});

  /// Raw Pango size token (1024ths of a point, points, percentage or keyword).
  String? get size => _attribute(['font_size', 'size'], shorthand: {'big': 'larger', 'small': 'smaller'});

  /// Weight token or number, including `b` shorthand.
  String? get weight => _attribute(['font_weight', 'weight'], shorthand: {'b': 'bold'});

  /// Slant token, including `i` shorthand.
  String? get slant => _attribute(['font_style', 'style'], shorthand: {'i': 'italic'});

  /// Variant such as small-caps.
  String? get variant => _attribute(['font_variant', 'variant']);

  /// Font width/stretch token.
  String? get stretch => _attribute(['font_width', 'width', 'font_stretch', 'stretch']);

  /// Foreground color spelling, without color-name lookup or conversion.
  String? get foreground => _attribute(['foreground', 'fgcolor', 'color']);

  /// Background color spelling.
  String? get background => _attribute(['background', 'bgcolor']);

  /// Foreground alpha token (integer or percentage).
  String? get alpha => _attribute(['alpha', 'fgalpha']);

  /// Underline token, including `u` shorthand.
  String? get underline => _attribute(['underline'], shorthand: {'u': 'single'});

  /// Whether strikethrough is explicitly requested, or null if unspecified.
  bool? get strikethrough {
    final String? value = _attribute(['strikethrough'], shorthand: {'s': 'true'});
    if (value == null) {
      return null;
    }
    if (!['true', 'false', '1', '0', 'yes', 'no'].contains(value)) {
      throw const XcfFormatException('Invalid Pango strikethrough value');
    }
    return ['true', '1', 'yes'].contains(value);
  }

  /// Baseline shift in Pango units when explicitly numeric.
  int? get rise => _integer(['rise']);

  /// Extra character spacing in Pango units (1/1024 point).
  int? get letterSpacing => _integer(['letter_spacing']);

  /// OpenType feature expression passed to Pango.
  String? get fontFeatures => _attribute(['font_features']);

  /// Inline language identifier.
  String? get language => _attribute(['lang']);

  /// Adds explicit overrides as an inner span, preserving unknown ancestors.
  XcfTextStyle copyWith({
    String? font,
    String? family,
    String? size,
    String? weight,
    String? slant,
    String? variant,
    String? stretch,
    String? foreground,
    String? background,
    String? alpha,
    String? underline,
    bool? strikethrough,
    int? rise,
    int? letterSpacing,
    String? fontFeatures,
    String? language,
    Map<String, String> attributes = const {},
  }) => XcfTextStyle(
    spans: [
      ...spans,
      XcfTextSpan(
        attributes: {
          ...attributes,
          'font_desc': ?font,
          'font_family': ?family,
          'size': ?size,
          'weight': ?weight,
          'style': ?slant,
          'variant': ?variant,
          'stretch': ?stretch,
          'foreground': ?foreground,
          'background': ?background,
          'alpha': ?alpha,
          'underline': ?underline,
          if (strikethrough != null) 'strikethrough': strikethrough ? 'true' : 'false',
          if (rise != null) 'rise': rise.toString(),
          if (letterSpacing != null) 'letter_spacing': letterSpacing.toString(),
          'font_features': ?fontFeatures,
          'lang': ?language,
        },
      ),
    ],
  );

  /// Resolves aliases from inner spans first, retaining convenience-tag scope.
  String? _attribute(List<String> names, {Map<String, String> shorthand = const {}}) {
    for (final XcfTextSpan span in spans.reversed) {
      for (final MapEntry<String, String> attribute in span.attributes.entries.toList().reversed) {
        if (names.contains(attribute.key)) {
          return attribute.value;
        }
      }
      if (shorthand.containsKey(span.name)) {
        return shorthand[span.name];
      }
    }
    return null;
  }

  /// Validates a numeric inline option without converting its unit.
  int? _integer(List<String> names) {
    final String? value = _attribute(names);
    if (value == null) {
      return null;
    }
    final int? result = int.tryParse(value);
    if (result == null) {
      throw const XcfFormatException('Invalid numeric Pango attribute');
    }
    return result;
  }
}

/// A UTF-16 range sharing one inline style, matching Dart String indexing.
final class XcfTextStyleRun {
  /// Inclusive code-unit start and range length.
  final int start;

  /// Range length in UTF-16 code units.
  final int length;

  /// Nested markup style for this range.
  final XcfTextStyle style;

  /// Creates a style range; its bounds are validated by [XcfTextContent].
  const XcfTextStyleRun({required this.start, required this.length, required this.style});
}

/// Editable text contents, analogous to the semantic text models of other kits.
final class XcfTextContent {
  /// Plain text with XML entities decoded and GIMP's newline spelling retained.
  final String text;

  /// Ordered, non-overlapping UTF-16 style ranges; gaps use the base options.
  final List<XcfTextStyleRun> styleRuns;

  /// Layer-wide typography and paragraph options.
  final XcfTextOptions options;

  /// GIMP 3 markup font aliases and their complete resource metadata.
  final Map<String, XcfTextFont> fonts;

  /// Untouched source markup, retained until contents or styles change.
  final String? _originalMarkup;

  /// Creates contents without rendering or inventing font/resource mappings.
  XcfTextContent({required String text, List<XcfTextStyleRun> styleRuns = const [], XcfTextOptions? options, Map<String, XcfTextFont> fonts = const {}})
    : this._(text: text, styleRuns: styleRuns, options: options ?? XcfTextOptions(), fonts: fonts);

  /// Creates a decoded snapshot with optional original markup.
  XcfTextContent._({required this.text, required List<XcfTextStyleRun> styleRuns, required this.options, required Map<String, XcfTextFont> fonts, this._originalMarkup})
    : styleRuns = List.unmodifiable(styleRuns),
      fonts = Map.unmodifiable(fonts) {
    if (text.length > 16 * 1024 * 1024 || styleRuns.length > 100000) {
      throw ArgumentError('Text contents exceed the limit');
    }
    _validateXmlCharacters(text);
    int end = 0;
    for (final XcfTextStyleRun run in styleRuns) {
      if (run.start < end || run.length < 0 || run.start + run.length > text.length || _splitsSurrogate(text, run.start) || _splitsSurrogate(text, run.start + run.length)) {
        throw ArgumentError('Invalid UTF-16 text style range');
      }
      end = run.start + run.length;
    }
  }

  /// Replaces contents, validating existing ranges against any replacement text.
  XcfTextContent copyWith({String? text, List<XcfTextStyleRun>? styleRuns, XcfTextOptions? options, Map<String, XcfTextFont>? fonts}) => XcfTextContent._(
    text: text ?? this.text,
    styleRuns: styleRuns ?? this.styleRuns,
    options: options ?? this.options,
    fonts: fonts ?? this.fonts,
    originalMarkup: text == null && styleRuns == null ? _originalMarkup : null,
  );

  /// Returns the inline style at a Dart string offset, or null for base styling.
  XcfTextStyle? styleAt(int offset) => styleRuns.where((run) => offset >= run.start && offset < run.start + run.length).firstOrNull?.style;

  /// Resolves an inline GIMP font alias without consulting installed fonts.
  XcfTextFont? fontAt(int offset) {
    final String? reference = styleAt(offset)?.font;
    return reference == null ? options.font : fonts[reference] ?? XcfTextFont.named(reference, modern: false);
  }

  /// Encodes nested styles without flattening relative sizes or unknown tags.
  String toMarkup() {
    if (_originalMarkup != null) {
      return _originalMarkup;
    }
    final StringBuffer output = StringBuffer('<markup>');
    int position = 0;
    for (final XcfTextStyleRun run in styleRuns) {
      output.write(_xmlEscape(text.substring(position, run.start)));
      for (final XcfTextSpan span in run.style.spans) {
        output.write('<${span.name}');
        for (final MapEntry<String, String> attribute in span.attributes.entries) {
          output.write(' ${attribute.key}="${_xmlEscape(attribute.value)}"');
        }
        output.write('>');
      }
      output.write(_xmlEscape(text.substring(run.start, run.start + run.length)));
      for (final XcfTextSpan span in run.style.spans.reversed) {
        output.write('</${span.name}>');
      }
      position = run.start + run.length;
    }
    output.write(_xmlEscape(text.substring(position)));
    output.write('</markup>');
    return output.toString();
  }
}

/// Pull-parses Pango markup with explicit depth/count limits and no DTD support.
XcfTextContent _textContent(XcfText source) {
  final String? markup = source.markup;
  if (markup == null) {
    return XcfTextContent(text: source.text ?? '', options: source.options);
  }
  if (markup.length > 16 * 1024 * 1024) {
    throw const XcfFormatException('Markup exceeds the limit');
  }
  final StringBuffer text = StringBuffer();
  final List<XcfTextSpan> stack = [];
  final List<XcfTextStyleRun> runs = [];
  int events = 0;
  try {
    for (final XmlEvent event in parseEvents('<xcfkit>$markup</xcfkit>', entityMapping: const _MarkupEntities(), validateNesting: true, validateDocument: true)) {
      if (++events > 100000) {
        throw const XcfFormatException('Too many markup events');
      }
      if (event is XmlStartElementEvent) {
        if (stack.length >= 65 || event.attributes.length > 1000) {
          throw const XcfFormatException('Markup nesting or attributes exceed the limit');
        }
        final Map<String, String> attributes = {};
        for (final XmlEventAttribute attribute in event.attributes) {
          if (attributes.containsKey(attribute.name)) {
            throw const XcfFormatException('Duplicate markup attribute');
          }
          attributes[attribute.name] = attribute.value;
        }
        if (!event.isSelfClosing) {
          stack.add(XcfTextSpan(name: event.name, attributes: attributes));
        }
      } else if (event is XmlEndElementEvent) {
        stack.removeLast();
      } else if (event is XmlTextEvent || event is XmlCDATAEvent) {
        final String value = event is XmlTextEvent ? event.value : (event as XmlCDATAEvent).value;
        _validateXmlCharacters(value);
        if (value.isNotEmpty) {
          runs.add(
            XcfTextStyleRun(
              start: text.length,
              length: value.length,
              style: XcfTextStyle(spans: stack.skip(1).where((span) => span.name != 'markup').toList()),
            ),
          );
          text.write(value);
        }
      } else if (event is! XmlCommentEvent) {
        throw const XcfFormatException('Markup declarations and DTDs are not supported');
      }
    }
  } on XmlException {
    throw const XcfFormatException('Malformed Pango markup');
  } on ArgumentError {
    throw const XcfFormatException('Invalid Pango markup contents');
  }
  return XcfTextContent._(text: text.toString(), styleRuns: runs, options: source.options, fonts: source.markupFonts, originalMarkup: markup);
}

/// Strict XML entities; unresolved references and invalid characters stay errors.
final class _MarkupEntities extends XmlDefaultEntityMapping {
  /// Uses only XML's five predefined entities and numeric character references.
  const _MarkupEntities() : super.xml();

  @override
  String decode(String input) {
    final StringBuffer result = StringBuffer();
    int position = 0;
    while (true) {
      final int start = input.indexOf('&', position);
      if (start < 0) {
        result.write(input.substring(position));
        break;
      }
      result.write(input.substring(position, start));
      final int end = input.indexOf(';', start + 1);
      if (end < 0) {
        throw const XcfFormatException('Unterminated markup entity');
      }
      final String? value = decodeEntity(input.substring(start + 1, end));
      if (value == null) {
        throw const XcfFormatException('Unknown markup entity');
      }
      result.write(value);
      position = end + 1;
    }
    final String decoded = result.toString();
    _validateXmlCharacters(decoded);
    return decoded;
  }
}

/// XML-compatible names used when generating markup from edited spans.
final RegExp _xmlName = RegExp(r'^[A-Za-z_][A-Za-z0-9_.:-]*$');

/// Escapes text and attribute values without interpreting markup.
String _xmlEscape(String value) => const HtmlEscape().convert(value);

/// Rejects XML control characters and unpaired UTF-16 surrogate code units.
void _validateXmlCharacters(String value) {
  for (int i = 0; i < value.length; i++) {
    final int unit = value.codeUnitAt(i);
    if (unit >= 0xd800 && unit <= 0xdbff && i + 1 < value.length && value.codeUnitAt(i + 1) >= 0xdc00 && value.codeUnitAt(i + 1) <= 0xdfff) {
      i++;
    } else if (unit != 9 && unit != 10 && unit != 13 && (unit < 32 || unit >= 0xd800 && unit <= 0xdfff || unit == 0xfffe || unit == 0xffff)) {
      throw ArgumentError('Invalid XML character');
    }
  }
}

/// Detects UTF-16 range boundaries that would split a supplementary character.
bool _splitsSurrogate(String value, int offset) =>
    offset > 0 && offset < value.length && value.codeUnitAt(offset - 1) >= 0xd800 && value.codeUnitAt(offset - 1) <= 0xdbff && value.codeUnitAt(offset) >= 0xdc00 && value.codeUnitAt(offset) <= 0xdfff;
