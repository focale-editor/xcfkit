# XCF technical reference

This document describes how XcfKit represents GIMP data, which parts of XCF it supports, and the responsibilities that remain with the host application. For a task-oriented introduction, start with the [README](../README.md).

XcfKit is an independent Dart implementation of the [GIMP XCF specification](https://developer.gimp.org/core/standards/xcf/). The GIMP source tree, particularly [`app/xcf`](https://gitlab.gnome.org/GNOME/gimp/-/tree/master/app/xcf), is the authoritative format reference. No GIMP/GEGL implementation is bundled or required at runtime.

The default APIs read and write in-memory documents. `XcfCodec.open` instead indexes a random-access source and defers sample reads; `encodeTo` writes to a seekable destination one tile at a time. Both paths share the same binary codec. Composition, color management, font layout and effect execution belong to the host engine; their absence is an intentional package boundary.

Compression uses [ZCodec](https://pub.dev/packages/zcodec); bounded Pango markup parsing uses [xml](https://pub.dev/packages/xml). Neither dependency adds a rendering engine. The optional whole-file compression entry point also uses ZCodec for GZIP, BZIP2, and XZ/LZMA2, including integrity checks.

## Reading and writing documents

`XcfCodec.decode` reads a complete XCF byte stream into an in-memory `XcfDocument`. `XcfCodec.encode` writes that model back to bytes:

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:xcfkit/xcfkit.dart';

final Uint8List input = await File('input.xcf').readAsBytes();
final XcfDocument document = XcfCodec.decode(input);
final Uint8List output = XcfCodec.encode(
  document,
  options: const XcfWriteOptions(compression: XcfCompression.zlib),
);
await File('output.xcf').writeAsBytes(output, flush: true);
```

`XcfCodec.matches(bytes)` checks the plain XCF signature. Use the optional envelope API below for compressed files. `document.warnings` reports compatibility repairs made during decoding.

For integration with APIs based on `dart:convert`, `XcfDocumentCodec` implements `Codec<XcfDocument, List<int>>`:

```dart
import 'dart:convert';

final Codec<XcfDocument, String> xcfAsBase64 =
    const XcfDocumentCodec().fuse(base64);
final String encoded = xcfAsBase64.encode(document);
final XcfDocument decoded = xcfAsBase64.decode(encoded);
```

Construct `XcfDocumentCodec` with `readOptions` and `writeOptions` to configure both directions. These converters operate on complete files; they are not incremental input streams.

## Updating copy-based models

Editing methods such as `copyWith`, `withText`, and `withVectorLayer` return an updated layer. Replace its entry in the document's flat list before encoding:

```dart
XcfDocument replaceLayer(
  XcfDocument document, {
  required int index,
  required XcfLayer replacement,
}) {
  final List<XcfLayer> layers = List<XcfLayer>.of(document.layers);
  layers[index] = replacement;
  return document.copyWith(layers: layers);
}
```

For example, move a layer while retaining its other properties:

```dart
final XcfLayer layer = document.layers.first;
final XcfLayer moved = layer.copyWith(
  properties: layer.properties.replacing(
    XcfProperty.offsets(x: 20, y: -5),
  ),
);
final XcfDocument edited = replaceLayer(
  document,
  index: 0,
  replacement: moved,
);
```

Document-level helpers such as `withPaths`, `withGuides`, and `withConfiguration` already return a complete updated document.

`XcfDocument.layers` is topmost-first, with a group's children immediately after their parent. A child path such as `[2, 1, 0]` identifies a top-level group at index 2, its second child group, and that group's first child. Root layers may omit `PROP_ITEM_PATH`. Invalid paths and nesting beyond 256 levels are rejected.

Reordering groups also requires updating their `itemPath` properties. Floating-selection indices must follow any changes to the referenced layer or channel lists.

`XcfProperty` and `XcfParasite` expose read-only copies. Scalar accessors use the last occurrence, as GIMP does. Repeated effect arguments and other opaque records retain their source order. Encoding preserves payload bytes while reconstructing known file pointers, so output is semantically compared rather than expected to be byte-identical to its source.

Historical property lengths require special treatment: colormaps and custom units are walked according to their actual fields. GIMP 3.2 linked-layer properties can undercount a nonempty source string by four bytes; only this known short form is repaired. Longer link payloads retain opaque suffixes, with typed access rejecting unknown extensions. These repairs appear in `document.warnings`. The writer emits corrected lengths.

## Pixel and channel model

`layer.raster.bytes` retains interleaved, straight-alpha samples at the document's original precision. Multi-byte components are big-endian, including floating-point values outside `[0, 1]`. `document.precision` describes storage and transfer encoding; the shared `document.palette` supplies indexed colors. Masks and channels have their own `XcfRaster` and property lists.

For a lossy RGBA8 layer preview:

```dart
final XcfLayer layer = document.layers.firstWhere(
  (layer) => !layer.isGroup && layer.raster != null,
);
final Uint8List rgba = XcfPixels.rgba8(document, layer);
```

`XcfPixels.rgba8` expands each color model to straight RGBA8. It rounds integer scaling, clamps floating samples to `[0, 1]`, and maps NaN to zero for the preview only. It retains the source transfer encoding; displaying a linear-light buffer as sRGB without conversion is incorrect. Original raster bytes are unchanged.

The conversion does not apply ICC transforms, layer opacity, masks, blend modes, or effects. XCF has no standard full-document merged preview: the host must compose its layers.

For sample-level access without RGBA8 quantization:

```dart
final ByteData samples = ByteData.sublistView(layer.raster!.bytes);
final double firstComponent = XcfPixels.readSample(
  samples,
  0,
  document.precision,
);
```

`readSample` normalizes integers and preserves floating HDR and non-finite values without applying a transfer curve or color profile. The offset is in bytes. For indexed layers, read palette indices as bytes rather than treating them as normalized RGB values. Use `readRegion` for bounded access to lazy rasters.

## Editable text

`layer.text` provides both the saved configuration and editable text models:

- `text.options`: font resource, size/unit, antialiasing, hinting, kerning, language, direction, alignment, indent, line/letter spacing, fill color, text box, transformation, and outline settings.
- `text.content`: plain text, UTF-16 style ranges, nested Pango attributes, and inline font references. Styles expose weight, slant, size, colors, underline, strikethrough, rise, spacing, and OpenType features. Unknown attributes and resource fields remain available.
- `layer.raster`: saved pixels that can be displayed without laying out the text again.

Inspect styles or prepare new paragraph options:

```dart
final XcfText text = layer.text!;
final XcfText editedText = text.withOptions(
  text.options.copyWith(
    justification: 'center',
    lineSpacing: 3,
    letterSpacing: 0.5,
  ),
);
for (final XcfTextStyleRun run in text.content.styleRuns) {
  print('${run.start}:${run.length} ${run.style.weight}');
}
```

Use `withContent(content.copyWith(...))` to change styled content. Style `copyWith` adds overrides while retaining nested relative styles and unknown attributes. The host must render the result before applying it to a layer. Here, `updatedRaster` is an `XcfRaster` produced by the host in the original sample layout and precision:

```dart
final XcfLayer editedLayer = layer.withText(
  editedText,
  renderedRaster: updatedRaster,
);
final XcfDocument edited = replaceLayer(
  document,
  index: layerIndex,
  replacement: editedLayer,
);
```

Semantic accessors decode metadata on demand. Reading a document preserves opaque text, vectors, and effect payloads even if a typed accessor cannot interpret them. `XcfText` keeps comments and unknown configuration fields verbatim. `withText` deliberately removes Pango markup; it does not retain per-span styling. `XcfLayer.withText` applies a supplied rendered raster, updates its dimensions and optional offsets, and clears GIMP's modified-pixel flag. The caller is responsible for rendering, color encoding, and consistency between pixels and text.

Text APIs are format-specific, analogous to PsdKit's semantic text models rather than a Photoshop-to-GIMP typography mapping. `XcfTextOptions` exposes GIMP's defaults for absent fields, with environment-dependent font/language left null. Font references retain full names, family/style, PostScript identifiers and available matching metadata without loading fonts. Modern base font resources require XCF 19+ and encoded text colors XCF 14+. Outline fields are GIMP 3.2 metadata; the tested outline files still use an XCF 19 header. Preflight recognizes structured font resources but cannot infer compatibility from arbitrary unknown text configuration or a GIMP release number.

`XcfTextContent` ranges use UTF-16 code units, like Dart String indices, and reject boundaries splitting a surrogate pair. Styles keep outer-to-inner Pango spans: relative sizes and font descriptions are not resolved by the kit. Untouched markup remains verbatim; edited content is reserialized with unknown tags/attributes and font-resource fields retained. Early inline font records are normalized to `markupfont` records when content is rewritten. Fill colors expose either exact legacy RGBA numbers or modern encoded color bytes. Outline pattern names remain references; no external pattern is loaded.

## Paths and vector layers

`document.paths` decodes Bézier strokes and control points from modern vectors, legacy `PROP_VECTORS`, and old `PROP_PATHS` versions 1–3. Use `document.withPaths(paths)` to replace them; this upgrades older documents to XCF 18. Unedited legacy payloads retain their original bytes.

`layer.vectorLayer` exposes the path tattoo, fill/stroke colors and pattern references, antialiasing, width, caps, joins, miter limit, and dash lengths. `vectorLayer.resolvePath(document)` resolves its geometry. Apply changes with `layer.withVectorLayer(parameters, renderedRaster: updatedRaster)` and replace the layer in the document. The host supplies the rendered raster.

Vector fill/stroke styles and enum values stay numeric. Pattern references carry
name, collection ID and internal-resource flag; no pattern pixels are embedded.
The vector property has no stroke unit or dash-offset field: XcfKit exposes only
what XCF actually stores. Path tattoos must resolve uniquely. Unknown suffixes
are preserved by typed edits; the original property remains available.

## Layer effects and serialized configurations

`layer.effects` exposes GEGL operation names, versions, masks, properties, and named arguments. Change an argument by name rather than by its position:

```dart
final XcfEffect editedEffect = effect.withArgument(
  XcfFilterArgument.floating('brightness', 0.45),
);
final List<XcfEffect> effects = List<XcfEffect>.of(layer.effects);
effects[effectIndex] = editedEffect;
final XcfLayer editedLayer = layer.copyWith(effects: effects);
```

Place `editedLayer` back into the document before encoding. XcfKit retains effect parameters; GEGL or an equivalent host renderer must execute them.

Integers, booleans, floats, strings, enums, serialized configurations, colors, and embedded gradients have typed access. Gradient segments retain positions, colors, and interpolation identifiers.

GEGL numeric arguments are serialized as float32 even for double-valued GEGL parameters. Semantic access preserves that precision. Color arguments expose `XcfColor` (Babl encoding, pixel bytes and ICC profile); embedded version-1 gradients expose `XcfGradient` and its segments. Unlike raster samples, Babl color bytes are native-format data without a portable byte-order marker. The kit preserves them without guessing; `XcfColor.rgba8` creates an endian-independent representation. Unknown argument types return null from `value`, with raw `data` still accessible. Null color/gradient resources also return null.

For configuration arguments, `argument.configuration` exposes structured GimpConfig values, including nested lists, binary strings, and repeated fields. Edits retain source order and unrelated comments:

```dart
final XcfConfiguration config = effect.argument('config')!.configuration!;
final XcfCurve curve = XcfCurve(config.nested('curve', occurrence: 0)!);
print(curve.points); // First curve, usually the value channel.
```

`withField` and `withNested` replace one occurrence in place; the default is the last occurrence. Inspect `names` to retain channel context.

`XcfConfiguration` retains repeated fields and assignment order. A curves
configuration alternates `channel` and `curve`; these are not a dictionary of
unique keys. Select an explicit `occurrence` when editing a particular channel.
`XcfCurve` exposes point kinds and inactive legacy coordinates, plus the saved
sample array. Its editing API requires replacement samples from the host so no
second interpolation engine is introduced.

## Document metadata and linked resources

Document helpers expose `guides`, `samplePoints`, `resolution`, `unitId`, and `userUnit`, with matching `with...` methods. `document.configuration(name)` reads configuration parasites such as `gimp-image-grid`; `withConfiguration` replaces their structured values while retaining unrelated metadata.

Custom units use five strings before XCF 21 and three thereafter. Changing a
header across that boundary requires reserializing the unit with `withUserUnit`.
Guide orientation is XCF-specific (horizontal=1, vertical=2), unlike GIMP's public
enum. Off-canvas guides require XCF 15 for compatible interpretation.

`document.iccProfile` exposes the embedded `icc-profile` parasite without performing color conversion. Other application parasites and unknown XML remain available as raw bytes.

`layer.link` and `layer.transform` expose linked-source metadata, flags, dimensions, and its transformation matrix. They never open the referenced file or refresh the saved raster.

## Floating selections

`XcfFloatingSelection.layerIndex` and `targetIndex` refer to the flat layer list (or the channel list for a channel target). They must be updated after reordering or removing items. Unlike older descriptions of XCF, GIMP 3 can save the floating layer inside a group instead of first in the flat list. GIMP may normalize layer order and group membership when loading that file; XcfKit preserves file order and item paths. The original raw `PROP_FLOATING_SELECTION` is retained for inspection, but encoding uses the resolved model to reconstruct its pointer. `copyWith(removeFloatingSelection: true)` removes the association and raw property; it does not anchor pixels or convert a grayscale floating layer into an RGB layer.

## Write diagnostics

Use `XcfCodec.preflight` to collect known compatibility issues before opening an output destination:

```dart
final XcfWriteReport report = XcfCodec.preflight(document);
print('Minimum known version: ${report.minimumVersion}');
print('Uncompressed sample bytes: ${report.sampleBytes}');
for (final XcfWriteDiagnostic diagnostic in report.diagnostics) {
  print('${diagnostic.severity.name} ${diagnostic.code} '
      '${diagnostic.path}: ${diagnostic.message}');
}
if (!report.canWrite) {
  throw StateError('Resolve the reported XCF write errors before saving.');
}
```

Diagnostic codes, severity, and document paths are available separately from messages. Applications should use the codes for localization and policy decisions.

`XcfCodec.preflight` gathers static errors and warnings without reading pixels:
geometry, raster layouts, nested masks, group paths, attachment references,
metadata sizes/layouts, known version requirements, vector path resolution,
opaque relocation risk and obvious output-budget violations. `minimumVersion`
is a known-feature lower bound. Unknown fields and exact compressed sizes can
require more; this is not a GIMP release compatibility guarantee. Reports do not
mutate or downgrade documents. Deferred corruption and I/O failures remain write-
time errors; use a temporary destination for replacing an existing file.

## Lazy and progressive storage

`XcfInput` provides fixed-length synchronous random-access reads. `XcfOutput`
accepts synchronous writes at absolute offsets, including pointer patches. Core
interfaces remain usable on Dart VM, JavaScript and Wasm. Optional
`xcfkit_io.dart` supplies file adapters with a bounded read cache.

`XcfCodec.open` parses structure and tile tables, retaining the source through
lazy `XcfRaster` providers. Tile indices count against the metadata budget.
`readRegion` requests only intersecting 64×64 tiles and returns original sample
bytes. Corrupt compressed data fails when that tile is requested. The source
must remain open and unchanged; closing it invalidates subsequent raster reads.
Lazy `bytes` accesses materialize again each time and obey the per-read ceiling.
There is no hidden full-raster cache.

`encodeTo` consumes region tiles and writes them immediately to a seekable sink.
Metadata and tile-pointer tables remain in memory, but full encoded output and
full decoded rasters need not. Never write into a lazy source's file. Operations
are synchronous; run them in an isolate when a UI must remain responsive.
Envelopes are sequential compression formats and cannot be sought directly;
the optional wrapper API currently materializes the unwrapped XCF in memory.

For native file access, the following example reads one pixel and rewrites the document into a separate temporary file:

```dart
import 'dart:typed_data';

import 'package:xcfkit/xcfkit_io.dart';

final XcfFileInput input = XcfFileInput('input.xcf');
try {
  final XcfDocument document = XcfCodec.open(input);
  final XcfLayer layer = document.layers.firstWhere(
    (layer) => !layer.isGroup && layer.raster != null,
  );
  final Uint8List pixel = layer.raster!.readRegion(
    x: 0,
    y: 0,
    width: 1,
    height: 1,
  );
  print('${pixel.length} original sample bytes');

  final XcfFileOutput output = XcfFileOutput('output.tmp.xcf');
  int? length;
  try {
    length = XcfCodec.encodeTo(document, output);
  } finally {
    output.close(length: length);
  }
} finally {
  input.close();
}
```

Both handles remain caller-owned. Closing the output with the returned length truncates it to the encoded file size. Replace an existing destination only after a successful write; clean up partial temporary files on failure. The portable core accepts custom `XcfInput` and `XcfOutput` implementations without importing `dart:io`.

## Optional compressed files

Import `package:xcfkit/xcfkit_compression.dart` for `XcfWrappedCodec` and `XcfEnvelope`. Signature detection supports plain XCF, `.xcf.gz`, `.xcf.bz2`, and `.xcf.xz`:

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:xcfkit/xcfkit_compression.dart';

final Uint8List input = await File('input.xcf.gz').readAsBytes();
final XcfEnvelope? envelope = XcfWrappedCodec.detect(input);
final XcfDocument document = XcfWrappedCodec.decode(input);
final Uint8List output = XcfWrappedCodec.encode(
  document,
  envelope: envelope ?? XcfEnvelope.none,
);
await File('output.xcf.gz').writeAsBytes(output, flush: true);
```

`decode` checks integrity, expanded size, and the XZ dictionary limit. `unwrap` returns plain XCF bytes; `wrap` adds an envelope without changing the inner file. All envelope codecs use ZCodec. XZ output compresses LZMA2 chunks and stores incompressible chunks; tile compression is an independent setting.

These convenience APIs are in-memory. Envelopes need decompression to a seekable source before lazy XCF access. Importing only `xcfkit.dart` does not include the optional envelope API.

## Support matrix

| Area | Behavior |
| --- | --- |
| XCF versions | Parses layouts 0–3 and 7–26; rejects development versions 4–6 and unknown future versions. Coverage of a header version does not imply semantic support for every associated feature. |
| Pre-12 high precision | Rejected: development files stored samples in an unspecified host byte order. |
| Pointer widths | Big-endian 32-bit before version 11, 64-bit thereafter. Values outside the exact JavaScript integer range are rejected. |
| Color models | RGB, grayscale, indexed with a shared palette. |
| Precision | u8/u16/u32, IEEE binary16/binary32/binary64; linear, profile-transfer, and perceptual identifiers are retained. |
| Tiles | Full-resolution 64×64 tiles, including partial edge tiles and empty levels. Unused lower-resolution levels are ignored and omitted on write. |
| Compression | Raw, byte-plane XCF RLE, independent zlib streams. The reserved fractal mode is rejected. |
| Layers | Names, dimensions, offsets, visibility, opacity, exact samples, property payloads. |
| Groups | Flat depth-first storage and validated item paths; `layerTree` provides a nested view. Cached group pixels may be absent. |
| Masks/channels | Samples and properties; active selections are channels with `isSelection == true`. |
| Blend/composite modes | Numeric identifiers and spaces are preserved. No translation to Flutter blend modes is implied. |
| Color profiles | The `icc-profile` parasite is exposed; no profile conversion is performed. |
| Text | Exposes global font/paragraph/box/transform/outline options, plain text, Pango style ranges, and font resources. Edits preserve unknown configuration and nested style context. Applying an edit requires a caller-rendered raster. No font resolution, markup layout or rendering. |
| Paths | Typed Bézier strokes/control points for modern vectors and legacy `PROP_VECTORS` (25), including extra tablet axes. Edits write modern XCF 18+ vectors. Old `PROP_PATHS` (23), versions 1–3, is also decoded, including multi-stroke paths and signed integer coordinates. |
| GEGL effects | Names, operation/version, masks and repeated properties are retained. Typed int/bool/float/string/enum/config/uint/color/gradient arguments; unknown kinds stay raw. Arguments are replaced by name. No execution. |
| Vector/linked layers | Typed vector path tattoos, fill/stroke paints, patterns, widths, caps, joins and dashes; unknown suffix bytes survive edits. Linked sources/flags/dimensions and matrices are typed. External resources are never fetched or opened. |
| Document metadata | Guides, legacy/modern sample points including reserved words, resolution, built-in/custom units, and structured configuration parasites. Unknown XML and application parasites retain raw bytes. |
| Serialized configurations | Bounded nested GimpConfig values, binary strings, source spans and repeated assignments. Typed curve points and saved sample arrays; no interpolation. |
| Floating selections | Layer, mask and channel attachments are resolved to list indices and relocated on write. Group children are supported. Anchoring/compositing is not performed. |
| Unknown properties | Retained on read. Writing identifiers above the known range (49) is rejected because arbitrary payloads may contain file pointers. |
| File-level compression | Optional `xcfkit_compression.dart` detects and reads/writes GZIP, BZIP2 and XZ with limits/checksums. XZ checks include portable CRC64 and SHA-256 verification; unknown checks are rejected. ZCodec supplies every envelope codec; XZ output uses LZMA2 compression (stored chunks when smaller) with CRC32. In-memory envelopes are separate from progressive plain-XCF I/O. |

New documents default to XCF 13. `withPaths` upgrades to at least XCF 18; a caller must select a suitable version when adding effects or newer text/resource metadata. Encoding rejects incompatible version/feature combinations rather than discarding the feature. Opaque metadata supplied by a caller must conform to the selected XCF version. A header version is not a GIMP feature compatibility level: the development gradient argument kind uses XCF 22, but GIMP 3.2.2 has no reader for that kind.

## Resource limits

Default `XcfReadOptions` limits:

| Resource | Default |
| --- | --- |
| Input bytes | 512 MiB |
| Pixels in any drawable/canvas | 100 million |
| Eager sample total / lazy per-request allocation | 512 MiB |
| Cumulative metadata payloads and tile indices | 64 MiB |
| Individual UTF-8 strings | 1 MiB |
| Layers/channels/effects/vectors | 10,000 |
| Property records | 100,000 |
| Recursive effect/mask depth | 64 |

Decoded-byte limits count eager samples, or bound each lazy region/full-raster request, not peak process RSS. Lazy reads also require room for at least one decoded tile; repeated requests do not consume a lifetime quota. Input bytes, defensive copies, output buffers, temporary tiles, strings, and application-side conversion add memory overhead. Hosts should enforce their own total memory policy. `XcfWriteOptions.maxOutputBytes` limits encoded output to 512 MiB by default.

Pointers, dimensions, scalar property sizes, RLE plane boundaries, zlib headers/checksums, and decompressed lengths are checked. Cyclic effect/mask references and oversized tables are rejected. These checks are covered by malformed-input tests and deterministic mutations; they are not a security audit.

On-demand path parsing additionally limits each payload to 64 MiB, 100,000 strokes and one million points, validating finite coordinates and Bézier anchor ordering. Text parasites are limited to 16 MiB, with at most 100,000 syntax nodes and 64 nesting levels. Pango parsing also limits events to 100,000, depth to 64 and attributes to 1,000 per element; DTDs, declarations, duplicate attributes, invalid XML characters and unresolved entities are rejected. Gradient parsing is bounded to 64 MiB and 100,000 segments, with color pixels limited to 4 KiB and profiles to 16 MiB. These semantic limits are independent of the file decoder options.

## Corpus validation

The external corpus contains **833 XCF inputs from six GitHub projects and the XCF Test Suite host**. Of these, 830 pass semantic decode/write/read checks; two known corrupt files and an empty upstream placeholder are rejected. The original 721 files and the 109 additional GIMP resource files were reconstructed and compared in GIMP 3.2.2, including exact layer samples and composed-image hashes.

Twenty-three small, original GIMP-generated fixtures are included for offline regression tests. Eight semantic edits (plain/styled text, text options, three path representations, brightness and color) were independently performed in GIMP and compared with the XcfKit results, including GIMP-rendered composite hashes. An additional 54 newly created files cover every precision/compression combination and were reopened in GIMP with exact sample comparisons. Two additional gradient fixtures were authored with GIMP 3.3.1 development: both rewrites and a semantic edit match GIMP's exact rendered composite. Their [separate provenance and reproduction steps](../test/fixtures/gimp-development/README.md) pin the build. Embedded gradients are a development-branch feature; GIMP 3.2.2 cannot interpret them despite their XCF 22 header. Eight further fixtures cover vector layers, curves, document metadata and compressed envelopes. Their rewrites and two semantic edits were compared with GIMP 3.3.1; see [advanced fixture provenance](../test/fixtures/gimp-advanced/README.md). File tests also exercise offsets above 4 GiB and a progressive 1 GiB sample workload. These results establish the tested cases, not exhaustive compatibility with every GIMP feature or version.


Reproduce the pinned external corpus and its semantic checks with:

```sh
python3 tool/fetch_corpus.py
python3 tool/fetch_corpus.py --verify-only
dart run tool/check_corpus.dart --round-trip --output=build/roundtrip
dart run tool/check_corpus.dart --round-trip --metadata
```

Downloaded artwork stays local, ignored by Git and excluded from the published package. See [corpus provenance and independent validation](../test/corpus/README.md) for pinned revisions, checksums, expected rejections, licensing boundaries, and GIMP oracle commands.

The optional large-file workload generates and rewrites 1 GiB of samples with a 1 MiB per-read limit. Compile it before measuring elapsed time and resident memory:

```sh
mkdir -p build
dart compile exe tool/large_file_smoke.dart -o build/large_file_smoke
./build/large_file_smoke
```

The command reports sample/output sizes, elapsed time, and process memory as JSON; results depend on the machine and SDK. A smaller multiple-of-64 side length can be passed for a smoke check. Sparse-file regression tests separately exercise offsets above 4 GiB.

## Validation boundaries

See [the corpus record](../test/corpus/README.md) for sources, commands, and tested counts. VM and Node tests are separate from browser/mobile/native Flutter integration. The main corpus uses GIMP 3.2.2; gradient fixtures use the separately pinned GIMP 3.3.1 development build. Compatibility with later effects, plug-ins, or all historical writers is not inferred from these results.

Advanced fixtures are authored with GIMP 3.2.2 and reopened with the pinned 3.3.1 build because the stable build returns unavailable vector options after loading. Color API comparisons allow 1e-6 for Babl round-trip rounding; raw metadata and raster preservation are checked exactly. Eight rewrites and two independent edits match GIMP's metadata and composed pixels.
