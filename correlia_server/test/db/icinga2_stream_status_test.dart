import 'dart:convert';

import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/database.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/lease.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/status.dart';
import 'package:postgres/postgres.dart' hide Session;
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_pipeline.dart';
import '../support/icinga2_stream_fixture.dart';
import '../support/icinga2_stream_pipeline.dart';
import '../support/ingest_schema.dart';
import '../support/secret_fixture.dart';

void main() {
  withServerpod(
    'stream status fences and connection gaps',
    (builder, _) {
      late Session session;
      late Connection connection;
      late StreamLeaseStore leases;
      late StreamStatusStore statuses;

      setUp(() async {
        session = builder.build();
        await initializeIngestSchema(session);
        await clearPipelineTables(session);
        await session.db.unsafeSimpleExecute(
          'TRUNCATE icinga2_stream_status, icinga2_stream_lease CASCADE',
        );
        await publishStreamDb(session);
        connection = await openStreamDatabase(session.serverpod);
        addTearDown(() async {
          if (connection.isOpen) await connection.close();
        });
        leases = StreamLeaseStore(connection);
        statuses = StreamStatusStore(connection);
      });

      Future<StreamLease> acquire(String holder) async {
        final lease = await leases.acquire(icinga2DbSourceId, holder);
        expect(lease, isNotNull);
        return lease!;
      }

      Future<void> expire() => session.db.unsafeExecute('''
        UPDATE icinga2_stream_lease SET "expiresAt" = clock_timestamp() - interval '1 second'
        WHERE "sourceId" = '$icinga2DbSourceId'
      ''');

      Future<Map<String, Object?>> storedStatus() async => (await queryRows(
        session,
        '''SELECT row_to_json(s)::text AS value FROM icinga2_stream_status s
           WHERE "sourceId" = '$icinga2DbSourceId' ''',
      )).single;

      Future<void> publish(
        int revision,
        List<Object?> sources,
        Map<String, Object?> material,
      ) async {
        await IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        ).publishConfig(
          streamBootstrap(revision, sources),
          material,
          runMode: 'test',
          clock: () => streamDbNow,
        );
      }

      test('source_removed_while_quiet', () async {
        final lease = await acquire('holder-a');
        final seq = (await statuses.startConnection(lease, 'connection-a'))!;
        expect(
          await statuses.setState(lease, StreamConsumerState.connected),
          isTrue,
        );
        await publish(2, [], {});

        expect(await statuses.recordGap(lease, seq), isTrue);
        expect(
          await statuses.setState(lease, StreamConsumerState.stopped),
          isTrue,
        );
        expect(await leases.release(lease), isTrue);
        final status = (await statuses.read(icinga2DbSourceId))!;
        expect(status.state, StreamConsumerState.stopped);
        expect(status.gapCount, 1);
        expect(status.lastGapSeq, seq);
      });

      test('rotation_between_batches', () async {
        final lease = await acquire('holder-a');
        final first = (await statuses.startConnection(lease, 'connection-a'))!;
        final source = streamSource(icinga2DbSourceId);
        (source['api']! as Map<String, Object?>)['password_ref'] =
            'icinga-password-next';
        final material = {
          'icinga-password-next': {
            'bytes': base64Url
                .encode(utf8.encode('rotated password'))
                .replaceAll('=', ''),
          },
        };
        await publish(2, [source], material);

        expect(await statuses.recordGap(lease, first), isTrue);
        final second = await statuses.startConnection(lease, 'connection-b');
        expect(second, first + 1);
        final status = (await statuses.read(icinga2DbSourceId))!;
        expect(status.connectionId, 'connection-b');
        expect(status.gapCount, 1);
        expect(status.lastGapSeq, first);
      });

      test('old_holder_cannot_write_after_takeover', () async {
        final old = await acquire('holder-a');
        final seq = (await statuses.startConnection(old, 'connection-a'))!;
        await expire();
        final current = await acquire('holder-b');
        expect(await statuses.recordGap(current, seq), isTrue);
        final before = await storedStatus();

        expect(
          await statuses.setState(old, StreamConsumerState.stopped),
          isFalse,
        );
        expect(await statuses.recordGap(old, seq), isFalse);
        expect(await statuses.recordOversize(old), isFalse);
        expect(await statuses.startConnection(old, 'obsolete'), isNull);
        expect(await storedStatus(), before);
      });

      test('holder_died_with_no_replacement', () async {
        final lease = await acquire('holder-a');
        await statuses.startConnection(lease, 'connection-a');
        expect(
          await statuses.setState(lease, StreamConsumerState.connected),
          isTrue,
        );
        final before = await storedStatus();
        await expire();

        expect(
          (await statuses.read(icinga2DbSourceId))!.state,
          StreamConsumerState.stale,
        );
        expect(await storedStatus(), before);
        expect(
          (await statuses.read(icinga2DbSourceId))!.state,
          StreamConsumerState.stale,
        );
        expect(await storedStatus(), before);
      });

      test('gap_recorded_by_the_next_holder', () async {
        final old = await acquire('holder-a');
        final first = (await statuses.startConnection(old, 'connection-a'))!;
        expect(
          await statuses.setState(old, StreamConsumerState.connected),
          isTrue,
        );
        await expire();
        final next = await acquire('holder-b');
        expect(await statuses.recordGap(next, first), isTrue);
        final second = await statuses.startConnection(next, 'connection-b');
        expect(second, first + 1);
        final status = (await statuses.read(icinga2DbSourceId))!;
        expect(status.gapCount, 1);
        expect(status.lastGapSeq, first);
      });

      test('gap_already_recorded', () async {
        final old = await acquire('holder-a');
        final first = (await statuses.startConnection(old, 'connection-a'))!;
        expect(await statuses.recordGap(old, first), isTrue);
        await expire();
        final next = await acquire('holder-b');
        await statuses.recordGap(next, first);
        expect(await statuses.startConnection(next, 'connection-b'), first + 1);
        final status = (await statuses.read(icinga2DbSourceId))!;
        expect(status.gapCount, 1);
        expect(status.lastGapSeq, first);
      });

      test('death_between_recording_a_connection_and_subscribing', () async {
        final old = await acquire('holder-a');
        final first = (await statuses.startConnection(old, 'not-subscribed'))!;
        // The committed connection record is the only action before the holder dies.
        expect(
          (await statuses.read(icinga2DbSourceId))!.connectionId,
          'not-subscribed',
        );
        await expire();
        final next = await acquire('holder-b');
        expect(await statuses.recordGap(next, first), isTrue);
        expect(await statuses.startConnection(next, 'connection-b'), first + 1);
        final status = (await statuses.read(icinga2DbSourceId))!;
        expect(status.gapCount, 1);
        expect(status.lastGapSeq, first);
      });

      test('late_retry_of_an_older_gap', () async {
        final lease = await acquire('holder-a');
        var seq = (await statuses.startConnection(lease, 'connection-1'))!;
        for (var i = 1; i <= 5; i++) {
          expect(await statuses.recordGap(lease, seq), isTrue);
          if (i < 5) {
            seq = (await statuses.startConnection(
              lease,
              'connection-${i + 1}',
            ))!;
          }
        }
        final before = (await statuses.read(icinga2DbSourceId))!;
        expect(before.gapCount, 5);
        expect(before.lastGapSeq, seq);
        await statuses.recordGap(lease, seq - 1);
        final after = (await statuses.read(icinga2DbSourceId))!;
        expect(after.gapCount, 5);
        expect(after.lastGapSeq, seq);
      });

      test('status_write_during_a_database_outage', () async {
        final old = await acquire('holder-a');
        final seq = (await statuses.startConnection(old, 'connection-a'))!;
        await expire();
        expect(await statuses.recordGap(old, seq), isFalse);
        final rejected = (await statuses.read(icinga2DbSourceId))!;
        expect(rejected.gapCount, 0);
        final next = await acquire('holder-b');
        expect(await statuses.recordGap(next, seq), isTrue);
        await statuses.recordGap(next, seq);
        final status = (await statuses.read(icinga2DbSourceId))!;
        expect(status.gapCount, 1);
        expect(status.lastGapSeq, seq);
      });

      test('two_oversize_lines_on_one_connection', () async {
        final lease = await acquire('holder-a');
        final seq = (await statuses.startConnection(lease, 'connection-a'))!;
        expect(await statuses.recordOversize(lease), isTrue);
        expect(await statuses.recordOversize(lease), isTrue);
        final status = (await statuses.read(icinga2DbSourceId))!;
        expect(status.connectionSeq, seq);
        expect(status.oversizeLines, 2);
        expect(status.gapCount, 0);
        await expire();
        await acquire('holder-b');
        final persisted = (await statuses.read(icinga2DbSourceId))!;
        expect(persisted.oversizeLines, 2);
        expect(persisted.gapCount, 0);
      });

      test('late_sync_status_cannot_replace_successor_state', () async {
        final lease = await acquire('same-holder');
        expect(await statuses.startConnection(lease, 'old'), 1);
        expect(
          await statuses.setState(
            lease,
            StreamConsumerState.syncing,
            connectionId: 'old',
          ),
          isTrue,
        );
        expect(await statuses.startConnection(lease, 'new'), 2);
        expect(
          await statuses.setState(
            lease,
            StreamConsumerState.backoff,
            connectionId: 'new',
          ),
          isTrue,
        );
        expect(
          await statuses.setState(
            lease,
            StreamConsumerState.connected,
            connectionId: 'old',
          ),
          isFalse,
        );
        final current = (await statuses.read(icinga2DbSourceId))!;
        expect(current.state, StreamConsumerState.backoff);
        expect(current.connectionId, 'new');
        expect(current.gapCount, 1);
      });

      test(
        'numbering_rechecks_current_config_before_credential_handoff',
        () async {
          final first =
              (await IngestConfigRepository(
                    session,
                  ).activeSnapshot())!['snapshotId']!
                  as String;
          final lease = await acquire('same-holder');
          final second = await publishStreamDb(
            session,
            revision: 2,
            apiUrl: 'https://changed.example:5665',
          );
          await expectLater(
            statuses.startConnection(lease, 'wrong', snapshotId: first),
            throwsA(isA<StreamTargetChanged>()),
          );
          expect(
            await statuses.startConnection(lease, 'right', snapshotId: second),
            1,
          );
          final current = (await statuses.read(icinga2DbSourceId))!;
          expect(current.connectionId, 'right');
          expect(current.gapCount, 0);
        },
      );
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
