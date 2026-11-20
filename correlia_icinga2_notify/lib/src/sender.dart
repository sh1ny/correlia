import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'arguments.dart';
import 'failure.dart';
import 'files.dart';
import 'signing.dart';

/// Credential files (token or HMAC key) are at most this large.
const maxCredentialBytes = 4096;

/// The CA file is at most this large.
const maxCaBytes = 1024 * 1024;

/// The distribution CA bundles, tried in order when no `--ca-file` is given.
const distributionCaBundles = [
  '/etc/ssl/certs/ca-certificates.crt',
  '/etc/pki/tls/certs/ca-bundle.crt',
  '/etc/ssl/ca-bundle.pem',
  '/etc/ssl/cert.pem',
];

final _keyForm = RegExp(r'^[A-Za-z0-9_-]{43}$');
final _tokenForm = RegExp(r'^[\x21-\x7e]+$');

/// Posts one webhook document and returns the process exit code.
///
/// Exit 0 only for HTTP 202, 1 for any other status, 2 for a configuration
/// error, 3 for a connection, TLS or [deadline] failure. At most one line is
/// handed to [writeError] (default: stderr), holding only a status or an error
/// class, never a response body, token, key or signature.
///
/// The collaborators are injectable for tests: [files], [deadline],
/// [environmentIsEmpty] (default: the process environment is empty; its values
/// are never read), [clock] (the HMAC timestamp) and [bundlePaths].
Future<int> runSender(
  List<String> args, {
  SenderFiles files = const DiskFiles(),
  Duration deadline = const Duration(seconds: 10),
  bool Function()? environmentIsEmpty,
  DateTime Function()? clock,
  List<String> bundlePaths = distributionCaBundles,
  void Function(String line)? writeError,
}) async {
  final void Function(String) write = writeError ?? stderr.writeln;
  final finished = Completer<int>();
  final cleanups = <void Function()>[];
  void finish(int code, String? line) {
    if (finished.isCompleted) return;
    if (line != null) write(line);
    finished.complete(code);
  }

  // The whole-run deadline starts before anything else and covers everything.
  final timer = Timer(deadline, () => finish(3, 'deadline'));
  unawaited(
    _deliver(
      args,
      files: files,
      environmentIsEmpty:
          environmentIsEmpty ?? () => Platform.environment.isEmpty,
      clock: clock ?? DateTime.now,
      bundlePaths: bundlePaths,
      cleanups: cleanups,
    ).then(
      (status) => switch (status) {
        202 => finish(0, null),
        _ => finish(1, 'status $status'),
      },
      onError: (Object error) => switch (error) {
        SenderExit(:final code, :final line) => finish(code, line),
        _ => finish(1, 'internal'),
      },
    ),
  );
  final code = await finished.future;
  timer.cancel();
  for (final cleanup in cleanups) {
    cleanup();
  }
  return code;
}

/// Runs the delivery and returns the HTTP status; throws [SenderExit].
Future<int> _deliver(
  List<String> args, {
  required SenderFiles files,
  required bool Function() environmentIsEmpty,
  required DateTime Function() clock,
  required List<String> bundlePaths,
  required List<void Function()> cleanups,
}) async {
  if (!environmentIsEmpty()) throw const SenderExit.config('environment');
  final arguments = SenderArguments.parse(args);
  final uri = _destination(arguments);

  final credentialName = arguments.credentialKind.argument;
  final credential = await _readChecked(
    files,
    arguments.credentialPath,
    credentialName,
    maxCredentialBytes,
    mode: _ModeRule.credential,
  );
  final (authorization, key) = switch (arguments.credentialKind) {
    CredentialKind.token => ('Bearer ${_token(credential)}', null),
    CredentialKind.hmacKey => (null, _hmacKey(credential)),
  };

  final context = SecurityContext(withTrustedRoots: false);
  if (uri.scheme == 'https') {
    final (bytes, name) = await _trust(files, arguments.caPath, bundlePaths);
    try {
      context.setTrustedCertificatesBytes(bytes);
    } on TlsException {
      throw SenderExit.config('invalid_ca $name');
    }
  }

  final body = utf8.encode(jsonEncode(arguments.document));
  final client = HttpClient(context: context)
    ..findProxy = ((_) => 'DIRECT')
    ..userAgent = 'correlia-icinga2-notify';
  cleanups.add(() => client.close(force: true));
  try {
    final request = await client.postUrl(uri);
    request
      ..followRedirects = false
      ..headers.set('content-type', 'application/json')
      ..contentLength = body.length;
    if (authorization != null) {
      request.headers.set('authorization', authorization);
    }
    if (key != null) {
      final timestamp = (clock().millisecondsSinceEpoch ~/ 1000).toString();
      request.headers
        ..set('x-correlia-timestamp', timestamp)
        ..set(
          'x-correlia-signature',
          'sha256=${ingressSignature(key, timestamp, body)}',
        );
    }
    request.add(body);
    final response = await request.close();
    return response.statusCode;
  } on TlsException {
    throw const SenderExit.connection('tls');
  } on IOException {
    throw const SenderExit.connection('connection');
  }
}

