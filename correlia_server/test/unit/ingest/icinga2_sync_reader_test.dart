import 'dart:async';
import 'dart:convert';

import 'package:correlia_server/src/event/canonical_event.dart';
import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/admission.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/decoder.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/redaction.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/sync_reader.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/sync_result.dart';
import 'package:test/test.dart';

import '../../support/icinga2_stream_decode_fixture.dart';
import '../../support/icinga2_stream_pipeline.dart';
import '../../support/stream_reader_clock.dart';

const _connection = 'a0a0a0a0-1111-4222-8333-444444444444';
const _sync = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _empty = '{"results":[]}';

typedef _Open = Future<SyncResponse> Function(SyncProjection);

Stream<List<int>> _chunks(String text, {int size = 31}) async* {
  final bytes = utf8.encode(text);
  for (var offset = 0; offset < bytes.length; offset += size) {
    final end = offset + size < bytes.length ? offset + size : bytes.length;
    yield bytes.sublist(offset, end);
  }
}

String _response(Iterable<Object?> objects) =>
    '{"results":[${objects.map(jsonEncode).join(',')}]}';

Map<String, Object?> _service(DateTime start, {int state = 0}) =>
    streamDbCheck(start, state: state, sync: true);

Map<String, Object?> _bad(Map<String, Object?> value) => {
  ...value,
  'attrs': {
    ...value['attrs']! as Map<String, Object?>,
    'last_check_result': 42,
  },
};

final class _Harness {
  _Harness(this.open, {this.keepRows = true});

  final _Open open;
  final bool keepRows;
  final clock = StreamReaderClock();
  final batches = <StreamRawBatch>[];
  final logs = <String>[];
  final projections = <SyncProjection>[];
  int items = 0;
  int largestRow = 0;

  SyncReader reader() => SyncReader(
    request: streamDecodeRequest(''),
    policy: StreamStateTypePolicy.softAndHard,
    redactor: PasswordRedactor(utf8.encode('secret-not-in-fixture')),
    connectionId: _connection,
    syncId: _sync,
    open: (projection) {
      projections.add(projection);
      return open(projection);
    },
    admit: (batch) async {
      expect(batch.origin, IcingaStreamOrigin.sync);
      expect(batch.connectionId, _connection);
      expect(batch.syncId, _sync);
      for (final row in batch.rows) {
        items += row.length;
        if (row.length > largestRow) largestRow = row.length;
        expect(row.length, inInclusiveRange(1, 100));
      }
      if (keepRows) batches.add(batch);
      return StreamAdmissionResult.committed;
    },
    log: logs.add,
    receiptClock: () => streamDbNow,
    monotonic: () => clock.elapsed,
    schedule: clock.schedule,
  );

  Iterable<StreamAdmissionItem> get admitted =>
      batches.expand((batch) => batch.rows).expand((row) => row);
}

_Harness _services(String body) => _Harness(
  (projection) async => SyncResponse(
    200,
    _chunks(projection == SyncProjection.hosts ? _empty : body),
  ),
);

// The admission item deliberately exposes its wire length, not its text.
// Match the exact serialized payload length and receipt against the original.
void _expectAdmittedObject(_Harness harness, Map<String, Object?> object) {
  final item = harness.admitted.single;
  final expected = jsonEncode({
    'received': streamDbNow.microsecondsSinceEpoch,
    'line': jsonEncode(object),
  });
  expect(item.received, streamDbNow);
  expect(item.invalidJson, isFalse);
  expect(item.encodedLength, utf8.encode(expected).length);
}

