# Contributing to XcfKit

Bug reports, focused fixes, documentation improvements, and well-scoped features are welcome.

## Before you start

- Search existing issues before opening a new one.
- Include a minimal reproduction, the Dart SDK version, and the GIMP version or other writer that produced the file.
- Share sample files only when their license and contents permit it. Do not include secrets, private artwork, or personal data in a public report.

## Development setup

Use a Dart SDK compatible with the constraint in [`pubspec.yaml`](pubspec.yaml). From the package checkout, install dependencies with:

```sh
dart pub get
```

Match the conventions in [`AGENTS.md`](AGENTS.md) and keep each change focused on one fix or feature.

## Making changes

- Keep format models independent of Flutter, native libraries, and Focale. Composition, color management, text layout, and effect execution belong to the host application.
- Document public and private APIs, preserve caller-owned values, and add regression tests for parser or writer changes.
- Base compatibility changes on the official specification and real files.
- Preserve opaque data when safe; reject transformations that would leave stale pointers or silently discard unsupported content.
- Update the [technical reference](docs/XCF.md), examples, and README when support or public behavior changes.

External corpora stay outside the published package and Git history. Pin source revisions, sizes, SHA-256 values, and provenance in the corpus manifest. Do not assume that a repository's code license covers every embedded artwork.

## Quality checks

Before opening a pull request, run:

```sh
dart format --output=none --set-exit-if-changed .
dart analyze
dart test
dart test --platform node
```

Add the relevant [corpus checks](docs/XCF.md#corpus-validation) for format changes. A decode/write/read test is not independent interoperability evidence: for writer changes, reopen emitted files in GIMP and compare raw samples, document structure, and the rendered composite with the original. State the GIMP version and any untested features. See [corpus provenance and GIMP oracle commands](test/corpus/README.md).

## Pull requests

Explain the problem and solution, link a related issue when applicable, and describe the checks and platforms exercised. Call out compatibility, performance, licensing, or migration implications. If a check cannot run in your environment, explain why.

Use Conventional Commits for commit messages and pull request titles, such as `fix:`, `feat:`, `docs:`, `test:`, or `refactor:`. Keep review follow-up changes on the same branch.
