<p align="center">
  <img src="screenshots/overview.png" alt="XcfKit package illustration" width="180">
</p>

# XcfKit

Read, inspect, edit, and write layered GIMP XCF documents in Dart.

XcfKit is intended for applications that need to work with GIMP documents without launching GIMP. It lets you access the canvas, layers, masks, saved pixels, editable content, and document metadata while preserving GIMP data that your application does not change.

It is written in pure Dart, with no Flutter or native dependency, so the same API can be used in Flutter applications, command-line tools, and server-side Dart programs.

## Installation

Add XcfKit to a Dart project:

```sh
dart pub add xcfkit
```

For a Flutter project, use `flutter pub add xcfkit` instead.

## Quick start

Open a document, inspect its layers, and save it again:

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:xcfkit/xcfkit.dart';

final Uint8List input = await File('input.xcf').readAsBytes();
final XcfDocument document = XcfCodec.decode(input);

print('${document.width} × ${document.height}');
for (final XcfLayer layer in document.layers) {
  print('${layer.visible ? 'visible' : 'hidden'}: ${layer.name}');
}

final Uint8List output = XcfCodec.encode(document);
await File('output.xcf').writeAsBytes(output, flush: true);
```

Editing helpers use a copy-based API: they return updated values and leave the source value untouched.

## Common tasks

### Read a layer's pixels

XcfKit converts an individual raster layer to an 8-bit RGBA buffer:

```dart
final XcfLayer rasterLayer = document.layers.firstWhere(
  (layer) => !layer.isGroup && layer.raster != null,
);
final Uint8List rgba = XcfPixels.rgba8(document, rasterLayer);
```

The bytes retain the source color profile and transfer encoding. Your application applies color conversion, masks, opacity, and blend modes for display. Use `rasterLayer.raster!.bytes` when you need the original sample precision. XCF has no standard merged document preview to extract.

### Read or replace editable text

Text layers expose their characters and formatting without requiring knowledge of the XCF text format:

```dart
for (final XcfLayer layer in document.layers) {
  if (layer.text case final XcfText text) {
    print('${layer.name}: ${text.content.text}');
    print('Font size: ${text.options.fontSize}');

    final XcfText editedText = text.withText('Updated copy');
    // Render editedText in your application, then apply it with
    // layer.withText(editedText, renderedRaster: updatedRaster).
  }
}
```

Use `withOptions` for font, spacing, alignment, text box, or outline settings. Use `withContent` to edit styled ranges; `withText` replaces the characters and clears inline markup. The saved `layer.raster` is available for displaying unchanged text. The technical reference shows how to [apply text and its rendered pixels](docs/XCF.md#editable-text) and [place an edited layer back into a document](docs/XCF.md#updating-copy-based-models).

### Work with other GIMP features

The most common entry points are organized around what an application needs to do:

| Goal | API |
| --- | --- |
| Inspect groups and layer masks | `document.layerTree`, `layer.mask` |
| Read or change saved paths | `document.paths`, `document.withPaths(...)` |
| Inspect or change vector-layer styles | `layer.vectorLayer`, `layer.withVectorLayer(...)` |
| Read or change effect parameters | `layer.effects`, `effect.withArgument(...)` |
| Find a linked layer's source and transform | `layer.link`, `layer.transform` |
| Read guides, sample points, and resolution | `document.guides`, `document.samplePoints`, `document.resolution` |
| Inspect an embedded color profile | `document.iccProfile` |
| Read or update configuration metadata | `document.configuration(...)`, `document.withConfiguration(...)` |
| Inspect saved channels and floating selections | `document.channels`, `document.floatingSelection` |

The [XCF technical reference](docs/XCF.md) contains examples and explains how these APIs map to GIMP data.

### Create a new document

New XCF documents can be assembled from RGBA pixels and layer models:

```dart
final XcfDocument created = XcfDocument(
  width: 1,
  height: 1,
  layers: [
    XcfLayer.rgba(
      name: 'Red pixel',
      width: 1,
      height: 1,
      pixels: [255, 0, 0, 255],
    ),
  ],
);
final Uint8List output = XcfCodec.encode(created);
```

## Compatibility controls

`XcfCodec.preflight(document)` reports known structural and version problems before writing, without decoding lazy pixels or changing the document. Read and write options provide resource limits. The optional `xcfkit_compression.dart` entry point handles `.xcf.gz`, `.xcf.bz2`, and `.xcf.xz` files. See the [write diagnostics](docs/XCF.md#write-diagnostics) and [compressed-file reference](docs/XCF.md#optional-compressed-files) for examples and limits.

## Rendering expectations

XcfKit reads and writes the editable information stored in an XCF, but it is not a GIMP rendering engine. The application composes layers, manages colors, lays out text, and applies effects. When it changes text or vector-layer metadata, it must also supply matching raster pixels. Linked resources are never opened or refreshed by the kit.

This separation is useful for editors: XcfKit handles the file and its editable data, while the application remains in control of rendering.

## Compatibility and large files

XcfKit reads and writes RGB, grayscale, and indexed documents, integer and floating-point samples, layers, groups, masks, channels, text metadata, paths, effects, and document properties. Unknown data is retained where it can be rewritten safely; unsupported versions and unsafe pointer relocation are rejected explicitly.

For large documents, lazy reads decode selected regions and a progressive writer emits tiles to a seekable destination. See the [XCF technical reference](docs/XCF.md) for the full support matrix, limitations, memory model, and safety options.

## More documentation

- [XCF technical reference](docs/XCF.md)
- [Document inspection and rewriting example](example/xcfkit_example.dart)
- [Corpus provenance and independent GIMP validation](test/corpus/README.md)
- [Contributing](CONTRIBUTING.md)

## Development

Run the standard project checks with:

```sh
dart format .
dart analyze
dart test
dart test --platform node
```

Additional corpus validation commands are documented in the [technical reference](docs/XCF.md#corpus-validation).

---

Built for **[Focale](https://focale-editor.app)**, an advanced local image editor. Discover what these packages make possible in a real creative workflow.
