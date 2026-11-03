// A stand-in for a foreign PostgreSQL: listens on a loopback TCP port and on a
// `.s.PGSQL.<port>` Unix socket in the directory given as the only argument,
// and counts every connection it accepts. Run as its own process by
// `postgres_isolation_test.dart`.
//
// Output: `READY <port>` once both listeners are bound, then `ACCEPT tcp` or
// `ACCEPT unix` per connection and `PONG <accepted>` per `ping` line on stdin.
// It exits on end-of-file of stdin or SIGTERM.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final directory = args.single;
  var accepted = 0;

  void onAccept(Socket socket, String kind) {
    accepted++;
    stdout.writeln('ACCEPT $kind');
    socket.destroy();
  }

  final tcp = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  tcp.listen((socket) => onAccept(socket, 'tcp'));
  final unix = await ServerSocket.bind(
    InternetAddress(
      '$directory/.s.PGSQL.${tcp.port}',
      type: InternetAddressType.unix,
    ),
    0,
  );
  unix.listen((socket) => onAccept(socket, 'unix'));
  stdout.writeln('READY ${tcp.port}');

  ProcessSignal.sigterm.watch().listen((_) => exit(0));
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line == 'ping') stdout.writeln('PONG $accepted');
  }
  exit(0);
}
