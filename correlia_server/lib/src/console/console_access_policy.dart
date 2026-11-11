import 'package:relic_core/relic_core.dart';

import '../generated/protocol.dart';
import '../runtime/process_options.dart';

/// Restricts the unauthenticated console to local development and test use.
abstract final class ConsoleAccessPolicy {
  /// Throws [ConsoleAccessDeniedException] unless the request is local and safe.
  static void check(String runMode, ProcessRole role, Request? request) {
    if ((runMode != 'development' && runMode != 'test') ||
        (role != ProcessRole.api && role != ProcessRole.all) ||
        request == null ||
        !_loopback(request.connectionInfo.remote.address) ||
        !_allowedHost(request.headers['host']) ||
        !_allowedOrigin(request.headers['origin'])) {
      throw ConsoleAccessDeniedException(message: 'Console access denied');
    }
  }

  static bool _loopback(IPAddress address) {
    final bytes = address.bytes;
    if (bytes.length == 4) return bytes[0] == 127;
    if (bytes.length != 16) return false;
    for (var i = 0; i < 10; i++) {
      if (bytes[i] != 0) return false;
    }
    // A dual-stack listener represents IPv4 TCP peers as ::ffff:a.b.c.d.
    if (bytes[10] == 255 && bytes[11] == 255) return bytes[12] == 127;
    for (var i = 10; i < 15; i++) {
      if (bytes[i] != 0) return false;
    }
    return bytes[15] == 1;
  }

  static bool _hostName(String host) =>
      host == 'localhost' ||
      host == '127.0.0.1' ||
      host == '[::1]' ||
      host == '::1';

  static bool _allowedHost(Iterable<String>? values) {
    if (values == null || values.length != 1) return false;
    final raw = values.single;
    try {
      final uri = Uri.parse('http://$raw');
      return uri.hasAuthority &&
          uri.userInfo.isEmpty &&
          uri.path.isEmpty &&
          !uri.hasQuery &&
          !uri.hasFragment &&
          _hostName(uri.host) &&
          (!uri.hasPort || uri.port <= 65535);
    } on FormatException {
      return false;
    }
  }

  static bool _allowedOrigin(Iterable<String>? values) {
    if (values == null) return true;
    if (values.length != 1) return false;
    try {
      final uri = Uri.parse(values.single);
      return uri.scheme == 'http' &&
          uri.hasAuthority &&
          uri.userInfo.isEmpty &&
          uri.path.isEmpty &&
          !uri.hasQuery &&
          !uri.hasFragment &&
          _hostName(uri.host) &&
          (!uri.hasPort || uri.port <= 65535);
    } on FormatException {
      return false;
    }
  }
}
