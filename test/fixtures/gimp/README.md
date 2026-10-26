# Original GIMP fixtures

Generated with GIMP 3.2.2 on 2026-10-26 by `tool/generate_gimp_fixtures.py` and
`tool/generate_semantic_fixtures.py`, and `tool/generate_metadata_fixtures.py`. The imagery is procedural. Text uses the
installed Nimbus Sans Regular font; no font files are redistributed. Files and
generators are covered by the package's MIT license.

The twenty-three files exercise six sample formats (u8/u16/u32/half/float/double), partial
edge tiles, a group, an offset layer, a raster mask, a modern vector path, and a
non-destructive GEGL brightness effect. The float fixture includes HDR and
negative values. The semantic additions cover editable text and a rendered edit,
legacy vector strokes, and floating selections attached to a layer, its mask,
a saved channel, or a child layer inside a group. Metadata fixtures cover old compatibility paths, global text options and contours, nested Pango styles with Unicode, GEGL colors, and a linked layer with a transform. `link-source.ppm` is a procedural asset for that link.

`reference.json` was produced by GIMP's Python/GEGL API, with native-endian sample
bytes converted to big-endian before SHA-256 hashing. It also records structural
metadata and a hash of GIMP's RGBA8 composite. Every file was rewritten by XcfKit
and independently reopened in GIMP with equality to the original.

`edits-reference.json` records eight edits independently made in GIMP by
`tool/gimp_semantic_edits.py`. XcfKit performs equivalent edits using
`tool/write_semantic_edits.dart`. All eight files were reopened in GIMP, with
matching text, paths, effect arguments, exact samples, and rendered composites.
GIMP normalizes layer order and membership for the grouped floating-selection
fixture on load. The codec retains the source item paths; offline comparison
uses tattoos to identify the same layers after GIMP's normalization.

Regenerate from the repository root (with GIMP's Python batch interpreter):

```sh
XCF_FIXTURES="$PWD/test/fixtures/gimp" gimp -n -i -d -s \
  --batch-interpreter=python-fu-eval \
  -b 'exec(open("tool/generate_gimp_fixtures.py").read())' --quit
XCF_FIXTURES="$PWD/test/fixtures/gimp" gimp -n -i \
  --batch-interpreter=python-fu-eval \
  -b 'exec(open("tool/generate_semantic_fixtures.py").read())' --quit
XCF_FIXTURES="$PWD/test/fixtures/gimp" gimp -n -i \
  --batch-interpreter=python-fu-eval \
  -b 'exec(open("tool/generate_metadata_fixtures.py").read())' --quit
```

Reproduce the semantic edit comparison:

```sh
dart run tool/write_semantic_edits.dart build/semantic-edits
XCF_INPUT="$PWD/test/fixtures/gimp" XCF_OUTPUT="$PWD/build/semantic-expected" \
  gimp -n -i --batch-interpreter=python-fu-eval \
  -b 'exec(open("tool/gimp_semantic_edits.py").read())' --quit
XCF_INPUT="$PWD/build/semantic-edits" XCF_REFERENCE="$PWD/build/semantic-expected" \
  XCF_OUTPUT="$PWD/build/semantic-edits-reference.json" \
  gimp -n -i --batch-interpreter=python-fu-eval \
  -b 'exec(open("tool/gimp_reference.py").read())' --quit
```

Check that the report contains exactly eight successful entries with
`equal_to_original: true`; a zero GIMP exit status alone is insufficient.

For a Flatpak install, replace `gimp` with `flatpak run org.gimp.GIMP`, grant it
access to the checkout if necessary, and pass the environment variables with
Flatpak's `--env=NAME=value` options. See `test/corpus/README.md` for the oracle
command and the distinction between offline tests and actual reopening.
