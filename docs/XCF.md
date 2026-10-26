# XCF technical reference

## Scope

XcfKit is an independent Dart implementation of the [GIMP XCF specification](https://developer.gimp.org/core/standards/xcf/). The GIMP source tree, particularly [`app/xcf`](https://gitlab.gnome.org/GNOME/gimp/-/tree/master/app/xcf), is the authoritative format reference. No GIMP/GEGL implementation is bundled or required at runtime.

The default APIs read and write in-memory documents. `XcfCodec.open` instead indexes a random-access source and defers sample reads; `encodeTo` writes to a seekable destination one tile at a time. Both paths share the same binary codec. Composition, color management, font layout and effect execution belong to the host engine; their absence is an intentional package boundary.

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

## Representation and editing

`XcfDocument.layers` is topmost-first, with a group's children immediately after their parent. A child path such as `[2, 1, 0]` identifies a top-level group at index 2, its second child group, and that group's first child. Root layers may omit `PROP_ITEM_PATH`. Invalid paths and nesting beyond 256 levels are rejected.

`XcfProperty` and `XcfParasite` expose read-only copies. Scalar accessors use the last occurrence, as GIMP does. Repeated effect arguments and other opaque records retain their source order. Encoding preserves payload bytes while reconstructing known file pointers, so output is semantically compared rather than expected to be byte-identical to its source.

Historical property lengths require special treatment: colormaps and custom units are walked according to their actual fields. GIMP 3.2 linked-layer properties can undercount a nonempty source string by four bytes; only this known short form is repaired. Longer link payloads retain opaque suffixes, with typed access rejecting unknown extensions. These repairs appear in `document.warnings`. The writer emits corrected lengths.

Semantic accessors decode metadata on demand. Reading a document preserves opaque text, vectors, and effect payloads even if a typed accessor cannot interpret them. `XcfText` keeps comments and unknown configuration fields verbatim. `withText` deliberately removes Pango markup; it does not retain per-span styling. `XcfLayer.withText` applies a supplied rendered raster, updates its dimensions and optional offsets, and clears GIMP's modified-pixel flag. The caller is responsible for rendering, color encoding, and consistency between pixels and text.

`XcfFloatingSelection.layerIndex` and `targetIndex` refer to the flat layer list (or the channel list for a channel target). They must be updated after reordering or removing items. Unlike older descriptions of XCF, GIMP 3 can save the floating layer inside a group instead of first in the flat list. GIMP may normalize layer order and group membership when loading that file; XcfKit preserves file order and item paths. The original raw `PROP_FLOATING_SELECTION` is retained for inspection, but encoding uses the resolved model to reconstruct its pointer. `copyWith(removeFloatingSelection: true)` removes the association and raw property; it does not anchor pixels or convert a grayscale floating layer into an RGB layer.

GEGL numeric arguments are serialized as float32 even for double-valued GEGL parameters. Semantic access preserves that precision. Color arguments expose `XcfColor` (Babl encoding, pixel bytes and ICC profile); embedded version-1 gradients expose `XcfGradient` and its segments. Unlike raster samples, Babl color bytes are native-format data without a portable byte-order marker. The kit preserves them without guessing; `XcfColor.rgba8` creates an endian-independent representation. Unknown argument types return null from `value`, with raw `data` still accessible. Null color/gradient resources also return null.

Text APIs are format-specific, analogous to PsdKit's semantic text models rather than a Photoshop-to-GIMP typography mapping. `XcfTextOptions` exposes GIMP's defaults for absent fields, with environment-dependent font/language left null. Font references retain full names, family/style, PostScript identifiers and available matching metadata without loading fonts. Modern base font resources require XCF 19+ and encoded text colors XCF 14+. Outline fields are GIMP 3.2 metadata; the tested outline files still use an XCF 19 header. Preflight recognizes structured font resources but cannot infer compatibility from arbitrary unknown text configuration or a GIMP release number.

`XcfTextContent` ranges use UTF-16 code units, like Dart String indices, and reject boundaries splitting a surrogate pair. Styles keep outer-to-inner Pango spans: relative sizes and font descriptions are not resolved by the kit. Untouched markup remains verbatim; edited content is reserialized with unknown tags/attributes and font-resource fields retained. Early inline font records are normalized to `markupfont` records when content is rewritten. Fill colors expose either exact legacy RGBA numbers or modern encoded color bytes. Outline pattern names remain references; no external pattern is loaded.

`XcfPixels.rgba8` expands each color model to straight RGBA8. It rounds integer scaling, clamps floating samples to `[0, 1]`, and maps NaN to zero for the preview only. It retains the source transfer encoding; displaying a linear-light buffer as sRGB without conversion is incorrect. Original raster bytes are unchanged.

## Structured metadata and preflight

`XcfConfiguration` retains repeated fields and assignment order. A curves
configuration alternates `channel` and `curve`; these are not a dictionary of
unique keys. Select an explicit `occurrence` when editing a particular channel.
`XcfCurve` exposes point kinds and inactive legacy coordinates, plus the saved
sample array. Its editing API requires replacement samples from the host so no
second interpolation engine is introduced.

Vector fill/stroke styles and enum values stay numeric. Pattern references carry
name, collection ID and internal-resource flag; no pattern pixels are embedded.
The vector property has no stroke unit or dash-offset field: XcfKit exposes only
what XCF actually stores. Path tattoos must resolve uniquely. Unknown suffixes
are preserved by typed edits; the original property remains available.

Custom units use five strings before XCF 21 and three thereafter. Changing a
header across that boundary requires reserializing the unit with `withUserUnit`.
Guide orientation is XCF-specific (horizontal=1, vertical=2), unlike GIMP's public
enum. Off-canvas guides require XCF 15 for compatible interpretation.

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

## Validation boundaries

See [the corpus record](../test/corpus/README.md) for sources, commands, and tested counts. VM and Node tests are separate from browser/mobile/native Flutter integration. The main corpus uses GIMP 3.2.2; gradient fixtures use the separately pinned GIMP 3.3.1 development build. Compatibility with later effects, plug-ins, or all historical writers is not inferred from these results.

Advanced fixtures are authored with GIMP 3.2.2 and reopened with the pinned 3.3.1 build because the stable build returns unavailable vector options after loading. Color API comparisons allow 1e-6 for Babl round-trip rounding; raw metadata and raster preservation are checked exactly. Eight rewrites and two independent edits match GIMP's metadata and composed pixels.
