# Advanced XCF fixtures

Original procedural images authored by `tool/generate_advanced_fixtures.py` using
GIMP 3.2.2 in an isolated Ubuntu 26.04 container. They are MIT-licensed test data;
no downloaded artwork is redistributed here. `manifest.json` records hashes.

The eight files cover two vector-layer variants, two editable curves variants,
resolution, off-canvas guides, sample points, a custom unit, an opaque binary
parasite, and GZIP/BZIP2/XZ envelopes written by GIMP. Vector stroke fields include
fractional width, caps, joins, miter limit and a custom dash sequence; saved
pattern references are retained even when solid-color painting is selected.

`reference.json` was obtained by reopening XcfKit's rewrites and their originals
with GIMP 3.3.1 development, commit
`a39a8a7e824fb11810baeeebd6c4edd03865768f`, official pipeline 1132142 / job 7242523.
The x86_64 AppImage SHA-256 is
`af89282e2e11d1fde628eb0b87ad3a28d914a76d85c69ed9b76ef124fc89bb90`.
GIMP 3.2.2 returns unavailable vector paint/stroke options after reopening these
files; the pinned development build exposes them correctly. Authoring-time
values from 3.2.2 are retained separately in the two `*-authoring.json` files.

All eight rewrite comparisons matched exact raster samples and the GIMP-rendered
composite, as well as the additional document/vector/curve metadata. Babl's color
API can round float components during load/conversion, so offline color checks
allow an absolute 1e-6 tolerance. Raw property preservation remains byte-exact.
The stable writer also under-declares the old custom-unit payload length; the
codec repairs that known form and retains the complete five-string definition.

`edits-reference.json` compares the two outputs of `tool/write_advanced_edits.dart`
with independently authored GIMP counterparts: vector width/fill changes and
value-channel curve points. Both comparisons matched, including composite hashes.
The host-rendered target vector raster and curve sample table are supplied from
the independent fixtures; XcfKit does not render or interpolate them. Curve edits
must target the appropriate repeated `curve` occurrence while preserving channel
assignment order. Other channels are checked unchanged in the offline tests.

Reproduce using GIMP's Python interpreter (with environment paths adjusted):

```sh
XCF_FIXTURES="$PWD/build/advanced-original" gimp -n -i \
  --batch-interpreter=python-fu-eval \
  -b 'exec(open("tool/generate_advanced_fixtures.py").read())' --quit

dart run tool/write_advanced_edits.dart build/advanced

XCF_TOOLS="$PWD/tool" XCF_INPUT="$PWD/build/advanced/rewrites" \
XCF_REFERENCE="$PWD/test/fixtures/gimp-advanced" \
XCF_OUTPUT="$PWD/build/advanced-reference.json" gimp -n -i \
  --batch-interpreter=python-fu-eval \
  -b 'exec(open("tool/gimp_advanced_reference.py").read())' --quit
```

The final command must use the pinned build for comparable vector API results.
Inspect JSON successes and equality fields; GIMP may exit zero after batch errors.
These fixtures do not establish support for every GIMP resource or future field.
