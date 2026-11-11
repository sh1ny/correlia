import 'dart:async';

import 'package:correlia_server/src/feed/feed_reader.dart';
import 'package:correlia_server/src/feed/feed_watermark_subsystem.dart';
import 'package:correlia_server/src/generated/protocol.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/ingest_schema.dart';

void main() {
  withServerpod(
    'feed watermark',
    (builder, _) {
      test('ui_3b_blocker_without_activity', () async {
        final blocker = builder.build();
        final writer = builder.build();
        await initializeIngestSchema(writer);
        await writer.db.unsafeExecute('DELETE FROM activity');
        final reader = FeedReader(builder.build());
        final cursor = (await reader.snapshot()).cursor;
        final started = Completer<void>();
        final release = Completer<void>();
        final firstPoll = Completer<void>();
        final wake = Completer<void>();
        final poller = FeedWatermarkSubsystem(
          openSession: () async => builder.build(),
          pollInterval: const Duration(milliseconds: 20),
          log: (_) {},
          onPoll: () {
            if (!firstPoll.isCompleted) firstPoll.complete();
          },
        );
        await poller.start();
        final pending = blocker.db.transaction((tx) async {
          await blocker.db.unsafeQuery(
            'SELECT pg_current_xact_id()',
            transaction: tx,
          );
          started.complete();
          await release.future;
        });
        StreamSubscription<FeedWakeUp>? subscription;
        try {
          await started.future;
          await writer.db.unsafeExecute('''
INSERT INTO activity (occurred_at, entity_kind, entity_id, entity_version, change_kind, actor_kind)
VALUES (now(), 'alert', 1, 1, 'created', 'pipeline')
''');
          subscription = poller.wakeUps().listen((_) {
            if (!wake.isCompleted) wake.complete();
          });
          await firstPoll.future;
          expect(wake.isCompleted, isFalse);
          release.complete();
          await pending;
          await wake.future.timeout(const Duration(seconds: 3));
          expect((await reader.feed(cursor, 10)).entries, hasLength(1));
        } finally {
          if (!release.isCompleted) release.complete();
          await pending;
          await subscription?.cancel();
          await poller.stop();
        }
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