/// Builds `<base-url>/hooks/icinga2/<source>` after the transport rules.
Uri _destination(SenderArguments arguments) {
  final Uri base;
  try {
    base = Uri.parse(arguments.baseUrl);
  } on FormatException {
    throw const SenderExit.config('invalid_argument --base-url');
  }
  if (base.host.isEmpty) {
    throw const SenderExit.config('invalid_argument --base-url');
  }
  switch (base.scheme) {
    case 'https':
      break;
    case 'http' when _isLiteralLoopback(base.host):
      break;
    default:
      throw const SenderExit.config('invalid_argument --base-url');
  }
  return base.replace(path: '/hooks/icinga2/${arguments.source}');
}

/// Whether [host] is a literal address in 127.0.0.0/8 or `::1`.
bool _isLiteralLoopback(String host) {
  final address = InternetAddress.tryParse(host);
  if (address == null) return false;
  final bytes = address.rawAddress;
  return switch (address.type) {
    InternetAddressType.IPv4 => bytes[0] == 127,
    InternetAddressType.IPv6 =>
      bytes.sublist(0, 15).every((byte) => byte == 0) && bytes[15] == 1,
    _ => false,
  };
}

/// Which permission rule the stat precheck applies.
enum _ModeRule {
  /// Any group or other permission bit is refused (`credential_mode`).
  credential('credential_mode', 0x3f),

  /// A group or other write bit is refused (`ca_mode`).
  ca('ca_mode', 0x12);

  const _ModeRule(this.line, this.forbidden);
  final String line;
  final int forbidden;
}

/// Checks [path] with `stat` and reads it, at most [cap] bytes.
///
/// A path that is not a regular file is never opened. The cap is enforced on
/// the bytes actually read: the stream is asked for [cap] plus one byte and
/// the extra byte is an error, so a file that grew after the check cannot
/// exceed it.
Future<Uint8List> _readChecked(
  SenderFiles files,
  String path,
  String argument,
  int cap, {
  required _ModeRule mode,
}) async {
  final info = await files.stat(path);
  if (info.type != FileSystemEntityType.file) {
    throw SenderExit.config('not_regular $argument');
  }
  if (info.mode & mode.forbidden != 0) {
    throw SenderExit.config('${mode.line} $argument');
  }
  if (info.size > cap) throw SenderExit.config('too_large $argument');
  final bytes = BytesBuilder(copy: false);
  try {
    await for (final chunk in files.open(path, cap + 1)) {
      bytes.add(chunk);
      if (bytes.length > cap) throw SenderExit.config('too_large $argument');
    }
  } on FileSystemException {
    // An open or read the user may not make (mode 000, say) is a
    // configuration error naming only the argument, never the OS message.
    throw SenderExit.config('unreadable $argument');
  }
  return bytes.takeBytes();
}

/// The configured CA file, or the first existing distribution bundle.
Future<(Uint8List, String)> _trust(
  SenderFiles files,
  String? caPath,
  List<String> bundlePaths,
) async {
  if (caPath != null) {
    final bytes = await _readChecked(
      files,
      caPath,
      '--ca-file',
      maxCaBytes,
      mode: _ModeRule.ca,
    );
    return (bytes, '--ca-file');
  }
  for (final path in bundlePaths) {
    final info = await files.stat(path);
    if (info.type == FileSystemEntityType.notFound) continue;
    final bytes = await _readChecked(
      files,
      path,
      'ca_bundle',
      maxCaBytes,
      mode: _ModeRule.ca,
    );
    return (bytes, 'ca_bundle');
  }
  throw const SenderExit.config('ca_missing');
}

/// The bearer token: its text, with one trailing newline allowed.
String _token(Uint8List bytes) {
  final text = _withoutNewline(bytes, '--token-file');
  if (!_tokenForm.hasMatch(text)) {
    throw const SenderExit.config('invalid_credential --token-file');
  }
  return text;
}

/// The HMAC key: 43 unpadded base64url characters and an optional trailing
/// newline, decoding to exactly 32 bytes, as Correlia's `decodeCredential`.
Uint8List _hmacKey(Uint8List bytes) {
  final text = _withoutNewline(bytes, '--hmac-key-file');
  if (_keyForm.hasMatch(text)) {
    try {
      final key = base64Url.decode('$text=');
      if (key.length == 32 &&
          base64Url.encode(key).replaceAll('=', '') == text) {
        return Uint8List.fromList(key);
      }
    } on FormatException {
      // Falls through to the error below.
    }
  }
  throw const SenderExit.config('invalid_credential --hmac-key-file');
}

String _withoutNewline(Uint8List bytes, String argument) {
  final end = bytes.isNotEmpty && bytes.last == 0x0a
      ? bytes.length - 1
      : bytes.length;
  try {
    return ascii.decode(bytes.sublist(0, end));
  } on FormatException {
    throw SenderExit.config('invalid_credential $argument');
  }
}
