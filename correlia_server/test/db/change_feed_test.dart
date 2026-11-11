import 'dart:async';

import 'package:correlia_server/src/feed/feed_reader.dart';
import 'package:correlia_server/src/generated/protocol.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/ingest_schema.dart';

Future<int> _alert(
  Session session,
  String name, {
  String severity = 'warning',
}) async {
  final rows = await session.db.unsafeQuery('''
INSERT INTO alerts (tenant, fingerprint, status, severity, summary, "sourceInstance", "firingSince",
 "fenceEffectiveSeconds", "fenceEffectiveNanos", "fenceObservedSeconds", "fenceObservedNanos",
 "fenceEventId", "lastObservedAt", version, "createdAt", "updatedAt")
VALUES ('test', @name, 'firing', @severity, @name, 'test', now(), 0, 0, 0, 0,
 '00000000-0000-4000-8000-000000000001', now(), 1, now(), now()) RETURNING id
''', parameters: QueryParameters.named({'name': name, 'severity': severity}));
  return rows.single[0] as int;
}

Future<void> _activity(
  Session session,
  int id, {
  Transaction? transaction,
  int version = 1,
}) async {
  await session.db.unsafeExecute(
    '''
INSERT INTO activity (occurred_at, entity_kind, entity_id, entity_version, change_kind, actor_kind)
VALUES (now(), 'alert', @id, @version, 'created', 'pipeline')
''',
    parameters: QueryParameters.named({'id': id, 'version': version}),
    transaction: transaction,
  );
}

Future<void> _awaitReadable(Session session) async {
  // xmin covers the entire cluster, including other tests' isolated databases.
  final deadline = Stopwatch()..start();
  while (true) {
    final rows = await session.db.unsafeQuery('''
SELECT NOT EXISTS (
  SELECT 1 FROM activity
  WHERE txid >= pg_snapshot_xmin(pg_current_snapshot())
)
''');
    if (rows.single[0] as bool) return;
    if (deadline.elapsed > const Duration(seconds: 30)) {
      throw StateError('Activity remains above the cluster watermark');
    }
  }
}

void main() {
  withServerpod(
    'change feed',
    (builder, _) {
      setUp(() async {
        final session = builder.build();
        await initializeIngestSchema(session);
        await session.db.unsafeExecute('DELETE FROM activity');
        await session.db.unsafeExecute('DELETE FROM alerts');
      });

      test('ui_3a_late_committing_transaction_never_skipped', () async {
        final a = builder.build();
        final b = builder.build();
        final reader = FeedReader(builder.build());
        final firstId = await _alert(a, 'a');
        final secondId = await _alert(b, 'b');
        final initial = await reader.snapshot();
        final written = Completer<void>();
        final release = Completer<void>();
        final pending = a.db.transaction((tx) async {
          await _activity(a, firstId, transaction: tx);
          written.complete();
          await release.future;
        });
        try {
          await written.future;
          await _activity(b, secondId);
          final before = await reader.feed(initial.cursor, 100);
          expect(before.entries, isEmpty);
          expect(before.heldBack, isTrue);
        } finally {
          release.complete();
          await pending;
        }
        await _awaitReadable(b);
        final after = await reader.feed(initial.cursor, 100);
        expect(after.entries.map((e) => e.entityId), [firstId, secondId]);
        expect((await reader.feed(after.nextCursor, 100)).entries, isEmpty);
      });

      test('page_limit', () async {
        final session = builder.build();
        final reader = FeedReader(session);
        final cursor = (await reader.snapshot()).cursor;
        final ids = <int>[];
        for (var i = 0; i < 3; i++) {
          final id = await _alert(session, 'page$i');
          ids.add(id);
          await _activity(session, id);
        }
        await _awaitReadable(session);
        final first = await reader.feed(cursor, 2);
        expect(first.entries.map((e) => e.entityId), ids.take(2));
        expect(first.more, isTrue);
        final second = await reader.feed(first.nextCursor, 2);
        expect(second.entries.map((e) => e.entityId), ids.skip(2));
        expect(second.more, isFalse);
      });

      test('malformed_cursor', () async {
        final reader = FeedReader(builder.build());
        await expectLater(
          reader.feed('bad', 10),
          throwsA(isA<InvalidCursorException>()),
        );
        await expectLater(
          reader.feed('v1.18446744073709551615.0', 10),
          throwsA(isA<InvalidCursorException>()),
        );
      });

      test('snapshot_cursor_on_empty_ledger', () async {
        final session = builder.build();
        final reader = FeedReader(session);
        final snapshot = await reader.snapshot();
        await session.db.unsafeExecute('SELECT pg_current_xact_id()');
        final page = await reader.feed(snapshot.cursor, 10);
        expect(page.entries, isEmpty);
        expect((await reader.feed(page.nextCursor, 10)).entries, isEmpty);
      });

      test('change_committed_during_snapshot', () async {
        final session = builder.build();
        final reader = FeedReader(builder.build());
        final id = await _alert(session, 'during');
        final written = Completer<void>();
        final release = Completer<void>();
        final pending = session.db.transaction((tx) async {
          await session.db.unsafeExecute(
            "UPDATE alerts SET status = 'resolved', version = 2 WHERE id = @id",
            parameters: QueryParameters.named({'id': id}),
            transaction: tx,
          );
          await _activity(session, id, transaction: tx);
          written.complete();
          await release.future;
        });
        late String cursor;
        try {
          await written.future;
          cursor = (await reader.snapshot()).cursor;
        } finally {
          release.complete();
          await pending;
        }
        await _awaitReadable(session);
        expect((await reader.feed(cursor, 10)).entries.map((e) => e.entityId), [
          id,
        ]);
      });

      test('repeated_change_in_snapshot_and_feed', () async {
        final blocker = builder.build();
        final writer = builder.build();
        final reader = FeedReader(builder.build());
        final started = Completer<void>();
        final release = Completer<void>();
        final pending = blocker.db.transaction((tx) async {
          await blocker.db.unsafeQuery(
            'SELECT pg_current_xact_id()',
            transaction: tx,
          );
          started.complete();
          await release.future;
        });
        late String cursor;
        late int id;
        try {
          await started.future;
          id = await _alert(writer, 'repeat');
          await _activity(writer, id);
          final snapshot = await reader.snapshot();
          expect(snapshot.alerts.single.version, 1);
          cursor = snapshot.cursor;
          await writer.db.unsafeExecute(
            'UPDATE alerts SET status = \'resolved\', version = 2 WHERE id = @id',
            parameters: QueryParameters.named({'id': id}),
          );
          await _activity(writer, id, version: 2);
        } finally {
          release.complete();
          await pending;
        }
        await _awaitReadable(writer);
        final page = await reader.feed(cursor, 10);
        expect(page.entries.map((e) => e.entityVersion), [1, 2]);
        expect(page.alerts.single.status, 'resolved');
        expect(page.alerts.single.version, 2);
      });

      test('snapshot_bound_exceeded', () async {
        final session = builder.build();
        for (var i = 0; i < 501; i++) {
          await _alert(
            session,
            'bound$i',
            severity: i == 500 ? 'critical' : 'warning',
          );
        }
        final snapshot = await FeedReader(session).snapshot();
        expect(snapshot.alerts, hasLength(500));
        expect(snapshot.omittedCount, 1);
        expect(snapshot.alerts.first.severity, 'critical');
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
