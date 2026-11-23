import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:postgres/postgres.dart' as pg;
import 'package:uuid/uuid.dart';

import '../../../event/cloud_event.dart';
import '../../../event/event_timestamp.dart';
import '../../../event/validation.dart';
import '../../bootstrap.dart';
import '../../source_decoder.dart';
import 'admission.dart';
import 'batcher.dart';
import 'decoder.dart';
import 'read_timing.dart';
import 'redaction.dart';

/// A cancellable monotonic timer, injectable independently of wall-clock receipts.
typedef ReaderScheduler = void Function() Function(Duration, void Function());

void Function() _scheduleTimer(Duration delay, void Function() action) =>
    Timer(delay, action).cancel;

/// A quiet subscription is healthy: no read-idle timeout closes it.
///
/// Liveness comes from the holder's lease, sustained lag, and periodic sync.
/// Only time spent unable to read (waiting to commit, at the retained-work cap,
/// or waiting for an in-flight slot) counts toward the reader stall limit.
final class StreamReader {
  StreamReader({
    required DecodeRequest request,
    required this._policy,
    required this._redactor,
    required this._connectionId,
    required this._admit,
    required this._onOversize,
    this._onObservation,
    DateTime Function()? receiptClock,
    Duration Function()? monotonic,
    ReaderScheduler? schedule,
    int maxEncodedBytes = streamEncodedRowBudget,
  }) : _request = DecodeRequest(
         bytes: request.bytes,
         sourceInstance: request.sourceInstance,
         namespace: request.namespace,
         excludedLabels: request.excludedLabels,
         // Generated raw references and processing receipts can have more
         // fractional digits than this item's wall clock at validation.
         rawRef:
             'raw:2000-01-01T00:00:00.999999Z/00000000-0000-4000-8000-000000000000',
         rawSha256: request.rawSha256,
         observedAt: request.observedAt,
         processedAt: EventTimestamp.fromParts(
           request.processedAt.seconds,
           999999999,
         ),
         configVersion: request.configVersion,
       ),
       _receiptClock = receiptClock ?? DateTime.now,
       _monotonic = monotonic ?? (Stopwatch()..start()).elapsedNow,
       _schedule = schedule ?? _scheduleTimer,
       _rows = StreamRowBatcher(
         streamEnvelopeBytes(IcingaStreamOrigin.stream, _connectionId),
         maxEncodedBytes: maxEncodedBytes,
       );

  final DecodeRequest _request;
  final StreamStateTypePolicy _policy;
  final PasswordRedactor _redactor;
  final String _connectionId;
  final Future<StreamAdmissionResult> Function(StreamRawBatch) _admit;
  final Future<void> Function() _onOversize;
  final void Function(DateTime, Duration?)? _onObservation;
  final DateTime Function() _receiptClock;
  final Duration Function() _monotonic;
  final ReaderScheduler _schedule;
  final StreamRowBatcher _rows;
  late final ReaderHealth _health = ReaderHealth(
    now: _monotonic,
    schedule: _schedule,
    onClose: _end,
  );
  bool _started = false;
  bool _flushDue = false;
  StreamReadEnd? _ending;
  Completer<void>? _wake;
  void Function()? _interrupt;
  void Function()? _cancelFlush;

  Duration? _flushAt;

  /// Cancels a read, timer or pending wait without submitting another batch.
  void stop() => _end(StreamReadEnd.stopped);

