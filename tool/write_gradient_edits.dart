import 'dart:io';

import 'package:xcfkit/xcfkit.dart';

/// Edits the gradient authored independently with GIMP's Gradient tool.
void main(List<String> arguments) {
  final String output = arguments.firstOrNull ?? 'build/gradient-edits';
  final XcfDocument document = XcfCodec.decode(File('test/fixtures/gimp-development/effect-gradient.xcf').readAsBytesSync());
  final XcfLayer layer = document.layers.single;
  final XcfEffect effect = layer.effects.single;
  final XcfGradient gradient = effect.argument('gradient')!.value! as XcfGradient;
  final XcfGradient changed = gradient.copyWith(
    segments: [
      gradient.segments[0].copyWith(middle: 0.25, leftColor: XcfColor.rgba8(255, 255, 0), blending: 1),
      gradient.segments[1].copyWith(blending: 2, coloring: 1),
    ],
  );
  final XcfDocument edited = document.copyWith(
    layers: [
      layer.copyWith(effects: [effect.withArgument(XcfFilterArgument.gradient('gradient', changed))]),
    ],
  );
  Directory(output).createSync(recursive: true);
  File('$output/effect-gradient-edited.xcf').writeAsBytesSync(XcfCodec.encode(edited));
}
