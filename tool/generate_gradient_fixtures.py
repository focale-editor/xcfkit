"""Create independent gradient fixtures through GIMP 3.3's Gradient tool.

Run in a graphical GIMP instance with python-fu-eval. Execute create, draw an
editable gradient with dithering disabled, then execute record. Execute edit,
draw the same gradient again, then execute record-edited. See the fixture README
for exact coordinates and the pinned GIMP build. No XcfKit code is used here.
"""
import json
import os
import sys
from pathlib import Path

from gi.repository import Babl, Gegl, Gimp, Gio


def require(result):
    """Fail if a GIMP procedure reports failure, including tuple return values."""
    if not (result[0] if isinstance(result, tuple) else result):
        raise RuntimeError('GIMP operation failed')


def color_record(color):
    """Read exact Babl bytes independently of XCF serialization."""
    encoding = color.get_format()
    return {'encoding': Babl.format_get_encoding(encoding),
            'pixel': color.get_bytes(encoding).get_data().hex()}


def gradient_record(gradient):
    """Read positions, enum values and endpoints through GIMP's resource API."""
    return {'name': gradient.get_name(), 'segments': [
        {'left': gradient.segment_get_left_pos(i)[1],
         'middle': gradient.segment_get_middle_pos(i)[1],
         'right': gradient.segment_get_right_pos(i)[1],
         'blending': int(gradient.segment_get_blending_function(i)[1]),
         'coloring': int(gradient.segment_get_coloring_type(i)[1]),
         'left_color': color_record(gradient.segment_get_left_color(i)),
         'right_color': color_record(gradient.segment_get_right_color(i))}
        for i in range(gradient.get_number_of_segments())]}


if tuple(int(part) for part in Gimp.version().split('.')[:2]) < (3, 3):
    raise RuntimeError('Editable gradient fixtures require GIMP 3.3 development or later')

stage = os.environ.get('XCF_GRADIENT_STAGE', 'create')
root = Path(os.environ.get('XCF_FIXTURES', '/work/gradient-originals'))
root.mkdir(parents=True, exist_ok=True)
if stage == 'create':
    gradient = Gimp.Gradient.new('XcfKit independent gradient')
    require(gradient.segment_range_split_uniform(0, 0, 2))
    for i, (left, right, middle) in enumerate([
            ('#ff0000ff', '#00ff0080', 0.125), ('#00ff0080', '#0000ffff', 0.875)]):
        require(gradient.segment_set_left_color(i, Gegl.Color.new(left)))
        require(gradient.segment_set_right_color(i, Gegl.Color.new(right)))
        require(gradient.segment_set_middle_pos(i, middle))
    require(Gimp.context_set_gradient(gradient))
    image = Gimp.Image.new(256, 128, Gimp.ImageBaseType.RGB)
    layer = Gimp.Layer.new(image, 'Gradient', 256, 128, Gimp.ImageType.RGBA_IMAGE, 100, Gimp.LayerMode.NORMAL)
    image.insert_layer(layer, None, 0)
    require(layer.fill(Gimp.FillType.TRANSPARENT))
    Gimp.Display.new(image)
    Gimp.displays_flush()
elif stage == 'edit':
    image = Gimp.get_images()[0]
    for effect in image.get_layers()[0].get_filters():
        effect.delete()
    gradient = Gimp.context_get_gradient()
    require(gradient.segment_set_middle_pos(0, 0.25))
    require(gradient.segment_set_left_color(0, Gegl.Color.new('#ffff00ff')))
    require(gradient.segment_range_set_blending_function(0, 0, Gimp.GradientSegmentType.CURVED))
    require(gradient.segment_range_set_blending_function(1, 1, Gimp.GradientSegmentType.SINE))
    require(gradient.segment_range_set_coloring_type(1, 1, Gimp.GradientSegmentColor.HSV_CCW))
    Gimp.displays_flush()
elif stage in ['record', 'record-edited']:
    image = Gimp.get_images()[0]
    effects = image.get_layers()[0].get_filters()
    if len(effects) != 1 or effects[0].get_operation_name() != 'gimp:gradient':
        raise RuntimeError('Draw and commit exactly one editable gradient before recording')
    name = 'effect-gradient-edited' if stage == 'record-edited' else 'effect-gradient'
    require(Gimp.file_save(Gimp.RunMode.NONINTERACTIVE, image, Gio.File.new_for_path(str(root / (name + '.xcf')))))
    reference = {'gimp_version': Gimp.version(), 'byte_order': sys.byteorder,
                 'gradient': gradient_record(Gimp.context_get_gradient())}
    (root / (name + '.json')).write_text(json.dumps(reference, indent=2) + '\n')
    print('RECORDED', name, flush=True)
else:
    raise ValueError('Unknown XCF_GRADIENT_STAGE: ' + stage)
print('GRADIENT STAGE COMPLETE', stage, flush=True)