  /// Runs one subscription, with no more than one admitted batch in flight.
  Future<StreamReadEnd> run(Stream<List<int>> input) async {
    if (_started) throw StateError('A stream reader runs only once');
    _started = true;
    final lines = _LineFramer(input);
    var reading = false;
    bool? available;
    ({DateTime wall, Duration monotonic})? seenAt;
    (Object, StackTrace)? failed;
    try {
      while (_ending == null) {
        if (failed case final error?) {
          Error.throwWithStackTrace(error.$1, error.$2);
        }
        if (_flushDue) {
          _resetFlush();
          await _submit(_rows.take());
          continue;
        }
        if (available == false) {
          await _submit(_rows.take());
          return _ending ?? StreamReadEnd.eof;
        }
        if (available == true) {
          available = null;
          final arrived = seenAt!;
          if (lines.current case final bytes?) {
            await _consume(bytes, arrived.wall, arrived.monotonic);
          } else {
            await _oversize();
          }
          continue;
        }
        if (!reading) {
          reading = true;
          unawaited(
            lines.moveNext().then<void>(
              (hasLine) {
                reading = false;
                available = hasLine;
                if (hasLine) {
                  seenAt = (
                    wall: _receiptClock().toUtc(),
                    monotonic: _monotonic(),
                  );
                }
                _notify();
              },
              onError: (Object error, StackTrace trace) {
                failed = (error, trace);
                _notify();
              },
            ),
          );
        }
        await (_wake ??= Completer<void>()).future;
      }
      return _ending!;
    } finally {
      _resetFlush();
      _health.close();
      await lines.cancel();
    }
  }

  void _end(StreamReadEnd reason) {
    if (_ending != null) return;
    _ending = reason;
    _interrupt?.call();
    _notify();
  }

  void _notify() {
    final waiter = _wake;
    _wake = null;
    waiter?.complete();
  }

  Future<void> _consume(
    Uint8List data,
    DateTime receipt,
    Duration readAt,
  ) async {
    final safe = _redactor.sanitize(data);
    if (safe.bytes.length > streamLineLimit) {
      await _oversize();
      return;
    }
    final StreamAdmissionItem item;
    int? canonicalBytes;
    final String? text;
    try {
      text = utf8.decode(safe.bytes);
    } on FormatException {
      final item = StreamAdmissionItem.binary(
        receipt,
        safe.bytes,
        redacted: safe.redacted,
      );
      await _queue(item, null, readAt);
      return;
    }
    item = StreamAdmissionItem.text(
      receipt,
      text,
      invalidJson: safe.invalidJson,
      redacted: safe.redacted,
    );
    if (!safe.invalidJson) {
      final micros = receipt.microsecondsSinceEpoch;
      try {
        final result = decodeIcingaStreamLine(
          text,
          request: _request,
          receivedAt: EventTimestamp.fromParts(
            micros ~/ 1000000,
            micros % 1000000 * 1000,
          ),
          policy: _policy,
          onUpstreamTime: (upstream) => _health.observeLag(
            Duration(
              microseconds:
                  micros - upstream.seconds * 1000000 - upstream.nanos ~/ 1000,
            ),
          ),
        );
        _onObservation?.call(receipt, _health.lag);
        canonicalBytes = switch (result) {
          IcingaStreamEvent(:final event) => CloudEvent(
            event: event,
          ).toJsonBytes().length,
          IcingaStreamSoftInfo() => 0,
        };
      } on EventValidationError {
        // Isolate the sanitized line so its exact parser failure is durable.
      }
    }
    if (_ending == null) await _queue(item, canonicalBytes, readAt);
  }

  Future<void> _queue(
    StreamAdmissionItem item,
    int? canonicalBytes,
    Duration readAt,
  ) async {
    if (_flushAt case final deadline? when readAt >= deadline) {
      _resetFlush();
      await _submit(_rows.take());
      if (_ending != null) return;
    }
    final wasEmpty = !_rows.hasPending;
    final batch = _rows.add(item, canonicalBytes);
    if (batch.preceding != null || batch.ready != null) _resetFlush();
    if (batch.preceding case final row?) await _submit(row);
    if (batch.ready case final row?) await _submit(row);
    if (_ending == null &&
        _rows.hasPending &&
        (wasEmpty || batch.preceding != null)) {
      final deadline = readAt + streamFlushInterval;
      _flushAt = deadline;
      final delay = deadline - _monotonic();
      if (delay <= Duration.zero) {
        _flushDue = true;
      } else {
        _cancelFlush = _schedule(delay, () {
          _flushDue = true;
          _cancelFlush = null;
          _notify();
        });
      }
    }
  }

  void _resetFlush() {
    _cancelFlush?.call();
    _flushAt = null;
    _cancelFlush = null;
    _flushDue = false;
  }

  Future<void> _oversize() async {
    _health.setBlocked(true);
    try {
      await _whileOpen(_onOversize().then((_) => true));
    } finally {
      _health.setBlocked(false);
    }
  }

