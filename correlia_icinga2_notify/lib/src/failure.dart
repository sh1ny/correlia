/// An orderly end of the run: the exit [code] and the one stderr [line].
///
/// The line holds only a status or an error class and, for a configuration
/// error, the name of the argument. Never a body, token, key or signature.
final class SenderExit implements Exception {
  /// Creates an exit with [code] and [line].
  const SenderExit(this.code, this.line);

  /// A configuration error (exit 2) naming [detail], usually an argument.
  const SenderExit.config(String detail) : this(2, detail);

  /// A connection, TLS or deadline failure (exit 3).
  const SenderExit.connection(String line) : this(3, line);

  /// The process exit code.
  final int code;

  /// The single diagnostic line.
  final String line;
}
