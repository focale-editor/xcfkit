"""Independent GIMP 3.2+ metadata oracle; compare original and rewritten XCFs.

Run with gimp --batch-interpreter=python-fu-eval. XCF_INPUT and XCF_OUTPUT
select the source directory and JSON output; XCF_REFERENCE enables comparison.
The sibling gimp_reference.py supplies the existing exact-sample oracle.
"""
import os
import json
from pathlib import Path
from gi.repository import Gimp, Gegl, Gio, Babl

base = Path(os.environ.get('XCF_TOOLS', '/work')) / 'gimp_reference.py'
exec(base.read_text().split("root = Path(os.environ.get('XCF_INPUT'")[0])
base_inspect = inspect


def color_record(color):
    if color is None:
        return None
    encoding = color.get_format()
    return {'encoding': Babl.format_get_encoding(encoding),
            'pixel': color.get_bytes(encoding).get_data().hex()}


def inspect(image):
    result = base_inspect(image)
    guides = []
    previous = 0
    while True:
        previous = image.find_next_guide(previous)
        if not previous:
            break
        guides.append({'position': image.get_guide_position(previous),
                       'orientation': int(image.get_guide_orientation(previous))})
    samples = []
    previous = 0
    while True:
        previous = image.find_next_sample_point(previous)
        if not previous:
            break
        position = image.get_sample_point_position(previous)
        samples.append(list(position))
    resolution = image.get_resolution()
    unit = image.get_unit()
    result['document_metadata'] = {'guides': guides, 'sample_points': samples,
        'resolution': list(resolution), 'unit': {'name': unit.get_name(),
        'factor': unit.get_factor(), 'digits': unit.get_digits(),
        'symbol': unit.get_symbol(), 'abbreviation': unit.get_abbreviation()}}
    for layer, entry in zip(image.get_layers(), result['layers']):
        if layer.is_vector_layer():
            entry['vector'] = {'path_tattoo': layer.get_path().get_tattoo(),
                'fill': layer.get_enable_fill(), 'stroke': layer.get_enable_stroke(),
                'width': layer.get_stroke_width(), 'cap': int(layer.get_stroke_cap_style()),
                'join': int(layer.get_stroke_join_style()), 'miter': layer.get_stroke_miter_limit(),
                'dashes': list(layer.get_stroke_dash_pattern()),
                'fill_color': list(layer.get_fill_color().get_rgba()) if layer.get_fill_color() else None,
                'stroke_color': list(layer.get_stroke_color().get_rgba()) if layer.get_stroke_color() else None,
                'fill_pattern': layer.get_fill_pattern().get_name() if layer.get_fill_pattern() else None,
                'fill_color_bytes': color_record(layer.get_fill_color()),
                'stroke_color_bytes': color_record(layer.get_stroke_color())}
        for effect, expected in zip(layer.get_filters(), entry['effects']):
            if effect.get_operation_name() == 'gimp:curves':
                curve = effect.get_config().get_property('curve')
                expected['curve'] = {'points': [list(curve.get_point(i)) for i in range(curve.get_n_points())],
                    'types': [int(curve.get_point_type(i)) for i in range(curve.get_n_points())],
                    'samples': [curve.get_sample(i) for i in range(curve.get_n_samples())] if curve.get_property('curve-type') == Gimp.CurveType.FREE else None}
    return result

root = Path(os.environ.get('XCF_INPUT', '/work/five'))
reference = os.environ.get('XCF_REFERENCE')
output = Path(os.environ.get('XCF_OUTPUT', '/work/five-reference.json'))
results = []
for path in sorted(root.rglob('*')):
    if not path.is_file() or not any(path.name.endswith(ext) for ext in ('.xcf', '.xcf.gz', '.xcf.bz2', '.xcf.xz')):
        continue
    images = []
    relative = str(path.relative_to(root))
    try:
        image = Gimp.file_load(Gimp.RunMode.NONINTERACTIVE, Gio.File.new_for_path(str(path)))
        if image is None:
            raise RuntimeError('GIMP returned no image')
        images.append(image)
        value = inspect(image)
        entry = {'file': relative, 'ok': True, **value}
        if reference:
            original = Gimp.file_load(Gimp.RunMode.NONINTERACTIVE, Gio.File.new_for_path(str(Path(reference) / relative)))
            images.append(original)
            expected = inspect(original)
            entry['equal_to_original'] = value == expected
            if value != expected:
                entry['original'] = expected
        results.append(entry)
        print('ADVANCED_ORACLE', relative, entry.get('equal_to_original', True), flush=True)
    except Exception as error:
        results.append({'file': relative, 'ok': False, 'error': repr(error)})
        print('ADVANCED_ORACLE_FAILED', relative, repr(error), flush=True)
    finally:
        for image in images:
            if image is not None:
                image.delete()
    output.write_text(json.dumps(results, indent=2) + '\n')
print('ADVANCED_ORACLE_COMPLETE', len(results), flush=True)
