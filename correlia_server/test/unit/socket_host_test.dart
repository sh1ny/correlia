import 'package:test/test.dart';

import '../support/shared_cluster.dart';

void main() {
  group('Given a child working directory', () {
    const deep =
        '/tmp/claude-1000/-home-bgshi-Development-dart-correlia/'
        'fe47366a-7c60-449c-83be-876b59e0f009/scratchpad/fresh/correlia/'
        'correlia_server';
    const socket = '$deep/.serverpod/test/run/.s.PGSQL.5432';

    test('a deep checkout gets a relative socket path within sun_path', () {
      final host = socketHostFor(socket, workingDirectory: deep);

      expect(host, '.serverpod/test/run/.s.PGSQL.5432');
      // Linux sun_path holds 108 bytes, the terminating NUL included.
      expect(socket.length, greaterThan(107));
      expect(host.length, lessThan(108));
    });

    test('an absolute path is kept when it is the shorter one', () {
      const short = '/s/.s.PGSQL.5432';

      expect(socketHostFor(short, workingDirectory: deep), short);
    });
  });
}
