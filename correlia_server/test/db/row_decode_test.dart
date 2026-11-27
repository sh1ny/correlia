import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:correlia_server/src/event/event_timestamp.dart';
import 'package:correlia_server/src/event/validation.dart';
import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/pipeline/row_decode.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/generic_pipeline_fixture.dart';
import '../support/icinga2_delivery.dart' as webhook;
import '../support/icinga2_pipeline.dart';
import '../support/icinga2_stream_pipeline.dart';
import '../support/ingest_schema.dart';
import '../support/secret_fixture.dart';
import '../unit/ingest/alertmanager_decoder_test.dart' as payload;
import 'ingest_config_test.dart' show token;

const _alertmanagerSource = '66666666-6666-4666-8666-666666666666';
final _observed = DateTime.utc(2026, 11, 23, 12);
final _firstProcessing = EventTimestamp.parse('2026-11-23T12:00:01Z');
final _secondProcessing = EventTimestamp.parse('2026-11-23T12:05:00Z');

/// The decode result as plain data, without processing time.
Map<String, Object?> _comparable(DecodedRow row) => {
  'events': [
    for (final event in row.batch.events)
      {...event.toJson()}..remove('processed_at'),
  ],
  'upstream_omissions': row.batch.upstreamOmissions,
  'soft_info': row.batch.softInfo,
  'unmapped_fields': row.batch.unmappedFields,
  'unknown_top_level': row.batch.unknownTopLevelFields,
  'unknown_top_level_overflow': row.batch.unknownTopLevelOverflow,
  'sync_id': row.syncId,
};

