import 'dart:convert';
import 'dart:io';

import 'package:correlia_server/event.dart';
import 'package:correlia_server/src/ingest/alertmanager_decoder.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

const _releases = ['v0.39.2', 'v0.40.1', 'v0.41.0', 'v0.42.5'];
const _runs = ['kept', 'dropped'];
const _statuses = ['firing', 'resolved'];
const _replicas = {'a', 'b'};
const _source = '11111111-1111-4111-8111-111111111111';
const _root = 'test/unit/ingest/fixtures/thanos';
final _digest = RegExp(r'^sha256:[0-9a-f]{64}$');

Map<String, Object?> _object(Object? value) => value as Map<String, Object?>;

List<Map<String, Object?>> _manifest() {
  final file = File('$_root/manifest.json');
  expect(file.existsSync(), isTrue, reason: 'missing ${file.path}');
  return (_object(jsonDecode(file.readAsStringSync()))['fixtures']!
          as List<Object?>)
      .cast<Map<String, Object?>>();
}

Set<String> _files() => Directory(_root)
    .listSync()
    .whereType<File>()
    .map((file) => file.uri.pathSegments.last)
    .where((name) => name.endsWith('.json') && name != 'manifest.json')
    .toSet();

void _verifyManifest(List<Map<String, Object?>> entries, Set<String> files) {
  final names = <String>{};
  final matrix = <(String, String, String)>{};
  final sequences = <(String, String), Set<int>>{};
  for (final entry in entries) {
    final file = entry['file']! as String;
    final release = entry['release']! as String;
    final run = entry['run']! as String;
    final status = entry['status']! as String;
    final sequence = entry['sequence']! as int;
    expect(names.add(file), isTrue, reason: 'duplicate manifest entry $file');
    expect(files, contains(file), reason: 'missing fixture $file');
    expect(_releases, contains(release), reason: file);
    expect(_runs, contains(run), reason: file);
    expect(_statuses, contains(status), reason: file);
    expect(sequence, greaterThan(0), reason: file);
    expect(
      sequences.putIfAbsent((release, run), () => {}).add(sequence),
      isTrue,
      reason: 'duplicate sequence for $release $run',
    );
    matrix.add((release, run, status));

    final images = _object(entry['images']);
    for (final (role, tag) in [
      ('thanos', 'quay.io/thanos/thanos:$release'),
      ('alertmanager', 'prom/alertmanager:v0.35.0'),
      ('query', 'prom/prometheus:v3.16.0'),
    ]) {
      final image = _object(images[role]);
      expect(image['tag'], tag, reason: '$file $role');
      expect(image['digest'], matches(_digest), reason: '$file $role');
    }
    final replicas = _object(entry['replicas']);
    for (final replica in _replicas) {
      final counter = _object(replicas[replica]);
      expect(
        counter['before'],
        isA<int>().having((n) => n >= 0, 'nonnegative', isTrue),
      );
      expect(
        counter['after'],
        greaterThan(counter['before']! as int),
        reason: '$release $run replica $replica did not send',
      );
    }
  }
  expect(files.difference(names), isEmpty, reason: 'unlisted fixtures');
  for (final release in _releases) {
    for (final run in _runs) {
      for (final status in _statuses) {
        expect(
          matrix,
          contains((release, run, status)),
          reason: 'missing capture $release $run $status',
        );
      }
    }
  }
}

List<CanonicalEvent> _decode(
  Map<String, Object?> entry, {
  List<String> excluded = const [],
}) {
  final name = entry['file']! as String;
  final bytes = File('$_root/$name').readAsBytesSync();
  final payload = _object(jsonDecode(utf8.decode(bytes)));
  expect(payload['status'], entry['status'], reason: name);
  final expectedStatus = entry['status'] == 'firing'
      ? EventStatus.firing
      : EventStatus.resolved;
  final batch = decodeAlertmanager(
    bytes: bytes,
    sourceInstance: _source,
    excludedLabels: excluded,
    rawRef: 'raw:$name',
    rawSha256: sha256.convert(bytes).toString(),
    observedAt: EventTimestamp.parse('2026-11-24T20:00:00Z'),
    processedAt: EventTimestamp.parse('2026-11-24T20:01:00Z'),
    configVersion: 'compatibility',
  );
  expect(batch.events, isNotEmpty, reason: name);
  expect(batch.upstreamOmissions, 0, reason: name);
  expect(batch.events.map((e) => e.status), everyElement(expectedStatus));
  expect(
    batch.events.map((e) => e.labels['alertname']),
    everyElement('CorreliaCapture'),
  );
  expect(
    batch.events.map((e) => e.labels['replica']).nonNulls.toSet(),
    unorderedEquals(entry['replica_labels']! as List<Object?>),
    reason: name,
  );
  return batch.events;
}

