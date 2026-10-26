/// Optional whole-file envelopes, separate from XCF's per-tile compression.
///
/// Importing `xcfkit.dart` alone does not pull these envelope codecs into a build.
/// This convenience API is bounded but in-memory; unwrap large files to a
/// temporary seekable file before opening them lazily.
library;

export 'src/envelope.dart';
export 'xcfkit.dart';
