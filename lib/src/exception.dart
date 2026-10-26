/// A malformed XCF structure or an exceeded decoding limit.
class XcfFormatException extends FormatException {
  /// Creates an error with an optional byte offset in the input.
  const XcfFormatException(String message, {int? offset}) : super(message, null, offset);
}

/// A valid feature which this codec or operation cannot safely handle.
final class XcfUnsupportedException extends XcfFormatException {
  /// Creates an explicit unsupported-feature error.
  const XcfUnsupportedException(super.message, {super.offset});
}