void main() {
  test('manifest_matches_the_fixtures', () {
    _verifyManifest(_manifest(), _files());
  });

  test('capture_matrix_incomplete', () {
    final entries = _manifest();
    final removed = entries
        .where(
          (e) =>
              e['release'] == _releases.last &&
              e['run'] == 'dropped' &&
              e['status'] == 'resolved',
        )
        .toList();
    expect(removed, isNotEmpty);
    entries.removeWhere(removed.contains);
    final files = _files()..removeAll(removed.map((e) => e['file']! as String));
    expect(
      () => _verifyManifest(entries, files),
      throwsA(
        isA<TestFailure>().having(
          (e) => e.message,
          'missing matrix cell',
          contains('missing capture ${_releases.last} dropped resolved'),
        ),
      ),
    );
  });

  test('replica_evidence_missing', () {
    final entries = _manifest();
    final entry = entries.first;
    final counter = _object(_object(entry['replicas'])['b']);
    counter['after'] = counter['before'];
    expect(
      () => _verifyManifest(entries, _files()),
      throwsA(
        isA<TestFailure>().having(
          (e) => e.message,
          'missing counter increase',
          contains(
            "${entry['release']} ${entry['run']} replica b did not send",
          ),
        ),
      ),
    );
  });

  test('fixture_added_by_hand', () {
    final entries = _manifest();
    expect(
      () => _verifyManifest(entries, _files()..add('added-by-hand.json')),
      throwsA(
        isA<TestFailure>().having(
          (e) => e.message,
          'unlisted file',
          contains('added-by-hand.json'),
        ),
      ),
    );
  });

  test('every_captured_thanos_release_decodes', () {
    final entries = _manifest();
    _verifyManifest(entries, _files());
    final byReplica = <String?, Set<String>>{};
    final source = SourceContext(
      sourceInstance: _source,
      sourceKind: 'alertmanager',
    );
    for (final event in entries.expand(_decode)) {
      expect(
        event.fingerprint,
        alertFingerprint(source, selectAlertmanagerIdentity(event.labels)),
      );
      byReplica
          .putIfAbsent(event.labels['replica'], () => {})
          .add(event.fingerprint);
    }
    expect(byReplica.keys, unorderedEquals([null, ..._replicas]));
    for (final fingerprints in byReplica.values) {
      expect(fingerprints, hasLength(1));
    }
  });

  test('two_ruler_replicas_replica_label_excluded', () {
    final entries = _manifest();
    for (final release in _releases) {
      final kept = entries
          .where((e) => e['release'] == release && e['run'] == 'kept')
          .expand((e) => _decode(e, excluded: ['replica']))
          .toList();
      expect(kept.map((e) => e.labels['replica']).toSet(), _replicas);
      expect(kept.map((e) => e.fingerprint).toSet(), hasLength(1));
    }
  });

  test('replica_label_dropped_by_ruler', () {
    final entries = _manifest();
    _verifyManifest(entries, _files());
    final dropped = entries
        .where((e) => e['run'] == 'dropped')
        .expand(_decode)
        .toList();
    expect(
      dropped.map((e) => e.labels.containsKey('replica')),
      everyElement(isFalse),
    );
    expect(dropped.map((e) => e.fingerprint).toSet(), hasLength(1));
  });

  test('replica_label_kept_in_identity', () {
    final entries = _manifest();
    for (final release in _releases) {
      for (final status in _statuses) {
        final kept = entries
            .where(
              (e) =>
                  e['release'] == release &&
                  e['run'] == 'kept' &&
                  e['status'] == status,
            )
            .expand(_decode)
            .toList();
        expect(kept.map((e) => e.labels['replica']).toSet(), _replicas);
        expect(kept.map((e) => e.fingerprint).toSet(), hasLength(2));
      }
    }
  });
}
