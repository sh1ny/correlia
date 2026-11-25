import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:correlia_server/event.dart';
import 'package:correlia_server/src/feed/feed_reader.dart';
import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/matcher/matcher_regex_worker.dart';
import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/ingest_schema.dart';
import '../support/secret_fixture.dart';
import '../unit/ingest/alertmanager_decoder_test.dart' as payload;
import 'ingest_config_test.dart' as fixture;
import 'pipeline_test.dart' as support;

void main() {
  withServerpod(
    'matcher event effects',
    (builder, _) {
      test('ordered patches and additive routes', () async {
        final session = builder.build();
        await initializeIngestSchema(session);
        const extraOutput = '33333333-3333-4333-8333-333333333333';
        await IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        ).publishConfig(
          {
            'format_version': 2,
            'revision': 1,
            'expected_active_snapshot': null,
            'sources': [
              {
                'id': fixture.sourceId,
                'kind': 'alertmanager',
                'enabled': true,
                'credentials': [
                  {'type': 'bearer', 'ref': 'token'},
                ],
                'output_ids': [fixture.outputId],
              },
            ],
            'outputs': [
              for (final id in [fixture.outputId, extraOutput])
                {
                  'id': id,
                  'kind': 'webhook',
                  'url': 'http://127.0.0.1:9099/events',
                  'signing_key_ref': 'key',
                },
            ],
            'matcher': {
              'language': 'matcher',
              'version': 1,
              'rules': [
                {
                  'id': 'a',
                  'when': {'field': 'summary', 'op': 'exists'},
                  'actions': [
                    {'type': 'team', 'value': 'first'},
                    {'type': 'route', 'output_id': extraOutput},
                  ],
                },
                {
                  'id': 'b',
                  'when': {'field': 'labels.team', 'op': 'exists'},
                  'actions': [
                    {'type': 'owner', 'value': 'must-not-chain'},
                  ],
                },
                {
                  'id': 'c',
                  'when': {
                    'not': {'field': 'labels.team', 'op': 'exists'},
                  },
                  'actions': [
                    {'type': 'team', 'value': 'last'},
                    {'type': 'route', 'output_id': extraOutput},
                  ],
                },
              ],
            },
          },
          {'token': fixture.token(1), 'key': fixture.token(2)},
          runMode: 'test',
        );
        await support.seed(session, [
          payload.alert(startsAt: '2026-11-10T12:00:00Z'),
        ]);
        final worker = PipelineRepository(session, clock: () => support.now);
        expect(await worker.pinOne(), isTrue);
        expect(await worker.processOne(), isTrue);
        final rows = await session.db.unsafeQuery(
          'SELECT output_id::text, payload FROM outbox ORDER BY output_id',
        );
        expect(rows.map((row) => row[0]), [fixture.outputId, extraOutput]);
        final eventRow = (await session.db.unsafeQuery(
          'SELECT payload FROM events',
        )).single;
        for (final route in rows) {
          expect(route[1], eventRow[0]);
        }
        final event = CloudEvent.decode(eventRow[0] as Uint8List).event;
        expect(event.labels['team'], 'last');
        expect(event.labels['owner'], isNull);
        final future = payload.alert(
          startsAt: '2026-11-12T12:00:00Z',
          labels: {'alertname': 'future'},
        );
        final ready = payload.alert(
          startsAt: '2026-11-10T12:00:00Z',
          labels: {'alertname': 'ready-after-quarantine'},
        );
        final claimed = Completer<void>();
        final resume = Completer<void>();
        final loser = PipelineRepository(
          builder.build(),
          clock: () => support.now,
          elapsedForTest: () => Duration.zero,
          afterClaim: () async {
            claimed.complete();
            await resume.future;
          },
        );
        await support.seed(session, [future, ready]);
        expect(await loser.pinOne(), isTrue);
        final losing = loser.processOne();
        try {
          await claimed.future;
          await support.seed(session, [future]);
          expect(await worker.pinOne(), isTrue);
          expect(await worker.processOne(), isTrue);
        } finally {
          resume.complete();
          expect(await losing, isTrue);
        }
        final outcomes = await session.db.unsafeQuery('''
SELECT outcome_json::jsonb->>'duplicate_quarantine'
FROM raw_inbox WHERE outcome_json::jsonb->>'duplicate_quarantine' = '1'
''');
        expect(outcomes.single[0], '1');
        expect(
          (await session.db.unsafeQuery(
            "SELECT count(*) FROM events WHERE disposition='future_dated'",
          )).single[0],
          1,
        );
        expect(
          (await session.db.unsafeQuery(
            'SELECT count(*) FROM outbox',
          )).single[0],
          4,
        );
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );

  for (final cutoff in [false, true]) {
    withServerpod(
      cutoff ? 'matcher shared cutoff' : 'matcher runtime faults',
      (builder, _) {
        test(
          cutoff
              ? 'shared cutoff reserves commit time'
              : 'RUL-7 one notice no publication',
          () async {
            final session = builder.build();
            await initializeIngestSchema(session);
            final repository = IngestConfigRepository(
              session,
              secretStore: testSecretStore,
            );
            final published = await repository.publishConfig(
              {
                'format_version': 2,
                'revision': 1,
                'expected_active_snapshot': null,
                'sources': [
                  {
                    'id': fixture.sourceId,
                    'kind': 'alertmanager',
                    'enabled': true,
                    'credentials': [
                      {'type': 'bearer', 'ref': 'token'},
                    ],
                    'output_ids': <Object?>[],
                  },
                ],
                'outputs': <Object?>[],
                'matcher': {
                  'language': 'matcher',
                  'version': 1,
                  'rules': [
                    {
                      'id': 'early',
                      'when': {'field': 'summary', 'op': 'exists'},
                      'actions': [
                        {'type': 'owner', 'value': 'early'},
                      ],
                    },
                    {
                      'id': 'blocked',
                      'when': {
                        'field': 'summary',
                        'op': 'regex',
                        'value': 'a+',
                      },
                      'actions': [
                        {'type': 'owner', 'value': 'must-not-leak'},
                      ],
                    },
                    {
                      'id': 'later',
                      'when': {'field': 'summary', 'op': 'exists'},
                      'actions': [
                        {'type': 'team', 'value': 'later'},
                      ],
                    },
                  ],
                },
              },
              <String, Object?>{'token': fixture.token(1)},
              runMode: 'test',
            );
            if (!cutoff) {
              await expectLater(
                session.db.transaction((tx) async {
                  await session.db.unsafeSimpleQuery(
                    "SELECT correlia_record_matcher_failure('${published.snapshotId}', 'blocked', 1, NULL, now())",
                    transaction: tx,
                  );
                  throw StateError('abort first matcher failure');
                }),
                throwsStateError,
              );
              expect(
                (await session.db.unsafeSimpleQuery(
                  'SELECT count(*) FROM matcher_failure',
                )).single[0],
                0,
              );
            }
            final reader = FeedReader(session);
            final cursor = (await reader.snapshot()).cursor;
            final count = cutoff ? 1 : 2;
            final workers = <MatcherRegexWorker>[];
            addTearDown(() {
              for (final worker in workers) {
                worker.close();
              }
            });
            final processors = <Future<bool> Function()>[];
            for (var i = 0; i < count; i++) {
              await support.seed(session, [
                payload.alert(
                  startsAt: '2026-11-10T12:00:00Z',
                  labels: {'alertname': 'example-$i'},
                ),
              ]);
              var elapsed = Duration.zero;
              var armed = 0;
              final regex = MatcherRegexWorker(
                entryPoint: _stall,
                elapsed: () => Duration.zero,
                arm: (_, fire) {
                  if (++armed == 2) {
                    scheduleMicrotask(() {
                      if (cutoff) elapsed = const Duration(seconds: 8);
                      fire();
                    });
                  }
                  return () {};
                },
              );
              workers.add(regex);
              final worker = PipelineRepository(
                builder.build(),
                clock: () => support.now,
                elapsedForTest: () => elapsed,
                regexWorker: regex,
              );
              expect(await worker.pinOne(), isTrue);
              processors.add(worker.processOne);
            }
            expect(
              await Future.wait(processors.map((work) => work())),
              everyElement(isTrue),
            );
            final rows = await session.db.unsafeQuery(
              'SELECT payload FROM events',
            );
            expect(rows, hasLength(count));
            for (final row in rows) {
              final event = CloudEvent.decode(row[0] as Uint8List).event;
              expect(event.labels['owner'], 'early');
              expect(event.labels['team'], cutoff ? isNull : 'later');
              if (!cutoff) {
                expect(
                  event.pipeline.enrichmentErrors.single.message,
                  'blocked',
                );
                expect(
                  event.pipeline.enrichmentErrors.single.code,
                  'regex_timeout',
                );
              }
            }
            final feed = await reader.feed(cursor, 100);
            final failure = feed.entries
                .where((entry) => entry.entityKind == 'matcher_failure')
                .single
                .matcherFailure!;
            expect(failure.snapshotId, published.snapshotId);
            expect(failure.ruleId, 'blocked');
            expect(failure.failureCount, count);
            expect(
              (await session.db.unsafeSimpleQuery(
                'SELECT count(*) FROM outbox',
              )).single[0],
              0,
            );
            expect(
              (await repository.activeSnapshot())?['snapshotId'],
              published.snapshotId,
            );
            final raw = await session.db.unsafeSimpleQuery(
              'SELECT status, attempt_count, outcome_json FROM raw_inbox',
            );
            for (final row in raw) {
              expect(row[0], 'done');
              expect(row[1], 0);
              final outcome =
                  jsonDecode(row[2] as String) as Map<String, Object?>;
              expect(outcome['matcher_unattempted'], cutoff ? 1 : isNull);
            }
            if (!cutoff) {
              final correction = <String, Object?>{
                'format_version': 2,
                'revision': 2,
                'expected_active_snapshot': published.snapshotId,
                'sources': [
                  {
                    'id': fixture.sourceId,
                    'kind': 'alertmanager',
                    'enabled': true,
                    'credentials': [
                      {'type': 'bearer', 'ref': 'token'},
                    ],
                    'output_ids': <Object?>[],
                  },
                ],
                'outputs': <Object?>[],
              };
              await expectLater(
                repository.publishConfig(
                  {
                    ...correction,
                    'matcher': {
                      'language': 'matcher',
                      'version': 1,
                      'rules': [
                        {
                          'id': 'blocked',
                          'when': {'field': 'summary', 'op': 'exists'},
                          'actions': [
                            {'type': 'route', 'output_id': fixture.outputId},
                          ],
                        },
                      ],
                    },
                  },
                  const <String, Object?>{},
                  runMode: 'test',
                ),
                throwsA(
                  isA<BootstrapError>().having(
                    (e) => e.code,
                    'code',
                    'unknown_output',
                  ),
                ),
              );
              expect(
                (await repository.activeSnapshot())?['snapshotId'],
                published.snapshotId,
              );
              final corrected = await repository.publishConfig(
                correction,
                const <String, Object?>{},
                runMode: 'test',
              );
              await support.seed(session, [
                payload.alert(
                  startsAt: '2026-11-10T12:00:00Z',
                  labels: {'alertname': 'corrected'},
                ),
              ]);
              final next = PipelineRepository(
                session,
                clock: () => support.now,
              );
              expect(await next.pinOne(), isTrue);
              expect(await next.processOne(), isTrue);
              final pins = await session.db.unsafeSimpleQuery(
                'SELECT config_snapshot_id FROM raw_inbox',
              );
              expect(
                pins.map((row) => row[0]),
                unorderedEquals([
                  published.snapshotId,
                  published.snapshotId,
                  corrected.snapshotId,
                ]),
              );
              expect(
                (await reader.feed(cursor, 100)).entries.where(
                  (entry) => entry.entityKind == 'matcher_failure',
                ),
                hasLength(1),
              );
            }
          },
          timeout: const Timeout(Duration(minutes: 5)),
        );
      },
      rollbackDatabase: RollbackDatabase.disabled,
      testGroupTagsOverride: ['db'],
    );
  }
}

void _stall(SendPort owner) {
  final inbox = ReceivePort();
  owner.send(inbox.sendPort);
  inbox.listen((_) {});
}
