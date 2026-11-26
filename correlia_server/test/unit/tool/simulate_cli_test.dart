import 'dart:convert';
import 'dart:io' show FileSystemException, Platform, Process;

import 'package:correlia_client/correlia_client.dart' as rpc;
import 'package:correlia_server/src/event/cloud_event.dart'
    show cloudEventEnvelopeLimit;
import 'package:correlia_server/src/simulator/rule_simulator.dart'
    show simulationDraftLimit;
import 'package:test/test.dart';

import '../../../tool/simulate_cli.dart';

/// The arguments the fake simulator received.
typedef _Call = ({
  String? eventJson,
  String? eventId,
  String? observedAt,
  String? disposition,
  String? draftMatcher,
});

rpc.RuleSimulationResult _result({
  rpc.SimulationError? error,
  List<rpc.RuleTrace>? trace,
}) => rpc.RuleSimulationResult(
  error: error,
  ruleSource: 'active',
  snapshotId: 'snap-1',
  snapshotRevision: 7,
  noRulesActive: false,
  eventKind: 'alert',
  noiseClassHint: 'flapping',
  trace:
      trace ??
      [
        rpc.RuleTrace(
          ruleId: 'matched-rule',
          outcome: 'matched',
          conditions: [
            rpc.ConditionTrace(kind: 'all', outcome: 'true'),
            rpc.ConditionTrace(
              parentIndex: 0,
              kind: 'leaf',
              field: 'summary',
              op: 'exists',
              outcome: 'true',
            ),
            rpc.ConditionTrace(
              parentIndex: 0,
              kind: 'leaf',
              field: 'labels.team',
              op: 'equals',
              outcome: 'false',
              failureCode: 'value_differs',
            ),
          ],
          actions: [
            rpc.ActionTrace(
              index: 0,
              type: 'set_label',
              detail: 'team=ops',
              effect: 'label set',
              applied: true,
            ),
          ],
        ),
        rpc.RuleTrace(
          ruleId: 'skipped-rule',
          outcome: 'no_match',
          failureCode: 'condition_false',
          conditions: [],
          actions: [],
        ),
      ],
  finalLabels: {'team': 'ops'},
  finalLabelOrigins: {'team': 'rule:matched-rule'},
  finalLinks: [
    rpc.SimulatedLink(href: 'https://x.example/a', relation: 'runbook'),
  ],
  finalSeverity: 'critical',
  baselineRoutes: ['out-a'],
  addedRoutes: ['out-b'],
  routeNote: 'sample route note',
  sourceAbsent: false,
  baselineOverFanout: false,
  notes: ['a note'],
  storedSnapshotId: 'snap-0',
  storedLabels: {'old': 'label'},
  storedLabelOrigins: {'old': 'normalizer'},
  storedEnrichmentErrors: [
    rpc.StoredEnrichmentError(stage: 'regex', code: 'budget', message: 'slow'),
  ],
);

class _Harness {
  _Harness(this.result);

  final rpc.RuleSimulationResult result;
  final calls = <_Call>[];
  final out = StringBuffer();
  final err = StringBuffer();

  Future<int> run(List<String> args, {Map<String, String> files = const {}}) =>
      runSimulate(
        args,
        ({
          String? eventJson,
          String? eventId,
          String? observedAt,
          String? disposition,
          String? draftMatcher,
        }) async {
          calls.add((
            eventJson: eventJson,
            eventId: eventId,
            observedAt: observedAt,
            disposition: disposition,
            draftMatcher: draftMatcher,
          ));
          return result;
        },
        out,
        err,
        readFile: (path, maxBytes) {
          final bytes = utf8.encode(
            files[path] ?? (throw FileSystemException('no such file', path)),
          );
          // Like the real reader: at most one byte past the limit.
          return bytes.length > maxBytes + 1
              ? bytes.sublist(0, maxBytes + 1)
              : bytes;
        },
      );
}

const _id = '11111111-1111-4111-8111-111111111111';