  Future<void> _submit(List<StreamAdmissionItem>? row) async {
    if (row == null || _ending != null) return;
    final batch = StreamRawBatch(
      id: const Uuid().v4(),
      connectionId: _connectionId,
      origin: IcingaStreamOrigin.stream,
      rows: [row],
    );
    _health.setBlocked(true);
    try {
      while (_ending == null) {
        StreamAdmissionResult? result;
        try {
          result = await _whileOpen(_admit(batch));
          switch (result) {
            case null || StreamAdmissionResult.committed:
              return;
            case StreamAdmissionResult.atCapacity:
              break;
            case StreamAdmissionResult.leaseLost:
              _end(StreamReadEnd.leaseLost);
              return;
            case StreamAdmissionResult.configChanged:
              _end(StreamReadEnd.configChanged);
              return;
            case StreamAdmissionResult.receiptBehindCutoff:
              _end(StreamReadEnd.receiptBehindCutoff);
              return;
          }
        } on pg.ServerException catch (error) {
          if (!const {
                '55P03',
                '57014',
                '40001',
                '40P01',
              }.contains(error.code) &&
              !(error.code?.startsWith('08') ?? false)) {
            rethrow;
          }
        } on SocketException {
          // Unknown acknowledgement: retry this same ID within the stall budget.
        } on TimeoutException {
          // The PostgreSQL client's timer can win over statement_timeout.
        }
        if (_ending != null) return;
        final wait = Completer<bool>();
        final cancel = _schedule(
          const Duration(seconds: 1),
          () => wait.complete(true),
        );
        try {
          await _whileOpen(wait.future);
        } finally {
          cancel();
        }
      }
    } finally {
      _health.setBlocked(false);
    }
  }

  Future<T?> _whileOpen<T>(Future<T> action) async {
    final step = Completer<T?>();
    void interrupt() {
      if (!step.isCompleted) step.complete(null);
    }

    _interrupt = interrupt;
    unawaited(
      action.then<void>(
        (value) {
          if (!step.isCompleted) step.complete(value);
        },
        onError: (Object error, StackTrace trace) {
          if (!step.isCompleted) step.completeError(error, trace);
        },
      ),
    );
    if (_ending != null) interrupt();
    try {
      return await step.future;
    } finally {
      _interrupt = null;
    }
  }
}

extension on Stopwatch {
  Duration elapsedNow() => elapsed;
}

/// Pulls a line at a time; null denotes one oversize line, not each fragment.
///
/// Unlike an async generator waiting on input, cancelling the underlying
/// iterator interrupts a quiet socket without waiting for another chunk.
final class _LineFramer {
  _LineFramer(Stream<List<int>> input) : _input = StreamIterator(input);

  final StreamIterator<List<int>> _input;
  final _pending = BytesBuilder(copy: false);
  List<int> _chunk = const [];
  int _position = 0;
  bool _oversize = false;
  bool _closed = false;
  Uint8List? current;

  Future<bool> moveNext() async {
    while (!_closed) {
      if (_position == _chunk.length) {
        if (!await _input.moveNext()) {
          if (_closed) return false;
          _closed = true;
          if (_oversize) {
            current = null;
            return true;
          }
          if (_pending.isEmpty) return false;
          current = _pending.takeBytes();
          return true;
        }
        _chunk = _input.current;
        _position = 0;
      }
      if (_chunk.isEmpty) continue;
      final newline = _chunk.indexOf(10, _position);
      final end = newline == -1 ? _chunk.length : newline;
      if (!_oversize && _pending.length + end - _position > streamLineLimit) {
        _pending.clear();
        _oversize = true;
      }
      if (!_oversize && end > _position) {
        _pending.add(
          _chunk is Uint8List
              ? Uint8List.sublistView(_chunk as Uint8List, _position, end)
              : _chunk.sublist(_position, end),
        );
      }
      _position = newline < 0 ? end : newline + 1;
      if (newline < 0) continue;
      current = _oversize ? null : _pending.takeBytes();
      _oversize = false;
      return true;
    }
    return false;
  }

  Future<void> cancel() {
    _closed = true;
    return _input.cancel();
  }
}
