import 'package:test/test.dart';

import '../../support/child_server.dart';

void main() {
  group('isBindFailure', () {
    test('recognizes the captured Serverpod and socket errors', () {
      expect(
        isBindFailure(
          'ERROR: Failed to bind socket, port 35585 may already be in use.',
        ),
        isTrue,
      );
      expect(
        isBindFailure(
          'SocketException: Failed to create server socket (OS Error: Address already in use, errno = 98), address = ::',
        ),
        isTrue,
      );
    });

    test('does not retry unrelated startup failures', () {
      for (final output in [
        '',
        'Migration failed: incompatible schema',
        'ingest bootstrap: invalid configuration',
      ]) {
        expect(isBindFailure(output), isFalse, reason: output);
      }
    });
  });

  group('ownsListeningSocket', () {
    const header =
        ' sl local_address rem_address st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode\n';
    const ipv4 =
        '0: 0100007F:8ADF 00000000:0000 0A 00000000:00000000 00:00000000 00000000 1000 0 12345 1';
    const ipv6 =
        '1: 00000000000000000000000000000000:8ADF 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000 1000 0 67890 1';

    test('matches IPv4 and IPv6 listening inodes owned by the process', () {
      expect(
        ownsListeningSocket(35551, '$header$ipv4', header, {'socket:[12345]'}),
        isTrue,
      );
      expect(
        ownsListeningSocket(35551, header, '$header$ipv6', {'socket:[67890]'}),
        isTrue,
      );
    });

    test('rejects another owner, another port and a non-listening socket', () {
      expect(
        ownsListeningSocket(35551, '$header$ipv4', '', {'socket:[99999]'}),
        isFalse,
      );
      expect(
        ownsListeningSocket(35552, '$header$ipv4', '', {'socket:[12345]'}),
        isFalse,
      );
      expect(
        ownsListeningSocket(35551, ipv4.replaceFirst(' 0A ', ' 01 '), '', {
          'socket:[12345]',
        }),
        isFalse,
      );
    });

    test('ignores headers, empty and malformed entries', () {
      expect(
        ownsListeningSocket(35551, '$header\nbad entry\n', '', {
          'socket:[12345]',
        }),
        isFalse,
      );
    });
  });
}
