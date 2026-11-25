import 'dart:async';
import 'dart:convert';

import 'package:correlia_server/event.dart';
import 'package:correlia_server/src/matcher/matcher_condition.dart';
import 'package:correlia_server/src/matcher/matcher_regex.dart';
import 'package:correlia_server/src/matcher/stored_matcher_filter.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/ingest_schema.dart';
import '../unit/event/fixture.dart';

void main() {
  withServerpod(
    'matcher filters',
    (builder, _) {
      test('RUL-6 condition corpus parity', () async {
        final session = builder.build();
        final cases = [
          (pattern: 'é.😀', input: 'é\n😀', expected: true),
          (pattern: 'é.😀', input: 'é\r\n😀', expected: false),
          (pattern: r'\[x\]\\', input: '[x]\\', expected: true),
          (pattern: '[a-z]{2,4}', input: 'ABC', expected: false),
          (pattern: 'a{255}|b', input: 'b', expected: true),
          (
            pattern: '.{255}aaaaaa',
            input: '${'~' * 255}aaaaaa',
            expected: true,
          ),
          (pattern: '([!ap]{2}){2}', input: '!app', expected: true),
          (pattern: r'\~|\!|\^', input: '^', expected: true),
          (pattern: '[ -~]', input: '\u0000', expected: false),
          (pattern: '\u0000', input: '\u0001', expected: false),
          (pattern: '\u0000', input: r'\u0000', expected: false),
          (pattern: '\u0000', input: '\u0000', expected: true),
        ];
        for (final (:pattern, :input, :expected) in cases) {
          final parsed = MatcherRegex.parse(pattern);
          expect(
            RegExp(
              parsed.dartPattern,
              unicode: true,
              dotAll: true,
            ).hasMatch(input),
            expected,
            reason: pattern,
          );
          final rows = await session.db.unsafeQuery(
            '''
SELECT regexp_like(@input::text COLLATE "C", @pattern::text, 's')
''',
            parameters: QueryParameters.named({
              'input': encodeMatcherText(input),
              'pattern': parsed.sqlPattern,
            }),
          );
          expect(rows.single[0], expected, reason: pattern);
        }
      });

      test('historical NUL parity', () async {
        final session = builder.build();
        await initializeIngestSchema(session);
        final rows = await session.db.unsafeQuery(
          r'''
SELECT correlia_matcher_data(convert_to(@doc, 'UTF8'))
       #>> ARRAY['labels', @key]::text[]
''',
          parameters: QueryParameters.named({
            'doc':
                r'{"data":{"labels":{"\u007E":"\\\u0000\u0001\u0021\u005e~"}}}',
            'key': encodeMatcherText('~'),
          }),
        );
        expect(rows.single[0], encodeMatcherText('\\\u0000\u0001!^~'));
        final literal = await session.db.unsafeQuery(
          r"SELECT correlia_matcher_data(convert_to(@doc, 'UTF8'))->>'summary'",
          parameters: QueryParameters.named({
            'doc': jsonEncode({
              'data': {'summary': r'\u0000'},
            }),
          }),
        );
        expect(literal.single[0], r'\u0000');
      });

      test('shared regex parser rejects expansions over the limit', () {
        expect(
          () => MatcherRegex.parse('.{255}aaaaaaa'),
          throwsFormatException,
        );
        expect(
          () => MatcherRegex.parse('((a{255}){255}){255}|b'),
          throwsFormatException,
        );
      });

      test('missing and null are false before negation', () async {
        final session = builder.build();
        final data = Map<String, Object?>.of(
          eventFixture()['data']! as Map<String, Object?>,
        )..['labels'] = <String, String>{'empty': ''};
        final event = CanonicalEvent.fromJson(data);
        data['labels'] = <String, Object?>{'empty': '', 'null_value': null};
        const leaf = {'field': 'labels.null_value', 'op': 'exists'};
        final cases = <(Map<String, Object?>, bool)>[
          ({'field': 'labels.empty', 'op': 'exists'}, true),
          ({'field': 'labels.missing', 'op': 'exists'}, false),
          (leaf, false),
          ({'not': leaf}, true),
          ({'field': 'severity', 'op': 'gt', 'value': 'unknown'}, true),
          ({'field': 'severity', 'op': 'lt', 'value': 'error'}, true),
          ({'field': 'severity', 'op': 'equals', 'value': 'warning'}, true),
          (
            {
              'field': 'status',
              'op': 'in',
              'value': ['firing'],
            },
            true,
          ),
          ({'field': 'kind', 'op': 'equals', 'value': 'alert'}, true),
          (
            {'field': 'labels.null_value', 'op': 'not_equals', 'value': ''},
            false,
          ),
        ];
        for (final (input, expected) in cases) {
          final condition = MatcherCondition.parse(input);
          final (:expression, :parameters) = condition.compileSql();
          final rows = await session.db.unsafeQuery(
            'SELECT $expression FROM (SELECT @doc::jsonb AS data) AS event',
            parameters: QueryParameters.named({
              ...parameters,
              'doc': jsonEncode(data),
            }),
          );
          expect(await condition.matches(event), expected);
          expect(rows.single[0], expected, reason: input.toString());
        }
      });

      test('scan cursor advances across ties and misses', () async {
        final session = builder.build();
        await initializeIngestSchema(session);
        final observedAt = DateTime.utc(2026, 11, 10);
        const id = '86fe3b73-ec2d-5dd3-b104-11f2ec79469c';
        const literal = "' OR TRUE; -- %_\u0000";
        final originals = <String, CanonicalEvent>{};
        for (final (disposition, summary) in [
          ('first', 'miss'),
          ('second', literal),
          ('third', r"' OR TRUE; -- %_\u0000"),
        ]) {
          final doc = eventFixture();
          final data = doc['data']! as Map<String, Object?>;
          data['summary'] = summary;
          originals[disposition] = CanonicalEvent.fromJson(data);
          await session.db.unsafeQuery(
            '''
INSERT INTO events
 (observed_at, event_id, disposition, raw_observed_at, raw_id, source_id,
  config_snapshot_id, source_time, payload)
VALUES (@observed, @id::uuid, @disposition, @observed, @id::uuid, @id::uuid,
        'snapshot', @observed, convert_to(@doc, 'UTF8'))
''',
            parameters: QueryParameters.named({
              'observed': observedAt,
              'id': id,
              'disposition': disposition,
              'doc': jsonEncode(doc),
            }),
          );
        }
        final filter = StoredMatcherFilter(session);
        final condition = MatcherCondition.parse({
          'field': 'summary',
          'op': 'equals',
          'value': literal,
        });
        final end = observedAt.add(const Duration(hours: 1));
        final first = await filter.scan(
          condition,
          start: observedAt,
          end: end,
          limit: 1,
        );
        expect(first.matches, isEmpty);
        expect(first.next?.disposition, 'first');
        final second = await filter.scan(
          condition,
          start: observedAt,
          end: end,
          limit: 2,
          after: first.next,
        );
        expect(second.matches.single.disposition, 'second');
        expect(second.matches.single.eventId, id);
        expect(second.next, isNull);
        for (final (op, operand) in <(String, Object)>[
          ('in', [literal]),
          ('glob', '*%_?'),
          ('regex', '\u0000'),
        ]) {
          final condition = MatcherCondition.parse({
            'field': 'summary',
            'op': op,
            'value': operand,
          });
          final expected = <String>[];
          for (final entry in originals.entries) {
            if (await condition.matches(entry.value)) expected.add(entry.key);
          }
          expect(expected, ['second']);
          final page = await filter.scan(
            condition,
            start: observedAt,
            end: end,
          );
          expect(page.matches.map((key) => key.disposition), expected);
        }
      });

      test('cancellation is an error', () async {
        final lockSession = builder.build();
        final scanSession = builder.build();
        final observer = builder.build();
        await initializeIngestSchema(lockSession);
        final acquired = Completer<void>();
        final release = Completer<void>();
        final lock = lockSession.db.transaction((tx) async {
          await lockSession.db.unsafeSimpleExecute(
            'LOCK TABLE events IN ACCESS EXCLUSIVE MODE',
            transaction: tx,
          );
          acquired.complete();
          await release.future;
        });
        try {
          await acquired.future;
          final filter = StoredMatcherFilter(
            scanSession,
            statementTimeout: const Duration(minutes: 3),
          );
          final start = DateTime.utc(2026, 11, 10);
          var settled = false;
          final outcome = expectLater(
            filter.scan(
              MatcherCondition.parse({'field': 'summary', 'op': 'exists'}),
              start: start,
              end: start.add(const Duration(hours: 1)),
            ),
            throwsA(isA<MatcherFilterCancelled>()),
          ).whenComplete(() => settled = true);
          while (!settled) {
            final cancelled = await observer.db.unsafeQuery('''
SELECT pg_cancel_backend(pid)
FROM pg_locks
WHERE relation = 'events'::regclass AND NOT granted
  AND mode = 'AccessShareLock' AND database = (
    SELECT oid FROM pg_database WHERE datname = current_database()
  )
''');
            if (cancelled.isNotEmpty) {
              expect(cancelled.single[0], isTrue);
              await outcome;
              return;
            }
          }
          await outcome;
          fail('Filter settled before the observer canceled its lock wait');
        } finally {
          release.complete();
          await lock;
        }
      }, timeout: const Timeout(Duration(minutes: 5)));
    },
    testGroupTagsOverride: ['db'],
    rollbackDatabase: RollbackDatabase.disabled,
  );
}
