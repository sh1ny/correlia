import 'dart:convert';
import 'dart:io';

import 'package:correlia_server/src/ingest/icinga2/stream/https_client.dart';

Future<void> main(List<String> args) async {
  final endpoint = Uri.parse(args[0]);
  if (args.length == 3) {
    // Seed only the child process's default trust and verify the handshake
    // without sending HTTP. The explicit-context client must still refuse it.
    SecurityContext.defaultContext.setTrustedCertificates(
      Platform.environment['SSL_CERT_FILE']!,
    );
    final baseline = await SecureSocket.connect(
      endpoint.host,
      endpoint.port,
      timeout: const Duration(seconds: 5),
    );
    baseline.destroy();
  }
  final client = IcingaStreamHttpClient(
    endpoint: endpoint,
    username: 'stream-user',
    password: utf8.encode('stream-password'),
    ca: await File(args[1]).readAsBytes(),
  );
  try {
    final response = await client.subscribe('source-one');
    final body = await utf8.decoder.bind(response.body).join();
    stdout.writeln(jsonEncode({'status': response.statusCode, 'body': body}));
  } on StreamHttpFailure catch (error) {
    stdout.writeln(jsonEncode({'error': error.code}));
  } finally {
    client.close();
  }
}
