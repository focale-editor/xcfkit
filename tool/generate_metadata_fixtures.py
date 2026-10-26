"""Generate procedural codec metadata fixtures with GIMP 3.2's Python API."""
import os
from pathlib import Path
from gi.repository import Gegl, Gimp, Gio

root = Path(os.environ.get('XCF_FIXTURES', '/work/metadata'))
root.mkdir(parents=True, exist_ok=True)


def save(image, name):
    if not Gimp.file_save(Gimp.RunMode.NONINTERACTIVE, image, Gio.File.new_for_path(str(root / (name + '.xcf')))):
        raise RuntimeError('Could not save ' + name)
    image.delete()
    print('GENERATED', name, flush=True)


def pixels(image):
    layer = Gimp.Layer.new(image, 'Pixels', 96, 64, Gimp.ImageType.RGBA_IMAGE, 100, Gimp.LayerMode.NORMAL)
    image.insert_layer(layer, None, 0)
    layer.get_buffer().set(Gegl.Rectangle.new(0, 0, 96, 64), "R'G'B'A u8",
                           bytes(c for y in range(64) for x in range(96) for c in (x * 2, y * 3, 128, 255)))
    return layer


image = Gimp.Image.new(96, 64, Gimp.ImageBaseType.RGB)
pixels(image)
path = Gimp.Path.new(image, 'Compatibility strokes')
image.insert_path(path, None, 0)
for points, closed in [([1, 2, 4, 5, 7, 8, 20, 22, 25, 26, 28, 29], True),
                       ([3, 4, 6, 7, 9, 10, 30, 32, 35, 36, 38, 39], True),
                       ([40, 42, 45, 46, 48, 49, 50, 52, 55, 56, 58, 59], False)]:
    path.stroke_new_from_points(Gimp.PathStrokeType.BEZIER, points, closed)
save(image, 'compat-paths')

for edited in [False, True]:
    image = Gimp.Image.new(160, 100, Gimp.ImageBaseType.RGB)
    text = Gimp.TextLayer.new(image, 'Été et hiver\nDeux lignes', Gimp.Font.get_by_name('Nimbus Sans Regular'), 18, Gimp.Unit.pixel())
    image.insert_layer(text, None, 0)
    text.set_name('Text options')
    text.set_antialias(False)
    text.set_hint_style(Gimp.TextHintStyle.FULL)
    text.set_kerning(True)
    text.set_language('fr')
    text.set_base_direction(Gimp.TextDirection.RTL)
    text.set_justification(Gimp.TextJustification.CENTER)
    text.set_indent(2.5)
    text.set_line_spacing(3.25)
    text.set_letter_spacing(1.5)
    text.set_color(Gegl.Color.new('rgba(0.1, 0.4, 0.8, 1.0)'))
    text.resize(150, 90)
    text.set_outline(Gimp.TextOutline.STROKE_FILL)
    text.set_outline_width(1.5, Gimp.Unit.pixel())
    text.set_outline_color(Gegl.Color.new('rgba(0.8, 0.2, 0.1, 1.0)'))
    text.set_outline_antialias(False)
    text.set_outline_cap_style(Gimp.CapStyle.ROUND)
    text.set_outline_join_style(Gimp.JoinStyle.ROUND)
    text.set_outline_miter_limit(3)
    text.set_outline_dash_offset(1)
    if edited:
        text.set_font(Gimp.Font.get_by_name('Nimbus Roman Italic'))
        text.set_justification(Gimp.TextJustification.RIGHT)
        text.set_letter_spacing(0.75)
        text.set_line_spacing(5)
        text.set_indent(-1)
    save(image, 'text-options-edited' if edited else 'text-options')

for edited in [False, True]:
    image = Gimp.Image.new(160, 100, Gimp.ImageBaseType.RGB)
    text = Gimp.TextLayer.new(image, 'styled', Gimp.Font.get_by_name('Nimbus Sans Regular'), 18, Gimp.Unit.pixel())
    image.insert_layer(text, None, 0)
    text.set_markup('<markup>Été <span font="Nimbus Roman Bold" foreground="#12a05f" size="18432" rise="1024" letter_spacing="512" font_features="kern=0"><b>ffi 😀</b></span>\n<u>سلام</u></markup>')
    text.set_name('Styled text')
    if edited:
        text.set_markup('<markup>Été <span font="Nimbus Roman Bold" foreground="#12a05f" size="18432" rise="1024" letter_spacing="512" font_features="kern=0"><b><span foreground="#cc2244">ffi 😀</span></b></span>\n<u>سلام</u></markup>')
    save(image, 'text-markup-edited' if edited else 'text-markup')

image = Gimp.Image.new(96, 64, Gimp.ImageBaseType.RGB)
layer = pixels(image)
effect = Gimp.DrawableFilter.new(layer, 'gegl:color-overlay', 'Colored overlay')
effect.get_config().set_property('value', Gegl.Color.new('rgba(0.2, 0.6, 0.9, 0.5)'))
layer.append_filter(effect)
save(image, 'effect-color')

source = root / 'link-source.ppm'
source.write_bytes(b'P6\n96 64\n255\n' + bytes([24, 128, 220]) * 96 * 64)
image = Gimp.Image.new(96, 64, Gimp.ImageBaseType.RGB)
linked = Gimp.LinkLayer.new(image, Gio.File.new_for_path(str(source)))
image.insert_layer(linked, None, 0)
linked.transform_matrix(1, 0.1, 3, 0, 1, -2, 0, 0, 1)
save(image, 'linked-layer')
