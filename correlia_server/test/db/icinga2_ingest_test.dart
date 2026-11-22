import 'dart:convert';
import 'dart:typed_data';

import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_delivery.dart';
import '../support/icinga2_pipeline.dart';

/// The worker's first observation time; every scenario is relative to it.
final base = DateTime.utc(2026, 11, 10, 12);

DateTime at(int minutes, [int seconds = 0]) =>
    base.add(Duration(minutes: minutes, seconds: seconds));

/// A delivery for service `db1!disk`; times are instants, not text.
Map<String, Object?> notify({
  String type = 'PROBLEM',
  String state = 'CRITICAL',
  String stateType = 'HARD',
  required DateTime changed,
  DateTime? notified,
  Map<String, Object?> set = const {},
}) => delivery(
  set: {
    'notification_type': type,
    'state': state,
    'state_type': stateType,
    'last_state_change': timeText(changed),
    'notification_time': timeText(notified ?? changed),
    ...set,
  },
);

/// Every ordering of [items].
Iterable<List<T>> permutations<T>(List<T> items) sync* {
  if (items.length <= 1) {
    yield [...items];
    return;
  }
  for (var i = 0; i < items.length; i++) {
    final rest = [...items]..removeAt(i);
    for (final tail in permutations(rest)) {
      yield [items[i], ...tail];
    }
  }
}

Uint8List nested(int depth) =>
    Uint8List.fromList('${'[' * depth}${']' * depth}'.codeUnits);