void main() {
  test('recovery_missed_while_disconnected', () async {
    final object = _service(streamDbNow.subtract(const Duration(minutes: 1)));
    final decoded =
        decodeIcingaStreamLine(
              jsonEncode(object),
              request: streamDecodeRequest(''),
              receivedAt: streamDecodeRequest('').observedAt,
              policy: StreamStateTypePolicy.softAndHard,
              origin: IcingaStreamOrigin.sync,
            )
            as IcingaStreamEvent;
    expect(decoded.event.status, EventStatus.resolved);
    final harness = _services(_response([object]));
    final result = await harness.reader().run();
    expect(result.problem, isNull);
    expect(harness.projections, [
      SyncProjection.hosts,
      SyncProjection.services,
    ]);
    _expectAdmittedObject(harness, object);
  });

  test('recovery_missed_nine_days_ago_checked_since', () async {
    final latestCheck = streamDbNow.subtract(const Duration(minutes: 5));
    final object = _service(latestCheck);
    final harness = _services(_response([object]));
    final result = await harness.reader().run();
    expect(result.problem, isNull);
    _expectAdmittedObject(harness, object);
    final event =
        decodeIcingaStreamLine(
              jsonEncode(object),
              request: streamDecodeRequest(''),
              receivedAt: streamDecodeRequest('').observedAt,
              policy: StreamStateTypePolicy.softAndHard,
              origin: IcingaStreamOrigin.sync,
            )
            as IcingaStreamEvent;
    expect(
      event.event.sourceTime!.seconds,
      latestCheck.millisecondsSinceEpoch ~/ 1000,
    );
    expect(event.event.status, EventStatus.resolved);
  });

  test('passive_service_not_reported_for_nine_days', () async {
    final originalStart = streamDbNow.subtract(const Duration(days: 9));
    final object = _service(originalStart);
    final harness = _services(_response([object]));
    final result = await harness.reader().run();
    expect(result.problem, isNull);
    _expectAdmittedObject(harness, object);
    final event =
        decodeIcingaStreamLine(
              jsonEncode(object),
              request: streamDecodeRequest(''),
              receivedAt: streamDecodeRequest('').observedAt,
              policy: StreamStateTypePolicy.softAndHard,
              origin: IcingaStreamOrigin.sync,
            )
            as IcingaStreamEvent;
    expect(
      event.event.sourceTime!.seconds,
      originalStart.millisecondsSinceEpoch ~/ 1000,
    );
  });

  test('sync_on_a_large_installation', () async {
    const count = 2048;
    const frameBytes = 100 * 1024;
    final object = jsonEncode(_service(streamDbNow));
    final frame = utf8.encode('$object${' ' * (frameBytes - object.length)}');
    Stream<List<int>> large() async* {
      yield utf8.encode('{"results":[');
      for (var i = 0; i < count; i++) {
        if (i != 0) yield const [44];
        yield frame;
      }
      yield utf8.encode(']}');
    }

    final harness = _Harness(
      (projection) async => SyncResponse(
        200,
        projection == SyncProjection.hosts ? _chunks(_empty) : large(),
      ),
      keepRows: false,
    );
    final result = await harness.reader().run();
    expect(result.problem, isNull);
    expect(harness.items, count);
    expect(harness.largestRow, lessThanOrEqualTo(100));
  });

  test('object_without_a_check_result', () async {
    final object = _service(streamDbNow);
    final attrs = {...object['attrs']! as Map<String, Object?>};
    attrs['last_check_result'] = null;
    final harness = _services(
      _response([
        {...object, 'attrs': attrs},
      ]),
    );
    final result = await harness.reader().run();
    expect(result.problem, isNull);
    expect(result.counts['no_result'], 1);
    expect(harness.items, 0);
  });

  test('sync_request_fails', () async {
    final harness = _Harness(
      (_) async => SyncResponse(500, _chunks('failure')),
    );
    final result = await harness.reader().run();
    expect(result.problem, SyncReadProblem.httpStatus);
    expect(harness.projections, [SyncProjection.hosts]);
    expect(harness.items, 0);
  });

  test('sync_denial_is_forbidden', () async {
    for (final denied in SyncProjection.values) {
      final harness = _Harness(
        (projection) async => SyncResponse(
          projection == denied ? 403 : 200,
          _chunks(_empty),
        ),
      );
      final result = await harness.reader().run();
      expect(result.problem, SyncReadProblem.forbidden);
      expect(harness.items, 0);
    }
  });

  test('object_query_404_is_not_empty_success', () async {
    for (final missing in SyncProjection.values) {
      final harness = _Harness(
        (projection) async => SyncResponse(
          projection == missing ? 404 : 200,
          _chunks(projection == missing ? 'No objects found.' : _empty),
        ),
      );
      final result = await harness.reader().run();
      expect(result.problem, SyncReadProblem.httpStatus);
      expect(harness.items, 0);
    }
  });

  test('persistent_bad_object_before_a_missed_recovery', () async {
    final valid = _service(streamDbNow.subtract(const Duration(minutes: 1)));
    for (var i = 0; i < 3; i++) {
      final harness = _services(_response([_bad(valid), valid]));
      final result = await harness.reader().run();
      expect(result.problem, SyncReadProblem.invalidObject);
      expect(result.counts['invalid_object'], 1);
      expect(result.samples, hasLength(1));
      expect(result.samples.single.identifier, contains('stream-service'));
      expect(result.samples.single.code, 'invalid_object');
      _expectAdmittedObject(harness, valid);
    }
  });

  test('bad_object_fixed_in_icinga_2', () async {
    final valid = _service(streamDbNow);
    final bad = _services(_response([_bad(valid)]));
    expect((await bad.reader().run()).problem, SyncReadProblem.invalidObject);
    expect(bad.items, 0);
    final fixed = _services(_response([valid]));
    final result = await fixed.reader().run();
    expect(result.problem, isNull);
    _expectAdmittedObject(fixed, valid);
  });

  test('per_object_error_in_a_2_16_response', () async {
    final valid = _service(streamDbNow);
    final harness = _services(
      _response([
        {'code': 500, 'status': 'Object query failed'},
        valid,
      ]),
    );
    final result = await harness.reader().run();
    expect(result.problem, SyncReadProblem.objectError);
    expect(result.counts['object_error'], 1);
    expect(result.samples.single.code, 'object_error');
    _expectAdmittedObject(harness, valid);
  });

  test('truncated_response_after_a_valid_prefix', () async {
    final object = _service(streamDbNow);
    final prefix = List.filled(500, jsonEncode(object)).join(',');
    final harness = _services('{"results":[$prefix,{"value":123');
    final result = await harness.reader().run();
    expect(result.problem, SyncReadProblem.truncated);
    expect(harness.items, 500);
  });

  test('unterminated_string', () async {
    final object = _service(streamDbNow);
    final harness = _services(
      '{"results":[${jsonEncode(object)},{"name":"unfinished',
    );
    final result = await harness.reader().run();
    expect(result.problem, SyncReadProblem.invalidFraming);
    _expectAdmittedObject(harness, object);
  });

  for (final (name, depth, mismatch, problem, oversize) in [
    (
      'structural_nesting_fits_the_framing_ceiling',
      1048576,
      false,
      SyncReadProblem.objectTooLarge,
      1,
    ),
    (
      'structural_nesting_exceeds_the_framing_ceiling',
      1048577,
      false,
      SyncReadProblem.invalidFraming,
      0,
    ),
    (
      'mismatched_bracket_in_an_oversized_object',
      1048576,
      true,
      SyncReadProblem.invalidFraming,
      0,
    ),
  ]) {
    test(name, () async {
      final valid = _service(streamDbNow);
      var reachedSuffix = false;
      Stream<List<int>> body() async* {
        yield utf8.encode('{"results":[${jsonEncode(valid)},');
        final openings = List<int>.filled(4096, 91);
        final closings = List<int>.filled(4096, 93);
        for (var remaining = depth; remaining > 0; remaining -= 4096) {
          yield remaining < 4096 ? openings.sublist(0, remaining) : openings;
        }
        yield [mismatch ? 125 : 48];
        for (var remaining = depth; remaining > 0; remaining -= 4096) {
          yield remaining < 4096 ? closings.sublist(0, remaining) : closings;
        }
        reachedSuffix = true;
        yield utf8.encode(',${jsonEncode(valid)}]}');
      }

      final harness = _Harness(
        (projection) async => SyncResponse(
          200,
          projection == SyncProjection.hosts ? _chunks(_empty) : body(),
        ),
      );
      final report = await harness.reader().run();
      expect(report.problem, problem);
      expect(report.counts['object_too_large'] ?? 0, oversize);
      expect(harness.items, oversize == 1 ? 2 : 1);
      expect(reachedSuffix, oversize == 1);
    });
  }

  test('oversized_object_and_unsafe_names_have_bounded_diagnostics', () async {
    final valid = _service(streamDbNow);
    final attrs = {
      ...valid['attrs']! as Map<String, Object?>,
      'name': 'bad\nname',
    };
    final unsafe = _bad({...valid, 'attrs': attrs});
    final oversized = '{"padding":"${'x' * (1024 * 1024)}"}';
    final body =
        '{"results":[$oversized,${List.filled(25, jsonEncode(unsafe)).join(',')},${jsonEncode(valid)}]}';
    final harness = _services(body);
    final result = await harness.reader().run();
    expect(result.counts['object_too_large'], 1);
    expect(result.counts['invalid_object'], 25);
    expect(result.samples, hasLength(20));
    expect(result.samples.first.identifier, 'results[0]');
    expect(result.samples[1].identifier, 'results[1]');
    expect(
      result.samples.every(
        (sample) => utf8.encode(sample.identifier).length <= 600,
      ),
      isTrue,
    );
    expect(harness.logs, hasLength(21));
    expect(harness.logs.join('\n'), isNot(contains('bad\nname')));
    expect(harness.logs.last, contains('25'));
    _expectAdmittedObject(harness, valid);
  });

  test('syncs_that_never_finish', () async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final object = jsonEncode(_service(streamDbNow));
      late _Harness harness;
      Stream<List<int>> slow() async* {
        yield utf8.encode('{"results":[');
        for (var i = 0; i < 20; i++) {
          yield utf8.encode('${i == 0 ? '' : ','}$object');
          harness.clock.advance(const Duration(seconds: 59));
        }
        yield utf8.encode(']}');
      }

      harness = _Harness(
        (projection) async => SyncResponse(
          200,
          projection == SyncProjection.hosts ? _chunks(_empty) : slow(),
        ),
      );
      final result = await harness.reader().run();
      expect(result.problem, SyncReadProblem.timeout);
      expect(result.lastObject, contains('stream-service'));
    }
  });

  test('read_idle_deadline', () async {
    final body = StreamController<List<int>>();
    var serviceOpened = false;
    final harness = _Harness((projection) async {
      if (projection == SyncProjection.services) serviceOpened = true;
      return SyncResponse(
        200,
        projection == SyncProjection.hosts ? _chunks(_empty) : body.stream,
      );
    });
    final scheduled = Completer<void>();
    harness.clock.onSchedule = (delay) {
      if (serviceOpened &&
          delay == const Duration(seconds: 60) &&
          !scheduled.isCompleted) {
        scheduled.complete();
      }
    };
    final run = harness.reader().run();
    await scheduled.future;
    harness.clock.advance(const Duration(seconds: 60));
    final result = await run;
    expect(result.problem, SyncReadProblem.timeout);
    await body.close();
  });
}
