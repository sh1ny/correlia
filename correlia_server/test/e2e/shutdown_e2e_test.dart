@Tags(['e2e'])
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

import '../support/child_server.dart';
import '../support/icinga2_stream_child.dart';
import '../support/shared_cluster.dart';

void main() {
  test(
    'SIGTERM stops subsystems before the pool closes and exits 0',
    () async {
      final serverDir = Directory.current;
      final database = await SharedClusterDatabase.create(serverDir);
      ChildServer? child;
      try {
        child = await ChildServer.startOnSharedCluster(
          serverDir: serverDir,
          database: database,
          environment: {'CORRELIA_TEST_STOP_PROBE': '1'},
        );
        await child.waitUntilReady();

        expect(await child.stop(), 0, reason: child.output);
        final lines = child.output.split('\n');
        int indexOf(Pattern pattern) =>
            lines.indexWhere((line) => line.contains(pattern));

        final probeStopped = indexOf('Stopped test-stop-hooks');
        final consoleStopped = indexOf('Stopped console');
        final probed = indexOf('test probe: ${database.name} ');
        final completed = indexOf('SERVERPOD shutdown completed');
        expect(
          [probed, probeStopped, consoleStopped, completed],
          everyElement(isNonNegative),
          reason: child.output,
        );
        expect(
          probed,
          lessThan(probeStopped),
          reason: 'the query ran while the subsystem was stopping',
        );
        expect(
          probeStopped,
          lessThan(consoleStopped),
          reason: 'subsystems stop in reverse start order',
        );
        expect(
          consoleStopped,
          lessThan(completed),
          reason: 'subsystems stopped before shutdown completed',
        );
        expect(
          lines[probed],
          contains(p.join(serverDir.path, '.serverpod', 'test', 'pgdata')),
          reason: 'the child used the shared cluster, not its own',
        );
        expect(child.output, isNot(contains('test probe failed')));
      } finally {
        if (child != null && !child.hasExited) await child.closeStdin();
        await database.drop();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  for (final condition in ['free', 'locked', 'unreachable']) {
    test(
      'SIGTERM with live Event Streams and $condition lease database',
      () async {
        final fixture = await Icinga2StreamChild.create();
        final child = await fixture.start(role: 'worker', revision: 1);
        await fixture.waitState('connected');
        final db = fixture.db;
        final leaseExpiry = (await db.execute(
          'SELECT "expiresAt" FROM icinga2_stream_lease',
        )).single.single;
        final locked = Completer<void>();
        final unlock = Completer<void>();
        final lock = condition == 'locked'
            ? db.runTx((tx) async {
                await tx.execute(
                  'SELECT 1 FROM icinga2_stream_lease FOR UPDATE',
                );
                locked.complete();
                await unlock.future;
              })
            : null;
        Connection? control;
        Connection? observer;
        try {
          if (lock != null) await locked.future;
          if (condition == 'unreachable') {
            final owned = fixture.cluster;
            expect(owned.name, matches(RegExp(r'^[a-z0-9_]+$')));
            final socket = socketHostFor(
              owned.socketPath,
              workingDirectory: Directory.current.path,
            );
            control = await Connection.open(
              Endpoint(
                host: socket,
                port: owned.port,
                database: 'postgres',
                username: 'postgres',
                isUnixSocket: true,
              ),
              settings: const ConnectionSettings(sslMode: SslMode.disable),
            );
            await control.execute(
              'ALTER DATABASE "${owned.name}" WITH ALLOW_CONNECTIONS false',
            );
            // Disconnect only Correlia's owned per-test database, never other sessions.
            await control.execute(
              Sql.named('''
            SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname=@owned
          '''),
              parameters: {'owned': owned.name},
            );
          }
          expect(
            await child.stop(deadline: const Duration(seconds: 15)),
            condition == 'unreachable' ? 1 : 0,
            reason: child.output,
          );
          await fixture.upstream.disconnected.future.timeout(
            const Duration(seconds: 2),
          );
          final output = child.output;
          final stopped = output.indexOf(
            condition == 'free' ? ' stopped' : ' lease expires',
            output.indexOf('icinga2-stream source='),
          );
          final workers = output.indexOf(
            condition == 'unreachable'
                ? 'Failed to stop ingest-workers'
                : 'Stopped ingest-workers',
          );
          expect(stopped, isNonNegative, reason: output);
          expect(workers, greaterThan(stopped), reason: output);
          expect(
            output.indexOf('SERVERPOD shutdown completed'),
            greaterThan(workers),
            reason: output,
          );
        } finally {
          unlock.complete();
          await lock;
          if (control != null) {
            final owned = fixture.cluster;
            try {
              await control.execute(
                'ALTER DATABASE "${owned.name}" WITH ALLOW_CONNECTIONS true',
              );
              observer = await Connection.open(
                Endpoint(
                  host: socketHostFor(
                    owned.socketPath,
                    workingDirectory: Directory.current.path,
                  ),
                  port: owned.port,
                  database: owned.name,
                  username: 'postgres',
                  isUnixSocket: true,
                ),
                settings: const ConnectionSettings(sslMode: SslMode.disable),
              );
              addTearDown(observer.close);
            } finally {
              await control.close();
            }
          }
        }
        final row = (await (observer ?? db).execute('''
        SELECT s.state, l."expiresAt", l."expiresAt" <= clock_timestamp()
        FROM icinga2_stream_status s JOIN icinga2_stream_lease l USING ("sourceId")
      ''')).single;
        if (condition == 'free') {
          expect(row[0], 'stopped');
          expect(row[2], isTrue);
        } else {
          expect(row[0], 'connected');
          expect(row[1], leaseExpiry);
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
}
