# Independent editable-gradient fixtures

These two procedural images were authored with GIMP's graphical Gradient tool
on 2026-10-26, using GIMP **3.3.1 development**, commit
`a39a8a7e824fb11810baeeebd6c4edd03865768f`. The official
[AppImage job 7242523](https://gitlab.gnome.org/GNOME/gimp/-/jobs/7242523) belongs
to pipeline 1132142. The x86_64 AppImage SHA-256 is
`af89282e2e11d1fde628eb0b87ad3a28d914a76d85c69ed9b76ef124fc89bb90`.
`manifest.json` pins the fixture/reference hashes. No GIMP binary is bundled.

The main corpus remains validated with stable GIMP 3.2.2. That version has no
reader for embedded gradient argument kind 9. The development files still use
an XCF 22 header: header versions alone do not imply feature compatibility.

## What is independently checked

- `effect-gradient.xcf`: two segments, noncentral midpoints, RGB interpolation,
  red/green/blue endpoints and partial transparency.
- `effect-gradient-edited.xcf`: first midpoint changed to 0.25, first color to
  yellow, interpolation changed to curved/sine, second segment to HSV CCW.
- The matching per-file JSON records come from GIMP's resource API and Babl
  pixel bytes before serialization, without reading the XCF through XcfKit.
- `reference.json`: both files were rewritten by XcfKit, opened in the pinned
  GIMP build and compared with the originals. Raw samples, structure and exact
  GIMP-rendered composite hashes match.
- `edits-reference.json`: `tool/write_gradient_edits.dart` performs the same
  changes through the kit. Its GIMP-rendered result matches the independently
  edited file exactly. The new yellow deliberately uses portable u8 encoding;
  GIMP's resource uses native float32. Offline tests compare their equivalent
  components without ICC conversion.

GIMP's Python bridge cannot expose the internal `context` property of
`gimp:gradient`, so `get_config()` cannot supply those effect parameters. The
oracle explicitly records that limitation instead of treating an empty config
as parameter validation. The separate resource JSON checks positions, enum
values and endpoint bytes. Fixed-color endpoints and default sRGB are covered;
dynamic foreground/background colors and arbitrary profiles are not.

## Reproduce the authoring

Run `tool/generate_gradient_fixtures.py` through `python-fu-eval` in a graphical
GIMP 3.3 instance, with `XCF_FIXTURES` pointing to an output directory. This
script does not depend on XcfKit. It supports these `XCF_GRADIENT_STAGE` values:

1. `create`: create the resource and a transparent 256×128 image.
2. Select the Gradient tool, disable **Dithering**, enable **Editable gradient**,
   keep Linear shape, Normal mode, 100% opacity and Perceptual RGB blending.
   Draw from image coordinates `(0, 64)` to `(256, 64)` and commit with Enter.
3. `record`: save `effect-gradient.xcf` and the resource API snapshot.
4. `edit`: remove the filter and modify the same gradient resource through
   GIMP's APIs. Draw and commit the same line again.
5. `record-edited`: save the independently edited file and snapshot.

The checked-in files used an isolated Ubuntu 26.04 container with Xvfb/Openbox
and the official AppImage. The image was displayed at 100% zoom. No interactive
GIMP settings or resources from the user's profile were used.

## Reproduce the codec comparisons

From the package root:

```sh
dart run tool/check_corpus.dart test/fixtures/gimp-development --metadata \
  --round-trip --output=build/gradient-roundtrip
dart run tool/write_gradient_edits.dart build/gradient-edits
XCF_INPUT="$PWD/build/gradient-roundtrip" \
  XCF_REFERENCE="$PWD/test/fixtures/gimp-development" \
  XCF_OUTPUT="$PWD/build/gradient-reference.json" \
  gimp-3.3 -n -i --batch-interpreter=python-fu-eval \
  -b 'exec(open("tool/gimp_reference.py").read())' --quit
XCF_INPUT="$PWD/build/gradient-edits" \
  XCF_REFERENCE="$PWD/test/fixtures/gimp-development" \
  XCF_OUTPUT="$PWD/build/gradient-edits-reference.json" \
  gimp-3.3 -n -i --batch-interpreter=python-fu-eval \
  -b 'exec(open("tool/gimp_reference.py").read())' --quit
```

Here `gimp-3.3` denotes the pinned development executable, not the stable GIMP
binary. Require two successful comparisons in the first report and one in the
second, all with `equal_to_original: true`. A zero batch exit status alone is
insufficient. Normal `dart test` uses the committed independent references and
does not require GIMP. These original fixtures and generators use the package's
MIT license.