void main() {
  withServerpod(
    'raw row decode',
    (builder, _) {
      late Session session;

      setUp(() async {
        session = builder.build();
        await initializeIngestSchema(session);
        await clearPipelineTables(session);
      });

      Future<String> onlySnapshot() async =>
          (await session.db.unsafeQuery(
                'SELECT "snapshotId" FROM ingest_config_snapshot',
              )).single[0]!
              as String;

      Future<String> publishAlertmanager() async =>
          (await IngestConfigRepository(
                session,
                secretStore: testSecretStore,
              ).publishConfig(
                {
                  'format_version': 2,
                  'revision': 1,
                  'sources': [
                    {
                      'id': _alertmanagerSource,
                      'kind': 'alertmanager',
                      'enabled': true,
                      'credentials': [
                        {'ref': 'am-key', 'type': 'bearer'},
                      ],
                      'output_ids': <Object?>[],
                    },
                  ],
                  'outputs': <Object?>[],
                },
                {'am-key': token(1)},
                runMode: 'test',
                clock: () => _observed,
              ))
              .snapshotId;

      /// Stores [body] pinned to [pin]; stream rows also get admission metadata.
      Future<RawKey> seed(
        String source,
        Uint8List body,
        String pin, {
        String? admission,
        bool sync = false,
      }) async {
        final id = await seedIcinga2(session, body, _observed, source: source);
        await session.db.unsafeExecute(
          'UPDATE raw_inbox SET config_snapshot_id=@pin WHERE raw_id=CAST(@id AS uuid)',
          parameters: QueryParameters.named({'pin': pin, 'id': id}),
        );
        if (admission != null) {
          await session.db.unsafeExecute(
            '''INSERT INTO icinga2_raw_origin
(raw_observed_at,raw_id,origin,sync_id,admission_snapshot_id)
VALUES (@observed,CAST(@raw AS uuid),@origin,CAST(@sync AS uuid),@snapshot)''',
            parameters: QueryParameters.named({
              'observed': _observed,
              'raw': id,
              'origin': sync ? 'sync' : 'stream',
              'sync': sync ? streamDbSyncId : null,
              'snapshot': admission,
            }),
          );
        }
        return RawKey(_observed, id);
      }

      Future<Uint8List> bytesOf(RawKey key) async {
        final value = (await session.db.unsafeQuery(
          'SELECT body FROM raw_inbox WHERE raw_id=CAST(@id AS uuid)',
          parameters: QueryParameters.named({'id': key.rawId}),
        )).single[0];
        return switch (value) {
          Uint8List bytes => bytes,
          ByteData data => data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          ),
          _ => throw StateError('Unexpected raw byte representation'),
        };
      }

      Future<DecodeInputs> read(RawKey key, String pin) async {
        final row = (await session.db.unsafeQuery(
          'SELECT source_id::text, body_sha256 FROM raw_inbox WHERE raw_id=CAST(@id AS uuid)',
          parameters: QueryParameters.named({'id': key.rawId}),
        )).single;
        final bytes = await bytesOf(key);
        return session.db.transaction(
          (tx) => readDecodeInputs(
            session,
            tx,
            key,
            pin,
            sourceId: row[0]! as String,
            digest: row[1]! as String,
            bytes: bytes,
          ),
        );
      }

      /// A stream row with one soft check and one hard check.
      Uint8List streamBody() => webhook.body({
        'format': 'correlia.icinga2.stream.v1',
        'origin': 'stream',
        'connection': 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        'items': [
          for (final check in [
            streamDbCheck(_observed, stateType: 0, service: 'soft'),
            streamDbCheck(_observed, service: 'hard'),
          ])
            {
              'received': _observed.microsecondsSinceEpoch,
              'line': jsonEncode(check),
            },
        ],
      });

      test('decode_is_deterministic_per_source', () async {
        final cases = <String, Future<({RawKey key, String pin})> Function()>{
          'alertmanager': () async {
            final pin = await publishAlertmanager();
            final body = Uint8List.fromList(
              utf8.encode(
                jsonEncode(
                  payload.groupOf([
                    payload.alert(startsAt: '2026-11-23T11:00:00Z'),
                  ]),
                ),
              ),
            );
            return (key: await seed(_alertmanagerSource, body, pin), pin: pin);
          },
          'thanos': () async {
            final pin = await publishAlertmanager();
            final body = await File(
              'test/unit/ingest/fixtures/thanos/v0.42.5-dropped-0001.json',
            ).readAsBytes();
            return (key: await seed(_alertmanagerSource, body, pin), pin: pin);
          },
          'icinga2_webhook': () async {
            await publishIcinga2Config(session);
            final pin = await onlySnapshot();
            final body = webhook.body(webhook.delivery());
            return (key: await seed(icinga2DbSourceId, body, pin), pin: pin);
          },
          'icinga2_stream_hard_only': () async {
            final pin = await publishStreamDb(session, policy: 'hard_only');
            return (
              key: await seed(
                icinga2DbSourceId,
                streamBody(),
                pin,
                admission: pin,
              ),
              pin: pin,
            );
          },
          'icinga2_stream_soft_and_hard': () async {
            final pin = await publishStreamDb(session);
            return (
              key: await seed(
                icinga2DbSourceId,
                streamBody(),
                pin,
                admission: pin,
              ),
              pin: pin,
            );
          },
          'generic': () async {
            final input = await publishGenericConfig(
              session,
              now: _observed,
            );
            final body = Uint8List.fromList(
              utf8.encode(jsonEncode(genericAlert(_observed))),
            );
            return (
              key: await seed(genericPipelineSource, body, input.snapshotId),
              pin: input.snapshotId,
            );
          },
        };
        for (final MapEntry(key: name, value: setup) in cases.entries) {
          await clearPipelineTables(session);
          final (:key, :pin) = await setup();
          final bytes = await bytesOf(key);
          final first = decodeRow(
            await read(key, pin),
            bytes,
            processedAt: _firstProcessing,
          );
          final second = decodeRow(
            await read(key, pin),
            bytes,
            processedAt: _secondProcessing,
          );
          expect(first.batch.events, isNotEmpty, reason: name);
          expect(_comparable(second), _comparable(first), reason: name);
        }
      });

      test('read_decode_inputs_returns_pin_settings_and_admission', () async {
        final pin = await publishStreamDb(
          session,
          shared: true,
          policy: 'hard_only',
        );
        final key = await seed(
          icinga2DbSourceId,
          streamBody(),
          pin,
          admission: pin,
          sync: true,
        );
        final inputs = await read(key, pin);
        expect(inputs.rejection, isNull);
        expect(inputs.rawKey, same(key));
        expect(inputs.sourceId, icinga2DbSourceId);
        expect(inputs.pin, pin);
        expect(inputs.kind, isA<Icinga2SourceKind>());
        expect(inputs.namespace, icinga2SharedNamespace);
        expect(inputs.stream, isTrue);
        expect(inputs.admission?.origin, 'sync');
        expect(inputs.admission?.statePolicy, 'hard_only');
        expect(inputs.admission?.syncId, streamDbSyncId);
      });

      test('an_admission_snapshot_with_nul_does_not_mask_the_format', () async {
        final pin = await publishStreamDb(session);
        // U+0000 in a plugin configuration cannot become jsonb.
        final text =
            (await session.db.unsafeQuery(
                  'SELECT "publicJson" FROM ingest_config_snapshot WHERE "snapshotId"=@pin',
                  parameters: QueryParameters.named({'pin': pin}),
                )).single[0]!
                as String;
        final document = jsonDecode(text) as Map<String, Object?>;
        document['outputs'] = [
          ...(document['outputs'] as List<Object?>),
          {
            'id': '33333333-3333-4333-8333-333333333333',
            'kind': 'plugin',
            'config': {'token': '\u0000'},
          },
        ];
        await session.db.unsafeExecute(
          'UPDATE ingest_config_snapshot SET "publicJson"=@json WHERE "snapshotId"=@pin',
          parameters: QueryParameters.named({
            'pin': pin,
            'json': jsonEncode(document),
          }),
        );
        final body = webhook.body({
          'format': 'correlia.icinga2.stream.v9',
          'origin': 'stream',
          'items': <Object?>[],
        });
        final key = await seed(icinga2DbSourceId, body, pin, admission: pin);
        final inputs = await read(key, pin);
        expect(inputs.stream, isTrue);
        expect(
          () => decodeRow(inputs, body, processedAt: _firstProcessing),
          throwsA(
            isA<EventFieldError>().having(
              (e) => e.code,
              'code',
              'unsupported_format',
            ),
          ),
        );
      });

      test(
        'an_unavailable_admission_read_does_not_mask_the_format',
        () async {
          final pin = await publishStreamDb(session);
          final body = webhook.body({
            'format': 'correlia.icinga2.stream.v9',
            'origin': 'stream',
            'items': <Object?>[],
          });
          final key = await seed(icinga2DbSourceId, body, pin, admission: pin);
          // Another transaction holds the admission table: a read of it would
          // wait out its timeout and the worker would retry the row.
          final lockSession = builder.build();
          final acquired = Completer<void>();
          final release = Completer<void>();
          final lock = lockSession.db.transaction((tx) async {
            await lockSession.db.unsafeSimpleExecute(
              'LOCK TABLE icinga2_raw_origin IN ACCESS EXCLUSIVE MODE',
              transaction: tx,
            );
            acquired.complete();
            await release.future;
          });
          try {
            await acquired.future;
            final inputs = await read(
              key,
              pin,
            ).timeout(const Duration(seconds: 2));
            expect(inputs.admission, isNull);
            expect(
              () => decodeRow(inputs, body, processedAt: _firstProcessing),
              throwsA(
                isA<EventFieldError>().having(
                  (e) => e.code,
                  'code',
                  'unsupported_format',
                ),
              ),
            );
          } finally {
            release.complete();
            await lock;
          }
        },
      );

      test(
        'an_unreadable_admission_snapshot_does_not_mask_the_format',
        () async {
          final admitted = await publishStreamDb(session);
          final processing = await publishStreamDb(session, revision: 2);
          final body = webhook.body({
            'format': 'correlia.icinga2.stream.v9',
            'origin': 'stream',
            'items': <Object?>[],
          });
          final key = await seed(
            icinga2DbSourceId,
            body,
            processing,
            admission: admitted,
          );
          // The admission snapshot is not JSON; the processing pin is fine.
          await session.db.unsafeExecute(
            '''UPDATE ingest_config_snapshot SET "publicJson"='{not json'
            WHERE "snapshotId"=@id''',
            parameters: QueryParameters.named({'id': admitted}),
          );
          final inputs = await read(key, processing);
          expect(
            () => decodeRow(inputs, body, processedAt: _firstProcessing),
            throwsA(
              isA<EventFieldError>().having(
                (e) => e.code,
                'code',
                'unsupported_format',
              ),
            ),
          );
          // The worker fails the row at once with the row's own format error.
          await processIcinga2(session, _observed);
          expect(
            await queryRows(
              session,
              'SELECT "errorClass", "fieldPath" FROM pipeline_failures',
            ),
            [
              {'errorClass': 'unsupported_format', 'fieldPath': 'format'},
            ],
          );
        },
      );

      test('an_admission_snapshot_listing_the_source_twice', () async {
        final admitted = await publishStreamDb(session);
        final processing = await publishStreamDb(session, revision: 2);
        // A damaged admission snapshot lists the row's source twice, with
        // different policies: neither may be guessed.
        final text =
            (await session.db.unsafeQuery(
                  'SELECT "publicJson" FROM ingest_config_snapshot WHERE "snapshotId"=@id',
                  parameters: QueryParameters.named({'id': admitted}),
                )).single[0]!
                as String;
        final document = jsonDecode(text) as Map<String, Object?>;
        final sources = document['sources']! as List<Object?>;
        final original = sources.cast<Map<String, Object?>>().singleWhere(
          (entry) => entry['id'] == icinga2DbSourceId,
        );
        document['sources'] = [
          {...original, 'state_type_policy': 'hard_only'},
          ...sources,
        ];
        await session.db.unsafeExecute(
          'UPDATE ingest_config_snapshot SET "publicJson"=@json WHERE "snapshotId"=@id',
          parameters: QueryParameters.named({
            'id': admitted,
            'json': jsonEncode(document),
          }),
        );
        final known = await seed(
          icinga2DbSourceId,
          streamBody(),
          processing,
          admission: admitted,
        );
        final knownInputs = await read(known, processing);
        expect(
          () => decodeRow(
            knownInputs,
            streamBody(),
            processedAt: _firstProcessing,
          ),
          throwsA(isA<InvalidStoredSettings>()),
        );
        // A row in an unknown format still fails with its own error.
        final body = webhook.body({
          'format': 'correlia.icinga2.stream.v9',
          'origin': 'stream',
          'items': <Object?>[],
        });
        final unknown = await seed(
          icinga2DbSourceId,
          body,
          processing,
          admission: admitted,
        );
        final unknownInputs = await read(unknown, processing);
        expect(
          () => decodeRow(unknownInputs, body, processedAt: _firstProcessing),
          throwsA(
            isA<EventFieldError>().having(
              (e) => e.code,
              'code',
              'unsupported_format',
            ),
          ),
        );
      });

      test('read_decode_inputs_names_a_pin_without_the_source', () async {
        final pin = await publishStreamDb(session);
        final key = await seed(
          icinga2DbSourceId,
          streamBody(),
          pin,
          admission: pin,
        );
        await session.db.unsafeExecute(
          '''UPDATE ingest_config_snapshot
SET "publicJson"=(("publicJson"::jsonb) || '{"sources":[]}'::jsonb)::text
WHERE "snapshotId"=@pin''',
          parameters: QueryParameters.named({'pin': pin}),
        );
        final inputs = await read(key, pin);
        expect(inputs.rejection, DecodeRejection.sourceNotConfigured);
        expect(
          () => decodeRow(inputs, streamBody(), processedAt: _firstProcessing),
          throwsStateError,
        );
      });

      test('decode_row_is_pure_over_its_inputs', () async {
        final pin = await publishAlertmanager();
        final body = Uint8List.fromList(
          utf8.encode(
            jsonEncode(
              payload.groupOf([
                payload.alert(startsAt: '2026-11-23T11:00:00Z'),
              ]),
            ),
          ),
        );
        final key = await seed(_alertmanagerSource, body, pin);
        final inputs = await read(key, pin);
        // The inputs hold everything: the database and the row can disappear.
        await clearPipelineTables(session);
        final first = decodeRow(inputs, body, processedAt: _firstProcessing);
        final second = decodeRow(inputs, body, processedAt: _firstProcessing);
        expect(first.batch.events, hasLength(1));
        expect(
          first.batch.events.single.toJson(),
          second.batch.events.single.toJson(),
        );
        expect(first.batch.events.single.processedAt, _firstProcessing);
      });

      test(
        'admission_snapshot_differing_from_the_pin_decodes_as_admitted',
        () async {
          final strict = await publishStreamDb(session, policy: 'hard_only');
          final permissive = await publishStreamDb(session, revision: 2);
          final body = Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                'format': 'correlia.icinga2.stream.v1',
                'origin': 'stream',
                'connection': 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
                'items': [
                  {
                    'received': _observed.microsecondsSinceEpoch,
                    'line': jsonEncode(streamDbCheck(_observed, stateType: 0)),
                  },
                ],
              }),
            ),
          );
          // Admitted under the strict snapshot, processed under the permissive one.
          final admittedStrict = await seed(
            icinga2DbSourceId,
            body,
            permissive,
            admission: strict,
          );
          final strictInputs = await read(admittedStrict, permissive);
          expect(strictInputs.pin, permissive);
          expect(strictInputs.admission?.statePolicy, 'hard_only');
          final dropped = decodeRow(
            strictInputs,
            body,
            processedAt: _firstProcessing,
          );
          expect(dropped.batch.events, isEmpty);
          expect(dropped.batch.softInfo, 1);

          // Admitted under the permissive snapshot, processed under the strict one.
          final admittedPermissive = await seed(
            icinga2DbSourceId,
            body,
            strict,
            admission: permissive,
          );
          final permissiveInputs = await read(admittedPermissive, strict);
          expect(permissiveInputs.admission?.statePolicy, 'soft_and_hard');
          final kept = decodeRow(
            permissiveInputs,
            body,
            processedAt: _firstProcessing,
          );
          expect(kept.batch.events, hasLength(1));
          expect(kept.batch.softInfo, 0);
        },
      );
    },
    // Each test commits its own rows; setUp truncates them.
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
