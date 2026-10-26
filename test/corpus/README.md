# External XCF corpus

Downloaded and verified on 2026-10-26. `manifest.json` pins 865 downloaded
artifacts (191,314,198 bytes), including 833 XCF inputs after expanding four
GZIP and two XZ wrappers, PNG references, and upstream license/documentation files.

## Sources

| Source | Pinned revision | XCF files |
| --- | --- | ---: |
| [GIMP](https://github.com/GNOME/gimp) | `03244d0fece4e9fc0cb5be41bbc05c351b43c7a6` | 3 |
| [GIMP resources](https://github.com/GNOME/gimp-data) | `dba1b6d3d5e0703c5337c9ec32805ac017dc1270` | 110 |
| [KDE kimageformats](https://github.com/KDE/kimageformats) | `a9faf5feeed8985adf4d80a315d9b93d6c82b6ea` | 27 |
| [GimpFormats](https://github.com/FHPythonUtils/GimpFormats) | `d3181b81a1accab51f6e892ec019ac0664ec83fc` | 30 |
| [PhotoCraft corpus](https://github.com/storytold/photocraft-corpus) | `c3abfc1c794409a71ade6a22283caab4ba4d2aa8` | 14 |
| [XCF Test Suite repository](https://github.com/ali1234/xcftestsuite) | `c48427821264deb45cededc084867afc7a8e64dd` | 1 |
| [XCF Test Suite generated cases](https://xcf.zerostem.io/) | hosted artifacts pinned individually by SHA-256 | 648 |

The hosted suite contains opacity/mode combinations rather than 648 independent
artworks. Repository revisions identify the source projects; the hosted outputs
are pinned by hashes, not claimed to be reproducibly derived from that commit.
GimpFormats downloads exclude empty files and files larger than 35 MB. Corpus
diversity includes old XCF versions, RGB/gray/indexed images, groups, masks,
selections, paths, editable text, ICC profiles, high precision, and large layers.

Upstream project licensing includes GPL for GIMP, multiple licenses for KDE,
LGPL for GimpFormats, MIT/Apache for PhotoCraft, and MIT for the XCF Test Suite
code. These do not automatically establish licenses for all embedded artwork,
including the custom-font artwork. All downloaded files remain local, ignored
by Git and excluded from the published package; they are not relicensed or
redistributed by XcfKit. The manifest, provenance, and scripts are tracked.

## Reproduce the corpus

```sh
python3 tool/fetch_corpus.py
python3 tool/fetch_corpus.py --verify-only
dart run tool/check_corpus.dart --round-trip --output=build/roundtrip
dart run tool/check_corpus.dart --round-trip --metadata
```

The downloader refuses changed hashes or sizes. Two known corrupt files and one empty upstream placeholder are
expected to fail decoding:

- `FHPythonUtils/test_files/64x64_copy.xcf`: invalid canvas dimensions.
- `FHPythonUtils/test_files/base24copy.xcf`: invalid property layout.
- `gimp-data/icons/Legacy/22/gimp-tool-handle-transform.xcf`: empty file.

GIMP 3.2.2 also rejected the two malformed nonempty files, reporting that it could not salvage image data.
The checker requires these specific rejections; an unexpected failure or an
unexpected acceptance makes the command fail.

## Independent GIMP validation

The original run used GIMP 3.2.2 in an isolated Ubuntu 26.04 container. GIMP was
used only as a test oracle, not as a runtime dependency. All 721 valid files
were rebuilt by XcfKit, reopened in GIMP, and compared with their originals:

- Layer hierarchy, names, offsets, visibility, opacity, mode, and group state.
- Exact non-group layer pixels, masks, saved channels, and active selection.
- Vector path control points and available effect configuration scalars.
- GIMP's merged RGBA8 result, compared by SHA-256.

All 721 comparisons matched. This proves preservation for those documents; it
does not prove that XcfKit itself renders their blend modes or effects.

Run against an installed GIMP with the Python batch interpreter:

```sh
XCF_INPUT="$PWD/build/roundtrip" \
XCF_REFERENCE="$PWD/test/corpus" \
XCF_OUTPUT="$PWD/test/corpus/gimp-reference.json" \
gimp -n -i -d -s --batch-interpreter=python-fu-eval \
  -b 'exec(open("tool/gimp_reference.py").read())' --quit

XCF_CORPUS=1 dart test test/gimp_fixtures_test.dart
```

For Flatpak, pass the same paths through `flatpak run --filesystem="$PWD"` and
`--env=XCF_INPUT=... --env=XCF_REFERENCE=... --env=XCF_OUTPUT=... org.gimp.GIMP`.
The script reads only the supplied input and reference paths and writes the
report. It does not save over either document.

A complete current report must contain 830 successful entries with `equal_to_original: true`.
GIMP can return exit status zero even when a batch script reports a failure, so
inspect the JSON as well as the process status. The optional corpus tests compare
the codec's exact samples directly with this independently generated report.

## Independent encoder cases

`dart run tool/write_interop_fixtures.dart` creates 54 new files: 18 precisions
times raw/RLE/zlib compression. Point `XCF_INPUT` at `build/interop`, omit
`XCF_REFERENCE`, and compare the resulting layer hashes against
`build/interop/expected.json`. All 54 were reopened in GIMP with byte-exact sample
matches, including multi-tile images and binary64 samples.

Twenty-three original procedural fixtures are also committed under `test/fixtures/gimp`
so normal offline tests do not depend on downloaded artwork or a GIMP install.

The semantic API validation additionally compares plain/styled text and text-option editing,
three path generations, and brightness/color editing with the same operations
performed through GIMP's own APIs. All eight comparisons matched, including
rendered composites. Twenty-three original fixtures also pass GIMP reopening after
rewrite, including floating selections inside groups and mask/channel targets.
The offline corpus checks additionally compare supported typed path geometry
and GEGL scalar arguments against the GIMP reference report.

The metadata corpus pass also parses text options, inline style ranges, all three
path generations, and supported effect resources for every valid document.
Embedded gradients have two independently authored fixtures and one semantic
edit under `test/fixtures/gimp-development`, validated with a pinned GIMP 3.3.1
development build. These are separate from the stable-version external corpus.

## Additional validation of the five workstreams

The added GIMP resource corpus includes 110 inputs, four of which are stored in
GZIP/XZ envelopes upstream. Its 109 nonempty files pass exact sample/metadata
round-trip checks; each rewrite was also reopened and compared with its original
in GIMP 3.2.2, including composed-image hashes. All 109 comparisons matched.
Together with the original 721 valid cases this gives 830 valid XCF inputs and
three expected rejections. All 865 downloaded artifacts pass size/SHA-256 checks.

`test/fixtures/gimp-advanced` adds eight procedural files (vectors, curves,
document metadata and three compressed envelopes), with two independently
authored semantic edits. Reopening uses the pinned GIMP 3.3.1 build to inspect
vector options unavailable through the stable build's API after loading.
All eight rewrites and both edits match GIMP's metadata and composite pixels.
See its README for detailed limitations and independent reference provenance.

File I/O tests include a real sparse file with structures past the 4 GiB boundary.
`tool/large_file_smoke.dart` generates and transcodes a 1 GiB tiled raster under a
1 MiB per-read limit, without holding full decoded or encoded files in memory.
The measurements and runtime coverage are documented in [validation](../../docs/VALIDATION.md).
