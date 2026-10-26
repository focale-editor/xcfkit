# Third-party notices

The Dart implementation is original code, distributed under the MIT license in `LICENSE`. Its runtime dependencies, ZCodec and xml, are separately distributed Dart packages with their own licenses. The crypto package is used only by tests and validation tools.

The [GIMP XCF documentation](https://developer.gimp.org/core/standards/xcf/) and the GIMP source were consulted as format references. GIMP, GEGL, and their source code are not bundled, linked, or executed by the package.

`test/fixtures/gimp-advanced` contains procedural vectors, curves, metadata and compressed files generated with GIMP 3.2.2 and validated with the pinned 3.3.1 build. `test/fixtures/gimp` contains original procedural images generated for this package through GIMP 3.2.2. `test/fixtures/gimp-development` contains original procedural gradients authored with the pinned GIMP 3.3.1 development build described in its README. Their generator and sample data are covered by this repository's MIT license; no third-party artwork is used there.

Downloaded test data is excluded from Git and publication. `test/corpus/manifest.json` records provenance and hashes; upstream licenses remain in the local corpus directories. Test-data copyright may differ from each upstream project's source-code license. These downloads are for local interoperability testing and are not relicensed by XcfKit. See `test/corpus/README.md`.
