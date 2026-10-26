<p align="center">
  <img src="screenshots/overview.png" alt="XcfKit package illustration" width="180">
</p>

# XcfKit

Read, inspect, edit, and write layered GIMP XCF documents in Dart.

XcfKit exposes layers, groups, masks, channels, exact pixel samples, and document metadata without launching GIMP. It is written in pure Dart, with no Flutter, native, or GEGL dependency. Compression uses [ZCodec](https://pub.dev/packages/zcodec); bounded Pango markup parsing uses [xml](https://pub.dev/packages/xml). The optional whole-file compression entry point also uses ZCodec for GZIP, BZIP2 and XZ/LZMA2, including integrity checks.

## Quick start

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:xcfkit/xcfkit.dart';

final XcfDocument document = XcfCodec.decode(
  await File('input.xcf').readAsBytes(),
);

print('${document.width} × ${document.height}');
for (final XcfLayer layer in document.layers) {
  print('${layer.visible ? 'visible' : 'hidden'}: ${layer.name}');
}

final Uint8List encoded = XcfCodec.encode(document);
await File('output.xcf').writeAsBytes(encoded);
```

`const XcfDocumentCodec()` also implements the standard `dart:convert` `Codec<XcfDocument, List<int>>` interface.

## Create or edit layers

```dart
final XcfLayer layer = XcfLayer.rgba(
  name: 'Red pixel',
  width: 1,
  height: 1,
  pixels: [255, 0, 0, 255],
);
final XcfDocument document = XcfDocument(
  width: 1,
  height: 1,
  layers: [layer],
);

final XcfLayer moved = layer.copyWith(
  properties: layer.properties.replacing(
    XcfProperty.offsets(x: 20, y: -5),
  ),
);
final XcfDocument edited = document.copyWith(layers: [moved]);
```

Editing helpers return new objects. Replace the corresponding entry in `document.layers` before encoding. `document.layerTree` reconstructs nested groups; the stored layer list remains top-first and depth-first. Reordering groups also requires updating their `itemPath` properties.

## Text, paths, effects, and floating selections

`layer.text` provides the saved configuration and editable text models:

- `text.options`: font resource, size/unit, antialiasing, hinting, kerning, language, direction, alignment, indent, line/letter spacing, fill color, text box, transformation, and outline settings.
- `text.content`: plain text, UTF-16 style ranges, nested Pango attributes, and inline font references. Styles expose weight, slant, size, colors, underline, strikethrough, rise, spacing, and OpenType features. Unknown attributes and resource fields remain available.
- `layer.raster`: the existing saved pixels, usable without laying out the text again.

```dart
final XcfText text = layer.text!;
final XcfText edited = text.withOptions(text.options.copyWith(
  justification: 'center',
  lineSpacing: 3,
  letterSpacing: 0.5,
));

final XcfTextContent content = text.content;
for (final XcfTextStyleRun run in content.styleRuns) {
  print('${run.start}:${run.length} ${run.style.weight}');
}
```

Use `withContent(content.copyWith(...))` to change styled content; style `copyWith`
adds overrides while retaining nested relative styles and unknown attributes.
`withText` replaces the content and clears inline markup. Apply edited metadata
using `layer.withText(text, renderedRaster: ...)`: the host supplies the updated
raster in the original sample layout and precision. These APIs do not resolve
fonts, lay out glyphs, or render. Choose a compatible document version when
adding newer resource or outline metadata; see [the technical reference](docs/XCF.md).

`document.paths` decodes Bézier strokes and control points from modern vectors,
legacy `PROP_VECTORS`, and old `PROP_PATHS` versions 1–3. Use
`document.withPaths(paths)` to replace them; this upgrades older documents to
XCF 18. Unedited legacy payloads retain their original bytes.

Effect arguments are named rather than indexed:

```dart
final XcfEffect edited = effect.withArgument(
  XcfFilterArgument.floating('brightness', 0.45),
);
```

Integers, booleans, floats, strings, enums, serialized configurations, colors,
and embedded gradients have typed access. Colors retain their encoded pixel and
ICC profile; gradient segments retain positions, colors and interpolation
identifiers. Unknown argument kinds retain their raw payload. Replace the effect
in its layer before encoding; the operation still needs GEGL or an equivalent
renderer to produce pixels.

`document.floatingSelection` identifies the floating layer and its destination
layer, mask, or channel by list indices. Encoding rebuilds attachment pointers,
including selections inside groups. Update these indices when reordering items;
anchoring a selection requires compositing in the host application.

`layer.link` and `layer.transform` expose linked-source metadata and its matrix.
They never open the referenced file or refresh the saved raster.

## Vector layers and document metadata

`layer.vectorLayer` exposes the path tattoo, fill/stroke colors and pattern
references, antialiasing, width, caps, joins, miter limit and dash lengths.
`vectorLayer.resolvePath(document)` resolves its geometry. Apply edits with
`layer.withVectorLayer(parameters, renderedRaster: ...)`; the host supplies the
new raster. Unknown suffix bytes survive typed edits.

Document helpers expose `guides`, `samplePoints`, `resolution`, `unitId` and
`userUnit`, with matching `with...` methods. `document.configuration(name)`
reads configuration parasites such as `gimp-image-grid`.

For effects, `argument.configuration` provides structured GimpConfig access,
including nested lists, binary strings and repeated fields. Edits retain source
order and unrelated comments. Repeated curve fields are **context-sensitive**:

```dart
final XcfConfiguration config = effect.argument('config')!.configuration!;
final XcfCurve curve = XcfCurve(config.nested('curve', occurrence: 0)!);
print(curve.points); // First curve, usually the value channel.
```

`withField`/`withNested` replace one occurrence in place; the default is the last
occurrence. Inspect `names` to retain channel context. `XcfCurve.withPoints`
requires the host's updated sample table; the kit does not interpolate effects.

## Write diagnostics and large files

`XcfCodec.preflight(document)` returns a `minimumVersion`, uncompressed sample
count and diagnostics with stable codes, severity and document paths. It finds
known compatibility and structural problems without reading lazy pixels.
`canWrite` does not guarantee I/O success, valid deferred tiles or the final
compressed size. The report never changes the document or drops features.

The regular `decode`/`encode` APIs remain in-memory. For bounded file access:

```dart
import 'package:xcfkit/xcfkit_io.dart';

final XcfFileInput input = XcfFileInput('input.xcf');
final XcfFileOutput output = XcfFileOutput('output.tmp.xcf');
int? length;
try {
  final XcfDocument document = XcfCodec.open(input);
  final Uint8List region = document.layers.first.raster!.readRegion(
    x: 0, y: 0, width: 64, height: 64,
  );
  length = XcfCodec.encodeTo(document, output);
} finally {
  input.close();
  output.close(length: length);
}
```

`open` indexes metadata and tile pointers. `readRegion` decodes intersecting tiles;
`encodeTo` emits tiles and patches a seekable destination. Keep input open and
unchanged while lazy rasters are used; use a separate output file. Reading
`raster.bytes` materializes the whole raster each time. File adapters are
synchronous; use an isolate when integrating with a UI. The portable core accepts
custom `XcfInput`/`XcfOutput` implementations without importing `dart:io`.

## Optional compressed files

Import `package:xcfkit/xcfkit_compression.dart` for `XcfWrappedCodec` and
`XcfEnvelope`. Signature detection supports plain XCF, `.xcf.gz`, `.xcf.bz2`
and `.xcf.xz`; decoding checks checksums, expanded size and the XZ dictionary
limit. `encode(document, envelope: XcfEnvelope.gzip)` writes an envelope.

These convenience APIs are in-memory. Compressed envelopes need decompression to
a seekable source before lazy XCF access. All envelopes use ZCodec; XZ encoding
compresses LZMA2 chunks and stores incompressible chunks. Tile compression is an
independent setting.

## Pixels and previews

`layer.raster.bytes` retains interleaved, straight-alpha samples at the document's original precision. Multi-byte samples are big-endian, including floating-point values outside `[0, 1]`.

For an explicitly lossy RGBA8 layer preview:

```dart
final XcfLayer layer = document.layers.firstWhere(
  (layer) => !layer.isGroup && layer.raster != null,
);
final Uint8List rgba = XcfPixels.rgba8(document, layer);
```

This preserves the source transfer encoding and color profile. It does not apply ICC conversion, opacity, masks, blend modes, or effects. XCF has no standard full-document merged preview to extract: an application must composite the layers itself.

## Compatibility

- Read and write RGB, grayscale, indexed color, layers, groups, masks, channels, and selections.
- Preserve 8/16/32-bit integer and 16/32/64-bit floating-point samples, including linear and perceptual encodings.
- Decode and encode uncompressed, XCF RLE, and zlib tiles, with 32-bit or 64-bit file pointers.
- Preserve ICC profiles and opaque metadata; edit text configuration, Bézier paths, and named GEGL arguments.
- Read and write floating-selection attachments with relocated file pointers.
- Reject unsupported versions, unsafe pointer relocation, and configured resource-limit violations explicitly.

Editing text or effect parameters does **not** implement their rendering. XcfKit provides document data and editing APIs; composition remains the host application's responsibility. See [the support matrix and limits](docs/XCF.md).

## Validation

The external corpus contains **833 XCF inputs from six GitHub projects and the XCF Test Suite host**. Of these, 830 pass semantic decode/write/read checks; two known corrupt files and an empty upstream placeholder are rejected. The original 721 files and the 109 additional GIMP resource files were reconstructed and compared in GIMP 3.2.2, including exact layer samples and composed-image hashes.

Twenty-three small, original GIMP-generated fixtures are included for offline regression tests. Eight semantic edits (plain/styled text, text options, three path representations, brightness and color) were independently performed in GIMP and compared with the XcfKit results, including GIMP-rendered composite hashes. An additional 54 newly created files cover every precision/compression combination and were reopened in GIMP with exact sample comparisons. Two additional gradient fixtures were authored with GIMP 3.3.1 development: both rewrites and a semantic edit match GIMP's exact rendered composite. Their [separate provenance and reproduction steps](test/fixtures/gimp-development/README.md) pin the build. Embedded gradients are a development-branch feature; GIMP 3.2.2 cannot interpret them despite their XCF 22 header. Eight further fixtures cover vector layers, curves, document metadata and compressed envelopes. Their rewrites and two semantic edits were compared with GIMP 3.3.1; see [advanced fixture provenance](test/fixtures/gimp-advanced/README.md). File tests also exercise offsets above 4 GiB and a progressive 1 GiB sample workload. These results establish the tested cases, not exhaustive compatibility with every GIMP feature or version.

```sh
dart pub get
dart analyze
dart test
dart test --platform node
python3 tool/fetch_corpus.py
dart run tool/check_corpus.dart --round-trip
```

See [corpus provenance and independent validation](test/corpus/README.md) and [contributing](CONTRIBUTING.md).
