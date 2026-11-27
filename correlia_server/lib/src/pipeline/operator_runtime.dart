import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:serverpod/serverpod.dart';

import '../generated/protocol.dart';
import '../ingest/admission.dart' show constantTimeDigestEquals;
import '../ingest/bootstrap.dart' show readBootstrapFile;
import '../runtime/process_options.dart';
import '../runtime/subsystem.dart';
import '../secrets/secret_store.dart';

/// Role-owned configuration for the generated queue operator endpoint.
final class OperatorRuntime extends Subsystem {
  OperatorRuntime(
    this.pod, {
    required this.path,
    required this.ready,
    required this.secretStore,
  });

  static final _instances = Expando<OperatorRuntime>();
  static final _machineId = RegExp(r'^[a-z][a-z0-9_-]{0,63}$');
  static final _digest = RegExp(r'^[0-9a-f]{64}$');
  static final _bearer = RegExp(
    r'^Bearer ([a-zA-Z0-9_-]{43})$',
    caseSensitive: false,
  );

  final Serverpod pod;
  final String? path;
  final bool Function() ready;
  final SecretStore? Function() secretStore;
  Map<String, String> _credentials = const {};

  @override
  String get name => 'dead-letter-operators';

  @override
  Set<ProcessRole> get roles => const {ProcessRole.api, ProcessRole.all};

  @override
  Future<void> start() async {
    if (path case final file?) {
      try {
        final text = utf8.decode(
          await readBootstrapFile(
            file,
            'operator',
            cap: 4096,
            private: true,
          ),
        );
        final value = jsonDecode(text);
        if (value is! Map<String, Object?> ||
            value.isEmpty ||
            value.length > 8) {
          throw const FormatException();
        }
        final credentials = <String, String>{};
        final digests = <String>{};
        for (final MapEntry(:key, :value) in value.entries) {
          if (_machineId.firstMatch(key)?.end != key.length ||
              value is! String ||
              value.length != 64 ||
              !_digest.hasMatch(value) ||
              !digests.add(value)) {
            throw const FormatException();
          }
          credentials[key] = value;
        }
        // These flat fields cannot contain a colon. Any extra separator in
        // the original object belongs to a member jsonDecode collapsed.
        var remaining = credentials.length;
        for (
          var colon = text.indexOf(':');
          colon >= 0;
          colon = text.indexOf(':', colon + 1)
        ) {
          if (--remaining < 0) throw const FormatException();
        }
        _credentials = credentials;
      } catch (_) {
        throw const FormatException('dead-letter operator file invalid');
      }
    }
    _instances[pod] = this;
  }

  @override
  Future<void> stop() async {
    _instances[pod] = null;
    _credentials = const {};
  }

  static Uint8List? _decodeBearer(String token) {
    try {
      return base64Url.decode('$token=');
    } on FormatException {
      // Decoder failures can include the supplied credential.
      return null;
    }
  }

  /// Returns the actor from a valid Authorization header, never an RPC field.
  static (String, SecretStore?) authorize(Session session) {
    final runtime = _instances[session.serverpod];
    if (runtime != null && runtime._credentials.isNotEmpty && runtime.ready()) {
      final headers = session.request?.headers['authorization'];
      if (headers != null && headers.length == 1) {
        final header = headers.single;
        final match = header.length == 50 ? _bearer.firstMatch(header) : null;
        if (match != null && match.end == header.length) {
          final token = match[1]!;
          final bytes = _decodeBearer(token);
          if (bytes != null && base64Url.encode(bytes) == '$token=') {
            final digest = sha256.convert(bytes).toString();
            String? actor;
            for (final MapEntry(:key, :value) in runtime._credentials.entries) {
              if (constantTimeDigestEquals(value, digest)) actor = key;
            }
            if (actor != null) return (actor, runtime.secretStore());
          }
        }
      }
    }
    throw QueueOperatorException(code: 'operator_access_denied');
  }
}
