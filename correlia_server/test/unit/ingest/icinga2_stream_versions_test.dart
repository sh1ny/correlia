import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

const _releases = ['2.13.14', '2.14.10', '2.15.7', '2.16.6'];
const _fixtureRoot = 'test/unit/ingest/fixtures/icinga2';
const _eventTypes = {
  'StateChange',
  'AcknowledgementSet',
  'AcknowledgementCleared',
  'DowntimeStarted',
  'DowntimeRemoved',
  'Flapping',
};
final _grants = {
  for (final type in _eventTypes) 'events/$type',
  'objects/query/Host',
  'objects/query/Service',
};

void main() {
  for (final release in _releases) {
    group(release, () {
      final path = '$_fixtureRoot/$release/stream';

      test('stream_and_sync_copies_parse_to_equal_doubles', () {
        final manifest = _object(
          File('$path/manifest.json').readAsStringSync(),
        );
        final expectedOutput = manifest['paired_service_output'];
        final sync = _object(File('$path/services.json').readAsStringSync());
        if (sync case {
          'results': [
            {
              'attrs': {
                'name': String serviceName,
                'host_name': String hostName,
                'last_check_result': Map<String, Object?> syncResult,
              },
            },
          ],
        }) {
          final streamResult = File('$path/events.ndjson')
              .readAsLinesSync()
              .map(_object)
              .where(
                (event) =>
                    event['type'] == 'StateChange' &&
                    event['host'] == hostName &&
                    event['service'] == serviceName,
              )
              .map((event) => event['check_result']! as Map<String, Object?>)
              .singleWhere((result) => result['output'] == expectedOutput);

          expect(syncResult['output'], expectedOutput);
          expect(
            (streamResult['execution_start']! as num).toDouble(),
            (syncResult['execution_start']! as num).toDouble(),
          );
        } else {
          fail('$release: service projection has no paired check result');
        }
      });

      test('version_matrix', () {
        final capture = _readCapture(path);
        final run = _consumerRun(path);
        final decoded = run['decoded']! as Map<String, Object?>;
        final lines = decoded['events']! as List<Object?>;
        expect(
          lines,
          hasLength(capture.events.length),
          reason: 'every stream line',
        );
        for (var i = 0; i < lines.length; i++) {
          final event = capture.events[i];
          final decodedLine = lines[i]! as Map<String, Object?>;
          expect(decodedLine['type'], event['type']);
          final expectedKind = switch (event['type']) {
            'StateChange' => 'alert',
            'AcknowledgementSet' || 'AcknowledgementCleared' => 'ack',
            'DowntimeStarted' || 'DowntimeRemoved' => 'downtime',
            'Flapping' => 'state',
            _ => throw StateError('unknown captured type'),
          };
          expect(decodedLine['kind'], expectedKind);
          final key =
              jsonDecode(decodedLine['key']! as String) as List<Object?>;
          final timestamp = expectedKind == 'alert'
              ? (event['check_result']!
                    as Map<String, Object?>)['execution_start']
              : event['timestamp'];
          expect(
            key[expectedKind == 'alert' ? 3 : 2],
            (timestamp! as num).toDouble().toString(),
          );
          if (expectedKind == 'alert') {
            final check = event['check_result']! as Map<String, Object?>;
            expect(
              key[4],
              (check['execution_end']! as num).toDouble().toString(),
            );
          }
        }
        expect(decoded['hosts'], hasLength(capture.hosts.length));
        expect(decoded['services'], hasLength(capture.services.length));
      });

      test('listed_release_that_fails', () {
        final capture = _readCapture(path);
        final lines = [...capture.events];
        final index = lines.indexWhere(
          (event) => event['type'] == 'StateChange',
        );
        lines[index] = {...lines[index]}..remove('check_result');
        expect(() => _validateEvents(lines), throwsFormatException);
      });

      test('release_whose_capture_fails', () {
        final capture = _readCapture(path);
        final lines = capture.events
            .where((event) => event['type'] != 'StateChange')
            .toList();
        expect(() => _validateEvents(lines), throwsFormatException);
      });

      test('same_service_through_stream_and_sync', () {
        _readCapture(path);
        final run = _consumerRun(path);
        final pair = run['paired_service']! as Map<String, Object?>;
        final stream = pair['stream']! as Map<String, Object?>;
        final sync = pair['sync']! as Map<String, Object?>;
        final fingerprint = stream['fingerprint'];
        final eventId = stream['event_id'];
        expect(fingerprint, matches(r'^[0-9a-f]{64}$'));
        expect(
          eventId,
          matches(r'^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$'),
        );
        expect(sync['fingerprint'], fingerprint);
        expect(sync['event_id'], eventId);
      });

      test('real_consumer_against_a_release', () {
        _readCapture(path);
        final run = _consumerRun(path);
        expect(run['first_sync'], 'complete');
        expect(run['consumer_status'], 'connected');
        expect(run['before_recovery'], 'firing');
        expect(run['after_recovery'], 'resolved');
      });

      test('missing_permission_in_the_documented_list', () {
        final capture = _readCapture(path);
        final upstream =
            capture.manifest['permission_denials']! as Map<String, Object?>;
        final actual =
            _consumerRun(path)['permission_denials']! as Map<String, Object?>;
        expect(actual.keys, unorderedEquals(_grants));
        for (final grant in _grants) {
          final wire = upstream[grant]! as Map<String, Object?>;
          final result = actual[grant]! as Map<String, Object?>;
          expect(result['upstream_status'], wire['status'], reason: grant);
          expect(result['phase'], wire['phase'], reason: grant);
          expect(
            result['error_class'],
            wire['status'] == 403 ? 'forbidden' : 'http_status',
            reason: grant,
          );
          expect(result['successful_first_sync'], isFalse, reason: grant);
          if (wire['phase'] == 'subscription') {
            expect(result['sync_started'], isFalse, reason: grant);
          }
        }
      });
    });
  }
}