void main() {
  group('readable output', () {
    test(
      'prints rules, condition leaves, actions and the final state',
      () async {
        final h = _Harness(_result());
        final code = await h.run(['--event-id', _id, '--observed-at', 'T']);
        expect(code, 0);
        final text = h.out.toString();
        expect(text, contains('rules: active (snapshot snap-1, revision 7)'));
        expect(text, contains('rule matched-rule: matched'));
        expect(text, contains('rule skipped-rule: no_match (condition_false)'));
        // The tree is indented by parent: the leaves sit one level below `all`.
        expect(text, contains('\n    all: true\n'));
        expect(text, contains('\n      summary exists: true\n'));
        expect(
          text,
          contains('\n      labels.team equals: false (value_differs)\n'),
        );
        expect(
          text,
          contains('action 0 set_label team=ops: label set (applied)'),
        );
        expect(text, contains('kind: alert'));
        expect(text, contains('noise class hint: flapping'));
        expect(text, contains('team=ops (rule:matched-rule)'));
        expect(text, contains('runbook https://x.example/a'));
        expect(text, contains('severity: critical'));
        expect(text, contains('out-b (hypothetical)'));
        expect(text, contains('note: a note'));
        expect(text, contains('stored snapshot: snap-0'));
        expect(text, contains('old=label (normalizer)'));
        expect(text, contains('regex budget: slow'));
        expect(h.err.toString(), isEmpty);
      },
    );

    test(
      'event text cannot forge a trace line or reach the terminal raw',
      () async {
        final forged = 'x\nrule forged: matched\r\x1b[2J\x07\x9b';
        final result = _result(
          trace: [
            rpc.RuleTrace(
              ruleId: 'r',
              outcome: 'matched',
              conditions: [],
              actions: [
                rpc.ActionTrace(
                  index: 0,
                  type: 'extract',
                  detail: 'k = $forged',
                  effect: 'staged',
                  applied: true,
                ),
              ],
            ),
          ],
        );
        result.finalLabels = {'team': forged};
        result.storedLabels = {'old': forged};
        result.finalLinks = [
          rpc.SimulatedLink(
            href: 'https://x.example/a',
            relation: 'runbook',
            text: forged,
          ),
        ];
        final h = _Harness(result);
        expect(await h.run(['--event-id', _id, '--observed-at', 'T']), 0);
        final text = h.out.toString();
        expect(text.split('\n'), isNot(contains(startsWith('rule forged'))));
        expect(text, isNot(contains('\r')));
        expect(text, isNot(contains('\x1b')));
        expect(text, isNot(contains('\x07')));
        expect(text, isNot(contains('\x9b')));
        expect(
          text,
          contains(r'team=x\nrule forged: matched\r\u{1b}[2J\u{7}\u{9b}'),
        );
      },
    );

    test('--json prints the result document only', () async {
      final h = _Harness(_result());
      final code = await h.run([
        '--event-id',
        _id,
        '--observed-at',
        'T',
        '--json',
      ]);
      expect(code, 0);
      final decoded = jsonDecode(h.out.toString()) as Map<String, Object?>;
      expect(decoded['ruleSource'], 'active');
      expect(decoded['finalLabels'], {'team': 'ops'});
    });

    test('--json escapes DEL and C1 controls', () async {
      const value = 'a\u007fb\u009b2Jc\u0085d';
      final result = _result()..finalLabels = {'team': value};
      final h = _Harness(result);
      final code = await h.run([
        '--event-id',
        _id,
        '--observed-at',
        'T',
        '--json',
      ]);
      expect(code, 0);
      final text = h.out.toString();
      expect(text.runes.where((r) => r >= 0x7f && r <= 0x9f), isEmpty);
      expect(text, contains(r'\u009b'));
      final decoded = jsonDecode(text) as Map<String, Object?>;
      expect(decoded['finalLabels'], {'team': value});
    });

    test('a pasted event file and a draft file are passed as read', () async {
      final h = _Harness(_result());
      final code = await h.run(
        ['--event', 'e.json', '--draft', 'd.json'],
        files: {'e.json': '{"id":"x"}', 'd.json': '{"rules":[]}'},
      );
      expect(code, 0);
      expect(h.calls.single.eventJson, '{"id":"x"}');
      expect(h.calls.single.draftMatcher, '{"rules":[]}');
      expect(h.calls.single.eventId, isNull);
    });

    test('a stored key passes ID, observed_at and disposition', () async {
      final h = _Harness(_result());
      await h.run([
        '--event-id',
        _id,
        '--observed-at',
        '2026-11-10T12:00:00Z',
        '--disposition',
        'late',
      ]);
      expect(h.calls.single.eventId, _id);
      expect(h.calls.single.observedAt, '2026-11-10T12:00:00Z');
      expect(h.calls.single.disposition, 'late');
      expect(h.calls.single.eventJson, isNull);
    });
  });

  group('usage', () {
    for (final args in [
      <String>[],
      ['--event', 'e.json', '--event-id', _id, '--observed-at', 'T'],
      ['--event-id', _id],
      ['--event', 'e.json', '--observed-at', 'T'],
      ['--event', 'e.json', '--bogus'],
      ['--event', 'e.json', 'draft', 'd.json'],
    ]) {
      test('${args.join(' ')} exits 64 with usage on stderr', () async {
        final h = _Harness(_result());
        expect(await h.run(args, files: {'e.json': '{}'}), 64);
        expect(h.out.toString(), isEmpty);
        expect(h.err.toString(), contains('Usage'));
        expect(h.calls, isEmpty);
      });
    }

    test('an unreadable file exits 64 naming the file', () async {
      final h = _Harness(_result());
      expect(await h.run(['--event', 'missing.json']), 64);
      expect(h.err.toString(), contains('missing.json'));
      expect(h.calls, isEmpty);
    });
  });

  group('file bounds', () {
    test('the limits are the server\'s', () {
      expect(eventFileLimit, cloudEventEnvelopeLimit);
      expect(draftFileLimit, simulationDraftLimit);
    });

    for (final (option, field, limit) in [
      ('--event', 'eventJson', eventFileLimit),
      ('--draft', 'draftMatcher', draftFileLimit),
    ]) {
      test('a $option file over its limit fails locally', () async {
        final h = _Harness(_result());
        final args = [
          if (option == '--draft') ...['--event-id', _id, '--observed-at', 'T'],
          option,
          'big.json',
        ];
        final code = await h.run(args, files: {'big.json': 'x' * (limit + 1)});
        expect(code, simulationFailedExit);
        expect(h.err.toString(), 'error: too_large\nfield: $field\n');
        expect(h.calls, isEmpty);
      });

      test('a $option file at its limit is sent', () async {
        final h = _Harness(_result());
        final args = [
          if (option == '--draft') ...['--event-id', _id, '--observed-at', 'T'],
          option,
          'big.json',
        ];
        expect(await h.run(args, files: {'big.json': 'x' * limit}), 0);
        expect(h.calls, hasLength(1));
      });
    }
  });

  test('malformed_timestamp', () async {
    for (final text in ['2026-11-10T12:00:00', '2026-02-30T12:00:00Z']) {
      final h = _Harness(
        _result(
          error: rpc.SimulationError(
            code: 'invalid_input',
            field: 'observedAt',
          ),
        ),
      );
      final code = await h.run(['--event-id', _id, '--observed-at', text]);
      expect(code, isNonZero);
      // The text reaches the simulator exactly as the operator typed it.
      expect(h.calls.single.observedAt, text);
      expect(h.err.toString(), contains('error: invalid_input'));
      expect(h.err.toString(), contains('field: observedAt'));
    }
  });

  test('simulator_error', () async {
    final errors = [
      rpc.SimulationError(code: 'event_not_found'),
      rpc.SimulationError(code: 'raw_unavailable'),
      rpc.SimulationError(code: 'ambiguous_member'),
      rpc.SimulationError(code: 'invalid_input', field: 'eventId'),
      rpc.SimulationError(code: 'missing_field', field: 'source'),
    ];
    for (final error in errors) {
      final h = _Harness(_result(error: error));
      final code = await h.run(['--event-id', _id, '--observed-at', 'T']);
      expect(code, 1, reason: error.code);
      expect(h.err.toString(), contains('error: ${error.code}'));
      if (error.field case final field?) {
        expect(h.err.toString(), contains('field: $field'));
      } else {
        expect(h.err.toString(), isNot(contains('field:')));
      }
      expect(h.out.toString(), isEmpty);
    }
  });

  test('an unknown output error names the output', () async {
    const output = '44444444-4444-4444-8444-444444444444';
    final h = _Harness(
      _result(
        error: rpc.SimulationError(
          code: 'unknown_output',
          field: 'matcher.rules[0].actions[0].output_id',
          missingOutputId: output,
        ),
      ),
    );
    expect(await h.run(['--event-id', _id, '--observed-at', 'T']), 1);
    expect(
      h.err.toString(),
      'error: unknown_output\n'
      'field: matcher.rules[0].actions[0].output_id\n'
      'output: $output\n',
    );
  });

  test('a stored label without an origin shows the source origin', () async {
    final result = _result()
      ..storedLabels = {'alertname': 'Example', 'old': 'label'}
      ..storedLabelOrigins = {'old': 'matcher'};
    final h = _Harness(result);
    expect(await h.run(['--event-id', _id, '--observed-at', 'T']), 0);
    final text = h.out.toString();
    expect(text, contains('alertname=Example (source)'));
    expect(text, contains('old=label (matcher)'));
    expect(text, isNot(contains('unknown origin')));
  });

  test('a server that is not an http URL is a usage error', () async {
    for (final server in ['localhost:8080', 'ftp://x.example/', 'http://']) {
      final h = _Harness(_result());
      expect(
        await h.run([
          '--server',
          server,
          '--event-id',
          _id,
          '--observed-at',
          'T',
        ]),
        64,
        reason: server,
      );
      expect(h.calls, isEmpty, reason: server);
      expect(h.err.toString(), contains('--server must be'), reason: server);
    }
    expect(isServerUrl('https://correlia.example:8443/'), isTrue);
  });

  test(
    'the entry point reports a bad server URL as a usage error',
    () async {
      final run = await Process.run(Platform.resolvedExecutable, [
        'run',
        'tool/simulate.dart',
        '--server',
        'localhost:8080',
        '--event-id',
        _id,
        '--observed-at',
        'T',
      ]);
      expect(run.exitCode, 64, reason: '${run.stderr}');
      expect('${run.stderr}', contains('--server must be'));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('an unreadable file path cannot forge a diagnostic line', () async {
    final h = _Harness(_result());
    const path = 'x\nerror: forged\x1b[2J';
    expect(await h.run(['--event', path]), 64);
    final text = h.err.toString();
    expect(text.split('\n'), isNot(contains(startsWith('error: forged'))));
    expect(text, isNot(contains('\x1b')));
    expect(text, contains(r'x\nerror: forged\u{1b}[2J'));
  });

  test('a rejected event cannot forge a diagnostic line', () async {
    // The field of an unknown-attribute rejection is the submitted name.
    final h = _Harness(
      _result(
        error: rpc.SimulationError(
          code: 'unknown_attribute',
          field: 'x\nerror: forged\x1b[2J',
        ),
      ),
    );
    expect(
      await h.run(['--event', 'e.json'], files: {'e.json': '{}'}),
      1,
    );
    final text = h.err.toString();
    expect(text.split('\n'), isNot(contains('error: forged')));
    expect(text, isNot(contains('\x1b')));
    expect(text, contains(r'field: x\nerror: forged\u{1b}[2J'));
  });

  test('a thrown call failure exits 1 with the message', () async {
    final err = StringBuffer();
    final code = await runSimulate(
      ['--event-id', _id, '--observed-at', 'T'],
      ({
        String? eventJson,
        String? eventId,
        String? observedAt,
        String? disposition,
        String? draftMatcher,
      }) => throw Exception('connection refused'),
      StringBuffer(),
      err,
    );
    expect(code, 1);
    expect(err.toString(), contains('connection refused'));
  });
}
