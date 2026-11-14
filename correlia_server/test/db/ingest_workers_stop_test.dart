import 'dart:async';
import 'dart:convert';

import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/ingest/ingest_startup.dart';
import 'package:correlia_server/src/ingest/ingest_test_gates.dart';
import 'package:correlia_server/src/ingest/ingest_workers.dart';
import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:correlia_server/src/runtime/process_options.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/ingest_schema.dart';

void main() {
  withServerpod(
    'worker stop ownership',
    (builder, _) {
      for (final scenario in [
        (
          name: 'stop_called_twice_completes_once',
          concurrent: false,
          fails: false,
        ),
        (
          name: 'concurrent_stops_both_complete',
          concurrent: true,
          fails: false,
        ),
        (
          name: 'stop_after_failed_stop_completes',
          concurrent: false,
          fails: true,
        ),
        (
          name: 'concurrent_stop_while_first_fails',
          concurrent: true,
          fails: true,
        ),
      ]) {
        test(scenario.name, () async {
          final session = builder.build();
          await initializeIngestSchema(session);
          final bootstrap = IngestBootstrap.parse(
            {
              'format_version': 1,
              'revision': 1,
              'sources': <Object>[],
              'outputs': [
                {
                  'id': '22222222-2222-4222-8222-222222222222',
                  'kind': 'webhook',
                  'url': 'http://127.0.0.1:9099/events',
                  'signing_key_ref': 'key',
                },
              ],
            },
            {
              'key': base64Url
                  .encode(List<int>.filled(32, 7))
                  .replaceAll('=', ''),
            },
            runMode: 'test',
          );
          await IngestConfigRepository(session).publish(bootstrap);
          final startup = IngestStartup(
            pod: session.serverpod,
            role: ProcessRole.worker,
            runMode: 'test',
            environment: const {},
          )..bootstrap = bootstrap;
          final calls = <String, int>{};
          final entered = Completer<void>();
          final release = Completer<void>();
          final failure = StateError('pipeline stop failed');
          final workers = IngestWorkers(
            pod: session.serverpod,
            startup: startup,
            runMode: 'test',
            gates: IngestTestGates.fromEnvironment('test', const {}),
            log: (_) {},
            beforeComponentStop: (name) async {
              calls.update(name, (count) => count + 1, ifAbsent: () => 1);
              if (name == 'pipeline') {
                if (scenario.concurrent) {
                  if (!entered.isCompleted) entered.complete();
                  await release.future;
                }
                if (scenario.fails) throw failure;
              }
            },
          );
          await workers.start();
          final first = workers.stop();
          final firstResult = expectLater(
            first,
            scenario.fails ? throwsA(same(failure)) : completes,
          );
          try {
            if (scenario.concurrent) {
              await entered.future;
              var laterFinished = false;
              final later = workers.stop().then((_) => laterFinished = true);
              final laterResult = expectLater(later, completes);
              expect(laterFinished, isFalse);
              expect(calls['supervisor'], isNull);
              release.complete();
              await firstResult;
              await laterResult;
              expect(laterFinished, isTrue);
            } else {
              await firstResult;
              await workers.stop();
            }
            expect(calls, {'relay': 1, 'pipeline': 1, 'supervisor': 1});
          } finally {
            if (!release.isCompleted) release.complete();
            // Every first stop attempts every real component, including on a hook error.
            await first.then<void>(
              (_) {},
              onError: (Object _, StackTrace _) {},
            );
          }
        }, timeout: const Timeout(Duration(seconds: 30)));
      }

      test('pipeline_stop_before_start_and_twice', () async {
        final pipeline = PipelineSubsystem(
          openSession: () =>
              builder.build().serverpod.createSession(enableLogging: false),
        );
        await pipeline.stop();
        await pipeline.start();
        await pipeline.stop();
        await pipeline.stop();
      }, timeout: const Timeout(Duration(seconds: 30)));
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
