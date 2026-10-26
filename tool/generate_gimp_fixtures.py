"""Generate original, procedural fixtures in GIMP 3 for offline codec tests.

Run through python-fu-eval. XCF_FIXTURES selects the output directory.
No external imagery, fonts, or copied implementation is used.
"""
import os
from pathlib import Path
import struct

from gi.repository import Gegl, Gimp, Gio

root = Path(os.environ.get('XCF_FIXTURES', '/work/generated'))
root.mkdir(parents=True, exist_ok=True)


def layer(image, name, width=67, height=3, parent=None, position=0):
    value = Gimp.Layer.new(image, name, width, height, Gimp.ImageType.RGBA_IMAGE, 100, Gimp.LayerMode.NORMAL)
    image.insert_layer(value, parent, position)
    samples = bytes(component for y in range(height) for x in range(width)
                    for component in ((x * 17 + y) % 256, (x + y * 13) % 256, 201, (x * 31 + y) % 256))
    value.get_buffer().set(Gegl.Rectangle.new(0, 0, width, height), "R'G'B'A u8", samples)
    return value


def save(image, name):
    path = root / (name + '.xcf')
    if not Gimp.file_save(Gimp.RunMode.NONINTERACTIVE, image, Gio.File.new_for_path(str(path))):
        raise RuntimeError('GIMP failed to save ' + str(path))
    image.delete()
    print('GENERATED', name, flush=True)


for precision in [Gimp.Precision.U8_NON_LINEAR, Gimp.Precision.U16_NON_LINEAR,
                  Gimp.Precision.U32_NON_LINEAR, Gimp.Precision.HALF_LINEAR,
                  Gimp.Precision.FLOAT_LINEAR, Gimp.Precision.DOUBLE_LINEAR]:
    image = Gimp.Image.new_with_precision(67, 3, Gimp.ImageBaseType.RGB, precision)
    value = layer(image, 'Procedural pixels')
    if precision == Gimp.Precision.FLOAT_LINEAR:
        samples = b''.join(struct.pack('=ffff', 1.5, -0.125, x / 66, 1.0) for y in range(3) for x in range(67))
        value.get_buffer().set(Gegl.Rectangle.new(0, 0, 67, 3), 'RGBA float', samples)
    save(image, 'precision-' + str(int(precision)))

image = Gimp.Image.new(67, 3, Gimp.ImageBaseType.RGB)
group = Gimp.GroupLayer.new(image, 'Group')
image.insert_layer(group, None, 0)
value = layer(image, 'Masked offset child', parent=group)
value.set_offsets(-2, 1)
mask = value.create_mask(Gimp.AddMaskType.WHITE)
value.add_mask(mask)
mask.get_buffer().set(Gegl.Rectangle.new(0, 0, 67, 3), 'Y u8', bytes(x * 255 // 66 for y in range(3) for x in range(67)))
layer(image, 'Background', position=1)
save(image, 'group-mask')

image = Gimp.Image.new(67, 3, Gimp.ImageBaseType.RGB)
layer(image, 'Path pixels')
path = Gimp.Path.new(image, 'Triangle')
image.insert_path(path, None, 0)
path.stroke_new_from_points(Gimp.PathStrokeType.BEZIER,
                           [0, 0, 0, 0, 0, 0, 60, 0, 60, 0, 60, 0, 30, 3, 30, 3, 30, 3], True)
path.set_color_tag(Gimp.ColorTag.BLUE)  # Forces the modern vector structure.
save(image, 'modern-path')

image = Gimp.Image.new(67, 3, Gimp.ImageBaseType.RGB)
value = layer(image, 'Filtered pixels')
effect = Gimp.DrawableFilter.new(value, 'gegl:brightness-contrast', 'Brightness')
effect.get_config().set_property('brightness', 0.2)
value.append_filter(effect)
save(image, 'effect')
