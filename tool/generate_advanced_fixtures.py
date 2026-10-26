import os,json,hashlib
from pathlib import Path
from gi.repository import Gimp,Gegl,Gio
root=Path(os.environ.get('XCF_FIXTURES', '/work/five'));root.mkdir(exist_ok=True)
def save(image,name):
 if not Gimp.file_save(Gimp.RunMode.NONINTERACTIVE,image,Gio.File.new_for_path(str(root/name))): raise RuntimeError(name)
 print('GENERATED',name,flush=True)
def pixels(image):
 layer=Gimp.Layer.new(image,'Pixels',96,64,Gimp.ImageType.RGBA_IMAGE,100,Gimp.LayerMode.NORMAL);image.insert_layer(layer,None,0)
 layer.get_buffer().set(Gegl.Rectangle.new(0,0,96,64),"R'G'B'A u8",bytes(c for y in range(64) for x in range(96) for c in (x*2,y*3,128,255)))
 return layer
for edited in [False,True]:
 image=Gimp.Image.new(96,64,Gimp.ImageBaseType.RGB)
 path=Gimp.Path.new(image,'Vector triangle');image.insert_path(path,None,0);path.set_tattoo(314)
 path.stroke_new_from_points(Gimp.PathStrokeType.BEZIER,[10,10,10,10,10,10,80,10,80,10,80,10,45,52,45,52,45,52],True)
 layer=Gimp.VectorLayer.new(image,path);image.insert_layer(layer,None,0);layer.set_name('Editable vector')
 layer.set_enable_fill(True);layer.set_fill_color(Gegl.Color.new('#2380cc'))
 layer.set_enable_stroke(True);layer.set_stroke_color(Gegl.Color.new('#d95e20'))
 layer.set_stroke_width(2.5 if not edited else 4.5)
 layer.set_stroke_cap_style(Gimp.CapStyle.ROUND);layer.set_stroke_join_style(Gimp.JoinStyle.BEVEL);layer.set_stroke_miter_limit(3.25)
 layer.set_stroke_dash_pattern([2.0,1.0,4.0,1.5])
 if edited: layer.set_fill_color(Gegl.Color.new('#45ac32'))
 layer.refresh()
 authored={'fill':layer.get_enable_fill(),'stroke':layer.get_enable_stroke(),'width':layer.get_stroke_width(),'cap':int(layer.get_stroke_cap_style()),'join':int(layer.get_stroke_join_style()),'miter':layer.get_stroke_miter_limit(),'dashes':list(layer.get_stroke_dash_pattern()),'fill_color':list(layer.get_fill_color().get_rgba()) if layer.get_fill_color() else None,'stroke_color':list(layer.get_stroke_color().get_rgba()) if layer.get_stroke_color() else None}
 (root/('vector-edited-authoring.json' if edited else 'vector-authoring.json')).write_text(json.dumps(authored,indent=2)+'\n')
 save(image,'vector-edited.xcf' if edited else 'vector.xcf');image.delete()
image=Gimp.Image.new(96,64,Gimp.ImageBaseType.RGB);layer=pixels(image)
image.set_resolution(144,288);image.add_hguide(-5);image.add_vguide(40);image.add_sample_point(12,34);image.add_sample_point(90,60)
unit=Gimp.Unit.new('kit units',7.5,3,'ku','kit');image.set_unit(unit)
image.attach_parasite(Gimp.Parasite.new('xcfkit-opaque',1,[0,-1,102,117,116,117,114,101,0]))
save(image,'document-metadata.xcf')
for ext in ['gz','bz2','xz']: save(image,'document-metadata.xcf.'+ext)
image.delete()
for edited in [False,True]:
 image=Gimp.Image.new(96,64,Gimp.ImageBaseType.RGB);layer=pixels(image)
 effect=Gimp.DrawableFilter.new(layer,'gimp:curves','Editable curves');config=effect.get_config();curve=config.get_property('curve')
 curve.add_point(0.25,0.6 if edited else 0.4);curve.add_point(0.75,0.8 if edited else 0.6)
 config.set_property('curve',curve);layer.append_filter(effect)
 save(image,'curves-edited.xcf' if edited else 'curves.xcf');image.delete()
print('FIVE_GENERATION_COMPLETE',flush=True)