void main() {
  withServerpod(
    'Icinga2 deliveries through the real pipeline',
    (builder, _) {
      late Session s;

      setUp(() async {
        s = builder.build();
        await clearPipelineTables(s);
        await publishIcinga2Config(s);
      });

      Future<void> expectNoEffects() async {
        for (final table in [
          'events',
          'observation_keys',
          'outbox',
          'alerts',
          'activity',
        ]) {
          expect(await countRows(s, table), 0, reason: table);
        }
      }

      /// The row failed in the first attempt: a validation outcome, no retry.
      Future<void> expectFailure(
        String raw,
        String code,
        String path,
      ) async {
        final row = (await queryRows(
          s,
          "SELECT status, attempt_count, next_attempt_at, config_snapshot_id FROM raw_inbox WHERE raw_id=CAST('$raw' AS uuid)",
        )).single;
        expect(row['status'], 'failed');
        expect(row['attempt_count'], 0);
        expect(row['next_attempt_at'], isNull);
        expect(row['config_snapshot_id'], isNotNull);
        final failures = await queryRows(
          s,
          'SELECT "errorClass", "fieldPath", "configSnapshotId" FROM pipeline_failures',
        );
        expect(failures, hasLength(1));
        expect(failures.single['errorClass'], code);
        expect(failures.single['fieldPath'], path);
        expect(failures.single['configSnapshotId'], row['config_snapshot_id']);
        await expectNoEffects();
      }

      group('decode failures', () {
        test('wrong_type_on_a_known_field', () async {
          final raw = await deliverIcinga2(
            s,
            delivery(set: {'state': 2}),
            base,
          );
          await expectFailure(raw, 'invalid_type', 'state');
        });

        test('duplicate_member_name', () async {
          // "state": 2 before a valid "state": jsonDecode alone would keep
          // the valid one and store a firing event.
          final text = utf8.decode(body(delivery()));
          final raw = await deliverIcinga2(
            s,
            Uint8List.fromList(utf8.encode('{"state":2,${text.substring(1)}')),
            base,
          );
          await expectFailure(raw, 'duplicate_field', 'state');
        });

        test('nul_in_a_host_name', () async {
          final raw = await deliverIcinga2(
            s,
            delivery(set: {'host': 'db1\u0000x'}),
            base,
          );
          await expectFailure(raw, 'invalid_text', 'host');
        });

        test('deeply_nested_body', () async {
          final raw = await deliverIcinga2(s, nested(10000), base);
          await expectFailure(raw, 'depth_bound', 'body');
        });

        test('out_of_range_time', () async {
          final raw = await deliverIcinga2(
            s,
            delivery(set: {'last_state_change': '253402300800.000000'}),
            base,
          );
          await expectFailure(raw, 'out_of_range', 'last_state_change');
        });

        test('invalid_state_change_time_on_a_non_state_delivery', () async {
          // The optional time is still checked: the worker stores the failure
          // at last_state_change, commits nothing and does not retry.
          final raw = await deliverIcinga2(
            s,
            delivery(
              set: {
                'notification_type': 'CUSTOM',
                'last_state_change': '0.000000',
              },
            ),
            base,
          );
          await expectFailure(raw, 'invalid_time', 'last_state_change');
        });

        test('missing_state_change_time', () async {
          final raw = await deliverIcinga2(
            s,
            delivery(
              set: {'notification_type': 'PROBLEM', 'last_state_change': null},
            ),
            base,
          );
          await expectFailure(raw, 'missing_field', 'last_state_change');
        });

        test('unsupported_notification_type', () async {
          final raw = await deliverIcinga2(
            s,
            delivery(set: {'notification_type': 'ESCALATION'}),
            base,
          );
          await expectFailure(raw, 'unsupported_type', 'notification_type');
        });
      });

      group('state is the object state when the command ran', () {
        test('recovery_notification_sent_after_a_refire', () async {
          final first = notify(changed: at(-60));
          await deliverIcinga2(s, first, base);
          // The delayed RECOVERY runs after the refire: state CRITICAL, the
          // refire's change time.
          final recovery = notify(
            type: 'RECOVERY',
            changed: at(-30),
            notified: at(1),
          );
          final raw = await deliverIcinga2(s, recovery, at(1));
          final event = await storedEvent(s, eventIdOf(recovery));
          expect(event['type'], 'io.correlia.alert.v1');
          final data = event['data']! as Map<String, Object?>;
          expect(data['status'], 'EVENT_STATUS_FIRING');
          expect(
            (data['annotations']!
                as Map<String, Object?>)['icinga2.notification_type'],
            'RECOVERY',
          );
          expect((await outcomeOf(s, raw))['applied'], 1);
          expect((await theAlert(s))['status'], 'firing');
          // The refire's own PROBLEM is the same observation.
          final problem = notify(changed: at(-30), notified: at(2));
          final second = await deliverIcinga2(s, problem, at(2));
          expect(eventIdOf(problem), eventIdOf(recovery));
          expect((await outcomeOf(s, second))['duplicate_observation'], 1);
          final alert = await theAlert(s);
          expect(alert['status'], 'firing');
          expect(alert['fenceEventId'], eventIdOf(recovery));
          expect(alert['lastObservedAt'], at(2));
          expect(await countRows(s, 'events'), 2);
        });

        test('delayed_notifications_in_any_order', () async {
          final deliveries = [
            (notify(changed: at(-2)), at(0)),
            (notify(state: 'OK', type: 'RECOVERY', changed: at(-1)), at(1)),
            (notify(changed: at(-1, 30)), at(2)),
          ];
          final lastCritical = eventIdOf(deliveries[2].$1);
          expect(
            {for (final (d, _) in deliveries) eventIdOf(d)},
            hasLength(3),
          );
          for (final order in permutations([0, 1, 2])) {
            await clearPipelineTables(s);
            await publishIcinga2Config(s);
            for (final i in order) {
              await deliverIcinga2(s, deliveries[i].$1, deliveries[i].$2);
            }
            final alert = await theAlert(s);
            expect(alert['status'], 'firing', reason: '$order');
            expect(alert['fenceEventId'], lastCritical, reason: '$order');
          }
        });
      });

      group('convergence contract', () {
        test('lost_recovery', () async {
          await deliverIcinga2(s, notify(changed: at(-10)), at(0));
          expect((await theAlert(s))['status'], 'firing');
          // The OK that follows is never delivered. A later eligible
          // observation with a new event id outranks the fence.
          final later = notify(state: 'OK', type: 'RECOVERY', changed: at(20));
          await deliverIcinga2(s, later, at(21));
          final alert = await theAlert(s);
          expect(alert['status'], 'resolved');
          expect(alert['fenceEventId'], eventIdOf(later));
        });

        test('late_reminder_wins_the_event_id_insert', () async {
          final prompt = notify(changed: at(-1));
          final reminderObserved = at(0).add(const Duration(days: 8));
          // Prompt first: the late reminder is a duplicate and stays out of
          // freshness.
          await deliverIcinga2(s, prompt, at(0));
          final reminder = await deliverIcinga2(s, prompt, reminderObserved);
          final outcome = await outcomeOf(s, reminder);
          expect(outcome['duplicate_observation'], 1);
          expect(outcome['late'], 0);
          final alert = await theAlert(s);
          expect(alert['status'], 'firing');
          expect(alert['lastObservedAt'], at(0));
          expect(await countRows(s, 'events'), 1);
          // Reminder first: stored late, the prompt delivery is the duplicate,
          // and no alert exists.
          await clearPipelineTables(s);
          await publishIcinga2Config(s);
          final lateRaw = await deliverIcinga2(s, prompt, reminderObserved);
          expect((await outcomeOf(s, lateRaw))['late'], 1);
          final promptRaw = await deliverIcinga2(s, prompt, at(0));
          expect((await outcomeOf(s, promptRaw))['duplicate_observation'], 1);
          expect(await countRows(s, 'alerts'), 0);
          expect(await countRows(s, 'outbox'), 0);
          expect(
            (await queryRows(
              s,
              'SELECT disposition FROM events',
            )).single['disposition'],
            'late',
          );
        });

        test('torn_delivery_arrives_after_the_coherent_one', () async {
          final coherent = notify(changed: at(-5));
          await deliverIcinga2(s, coherent, at(0));
          // A delayed RECOVERY read state OK but the refire's change time.
          final torn = notify(state: 'OK', type: 'RECOVERY', changed: at(-5));
          await deliverIcinga2(s, torn, at(1));
          expect((await theAlert(s))['status'], 'resolved');
          final reminder = await deliverIcinga2(
            s,
            notify(changed: at(-5), notified: at(30)),
            at(30),
          );
          expect((await outcomeOf(s, reminder))['duplicate_observation'], 1);
          expect((await theAlert(s))['status'], 'resolved');
          final next = notify(changed: at(40));
          await deliverIcinga2(s, next, at(41));
          final alert = await theAlert(s);
          expect(alert['status'], 'firing');
          expect(alert['fenceEventId'], eventIdOf(next));
        });

        test('regressing_execution_end', () async {
          await deliverIcinga2(s, notify(changed: at(4)), at(5));
          final regressed = notify(
            state: 'OK',
            type: 'RECOVERY',
            changed: at(3),
          );
          final raw = await deliverIcinga2(s, regressed, at(6));
          expect((await outcomeOf(s, raw))['stale'], 1);
          final event = await storedEvent(s, eventIdOf(regressed));
          expect(event['_state_outcome'], 'stale');
          expect((await theAlert(s))['status'], 'firing');
          final next = notify(state: 'OK', type: 'RECOVERY', changed: at(7));
          await deliverIcinga2(s, next, at(8));
          final alert = await theAlert(s);
          expect(alert['status'], 'resolved');
          expect(alert['fenceEventId'], eventIdOf(next));
        });

        test('first_delivery_of_an_old_problem', () async {
          final old = notify(
            changed: base.subtract(const Duration(days: 9)),
            notified: base,
          );
          final raw = await deliverIcinga2(s, old, base);
          expect((await outcomeOf(s, raw))['late'], 1);
          expect(
            (await storedEvent(s, eventIdOf(old)))['_disposition'],
            'late',
          );
          expect(await countRows(s, 'alerts'), 0);
          expect(await countRows(s, 'outbox'), 0);
          expect(await countRows(s, 'activity'), 0);
        });

        test('reversed_receipt_under_the_skew_clamp', () async {
          // Observed 10:02 and 10:01; clamped effective times 10:07 and 10:06.
          final critical = notify(changed: DateTime.utc(2026, 11, 10, 10, 30));
          final ok = notify(
            state: 'OK',
            type: 'RECOVERY',
            changed: DateTime.utc(2026, 11, 10, 10, 31),
          );
          final criticalObserved = DateTime.utc(2026, 11, 10, 10, 2);
          final okObserved = DateTime.utc(2026, 11, 10, 10, 1);
          for (final criticalFirst in [true, false]) {
            await clearPipelineTables(s);
            await publishIcinga2Config(s);
            final steps = [(critical, criticalObserved), (ok, okObserved)];
            for (final (document, observed)
                in criticalFirst ? steps : steps.reversed) {
              await deliverIcinga2(s, document, observed);
            }
            final alert = await theAlert(s);
            expect(
              alert['status'],
              'firing',
              reason: 'criticalFirst=$criticalFirst',
            );
            expect(alert['fenceEventId'], eventIdOf(critical));
            final effective = await queryRows(
              s,
              'SELECT events_effective_source_time(e) AS t FROM events e ORDER BY 1',
            );
            expect(effective.map((e) => e['t']), [
              DateTime.utc(2026, 11, 10, 10, 6),
              DateTime.utc(2026, 11, 10, 10, 7),
            ]);
          }
        });

        test('equal_state_change_times', () async {
          final changed = at(-3);
          final a = notify(changed: changed, notified: at(0));
          final b = notify(
            state: 'OK',
            type: 'RECOVERY',
            changed: changed,
            notified: at(1),
          );
          final c = notify(changed: changed, notified: at(2));
          final received = {'A': at(0), 'B': at(1), 'C': at(2)};
          final documents = {'A': a, 'B': b, 'C': c};
          expect(eventIdOf(a), eventIdOf(c));
          expect(eventIdOf(a), isNot(eventIdOf(b)));
          for (final order in permutations(['A', 'B', 'C'])) {
            await clearPipelineTables(s);
            await publishIcinga2Config(s);
            final raws = <String, String>{};
            for (final name in order) {
              raws[name] = await deliverIcinga2(
                s,
                documents[name],
                received[name]!,
              );
            }
            // A and C are one observation, carried by whichever came first.
            final carrier = order.firstWhere((n) => n != 'B');
            final duplicate = carrier == 'A' ? 'C' : 'A';
            expect(
              (await outcomeOf(s, raws[duplicate]!))['duplicate_observation'],
              1,
              reason: '$order',
            );
            // The result is the observation whose carrier was received last.
            final criticalWins = carrier == 'C';
            final alert = await theAlert(s);
            expect(
              alert['status'],
              criticalWins ? 'firing' : 'resolved',
              reason: '$order',
            );
            expect(
              alert['fenceEventId'],
              criticalWins ? eventIdOf(a) : eventIdOf(b),
              reason: '$order',
            );
          }
        });
      });

      group('projection', () {
        test('id_7a_warning_to_critical_updates_one_alert', () async {
          await deliverIcinga2(
            s,
            notify(state: 'WARNING', changed: at(-10)),
            at(0),
          );
          await deliverIcinga2(s, notify(changed: at(-5)), at(1));
          final alert = await theAlert(s);
          expect(await countRows(s, 'alerts'), 1);
          expect(alert['severity'], 'critical');
          expect(alert['status'], 'firing');
          expect(alert['version'], 2);
          final ledger = await queryRows(
            s,
            'SELECT change_kind, entity_version FROM activity ORDER BY id',
          );
          expect(ledger.map((e) => e['change_kind']), [
            'created',
            'severity_changed',
          ]);
          expect(ledger.map((e) => e['entity_version']), [1, 2]);
        });

        test('same_state_with_different_check_output', () async {
          await deliverIcinga2(
            s,
            notify(changed: at(-10), set: {'output': 'DISK CRITICAL - 90%'}),
            at(0),
          );
          final before = await theAlert(s);
          final second = notify(
            changed: at(-5),
            set: {'output': 'DISK CRITICAL - 95%'},
          );
          final raw = await deliverIcinga2(s, second, at(1));
          expect((await outcomeOf(s, raw))['applied'], 1);
          final after = await theAlert(s);
          expect(after['fenceEventId'], eventIdOf(second));
          expect(after['fenceEventId'], isNot(before['fenceEventId']));
          expect(after['summary'], before['summary']);
          expect(after['summary'], 'db1!disk CRITICAL');
          expect(after['version'], before['version']);
          expect(await countRows(s, 'activity'), 1);
        });

        test('soft_problem_sampled_by_a_delayed_notification', () async {
          final soft = notify(stateType: 'SOFT', changed: at(-1));
          await deliverIcinga2(s, soft, at(0));
          final event = await storedEvent(s, eventIdOf(soft));
          expect(event['type'], 'io.correlia.state.v1');
          expect(
            (event['data']! as Map<String, Object?>)['status'],
            'EVENT_STATUS_INFO',
          );
          expect(event['_disposition'], 'ready');
          expect(await countRows(s, 'alerts'), 0);
          expect(await countRows(s, 'activity'), 0);
          // Routed: one output intent per route.
          expect(await countRows(s, 'outbox'), icinga2DbOutputIds.length);
        });

        test('soft_recovery_resolves', () async {
          await deliverIcinga2(s, notify(changed: at(-10)), at(0));
          expect((await theAlert(s))['status'], 'firing');
          final soft = notify(
            type: 'RECOVERY',
            state: 'OK',
            stateType: 'SOFT',
            changed: at(-5),
          );
          await deliverIcinga2(s, soft, at(1));
          final alert = await theAlert(s);
          expect(alert['status'], 'resolved');
          expect(alert['fenceEventId'], eventIdOf(soft));
        });
      });

      group('observations', () {
        test('re_notification_of_an_unchanged_problem', () async {
          final problem = notify(changed: at(-5));
          await deliverIcinga2(s, problem, at(0));
          final before = await theAlert(s);
          final outboxBefore = await countRows(s, 'outbox');
          final again = notify(changed: at(-5), notified: at(30));
          final raw = await deliverIcinga2(s, again, at(30));
          expect((await outcomeOf(s, raw))['duplicate_observation'], 1);
          final after = await theAlert(s);
          expect(after['lastObservedAt'], at(30));
          expect(after['version'], before['version']);
          expect(after['fenceEventId'], before['fenceEventId']);
          expect(await countRows(s, 'outbox'), outboxBefore);
          expect(await countRows(s, 'events'), 1);
        });

        test('soft_to_hard_without_a_state_value_change', () async {
          final soft = notify(stateType: 'SOFT', changed: at(-5));
          final hard = notify(stateType: 'HARD', changed: at(-5));
          expect(eventIdOf(soft), isNot(eventIdOf(hard)));
          await deliverIcinga2(s, soft, at(0));
          expect(await countRows(s, 'alerts'), 0);
          await deliverIcinga2(s, hard, at(1));
          final alert = await theAlert(s);
          expect(alert['status'], 'firing');
          expect(alert['fenceEventId'], eventIdOf(hard));
          expect(await countRows(s, 'events'), 2);
        });
      });

      group('informational events', () {
        test('custom_notification_while_the_service_is_ok', () async {
          await deliverIcinga2(s, notify(changed: at(-10)), at(0));
          final before = await theAlert(s);
          final custom = notify(
            type: 'CUSTOM',
            state: 'OK',
            changed: at(-1),
            notified: at(1),
            set: {'notification_author': 'bob', 'notification_comment': 'hi'},
          );
          await deliverIcinga2(s, custom, at(1));
          final event = await storedEvent(s, eventIdOf(custom));
          expect(event['type'], 'io.correlia.comment.v1');
          expect(
            (event['data']! as Map<String, Object?>)['status'],
            'EVENT_STATUS_INFO',
          );
          final after = await theAlert(s);
          expect(after['status'], 'firing');
          expect(after['fenceEventId'], before['fenceEventId']);
          expect(after['version'], before['version']);
          expect(await countRows(s, 'activity'), 1);
        });

        test('custom_notification_without_a_state_change_time', () async {
          final custom = notify(
            type: 'CUSTOM',
            changed: at(0),
            notified: at(1),
            set: {
              'last_state_change': null,
              'output': null,
              'notification_author': 'bob',
              'notification_comment': 'before the first check',
            },
          );
          expect(custom.containsKey('last_state_change'), isFalse);
          await deliverIcinga2(s, custom, at(1));
          final event = await storedEvent(s, eventIdOf(custom));
          expect(event['type'], 'io.correlia.comment.v1');
          expect(
            (event['data']! as Map<String, Object?>)['status'],
            'EVENT_STATUS_INFO',
          );
          expect(await countRows(s, 'events'), 1);
          expect(await countRows(s, 'alerts'), 0);
        });

        test('acknowledgement_is_published_without_state_change', () async {
          final problem = notify(changed: at(-10));
          await deliverIcinga2(s, problem, at(0));
          final before = await theAlert(s);
          final ack = notify(
            type: 'ACKNOWLEDGEMENT',
            changed: at(-10),
            notified: at(1),
            set: {'notification_author': 'alice'},
          );
          await deliverIcinga2(s, ack, at(1));
          final event = await storedEvent(s, eventIdOf(ack));
          expect(event['type'], 'io.correlia.ack.v1');
          expect(
            (event['data']! as Map<String, Object?>)['status'],
            'EVENT_STATUS_INFO',
          );
          expect(event['subject'], before['fingerprint']);
          final intents = await queryRows(
            s,
            "SELECT output_id::text AS output FROM outbox WHERE event_id=CAST('${eventIdOf(ack)}' AS uuid) ORDER BY 1",
          );
          expect(intents.map((e) => e['output']), icinga2DbOutputIds);
          final after = await theAlert(s);
          expect(after['status'], before['status']);
          expect(after['severity'], before['severity']);
          expect(after['version'], before['version']);
          expect(after['fenceEventId'], before['fenceEventId']);
        });

        test('same_microsecond_executions_coalesce', () async {
          final first = notify(
            type: 'CUSTOM',
            changed: at(-1),
            notified: at(0),
            set: {'notification_author': 'bob', 'notification_comment': 'one'},
          );
          final second = notify(
            type: 'CUSTOM',
            changed: at(-1),
            notified: at(0),
            set: {'notification_author': 'bob', 'notification_comment': 'two'},
          );
          await deliverIcinga2(s, first, at(0));
          final raw = await deliverIcinga2(s, second, at(0, 1));
          expect(eventIdOf(first), eventIdOf(second));
          expect((await outcomeOf(s, raw))['duplicate_observation'], 1);
          expect(await countRows(s, 'events'), 1);
        });

        test('authors_equal_in_their_first_1_kib', () async {
          // The shipped command delivers the cut and marked author, so two
          // authors equal in their first 1 KiB arrive as the same text.
          final delivered = '${'a' * 1024}…[truncated by correlia]';
          Map<String, Object?> custom(String author, String comment) => notify(
            type: 'CUSTOM',
            changed: at(-1),
            notified: at(0),
            set: {
              'notification_author': author,
              'notification_comment': comment,
            },
          );
          await deliverIcinga2(s, custom(delivered, 'one'), at(0));
          final raw = await deliverIcinga2(
            s,
            custom(delivered, 'two'),
            at(0, 1),
          );
          expect((await outcomeOf(s, raw))['duplicate_observation'], 1);
          expect(await countRows(s, 'events'), 1);
          // Authors that differ within the first 1 KiB are two events.
          final other = '${'b'}${'a' * 1023}…[truncated by correlia]';
          await deliverIcinga2(s, custom(other, 'three'), at(0, 2));
          expect(await countRows(s, 'events'), 2);
        });
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
