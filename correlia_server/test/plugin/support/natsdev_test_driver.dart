import 'dart:convert';
import 'dart:io';

import 'natsdev.dart';
import 'plugin_process_identity.dart';

Future<void> main(List<String> args) async {
  if (args.single == 'failure') {
    final root = Directory.systemTemp.createTempSync('natsdev_failure_');
    try {
      final notDirectory = File('${root.path}/not-a-directory')
        ..writeAsStringSync('x');
      try {
        final server = await NatsTestServer.start(storePath: notDirectory.path);
        await server.close();
        throw StateError('NATS unexpectedly started with invalid storage');
      } on NatsStartupException catch (error) {
        stdout.writeln(error);
      }
    } finally {
      root.deleteSync(recursive: true);
    }
    return;
  }

  final server = await NatsTestServer.start();
  final uri = server.url;
  final pid = server.pid;
  final identity = PluginProcessIdentity.read(pid);
  if (identity == null) {
    await server.close();
    throw StateError('owned NATS process is not observable');
  }
  final storage = server.scratch.path;
  try {
    final stream = await Process.run(
      '${Directory.current.parent.path}/build/plugins/natsdev',
      ['stream', '--url', uri.toString()],
    );
    if (stream.exitCode != 0) {
      throw StateError('stream creation failed: ${stream.stderr}');
    }
    final socket = await Socket.connect(uri.host, uri.port);
    try {
      const subject = 'correlia.v1.ev.tenant.alert.source.info';
      socket.write(
        'CONNECT {}\r\nSUB $subject 1\r\nPUB $subject 5\r\nhello\r\nPING\r\n',
      );
      await socket.flush();
      final text = StringBuffer();
      await for (final chunk
          in utf8.decoder.bind(socket).timeout(const Duration(seconds: 10))) {
        text.write(chunk);
        if (text.toString().contains('PONG\r\n')) break;
      }
      if (!text.toString().contains('MSG $subject 1 5\r\nhello\r\n')) {
        throw StateError(
          'owned server did not deliver the published bytes: $text',
        );
      }
    } finally {
      await socket.close();
    }
  } finally {
    await server.close();
  }
  stdout.writeln(
    jsonEncode({
      'url': uri.toString(),
      'pid': pid,
      'startTime': identity.startTime,
      'storage': storage,
    }),
  );
}
