# Contributing to XcfKit

Use the Dart SDK version declared in `pubspec.yaml`. Run `dart pub get`, then:

```sh
dart format --output=none --set-exit-if-changed .
dart analyze
dart test
dart test --platform node
```

Keep format models independent of Flutter, native libraries, and Focale. Document public and private APIs, preserve caller-owned values, and add regression tests for parser or writer changes. Match the conventions in `AGENTS.md` and use Conventional Commits when preparing commits.

Compatibility changes should be based on the official specification and real files. Preserve opaque data when safe; reject transformations which would leave stale pointers or silently discard unsupported content. Update `docs/XCF.md` whenever support changes.

External corpora stay outside the published package and Git history. Pin source revisions, sizes, SHA-256 values, and provenance in the corpus manifest. Do not assume that a repository's code license covers every embedded artwork. See `test/corpus/README.md` for local-only downloads and GIMP oracle commands.

A decode/write/read test is not independent interoperability evidence. For writer changes, reopen emitted files in GIMP and compare raw samples, document structure, and the rendered composite with the original. State the GIMP version and any untested features.
