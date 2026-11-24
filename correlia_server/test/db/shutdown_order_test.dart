@Tags(['db'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:async';

import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/database.dart';
import 'package:correlia_server/src/ingest/ingest_startup.dart';
import 'package:correlia_server/src/ingest/ingest_test_gates.dart';
import 'package:correlia_server/src/ingest/ingest_workers.dart';
import 'package:correlia_server/src/runtime/process_options.dart';
import 'package:correlia_server/src/runtime/role_runtime.dart';
import 'package:correlia_server/src/runtime/subsystem.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_consumer_loopback.dart';
import '../support/icinga2_pipeline.dart';
import '../support/icinga2_stream_fixture.dart';
import '../support/postgres_lock_witness.dart';
import '../support/ingest_schema.dart';
import '../support/pod_fixture.dart';
import '../support/secret_fixture.dart';

/// A subsystem whose [stop] runs [onStop] and then throws [failure], if set.
final class _Subsystem extends Subsystem {
  _Subsystem(this.name, this.events, {this.onStop, this.failure});

  @override
  final String name;
  final List<String> events;
  final Future<void> Function()? onStop;
  final Object? failure;

  @override
  Set<ProcessRole> get roles => {ProcessRole.all};

  @override
  Future<void> start() async => events.add('start $name');

  @override
  Future<void> stop() async {
    events.add('stop $name');
    await onStop?.call();
    if (failure case final Object error) throw error;
  }
}

void main() {
  group(
    'Given a started role whose subsystem queries the database on stop',
    () {
      late PodFixture fixture;
      final events = <String>[];

      setUp(() async {
        events.clear();
        fixture = await PodFixture.create([
          _Subsystem(
            'queries',
            events,
            onStop: () async {
              final session = await fixture.pod.createSession(
                enableLogging: false,
              );
              try {
                await session.db.unsafeQuery('SELECT 1');
                events.add('query ok');
              } finally {
                await session.close();
              }
            },
          ),
        ]);
        expect(await fixture.start(), isA<Started>());
      });
      tearDown(() => fixture.shutdown());

      test(
        'when the server shuts down then the stop callback runs before the '
        'pool closes',
        () async {
          await fixture.shutdown();

          expect(events, ['start queries', 'stop queries', 'query ok']);
          final late = await fixture.pod.createSession(enableLogging: false);
          await expectLater(late.db.unsafeQuery('SELECT 1'), throwsA(anything));
        },
      );
    },
  );

  group('Given a started role whose first-started subsystem fails to stop', () {
    late PodFixture fixture;
    final events = <String>[];

    setUp(() async {
      events.clear();
      fixture = await PodFixture.create([
        _Subsystem('first', events, failure: StateError('first is stuck')),
        _Subsystem('second', events),
      ]);
      expect(await fixture.start(), isA<Started>());
    });
    tearDown(() => fixture.shutdown());

    test(
      'a failing stop callback makes Serverpod report a failed shutdown',
      () async {
        await expectLater(
          fixture.shutdown(),
          throwsA(
            isA<SubsystemStopException>().having(
              (e) => e.failures.keys,
              'failed subsystems',
              ['first'],
            ),
          ),
        );

        expect(events, [
          'start first',
          'start second',
          'stop second',
          'stop first',
        ]);
        expect(
          fixture.logs,
          contains(startsWith('Failed to stop first:')),
          reason: 'the failure is logged with the subsystem name',
        );
        final late = await fixture.pod.createSession(enableLogging: false);
        await expectLater(late.db.unsafeQuery('SELECT 1'), throwsA(anything));
      },
    );
  });

  withServerpod(
    'Worker stops live Icinga consumers before its pipeline',
    (builder, _) {
      for (final (name, locked, unreachable) in [
        ('shutdown_order', false, false),
        ('shutdown_with_the_lease_row_locked', true, false),
        ('shutdown_with_the_database_unreachable', false, true),
      ]) {
        test(name, () async {
          final session = builder.build();
          await initializeIngestSchema(session);
          await clearPipelineTables(session);
          await session.db.unsafeSimpleExecute(
            'TRUNCATE icinga2_stream_lease,icinga2_stream_status,icinga2_admitted_batch,icinga2_stream_resync',
          );
          final server = await IcingaConsumerLoopback.start();
          addTearDown(server.close);
          final source = streamSource(icinga2DbSourceId);
          (source['api']! as Map<String, Object?>)['url'] = server.url
              .toString();
          final bootstrap =
              await IngestConfigRepository(
                session,
                secretStore: testSecretStore,
              ).publishConfig(
                streamBootstrap(1, [source]),
                streamMaterial(),
                runMode: 'test',
              );
          final startup =
              IngestStartup(
                  pod: session.serverpod,
                  role: ProcessRole.worker,
                  runMode: 'test',
                  environment: const {},
                )
                ..bootstrap = bootstrap
                ..resolver = testSecretResolver(session);
          final endpoint = await StreamDatabaseEndpoint.resolve(
            session.serverpod,
          );
          final order = <String>[];
          var offline = false;
          bool? expiredAtPipelineStop;
          final workers = IngestWorkers(
            pod: session.serverpod,
            startup: startup,
            runMode: 'test',
            gates: IngestTestGates.fromEnvironment('test', const {}),
            log: (_) {},
            openStreamDatabaseForTest: (_) async {
              if (offline) throw StateError('database unreachable on stop');
              return endpoint.open();
            },
            beforeComponentStop: (component) async {
              order.add(component);
              if (component != 'pipeline') return;
              expiredAtPipelineStop =
                  (await queryRows(
                        session,
                        'SELECT "expiresAt"<=clock_timestamp() AS expired FROM icinga2_stream_lease',
                      )).single['expired']
                      as bool;
            },
          );
          addTearDown(workers.stop);
          await workers.start();
          await server.waitForObjectResponses(1);
          final lockAcquired = Completer<void>();
          final unlock = Completer<void>();
          final lock = locked
              ? session.db.transaction((tx) async {
                  await pooledLockActor(session, tx);
                  await session.db.unsafeQuery(
                    'SELECT 1 FROM icinga2_stream_lease FOR UPDATE',
                    transaction: tx,
                  );
                  lockAcquired.complete();
                  await unlock.future;
                })
              : null;
          try {
            if (locked) await lockAcquired.future;
            offline = unreachable;
            await workers.stop();
            expect(
              order,
              containsAllInOrder(['icinga2-event-streams', 'pipeline']),
            );
            expect(expiredAtPipelineStop, !locked && !unreachable);
          } finally {
            unlock.complete();
            await lock;
          }
        });
      }
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
