import 'dart:io';
import 'dart:typed_data';

import 'package:xcfkit/xcfkit.dart';

/// Inspects a layered document and optionally writes a reconstructed copy.
Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty) {
    stdout.writeln('Usage: dart run example/xcfkit_example.dart input.xcf [output.xcf]');
    return;
  }
  final XcfDocument document = XcfCodec.decode(await File(arguments.first).readAsBytes());
  stdout.writeln('${document.width} × ${document.height}, ${document.precision.name}, ${document.layers.length} layers');
  for (final XcfLayer layer in document.layers) {
    stdout.writeln('${layer.isGroup ? 'Group' : 'Layer'}: ${layer.name}, offset (${layer.x}, ${layer.y}), mode ${layer.mode}');
    if (!layer.isGroup && layer.raster != null) {
      final Uint8List rgba = XcfPixels.rgba8(document, layer);
      stdout.writeln('  ${rgba.length} RGBA8 preview bytes in the source profile and transfer encoding');
    }
  }
  if (arguments.length > 1) {
    await File(arguments[1]).writeAsBytes(XcfCodec.encode(document));
  }
}
