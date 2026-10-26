"""Run inside GIMP's python-fu-eval interpreter, never with plain Python.

Set XCF_INPUT, XCF_OUTPUT and optionally XCF_REFERENCE in the environment.
The report compares exact non-group samples and GIMP-rendered composites.
GIMP itself may normalize metadata or regenerate group caches when loading.
"""
import hashlib
import json
import os
from pathlib import Path

from gi.repository import Gegl, Gimp, Gio


def digest(data):
    return hashlib.sha256(bytes(data)).hexdigest()


def raster(drawable, precision):
    rect = Gegl.Rectangle.new(0, 0, drawable.get_width(), drawable.get_height())
    data = bytearray(drawable.get_buffer().get(rect, 1.0, None, Gegl.AbyssPolicy.NONE))
    # GEGL exposes native-endian samples. XCF stores multi-byte samples big-endian.
    component = {1: 1, 2: 2, 3: 4, 5: 2, 6: 4, 7: 8}[int(precision) // 100]
    if component > 1 and __import__('sys').byteorder == 'little':
        for i in range(0, len(data), component):
            data[i:i + component] = data[i:i + component][::-1]
    return {'width': drawable.get_width(), 'height': drawable.get_height(),
            'bpp': drawable.get_bpp(), 'sha256': digest(data)}


def inspect(image):
    precision = image.get_precision()
    layers = []
    drawables = []

    def filters(drawable):
        values = []
        for effect in drawable.get_filters():
            # GIMP 3.3's Python bridge cannot expose the internal context
            # property of gimp:gradient, which prevents creating its config.
            # Resource fields have a separate reference from the authoring API.
            operation = effect.get_operation_name()
            config = None if operation == 'gimp:gradient' else effect.get_config()
            parameters = {}
            for property in config.list_properties() if config is not None else []:
                value = config.get_property(property.name)
                if value is None or isinstance(value, (str, bool, int, float)):
                    parameters[property.name] = value
                elif isinstance(value, Gegl.Color):
                    parameters[property.name] = {'rgba': list(value.get_rgba())}
            values.append({'name': effect.get_name(), 'operation': operation,
                           'visible': effect.get_visible(), 'opacity': effect.get_opacity(),
                           'mode': int(effect.get_blend_mode()), 'parameters': parameters,
                           **({'parameters_unavailable': 'GIMP gradient context is not exposed through Python'} if config is None else {})})
        return values

    def visit(items, parent):
        for index, layer in enumerate(items):
            drawables.append(layer)
            path = parent + [index]
            offsets = layer.get_offsets()
            entry = {'name': layer.get_name(), 'path': path, 'tattoo': layer.get_tattoo(),
                     'x': offsets.offset_x, 'y': offsets.offset_y,
                     'opacity': layer.get_opacity(), 'visible': layer.get_visible(),
                     'mode': int(layer.get_mode()), 'group': layer.is_group(), 'effects': filters(layer)}
            if not layer.is_group():
                entry['raster'] = raster(layer, precision)
            if layer.is_text_layer():
                size, unit = layer.get_font_size()
                entry['text'] = {'text': layer.get_text(), 'markup': layer.get_markup(),
                                 'font': layer.get_font().get_name(), 'size': size,
                                 'options': {
                                     'antialias': layer.get_antialias(), 'hint': int(layer.get_hint_style()),
                                     'kerning': layer.get_kerning(), 'language': layer.get_language(),
                                     'direction': int(layer.get_base_direction()), 'justification': int(layer.get_justification()),
                                     'indent': layer.get_indent(), 'line_spacing': layer.get_line_spacing(),
                                     'letter_spacing': layer.get_letter_spacing(), 'color': list(layer.get_color().get_rgba()),
                                     'outline': int(layer.get_outline()), 'outline_width': layer.get_outline_width()[0],
                                     'outline_direction': int(layer.get_outline_direction()), 'outline_antialias': layer.get_outline_antialias(),
                                     'outline_cap': int(layer.get_outline_cap_style()), 'outline_join': int(layer.get_outline_join_style()),
                                     'outline_miter': layer.get_outline_miter_limit(), 'outline_dash_offset': layer.get_outline_dash_offset(),
                                     'outline_color': list(layer.get_outline_color().get_rgba()),
                                 }}
            mask = layer.get_mask()
            if mask:
                entry['mask'] = raster(mask, precision)
                entry['apply_mask'] = layer.get_apply_mask()
            layers.append(entry)
            if layer.is_group():
                visit(layer.get_children(), path)

    visit(image.get_layers(), [])
    floating = None
    attached = image.floating_sel_attached_to()
    if attached:
        for index, layer in enumerate(drawables):
            if layer.get_id() == attached.get_id():
                floating = {'kind': 'layer', 'index': index}
            mask = layer.get_mask()
            if mask and mask.get_id() == attached.get_id():
                floating = {'kind': 'layerMask', 'index': index}
        for index, channel in enumerate(image.get_channels()):
            if channel.get_id() == attached.get_id():
                floating = {'kind': 'channel', 'index': index}
        if floating is None:
            raise RuntimeError('Unknown floating selection target')
        floating['layer_index'] = next(index for index, layer in enumerate(drawables) if layer.is_floating_sel())
    duplicate = image.duplicate()
    merged = duplicate.merge_visible_layers(Gimp.MergeType.CLIP_TO_IMAGE)
    composite = None
    if merged:
        # Request the complete canvas, accounting for a merged drawable offset.
        offsets = merged.get_offsets()
        rect = Gegl.Rectangle.new(-offsets.offset_x, -offsets.offset_y, image.get_width(), image.get_height())
        composite = digest(merged.get_buffer().get(rect, 1.0, "R'G'B'A u8", Gegl.AbyssPolicy.NONE))
    duplicate.delete()
    paths = []
    for path in image.get_paths():
        strokes = []
        for stroke in path.get_strokes():
            kind, points, closed = path.stroke_get_points(stroke)
            strokes.append({'type': int(kind), 'points': points, 'closed': closed})
        paths.append({'name': path.get_name(), 'visible': path.get_visible(), 'strokes': strokes})
    return {'width': image.get_width(), 'height': image.get_height(), 'precision': int(precision), 'paths': paths, 'floating': floating,
            'layers': layers, 'channels': [dict(name=c.get_name(), **raster(c, precision)) for c in image.get_channels()],
            'selection': raster(image.get_selection(), precision),
            'composite_sha256': composite}


root = Path(os.environ.get('XCF_INPUT', '/work/storytold'))
reference_root = os.environ.get('XCF_REFERENCE')
output = Path(os.environ.get('XCF_OUTPUT', '/work/gimp-reference.json'))
results = []
for path in sorted(root.rglob('*.xcf')):
    relative = str(path.relative_to(root))
    images = []
    try:
        image = Gimp.file_load(Gimp.RunMode.NONINTERACTIVE, Gio.File.new_for_path(str(path)))
        if image is None:
            raise RuntimeError('GIMP returned no image')
        images.append(image)
        value = inspect(image)
        entry = {'file': relative, 'ok': True, **value}
        if reference_root:
            original = Gimp.file_load(Gimp.RunMode.NONINTERACTIVE, Gio.File.new_for_path(str(Path(reference_root) / relative)))
            images.append(original)
            reference = inspect(original)
            entry['equal_to_original'] = value == reference
            if value != reference:
                entry['original'] = reference
        results.append(entry)
        print('ORACLE', relative, 'equal=' + str(entry.get('equal_to_original', True)), flush=True)
    except Exception as error:
        results.append({'file': relative, 'ok': False, 'error': repr(error)})
        print('ORACLE FAILED', relative, repr(error), flush=True)
    finally:
        for image in images:
            if image is not None:
                image.delete()
    output.write_text(json.dumps(results, indent=2) + '\n')
print('ORACLE COMPLETE', len(results), 'files', flush=True)
