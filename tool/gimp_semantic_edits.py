"""Apply the same semantic edits as write_semantic_edits.dart, using GIMP APIs.

Run via python-fu-eval; XCF_INPUT is the fixture directory and XCF_OUTPUT the
directory for independently edited XCF files, compared by gimp_reference.py.
"""
import os
from pathlib import Path
from gi.repository import Gegl, Gimp, Gio

root = Path(os.environ['XCF_INPUT'])
output = Path(os.environ['XCF_OUTPUT'])
output.mkdir(parents=True, exist_ok=True)
for name in ['text', 'text-options', 'text-markup', 'modern-path', 'legacy-path', 'compat-paths', 'effect', 'effect-color']:
    image = Gimp.file_load(Gimp.RunMode.NONINTERACTIVE, Gio.File.new_for_path(str(root / (name + '.xcf'))))
    if name == 'text':
        layer = image.get_layers()[0]
        layer.set_text('Été "X"')
        layer.set_font_size(20, Gimp.Unit.pixel())
    elif name == 'text-options':
        layer = image.get_layers()[0]
        layer.set_font(Gimp.Font.get_by_name('Nimbus Roman Italic'))
        layer.set_justification(Gimp.TextJustification.RIGHT)
        layer.set_letter_spacing(0.75)
        layer.set_line_spacing(5)
        layer.set_indent(-1)
    elif name == 'text-markup':
        image.get_layers()[0].set_markup('<markup>Été <span font="Nimbus Roman Bold" foreground="#12a05f" size="18432" rise="1024" letter_spacing="512" font_features="kern=0"><b><span foreground="#cc2244">ffi 😀</span></b></span>\n<u>سلام</u></markup>')
    elif 'path' in name:
        for path in image.get_paths():
            path.set_name(path.get_name() + ' edited')
            for stroke in path.get_strokes():
                path.stroke_translate(stroke, 3, 2)
    else:
        effect = image.get_layers()[0].get_filters()[0]
        if name == 'effect-color':
            effect.get_config().set_property('value', Gegl.Color.new('#ff00ff80'))
        else:
            effect.get_config().set_property('brightness', 0.45)
        effect.update()
    if not Gimp.file_save(Gimp.RunMode.NONINTERACTIVE, image, Gio.File.new_for_path(str(output / (name + '.xcf')))):
        raise RuntimeError('Could not save ' + name)
    image.delete()
    print('EDITED', name, flush=True)
