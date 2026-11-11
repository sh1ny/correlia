import 'package:correlia_server/src/console/console_access_policy.dart';
import 'package:correlia_server/src/generated/protocol.dart';
import 'package:correlia_server/src/runtime/process_options.dart';
import 'package:relic_core/relic_core.dart';
import 'package:test/test.dart';

Request _request({
  String peer = '127.0.0.1',
  String host = 'localhost:8080',
  String? origin,
  String? forwarded,
}) => RequestInternal.create(
  Method.get,
  Uri.parse('http://localhost:8080/'),
  Object(),
  headers: Headers.fromMap({
    'host': [host],
    if (origin != null) 'origin': [origin],
    if (forwarded != null) 'x-forwarded-for': [forwarded],
  }),
  connectionInfo: ConnectionInfo(
    remote: SocketAddress(address: IPAddress.parse(peer), port: 1234),
    localPort: 8080,
  ),
);

void main() {
  void check({
    String mode = 'development',
    ProcessRole role = ProcessRole.all,
    Request? request,
  }) => ConsoleAccessPolicy.check(mode, role, request);
  final denied = throwsA(isA<ConsoleAccessDeniedException>());

  test('production_mode_refuses', () {
    expect(() => check(mode: 'production', request: _request()), denied);
  });
  test('non_loopback_peer_refuses', () {
    expect(() => check(request: _request(peer: '192.0.2.1')), denied);
    expect(
      () => check(request: _request(peer: '::ffff:c000:201')),
      denied,
    );
    expect(
      () => check(
        request: _request(peer: '192.0.2.1', forwarded: '127.0.0.1'),
      ),
      denied,
    );
  });
  test('rejects non-loopback hosts and foreign origins', () {
    expect(() => check(request: _request(host: 'example.com')), denied);
    expect(
      () => check(request: _request(origin: 'http://evil.example')),
      denied,
    );
    expect(() => check(request: _request(origin: 'https://localhost')), denied);
  });
  test('rejects worker and null request', () {
    expect(() => check(role: ProcessRole.worker, request: _request()), denied);
    expect(() => check(), denied);
  });
  test('allows development and test loopback requests', () {
    for (final mode in ['development', 'test']) {
      for (final role in [ProcessRole.api, ProcessRole.all]) {
        expect(
          () => check(
            mode: mode,
            role: role,
            request: _request(origin: 'http://localhost:3000'),
          ),
          returnsNormally,
        );
        expect(
          () => check(
            mode: mode,
            role: role,
            request: _request(
              peer: '::1',
              host: '[::1]:8080',
              origin: 'http://[::1]:3000',
            ),
          ),
          returnsNormally,
        );
      }
    }
  });
}