Map<String, Object?> _object(String json) =>
    jsonDecode(json) as Map<String, Object?>;

({
  Map<String, Object?> manifest,
  List<Map<String, Object?>> events,
  List<Object?> hosts,
  List<Object?> services,
})
_readCapture(String path) {
  final manifest = _object(File('$path/manifest.json').readAsStringSync());
  expect(manifest['subscription_status'], 200);
  expect(manifest['grants'], unorderedEquals(_grants));
  final denials = manifest['permission_denials']! as Map<String, Object?>;
  expect(denials.keys, unorderedEquals(_grants));
  for (final MapEntry(key: grant, value: denial) in denials.entries) {
    final detail = denial! as Map<String, Object?>;
    expect(detail['phase'], switch (grant) {
      'objects/query/Host' => 'hosts',
      'objects/query/Service' => 'services',
      _ => 'subscription',
    });
    expect(detail['status'], anyOf(403, 404), reason: grant);
  }
  final events = File(
    '$path/events.ndjson',
  ).readAsLinesSync().map(_object).toList();
  _validateEvents(events);
  List<Object?> objects(String kind) {
    final json = _object(File('$path/$kind.json').readAsStringSync());
    final results = json['results']! as List<Object?>;
    expect(results, isNotEmpty, reason: kind);
    return results;
  }

  return (
    manifest: manifest,
    events: events,
    hosts: objects('hosts'),
    services: objects('services'),
  );
}

void _validateEvents(List<Map<String, Object?>> events) {
  final types = <Object?>{};
  for (final event in events) {
    final type = event['type'];
    if (!_eventTypes.contains(type) || event['timestamp'] is! num) {
      throw const FormatException('invalid subscribed event or timestamp');
    }
    types.add(type);
    if (type != 'StateChange') continue;
    if (event case {
      'check_result': {
        'execution_start': num _,
        'execution_end': num _,
        'vars_after': {'state': num _, 'state_type': num _},
      },
    }) {
      continue;
    } else {
      throw const FormatException('StateChange missing check-result evidence');
    }
  }
  if (!types.containsAll(_eventTypes)) {
    throw const FormatException('capture omits a subscribed event type');
  }
}

Map<String, Object?> _consumerRun(String path) {
  final file = File('$path/consumer-run.json');
  if (!file.existsSync()) {
    fail('missing real consumer run record: ${file.path} (task 11.4)');
  }
  return _object(file.readAsStringSync());
}
