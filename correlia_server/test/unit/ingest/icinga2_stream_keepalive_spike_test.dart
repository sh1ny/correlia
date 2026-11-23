import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

void main() {
  test(
    'A3: custom HTTPS socket retains the kernel keepalive options',
    () async {
      const fixtures = '../correlia_icinga2_notify/test/fixtures';
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        SecurityContext()
          ..useCertificateChain('$fixtures/server_one.pem')
          ..usePrivateKey('$fixtures/server_one.key'),
      );
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.write('https on configured socket');
        await request.response.close();
      });

      final readback = <int>[];
      final context = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates('$fixtures/ca_one.pem');
      final client = HttpClient(context: context)
        ..findProxy = ((_) => 'DIRECT')
        ..connectionFactory = (uri, _, _) async {
          final task = await Socket.startConnect(uri.host, uri.port);
          return ConnectionTask.fromSocket(
            task.socket.then((socket) async {
              try {
                // Linux socket.h and tcp.h option numbers.
                for (final (level, option, expected) in [
                  (RawSocketOption.levelSocket, 9, 1), // SO_KEEPALIVE
                  (RawSocketOption.levelTcp, 4, 60), // TCP_KEEPIDLE
                  (RawSocketOption.levelTcp, 5, 10), // TCP_KEEPINTVL
                  (RawSocketOption.levelTcp, 6, 6), // TCP_KEEPCNT
                ]) {
                  socket.setRawOption(
                    RawSocketOption.fromInt(level, option, expected),
                  );
                  final actual = socket.getRawOption(
                    RawSocketOption.fromInt(level, option, 0),
                  );
                  readback.add(
                    ByteData.sublistView(actual).getInt32(0, Endian.host),
                  );
                }
                // The custom factory supplies the final socket, not a
                // transport for HttpClient to upgrade.
                return await SecureSocket.secure(
                  socket,
                  host: uri.host,
                  context: context,
                );
              } catch (_) {
                socket.destroy();
                rethrow;
              }
            }),
            task.cancel,
          );
        };
      addTearDown(() => client.close(force: true));

      final request = await client.getUrl(
        Uri.https('127.0.0.1:${server.port}', '/'),
      );
      final response = await request.close();
      expect(response.statusCode, HttpStatus.ok);
      expect(
        await utf8.decoder.bind(response).join(),
        'https on configured socket',
      );
      expect(readback, [1, 60, 10, 6]);
    },
  );
}
