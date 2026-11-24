import 'dart:async';
import 'dart:convert';

import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/admission.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/read_timing.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/redaction.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/stream_reader.dart';
import 'package:test/test.dart';

import '../../support/icinga2_stream_decode_fixture.dart';
import '../../support/icinga2_stream_pipeline.dart';
import '../../support/stream_reader_clock.dart';

const _connection = 'a0a0a0a0-1111-4222-8333-444444444444';

void main() {
  final fixture = capturedStreamEvents(streamCaptures.last).first;
  String line({String? output}) => jsonEncode({
    ...fixture,
    'timestamp': streamDbNow.microsecondsSinceEpoch / 1000000,
    'check_result': {
      ...fixture['check_result']! as Map<String, Object?>,
      'output': ?output,
    },
  });

  late StreamReaderClock clock;
  late List<StreamRawBatch> accepted;
  late Completer<void> firstAdmitted;
  late int oversize;
  late int receipt;
  setUp(() {
    clock = StreamReaderClock();
    accepted = [];
    firstAdmitted = Completer<void>();
    oversize = 0;
    receipt = 0;
  });

  StreamReader reader({int maxEncodedBytes = 256 * 1024}) => StreamReader(
    request: streamDecodeRequest(''),
    policy: StreamStateTypePolicy.softAndHard,
    redactor: PasswordRedactor(utf8.encode('not-the-payload')),
    connectionId: _connection,
    admit: (batch) async {
      accepted.add(batch);
      if (!firstAdmitted.isCompleted) firstAdmitted.complete();
      return StreamAdmissionResult.committed;
    },
    onOversize: () async {
      oversize++;
    },
    receiptClock: () => streamDbNow.add(Duration(microseconds: receipt++)),
    monotonic: () => clock.elapsed,
    schedule: clock.schedule,
    maxEncodedBytes: maxEncodedBytes,
  );

  Iterable<List<StreamAdmissionItem>> rows() =>
      accepted.expand((batch) => batch.rows);
  List<int> lengths() => [for (final row in rows()) row.length];

  test('burst_of_events', () async {
    final wire = utf8.encode('${line()}\n' * 250);
    expect(await reader().run(Stream.value(wire)), StreamReadEnd.eof);
    expect(lengths(), [100, 100, 50]);
    expect(
      rows()
          .expand((row) => row)
          .map((item) => item.received.microsecondsSinceEpoch),
      List.generate(250, (i) => streamDbNow.microsecondsSinceEpoch + i),
    );
    expect(accepted.map((batch) => batch.id).toSet(), hasLength(3));
  });

  test('large_valid_line', () async {
    final large = line(output: 'x' * (300 * 1024));
    final wire = utf8.encode('${line()}\n$large\n${line()}\n${line()}\n');
    expect(await reader().run(Stream.value(wire)), StreamReadEnd.eof);
    expect(lengths(), [1, 1, 2]);
  });

  test('bad_line_beside_a_valid_recovery', () async {
    final recovery = streamDbCheck(streamDbNow, state: 0);
    final wire = utf8.encode(
      '${line()}\n{"type":"bad","secret_hint":"untrusted"}\n${jsonEncode(recovery)}\n${line()}\n',
    );
    expect(await reader().run(Stream.value(wire)), StreamReadEnd.eof);
    expect(lengths(), [1, 1, 2]);
    expect(rows().expand((row) => row), hasLength(4));
  });

  test('oversize_line', () async {
    final stream = Stream<List<int>>.fromIterable([
      for (var i = 0; i < 32; i++) List<int>.filled(64 * 1024, 97),
      utf8.encode('\n${line()}\n'),
    ]);
    expect(await reader().run(stream), StreamReadEnd.eof);
    expect(oversize, 1);
    expect(lengths(), [1]);
  });

  test('single_slow_event', () async {
    final scheduled = Completer<void>();
    clock.onSchedule = (delay) {
      if (delay == const Duration(seconds: 1) && !scheduled.isCompleted) {
        scheduled.complete();
      }
    };
    final input = StreamController<List<int>>();
    final accepting = reader().run(input.stream);
    input.add(utf8.encode('${line()}\n'));
    await scheduled.future;
    clock.advance(const Duration(milliseconds: 999));
    expect(accepted, isEmpty);
    clock.advance(const Duration(milliseconds: 1));
    // Give the already-completed timer event its microtask; do not close the
    // input until it proves the flush can run without more data or EOF.
    await firstAdmitted.future;
    expect(lengths(), [1]);
    await input.close();
    expect(await accepting, StreamReadEnd.eof);
  });

  test('quiet_reader_can_be_stopped_without_another_byte', () async {
    final listening = Completer<void>();
    final cancelled = Completer<void>();
    final input = StreamController<List<int>>(
      onListen: listening.complete,
      onCancel: cancelled.complete,
    );
    final running = reader();
    final ended = running.run(input.stream);
    try {
      await listening.future;
      clock.advance(const Duration(minutes: 10));
      expect(accepted, isEmpty);
      running.stop();
      expect(await ended, StreamReadEnd.stopped);
      await cancelled.future;
    } finally {
      await input.close();
    }
  }, timeout: const Timeout(Duration(seconds: 5)));

  test('fanout_cut_before_the_encoded_cut', () async {
    // A four-byte scalar maximizes the payload of a 4096-scalar description.
    final large = line(output: '🛰' * 4096);
    expect(utf8.encode(large).length * 100, lessThan(16 * 1024 * 1024));
    final wire = utf8.encode('$large\n' * 100);
    expect(
      await reader(maxEncodedBytes: 16 * 1024 * 1024).run(Stream.value(wire)),
      StreamReadEnd.eof,
    );
    expect(lengths(), hasLength(2));
    expect(lengths().reduce((a, b) => a + b), 100);
    expect(lengths().first, lessThan(100));
  });
}
