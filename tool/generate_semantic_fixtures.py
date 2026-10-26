"""Generate original text, legacy paths and floating selections with GIMP.

Run in GIMP 3's python-fu-eval with XCF_FIXTURES selecting the destination.
Text uses the installed Nimbus Sans font; no font file is redistributed.
"""
import os
from pathlib import Path
from gi.repository import Gegl, Gimp, Gio

root = Path(os.environ.get('XCF_FIXTURES', '/work/semantic'))
root.mkdir(parents=True, exist_ok=True)


def save(image, name):
    if not Gimp.file_save(Gimp.RunMode.NONINTERACTIVE, image, Gio.File.new_for_path(str(root / (name + '.xcf')))):
        raise RuntimeError('Failed to save ' + name)
    image.delete()
    print('GENERATED', name, flush=True)


def background(image, parent=None):
    layer = Gimp.Layer.new(image, 'Background', 96, 48, Gimp.ImageType.RGBA_IMAGE, 100, Gimp.LayerMode.NORMAL)
    image.insert_layer(layer, parent, 0)
    layer.get_buffer().set(Gegl.Rectangle.new(0, 0, 96, 48), "R'G'B'A u8",
                           bytes(c for y in range(48) for x in range(96) for c in (x * 2, y * 4, 180, 255)))
    return layer


for name, content, size in [('text', 'XCF', 18), ('text-edited', 'Été "X"', 20)]:
    image = Gimp.Image.new(96, 48, Gimp.ImageBaseType.RGB)
    text = Gimp.TextLayer.new(image, content, Gimp.Font.get_by_name('Nimbus Sans Regular'), size, Gimp.Unit.pixel())
    image.insert_layer(text, None, 0)
    text.set_name('Editable text')
    text.set_offsets(3, 5)
    save(image, name)

image = Gimp.Image.new(96, 48, Gimp.ImageBaseType.RGB)
background(image)
path = Gimp.Path.new(image, 'Legacy triangle')
image.insert_path(path, None, 0)
path.set_visible(True)  # Forces PROP_VECTORS instead of pre-GIMP-2 PROP_PATHS.
path.stroke_new_from_points(Gimp.PathStrokeType.BEZIER,
                           [0, 0, 0, 0, 0, 0, 60, 0, 60, 0, 60, 0, 30, 30, 30, 30, 30, 30], True)
save(image, 'legacy-path')

for kind in ['layer', 'mask', 'channel', 'group-child']:
    image = Gimp.Image.new(96, 48, Gimp.ImageBaseType.RGB)
    group = None
    if kind == 'group-child':
        group = Gimp.GroupLayer.new(image, 'Group')
        image.insert_layer(group, None, 0)
    layer = background(image, group)
    target = layer
    if kind == 'mask':
        target = layer.create_mask(Gimp.AddMaskType.WHITE)
        layer.add_mask(target)
    elif kind == 'channel':
        target = Gimp.Channel.new(image, 'Saved channel', 96, 48, 100, Gegl.Color.new('black'))
        image.insert_channel(target, None, 0)
        target.get_buffer().set(Gegl.Rectangle.new(0, 0, 96, 48), 'Y u8', bytes([180] * 96 * 48))
    image.select_rectangle(Gimp.ChannelOps.REPLACE, 10, 8, 15, 12)
    floating = Gimp.Selection.float(image, [target], 2, 3)
    if floating is None:
        raise RuntimeError('Could not float ' + kind)
    save(image, 'floating-' + kind)
