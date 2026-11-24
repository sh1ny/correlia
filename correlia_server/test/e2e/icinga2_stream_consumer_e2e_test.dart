@Tags(['e2e'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:correlia_server/src/ingest/icinga2/stream/batcher.dart'
    show streamLineLimit;
import 'package:test/test.dart';

import '../support/child_server.dart';
import '../support/icinga2_consumer_loopback.dart';
import '../support/icinga2_stream_child.dart';
import '../support/icinga2_pipeline.dart';
import '../support/icinga2_delivery.dart';
import '../support/icinga2_stream_fixture.dart';
import '../support/icinga2_stream_pipeline.dart';

const _source = icinga2DbSourceId;
const _timeout = Timeout(Duration(minutes: 4));
final _connectedLine = RegExp('icinga2-stream source=$_source connected');

void main() {
  late Icinga2StreamChild scenario;
  setUp(() async => scenario = await Icinga2StreamChild.create());

  for (final chunked in [false, true]) {
    test(
      'valid_stream_source_and_subscription_accepted_${chunked ? 'chunked' : 'close_delimited'}',
      () async {
        scenario.upstream.chunked = chunked;
        final child = await scenario.start(revision: 1);
        await scenario.waitState('connected');
        expect(scenario.upstream.subscriptionsReady, 1);
        expect(scenario.upstream.reads, 1);
        expect(scenario.upstream.eventRequests.single, (
          'POST',
          jsonEncode({
            'queue': _source,
            'types': [
              'StateChange',
              'AcknowledgementSet',
              'AcknowledgementCleared',
              'DowntimeStarted',
              'DowntimeRemoved',
              'Flapping',
            ],
          }),
        ));
        const host = 'accepted-subscription-host';
        await scenario.upstream.send(
          streamDbCheck(DateTime.now().toUtc(), host: host),
        );
        await scenario.expectDelivery(_source, host);
        await child.waitForOutput(_connectedLine, timeout: null);
      },
      timeout: _timeout,
    );
  }

  test('first_stream_source_on_a_running_worker', () async {
    final worker = await scenario.start(
      role: 'worker',
      revision: 1,
      sources: [],
    );
    expect(await scenario.count('icinga2_stream_lease'), 0);
    final publisher = await scenario.start(role: 'api', revision: 2);
    await scenario.waitState('connected');
    expect(scenario.upstream.subscriptionsReady, 1);
    await worker.waitForOutput(_connectedLine, timeout: null);
    expect(publisher.output, isNot(contains('icinga2-stream source=')));
  }, timeout: _timeout);

  for (final (name, response, error) in [
    ('permission_missing', 403, 'forbidden'),
    ('subscription_not_found_backs_off', 404, 'http_status'),
    ('headers_never_arrive', null, 'timeout'),
  ]) {
    test(name, () async {
      scenario.upstream.subscriptionStatus = response;
      await scenario.start(revision: 1);
      final backoff = await scenario.firstBackoff();
      expect(backoff[0], error);
      if (response != null) expect(scenario.upstream.eventRequests, isNotEmpty);
      expect(scenario.upstream.reads, 0);
      expect(await scenario.count('icinga2_sync_progress'), 0);
      expect(await scenario.count('raw_inbox'), 0);
    }, timeout: _timeout);
  }

  test('status_read_locally', () async {
    final child = await scenario.start(revision: 1, mode: 'development');
    await scenario.waitState('connected');
    final (status, body) = await _status(child);
    expect(status, HttpStatus.ok, reason: body);
    final data = jsonDecode(body) as Map<String, Object?>;
    expect(data, containsPair('sourceId', _source));
    expect(data, containsPair('state', 'connected'));
    expect(data, containsPair('gapCount', 0));
    expect(data['lastSync'], isA<Map<String, Object?>>());
    expect(body, isNot(contains('fixture password')));
    expect(body, isNot(contains('BEGIN CERTIFICATE')));
    expect(body, isNot(contains('commitment')));
  }, timeout: _timeout);

  test('status_method_in_production', () async {
    final child = await scenario.start(revision: 1, mode: 'production');
    await scenario.waitState('connected');
    final (code, body) = await _status(child);
    expect(code, isNot(HttpStatus.ok));
    expect(body, contains('Console access denied'));
    await child.waitForOutput(_connectedLine, timeout: null);
  }, timeout: _timeout);

  test('holder_died_with_no_replacement', () async {
    final worker = await scenario.start(role: 'worker', revision: 1);
    await scenario.waitState('connected');
    final api = await scenario.start(role: 'api');
    final pending = expectLater(
      scenario.waitState('stopped'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('Stream child ${worker.pid} exited'),
        ),
      ),
    );
    worker.kill();
    await worker.exitCode;
    await pending;
    await scenario.db.execute(
      'UPDATE icinga2_stream_lease SET "expiresAt"=clock_timestamp()',
    );
    final before = await scenario.db.execute(
      'SELECT row_to_json(s)::text FROM icinga2_stream_status s',
    );
    final (status, body) = await _status(api);
    expect(status, 200, reason: body);
    expect((jsonDecode(body) as Map<String, Object?>)['state'], 'stale');
    final docs = File('../docs/ingest-pipeline.md').readAsStringSync();
    final sql = RegExp(
      r'### Read Icinga 2 Event Streams status[\s\S]*?```sql\n([\s\S]*?)```',
    ).firstMatch(docs)!.group(1)!;
    expect(
      (await scenario.db.execute(sql)).single.toColumnMap()['state'],
      'stale',
    );
    expect(
      await scenario.db.execute(
        'SELECT row_to_json(s)::text FROM icinga2_stream_status s',
      ),
      before,
    );
    expect(await scenario.count('icinga2_stream_lease'), 1);
  }, timeout: _timeout);

  for (final removed in [false, true]) {
    test(
      removed
          ? 'source_removed_while_quiet'
          : 'source_disabled_on_a_running_worker',
      () async {
        await scenario.start(role: 'worker', revision: 1);
        await scenario.waitState('connected');
        await scenario.upstream.waitForObjectResponses(1);
        await scenario.start(
          role: 'api',
          revision: 2,
          sources: [
            if (!removed) scenario.source(enabled: false),
          ],
        );
        await scenario.upstream.waitForDisconnects(1);
        await scenario.waitState('stopped');
        final last = (await scenario.db.execute('''
        SELECT "gapCount", l."expiresAt" <= clock_timestamp()
        FROM icinga2_stream_status s JOIN icinga2_stream_lease l USING ("sourceId")
      ''')).single;
        expect(last.toList(), [1, true]);
      },
      timeout: _timeout,
    );
  }

  test('unrelated_revision_reuses_the_connection', () async {
    await scenario.start(role: 'worker', revision: 1);
    await scenario.waitState('connected');
    await scenario.start(
      role: 'api',
      revision: 2,
      sources: [
        scenario.source(),
        streamSource('44444444-4444-4444-8444-444444444444', enabled: false),
      ],
    );
    const host = 'after-unrelated-revision-host';
    await scenario.upstream.send(
      streamDbCheck(DateTime.now().toUtc(), host: host),
    );
    await scenario.expectDelivery(_source, host);
    expect(scenario.upstream.subscriptionsReady, 1);
    expect(
      (await scenario.db.execute('''
      SELECT "connectionSeq", "gapCount" FROM icinga2_stream_status
    ''')).single.toList(),
      [1, 0],
    );
    expect(
      (await scenario.db.execute('''
      SELECT o.admission_snapshot_id = c."snapshotId"
      FROM icinga2_raw_origin o CROSS JOIN ingest_active_config c
      WHERE o.origin='stream'
    ''')).single.single,
      isTrue,
    );
  }, timeout: _timeout);

  test('endpoint_changed', () async {
    await scenario.start(role: 'worker', revision: 1);
    await scenario.waitState('connected');
    final replacement = await IcingaConsumerLoopback.start();
    addTearDown(replacement.close);
    await scenario.ageSync();
    await scenario.start(
      role: 'api',
      revision: 2,
      sources: [scenario.source(url: replacement.url)],
    );
    await scenario.upstream.waitForDisconnects(1);
    await replacement.waitForSubscriptions(1);
    await replacement.waitForObjectResponses(1);
    await scenario.waitState('connected');
    expect(replacement.reads, 1);
    expect(
      (await scenario.db.execute(
        'SELECT "gapCount" FROM icinga2_stream_status',
      )).single.single,
      1,
    );
  }, timeout: _timeout);

  test('rotation_between_batches', () async {
    await scenario.start(role: 'worker', revision: 1);
    await scenario.waitState('connected');
    const replacement = 'rotated-stream-password';
    scenario.upstream.expectedAuthorization =
        'Basic ${base64Encode(utf8.encode('correlia:$replacement'))}';
    await scenario.ageSync();
    final updated = scenario.source();
    (updated['api']! as Map<String, Object?>)['password_ref'] =
        'rotated-password';
    await scenario.start(
      role: 'api',
      revision: 2,
      sources: [updated],
      material: {
        ...streamMaterial(),
        'rotated-password': {
          'bytes': base64UrlEncode(
            utf8.encode(replacement),
          ).replaceAll('=', ''),
        },
      },
    );
    await scenario.upstream.waitForDisconnects(1);
    await scenario.until(() async {
      final current = (await scenario.db.execute('''
        SELECT "connectionSeq", "gapCount", state FROM icinga2_stream_status
      ''')).single;
      return current[0] == 2 && current[1] == 1 && current[2] == 'connected';
    });
    expect(scenario.upstream.subscriptionsReady, 2);
    const host = 'after-password-rotation-host';
    await scenario.upstream.send(
      streamDbCheck(DateTime.now().toUtc(), host: host),
    );
    await scenario.expectDelivery(_source, host);
  }, timeout: _timeout);

  test('buffered_item_behind_cutoff_causes_gap_and_sync', () async {
    await scenario.start(role: 'worker', revision: 1);
    await scenario.waitState('connected');
    await scenario.ageSync();
    await scenario.db.execute(
      "UPDATE raw_admission_cutoff SET cutoff = 'infinity'",
    );
    await scenario.upstream.send(streamDbCheck(DateTime.now().toUtc()));
    await scenario.upstream.waitForDisconnects(1);
    final backoff = await scenario.firstBackoff();
    expect(backoff.toList(), ['receipt_behind_cutoff', 1, 1]);
    expect(await scenario.count('raw_inbox'), 0);
    expect(await scenario.count('icinga2_raw_origin'), 0);
    expect(await scenario.count('icinga2_admitted_batch'), 0);
    await scenario.until(() async {
      final current = (await scenario.db.execute('''
        SELECT "connectionSeq", "gapCount", state FROM icinga2_stream_status
      ''')).single;
      return current[0] == 2 && current[1] == 1 && current[2] == 'connected';
    });
    expect(scenario.upstream.reads, 2);
  }, timeout: _timeout);

  test('two_oversize_lines_on_one_connection', () async {
    await scenario.start(revision: 1);
    await scenario.waitState('connected');
    final oversized = 'x' * (streamLineLimit + 1);
    final inspected = Completer<void>();
    final counted = scenario.until(() async {
      final outcome = await scenario.db.execute('''
        SELECT "oversizeLines", "connectionSeq", "gapCount"
        FROM icinga2_stream_status
      ''');
      final counts = outcome.single.toList();
      if (!inspected.isCompleted) {
        expect(counts, [0, 1, 0]);
        inspected.complete();
      }
      return counts[0] == 2 && counts[1] == 1 && counts[2] == 0;
    });
    counted.ignore();
    await Future.any([inspected.future, counted]);
    await scenario.upstream.sendLine(oversized);
    await scenario.upstream.sendLine(oversized);
    await counted;
    expect(scenario.upstream.subscriptionsReady, 1);
    expect(await scenario.count('raw_inbox'), 0);
  }, timeout: _timeout);

  test(
    'new_source_for_the_stream_runs_beside_webhook_without_webhook_credentials',
    () async {
      const webhookId = '44444444-4444-4444-8444-444444444444';
      const credential = 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE';
      const webhookKey = 'combined-source-webhook';
      const webhookHost = 'combined-webhook-host';
      const streamHost = 'combined-stream-host';
      final webhook = {
        'id': webhookId,
        'kind': 'icinga2',
        'enabled': true,
        'output_ids': <String>[],
        'credentials': [
          {'ref': 'webhook-token', 'type': 'bearer'},
        ],
      };
      final materials = {...streamMaterial(), 'webhook-token': credential};
      final initial = await scenario.start(
        role: 'api',
        revision: 1,
        sources: [webhook],
        material: {'webhook-token': credential},
      );
      expect(await initial.closeStdin(deadline: null), 0);
      final combined = await scenario.start(
        revision: 2,
        sources: [webhook, scenario.source()],
        material: materials,
      );
      await scenario.waitState('connected');
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      Future<int> post(String sourceId) async {
        final request = await client.post(
          '127.0.0.1',
          combined.webPort,
          '/hooks/icinga2/$sourceId',
        );
        request.headers.contentType = ContentType.json;
        request.headers.set('Authorization', 'Bearer $credential');
        request.headers.set('Idempotency-Key', webhookKey);
        final seconds = DateTime.now().microsecondsSinceEpoch / 1000000;
        request.write(
          jsonEncode(
            delivery(
              set: {
                'host': webhookHost,
                'last_state_change': '$seconds',
                'notification_time': '$seconds',
              },
            ),
          ),
        );
        final response = await request.close();
        await response.drain<void>();
        return response.statusCode;
      }

      expect(await post(_source), HttpStatus.unauthorized);
      expect(await post(webhookId), HttpStatus.accepted);
      await scenario.upstream.send(
        streamDbCheck(DateTime.now().toUtc(), host: streamHost),
      );
      await scenario.expectDelivery(webhookId, webhookHost);
      await scenario.expectDelivery(_source, streamHost);
      expect(await scenario.count('events'), 2);
    },
    timeout: _timeout,
  );
}

Future<(int, String)> _status(ChildServer child) async {
  final client = HttpClient();
  try {
    final request = await client.post(
      '127.0.0.1',
      child.apiPort,
      '/icinga2Stream/status',
    );
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({'sourceId': _source}));
    final response = await request.close();
    return (response.statusCode, await response.transform(utf8.decoder).join());
  } finally {
    client.close(force: true);
  }
}
