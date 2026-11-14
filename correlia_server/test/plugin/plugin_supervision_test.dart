@Tags(['plugin'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/ingest/ingest_startup.dart';
import 'package:correlia_server/src/ingest/ingest_test_gates.dart';
import 'package:correlia_server/src/ingest/ingest_workers.dart';
import 'package:correlia_server/src/output/delivery_permit.dart';
import 'package:correlia_server/src/output/output_relay.dart';
import 'package:correlia_server/src/output/plugin_output_router.dart';
import 'package:correlia_server/src/plugin/plugin_supervisor.dart';
import 'package:correlia_server/src/runtime/process_options.dart';
import 'package:crypto/crypto.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/ingest_schema.dart';
import 'support/plugin_fixture_support.dart';

const output = '22222222-2222-4222-8222-222222222222';

void main() {
  withServerpod(
    'plugin supervision through worker lifecycle',
    (builder, _) {
      late PluginFixtureSuite suite;
      late PluginFixtureBuild build;
      late Directory testDirectory;
      late File executable;
      late IngestBootstrap bootstrap;
      late Session session;
      IngestWorkers? workers;
      final supervisorLog = <String>[];
      final statusHistory = <String>[];

      setUpAll(() async {
        suite = PluginFixtureSuite.create();
        build = await suite.build();
      });
      tearDownAll(() => suite.dispose());
      setUp(() async {
        supervisorLog.clear();
        statusHistory.clear();
        testDirectory = await suite.scratchDirectory.createTemp('case-');
        executable = await build.binaries[PluginFixtureBinary.outputProduction]!
            .copy('${testDirectory.path}/fixture');
        await Process.run('chmod', ['700', executable.path]);
        final digest = sha256
            .convert(await executable.readAsBytes())
            .toString();
        bootstrap = IngestBootstrap.parse(
          {
            'format_version': 1,
            'revision': 1,
            'sources': <Object>[],
            'outputs': [
              {
                'id': output,
                'kind': 'plugin',
                'plugin': 'fixture',
                'sha256': digest,
                'config': {'subject': 'alerts'},
                'secret_refs': {'token': 'token'},
              },
            ],
          },
          {
            'token': {
              'bytes': base64Url
                  .encode(utf8.encode('fixture-secret'))
                  .replaceAll('=', ''),
            },
          },
          runMode: 'test',
        );
        session = builder.build();
        await initializeIngestSchema(session);
        for (final table in [
          'outbox',
          'plugin_definition_health',
          'plugin_instance_status',
          'ingest_active_config',
          'ingest_config_snapshot',
          'ingest_secret_commitment',
        ]) {
          await session.db.unsafeSimpleExecute('DELETE FROM "$table"');
        }
        await IngestConfigRepository(session).publish(bootstrap);
        final definition = bootstrap.outputs.single as PluginIngestOutput;
        await session.db.unsafeExecute(
          '''INSERT INTO outbox
        (created_at,delivery_id,event_observed_at,event_id,event_disposition,output_id,
         config_snapshot_id,payload,output_kind,definition_digest)
        VALUES (now(),gen_random_uuid(),now(),gen_random_uuid(),'ready',CAST(@output AS uuid),
         @snapshot,decode('7b7d','hex'),'plugin',@digest)''',
          parameters: QueryParameters.named({
            'output': output,
            'snapshot': bootstrap.snapshotId,
            'digest': definition.definitionDigest,
          }),
        );
      });
      tearDown(() async {
        await workers?.stop();
        await testDirectory.delete(recursive: true);
        workers = null;
      });

      Future<void> startWorker({bool releaseRelay = false}) async {
        final gate = '${testDirectory.path}/relay-gate';
        if (releaseRelay) await File(gate).writeAsString('open');
        final startup =
            IngestStartup(
                pod: session.serverpod,
                role: ProcessRole.worker,
                runMode: 'test',
                environment: {'CORRELIA_PLUGIN_DIR': testDirectory.path},
              )
              ..bootstrap = bootstrap
              ..ready = true;
        workers = IngestWorkers(
          pod: session.serverpod,
          startup: startup,
          runMode: 'test',
          gates: IngestTestGates.fromEnvironment('test', {
            'CORRELIA_TEST_RELAY_ACQUIRE_GATE': gate,
          }),
          log: supervisorLog.add,
        );
        await workers!.start();
      }

      Future<List<Object?>> waitForStatus(
        bool Function(List<Object?>) accept,
      ) async {
        final watch = Stopwatch()..start();
        while (watch.elapsed < const Duration(seconds: 15)) {
          final rows = await session.db.unsafeQuery(
            '''SELECT state,"pluginName","pluginVersion",pid,"heartbeatAt","lastErrorClass",version
          FROM plugin_instance_status WHERE "outputId"=@output ORDER BY id DESC LIMIT 1''',
            parameters: QueryParameters.named({'output': output}),
          );
          if (rows.isNotEmpty) {
            final row = rows.single.toList();
            final observation =
                'state=${row[0]} pid=${row[3]} lastErrorClass=${row[5]} version=${row[6]}';
            if (!statusHistory.contains(observation)) {
              statusHistory.add(observation);
            }
            if (accept(row)) return row;
          }
        }
        fail(
          'Worker did not publish the expected plugin status before the deadline',
        );
      }

      Future<void> waitForFile(File file) async {
        final found = Completer<void>();
        final subscription = file.parent.watch().listen((_) {
          if (file.existsSync() && !found.isCompleted) found.complete();
        });
        try {
          if (!await file.exists()) {
            await found.future.timeout(const Duration(seconds: 15));
          }
        } finally {
          await subscription.cancel();
        }
      }

      Future<void> waitForDelivery(String digest) async {
        final watch = Stopwatch()..start();
        while (watch.elapsed < const Duration(seconds: 45)) {
          final rows = await session.db.unsafeQuery(
            "SELECT status FROM outbox WHERE definition_digest=@digest",
            parameters: QueryParameters.named({'digest': digest}),
          );
          if (rows.isNotEmpty && rows.every((row) => row[0] == 'delivered')) {
            return;
          }
        }
        final outbox = await session.db.unsafeQuery(
          '''SELECT status,delivery_id::text,claim_id::text,
        attempt_count,next_attempt_at,lease_until FROM outbox WHERE definition_digest=@digest''',
          parameters: QueryParameters.named({'digest': digest}),
        );
        final attempts = await session.db.unsafeQuery(
          '''SELECT "deliveryId"::text,"attemptNumber",
        outcome,"errorClass","startedAt","finishedAt" FROM delivery_attempts ORDER BY id''',
        );
        final statuses = await session.db.unsafeQuery(
          '''SELECT "hostInstanceId",state,pid,
        "restartCount","crashesInWindow","lastErrorClass","heartbeatAt"
        FROM plugin_instance_status WHERE "definitionDigest"=@digest''',
          parameters: QueryParameters.named({'digest': digest}),
        );
        final health = await session.db.unsafeQuery(
          '''SELECT "hostInstanceId","backoffStep",
        "nextStartAt",circuit,"nextProbeAt","lastErrorClass" FROM plugin_definition_health
        WHERE "definitionDigest"=@digest''',
          parameters: QueryParameters.named({'digest': digest}),
        );
        fail(
          'Plugin intent was not delivered before the deadline; '
          'outbox=${outbox.map((row) => row.toColumnMap()).toList()}; '
          'attempts=${attempts.map((row) => row.toColumnMap()).toList()}; '
          'status=${statuses.map((row) => row.toColumnMap()).toList()}; '
          'health=${health.map((row) => row.toColumnMap()).toList()}',
        );
      }

      test('pinned_executable_launches', () async {
        await startWorker();
        final row = await waitForStatus((row) => row[0] == 'ready');
        expect(row[0], 'ready');
        expect(row[3], isA<int>());
      });

      test('replaced_or_unsafe_executable', () async {
        await executable.writeAsString('replacement');
        await startWorker();
        final row = await waitForStatus(
          (row) => row[5] == 'plugin_executable_rejected',
        );
        expect(row[3], isNull);
        expect(
          (await session.db.unsafeQuery(
            'SELECT attempt_count FROM outbox',
          )).single[0],
          0,
        );
      });

      test('group_writable_executable_is_rejected', () async {
        await Process.run('chmod', ['720', executable.path]);
        await startWorker();
        final row = await waitForStatus(
          (row) => row[5] == 'plugin_executable_rejected',
        );
        expect(row[3], isNull);
        expect(
          (await session.db.unsafeQuery(
            'SELECT attempt_count FROM outbox',
          )).single[0],
          0,
        );
      });

      test('missing_executable_is_rejected', () async {
        await executable.delete();
        await startWorker();
        final row = await waitForStatus(
          (row) => row[5] == 'plugin_executable_rejected',
        );
        expect(row[3], isNull);
      });

      test('executable_symlink_outside_plugin_directory_is_rejected', () async {
        final outside = await executable.copy(
          '${suite.scratchDirectory.path}-outside',
        );
        addTearDown(() => outside.delete());
        await executable.delete();
        await Link(executable.path).create(outside.path);
        await startWorker();
        final row = await waitForStatus(
          (row) => row[5] == 'plugin_executable_rejected',
        );
        expect(row[3], isNull);
      });

      test('status_of_a_ready_plugin', () async {
        await startWorker();
        final row = await waitForStatus((row) => row[0] == 'ready');
        expect(row[1], 'fixture');
        expect(row[2], '1.0');
        expect(row[3], isA<int>());
        expect(
          DateTime.now().toUtc().difference(row[4] as DateTime),
          lessThan(const Duration(seconds: 15)),
        );
      });

      test('plugin_ignores_shutdown', () async {
        await startWorker();
        final ready = await waitForStatus((row) => row[0] == 'ready');
        String diagnostics() =>
            'log:\n${supervisorLog.join('\n')}\nstatus:\n${statusHistory.join('\n')}';
        expect(ready[5], isNull, reason: diagnostics());
        final pid = ready[3] as int;
        expect(
          Process.killPid(pid, ProcessSignal.sigstop),
          isTrue,
          reason: diagnostics(),
        );
        await waitForStoppedThreads(pid);
        await workers!.stop();
        final stopped = await waitForStatus((row) => row[0] == 'stopped');
        expect(stopped[5], isNotNull, reason: diagnostics());
        expect(
          supervisorLog.where(
            (line) =>
                line.startsWith('plugin-reaped ') &&
                line.contains(' pid=$pid ') &&
                line.contains(' forced=true '),
          ),
          hasLength(1),
          reason: diagnostics(),
        );
        expect(
          Process.killPid(pid, ProcessSignal.sigcont),
          isFalse,
          reason: diagnostics(),
        );
        workers = null;
      });

      test('pinned_definition_cannot_run', () async {
        final oldDigest =
            (bootstrap.outputs.single as PluginIngestOutput).definitionDigest;
        await executable.writeAsBytes([0], mode: FileMode.append);
        final newSha = sha256
            .convert(await executable.readAsBytes())
            .toString();
        bootstrap = IngestBootstrap.parse(
          {
            'format_version': 1,
            'revision': 2,
            'sources': <Object>[],
            'outputs': [
              {
                'id': output,
                'kind': 'plugin',
                'plugin': 'fixture',
                'sha256': newSha,
                'config': {'subject': 'alerts'},
                'secret_refs': {'token': 'token'},
              },
            ],
          },
          {
            'token': {
              'bytes': base64Url
                  .encode(utf8.encode('fixture-secret'))
                  .replaceAll('=', ''),
            },
          },
          runMode: 'test',
        );
        await IngestConfigRepository(session).publish(bootstrap);
        final newDigest =
            (bootstrap.outputs.single as PluginIngestOutput).definitionDigest;
        await session.db.unsafeExecute(
          '''INSERT INTO outbox
        (created_at,delivery_id,event_observed_at,event_id,event_disposition,output_id,
         config_snapshot_id,payload,output_kind,definition_digest)
        SELECT now(),gen_random_uuid(),now(),id,'ready',CAST(@output AS uuid),@snapshot,
          convert_to('bytes-' || id::text,'UTF8'),'plugin',@digest FROM (SELECT gen_random_uuid() id) event''',
          parameters: QueryParameters.named({
            'output': output,
            'snapshot': bootstrap.snapshotId,
            'digest': newDigest,
          }),
        );
        await startWorker(releaseRelay: true);
        await waitForDelivery(newDigest);
        final old = (await session.db.unsafeQuery(
          'SELECT status,attempt_count FROM outbox WHERE definition_digest=@digest',
          parameters: QueryParameters.named({'digest': oldDigest}),
        )).single;
        expect(old[0], 'queued');
        expect(old[1], 0);
      }, timeout: const Timeout(Duration(seconds: 90)));

      test('plugin_dies_with_batch_unanswered', () async {
        final fixture = File(
          '${suite.scratchDirectory.path}/bin/supervision-fixture',
        );
        await fixture.copy(executable.path);
        await Process.run('chmod', ['700', executable.path]);
        final marker = File('${suite.scratchDirectory.path}/delivery.json');
        final digest = sha256
            .convert(await executable.readAsBytes())
            .toString();
        bootstrap = IngestBootstrap.parse(
          {
            'format_version': 1,
            'revision': 2,
            'sources': <Object>[],
            'outputs': [
              {
                'id': output,
                'kind': 'plugin',
                'plugin': 'fixture',
                'sha256': digest,
                'config': {'marker': marker.path},
                'secret_refs': <String, String>{},
              },
            ],
          },
          <String, Object?>{},
          runMode: 'test',
        );
        await IngestConfigRepository(session).publish(bootstrap);
        final definition = bootstrap.outputs.single as PluginIngestOutput;
        await session.db.unsafeExecute(
          '''UPDATE outbox SET config_snapshot_id=@snapshot,
        definition_digest=@digest WHERE output_id=CAST(@output AS uuid)''',
          parameters: QueryParameters.named({
            'snapshot': bootstrap.snapshotId,
            'digest': definition.definitionDigest,
            'output': output,
          }),
        );
        await session.db.unsafeExecute(
          '''INSERT INTO outbox
        (created_at,delivery_id,event_observed_at,event_id,event_disposition,output_id,
         config_snapshot_id,payload,output_kind,definition_digest)
        VALUES (now(),gen_random_uuid(),now(),gen_random_uuid(),'ready',CAST(@output AS uuid),
          @snapshot,decode('7b227365636f6e64223a747275657d','hex'),'plugin',@digest)''',
          parameters: QueryParameters.named({
            'output': output,
            'snapshot': bootstrap.snapshotId,
            'digest': definition.definitionDigest,
          }),
        );
        final original = await session.db.unsafeQuery(
          "SELECT event_id::text,encode(payload,'base64') FROM outbox ORDER BY event_id",
        );
        expect(original, hasLength(2));
        await startWorker(releaseRelay: true);
        final ready = await waitForStatus((row) => row[0] == 'ready');
        await waitForFile(marker);
        final observed = await marker.readAsString();
        for (final row in original) {
          expect(observed, contains(row[0] as String));
          expect(observed, contains(row[1] as String));
        }
        expect(Process.killPid(ready[3] as int, ProcessSignal.sigkill), isTrue);
        await waitForDelivery(definition.definitionDigest);
        final retry = File('${marker.path}.retry');
        await waitForFile(retry);
        expect(await retry.readAsString(), observed);
        final after = await session.db.unsafeQuery(
          "SELECT event_id::text,encode(payload,'base64'),attempt_count FROM outbox ORDER BY event_id",
        );
        expect(after, hasLength(2));
        for (var i = 0; i < 2; i++) {
          expect(after[i][0], original[i][0]);
          expect(after[i][1], original[i][1]);
          expect(after[i][2] as int, greaterThanOrEqualTo(2));
        }
        final failed = await session.db.unsafeQuery(
          "SELECT count(*) FROM delivery_attempts WHERE \"errorClass\"='plugin_connection_lost' AND \"finishedAt\" IS NOT NULL",
        );
        expect(failed.single[0], 2);
      }, timeout: const Timeout(Duration(seconds: 90)));

      for (final stopMode in ['idle', 'shutdown', 'failure']) {
        test('held_permit_survives_voluntary_$stopMode', () async {
          var now = DateTime.now().toUtc();
          final definition = bootstrap.outputs.single as PluginIngestOutput;
          final supervisor = PluginSupervisor(
            openSession: () =>
                session.serverpod.createSession(enableLogging: false),
            bootstrap: bootstrap,
            pluginDirectory: testDirectory.path,
            hostInstanceId: 'drain-$stopMode',
            clock: () => now,
            log: (_) {},
          );
          DeliveryPermit? held;
          Future<void>? stopping;
          try {
            await session.db.unsafeSimpleExecute(
              "UPDATE outbox SET payload=convert_to('bytes-' || event_id::text,'UTF8')",
            );
            await supervisor.start();
            await Stream<void>.periodic(const Duration(milliseconds: 1))
                .firstWhere(
                  (_) =>
                      supervisor.readyDefinitions[output]?.contains(
                        definition.definitionDigest,
                      ) ??
                      false,
                )
                .timeout(const Duration(seconds: 15));
            held = supervisor.tryAcquire(output, definition.definitionDigest)!;
            final repo = OutputRelayRepository(
              session,
              bootstrap.secret,
              loadedReferences: bootstrap.loadedReferences,
            );
            final batch = (await repo.claim(
              output,
              limit: 1,
              readyDigests: {definition.definitionDigest},
              permit: held,
            ))!;
            if (stopMode == 'shutdown') {
              stopping = supervisor.stop();
              final extra = supervisor.tryAcquire(
                output,
                definition.definitionDigest,
              );
              extra?.release();
              expect(extra, isNull);
            } else {
              now = now.add(const Duration(seconds: 61));
            }
            await Stream<void>.periodic(const Duration(milliseconds: 1))
                .firstWhere(
                  (_) =>
                      !(supervisor.readyDefinitions[output]?.contains(
                            definition.definitionDigest,
                          ) ??
                          false),
                )
                .timeout(const Duration(seconds: 15));
            expect(
              supervisor.tryAcquire(output, definition.definitionDigest),
              isNull,
            );
            expect(held.isValid, isTrue);
            if (stopMode == 'failure') {
              final row = (await session.db.unsafeQuery(
                'SELECT pid FROM plugin_instance_status WHERE "hostInstanceId"=@host',
                parameters: QueryParameters.named({'host': 'drain-$stopMode'}),
              )).single;
              final identity = PluginProcessIdentity.read(row[0] as int)!;
              expect(identity.signalIfExact(ProcessSignal.sigkill), isTrue);
              await Stream<void>.periodic(const Duration(milliseconds: 1))
                  .firstWhere((_) => !held!.isValid)
                  .timeout(const Duration(seconds: 15));
            }
            final outcomes = await deliverPluginBatch(supervisor, held, batch);
            expect(
              outcomes.single,
              stopMode == 'failure'
                  ? isA<DeliveryRetryable>()
                  : isA<DeliveryAcknowledged>(),
            );
            expect(await repo.completeBatch(batch, outcomes), isTrue);
            stopping ??= supervisor.stop();
            held.release();
            held = null;
            await stopping;
            final row = (await session.db.unsafeQuery(
              'SELECT status,attempt_count FROM outbox',
            )).single;
            expect(row[0], stopMode == 'failure' ? 'queued' : 'delivered');
            expect(row[1], 1);
            final attempts = await session.db.unsafeQuery(
              '''SELECT a.outcome FROM delivery_attempts a JOIN outbox o
                ON a."deliveryId"=o.delivery_id AND a."outboxCreatedAt"=o.created_at''',
            );
            expect(attempts.map((row) => row[0]), [
              stopMode == 'failure' ? 'retryable' : 'acknowledged',
            ]);
          } finally {
            held?.release();
            await (stopping ?? supervisor.stop());
          }
        });
      }
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['plugin'],
  );
}

Future<void> waitForStoppedThreads(int pid) async {
  final watch = Stopwatch()..start();
  while (watch.elapsed < const Duration(seconds: 15)) {
    final tasks = await Directory('/proc/$pid/task').list().toList();
    var stopped = tasks.isNotEmpty;
    for (final task in tasks) {
      final stat = await File('${task.path}/stat').readAsString();
      final state = stat.substring(stat.lastIndexOf(')') + 2).split(' ').first;
      stopped = stopped && state == 'T';
    }
    if (stopped) return;
  }
  fail('Plugin $pid did not finish its group stop before shutdown');
}
