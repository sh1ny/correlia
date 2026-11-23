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
import 'guarded_json.dart';
import 'redaction.dart';
import 'stream_reader.dart' show ReaderScheduler;
import 'sync_result.dart';

/// The whole-sync reading deadline, across both object queries.
const streamSyncReadDeadline = Duration(minutes: 15);

/// A separately projected Icinga object collection.
enum SyncProjection {
  hosts,
  services;

  /// The object-query path for this projection.
  String get path => switch (this) {
    hosts => '/v1/objects/hosts',
    services => '/v1/objects/services',
  };

  /// The attributes requested from Icinga for this projection.
  List<String> get attrs => switch (this) {
    hosts => const ['name', 'last_check_result'],
    services => const ['name', 'host_name', 'last_check_result'],
  };
}

/// The status and streaming body of one object query.
final class SyncResponse {
  const SyncResponse(this.statusCode, this.body);
  final int statusCode;
  final Stream<List<int>> body;
}

void Function() _timer(Duration delay, void Function() action) =>
    Timer(delay, action).cancel;

/// Reads a bounded sync without treating upstream absence as a recovery.
///
/// Only a reported check result can produce a reconcile observation; an object
/// missing from the upstream response never resolves an existing alert.
final class SyncReader {
  SyncReader({
    required this._request,
    required this._policy,
    required this._redactor,
    required String connectionId,
    required String syncId,
    required this._open,
    required this._admit,
    this._log,
    DateTime Function()? receiptClock,
    Duration Function()? monotonic,
    ReaderScheduler? schedule,
  }) : _connectionId = connectionId,
       _syncId = syncId,
       _receiptClock = receiptClock ?? DateTime.now,
       _monotonic = monotonic ?? (Stopwatch()..start()).elapsedNow,
       _schedule = schedule ?? _timer,
       _rows = StreamRowBatcher(
         streamEnvelopeBytes(
           IcingaStreamOrigin.sync,
           connectionId,
           syncId: syncId,
         ),
       );

  final DecodeRequest _request;
  final StreamStateTypePolicy _policy;
  final PasswordRedactor _redactor;
  final String _connectionId;
  final String _syncId;
  final Future<SyncResponse> Function(SyncProjection) _open;
  final Future<StreamAdmissionResult> Function(StreamRawBatch) _admit;
  final void Function(String)? _log;
  final DateTime Function() _receiptClock;
  final Duration Function() _monotonic;
  final ReaderScheduler _schedule;
  final StreamRowBatcher _rows;
  final _counts = <String, int>{};
  final _samples = <SyncBadObject>[];
  SyncReadProblem? _ending;
  SyncReadProblem? _badProblem;
  String? _lastObject;
  bool _started = false;
  Completer<void>? _wake;
  void Function()? _interrupt;
  void Function()? _cancelFlush;
  bool _flushDue = false;
  late Duration _deadline;

  /// Interrupts an open query, read, retry or admission wait.
  void stop() => _end(SyncReadProblem.interrupted);

  void _end(SyncReadProblem problem) {
    _ending ??= problem;
    _interrupt?.call();
    _notify();
  }

  void _notify() {
    final wake = _wake;
    _wake = null;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  /// Reads both projections and returns the reading outcome and diagnostics.
  Future<SyncReadReport> run() async {
    if (_started) throw StateError('A sync reader runs only once');
    _started = true;
    _deadline = _monotonic() + streamSyncReadDeadline;
    final cancelDeadline = _schedule(streamSyncReadDeadline, () {
      _end(SyncReadProblem.timeout);
    });
    try {
      for (final projection in SyncProjection.values) {
        if (_ending != null) break;
        SyncResponse? response;
        try {
          response = await _whileOpen(_open(projection));
        } on TimeoutException {
          _end(SyncReadProblem.timeout);
          break;
        } on Object {
          _end(SyncReadProblem.httpStatus);
          break;
        }
        if (response == null) break;
        if (response.statusCode != 200) {
          _end(
            response.statusCode == 403
                ? SyncReadProblem.forbidden
                : SyncReadProblem.httpStatus,
          );
          break;
        }
        await _read(response.body, projection);
      }
      if (_ending == null) await _submit(_rows.take());
    } finally {
      cancelDeadline();
      _cancelFlush?.call();
    }
    if (_samples.isNotEmpty) {
      _log?.call('sync bad objects: ${jsonEncode(_counts)}');
    }
    return SyncReadReport(
      problem: _ending ?? _badProblem,
      counts: Map.unmodifiable(_counts),
      samples: List.unmodifiable(_samples),
      lastObject: _lastObject,
    );
  }

  Future<void> _read(Stream<List<int>> body, SyncProjection projection) async {
    final input = StreamIterator<List<int>>(body);
    final scanner = _SyncFramer();
    List<int>? chunk;
    var reading = false;
    var eof = false;
    Object? failure;
    void Function()? cancelIdle;
    try {
      while (_ending == null) {
        if (_monotonic() >= _deadline) {
          _end(SyncReadProblem.timeout);
          break;
        }
        if (_flushDue) {
          _resetFlush();
          cancelIdle?.call();
          cancelIdle = null;
          await _submit(_rows.take());
          if (reading && _ending == null) {
            cancelIdle = _schedule(const Duration(seconds: 60), () {
              _end(SyncReadProblem.timeout);
            });
          }
          continue;
        }
        if (failure != null) {
          await _submit(_rows.take());
          if (_ending == null) _end(SyncReadProblem.httpStatus);
          break;
        }
        if (chunk case final bytes?) {
          chunk = null;
          for (final byte in bytes) {
            final frame = scanner.add(byte);
            if (scanner.problem case final problem?) {
              await _submit(_rows.take());
              _end(problem);
              break;
            }
            if (frame != null) {
              final receipt = _receiptClock().toUtc();
              await _consume(frame, projection, receipt);
              if (_ending != null) break;
            }
          }
          continue;
        }
        if (eof) {
          await _submit(_rows.take());
          if (_ending == null && !scanner.complete) {
            _end(scanner.eofProblem);
          }
          break;
        }
        if (!reading) {
          reading = true;
          cancelIdle = _schedule(const Duration(seconds: 60), () {
            _end(SyncReadProblem.timeout);
          });
          unawaited(
            input.moveNext().then<void>(
              (available) {
                cancelIdle?.call();
                cancelIdle = null;
                reading = false;
                if (available) {
                  chunk = input.current;
                } else {
                  eof = true;
                }
                _notify();
              },
              onError: (Object error, StackTrace trace) {
                cancelIdle?.call();
                cancelIdle = null;
                reading = false;
                failure = error;
                _notify();
              },
            ),
          );
        }
        await (_wake ??= Completer<void>()).future;
      }
    } finally {
      cancelIdle?.call();
      await input.cancel();
    }
  }

  Future<void> _consume(
    _Frame frame,
    SyncProjection projection,
    DateTime receipt,
  ) async {
    final fallback = 'results[${frame.index}]';
    if (frame.bytes == null) {
      _bad(SyncReadProblem.objectTooLarge, fallback);
      return;
    }
    final safe = _redactor.sanitize(frame.bytes!);
    String? identifier;
    try {
      final text = utf8.decode(safe.bytes);
      if (safe.invalidJson) throw const FormatException();
      final document = readStreamJson(text);
      identifier = _identifier(document, projection);
      if (document.containsKey('code')) {
        _bad(SyncReadProblem.objectError, identifier ?? fallback);
        return;
      }
      final attrs = document['attrs'];
      if (attrs is Map<String, Object?> &&
          attrs.containsKey('last_check_result') &&
          attrs['last_check_result'] == null) {
        guardStreamMembers(text, const {
          '': {'attrs', 'joins', 'meta', 'name', 'type'},
          'attrs': {'host_name', 'last_check_result', 'name'},
        });
        if (identifier == null ||
            document['type'] !=
                (projection == SyncProjection.hosts ? 'Host' : 'Service')) {
          throw const FormatException();
        }
        _counts['no_result'] = (_counts['no_result'] ?? 0) + 1;
        _lastObject = identifier;
        return;
      }
      final micros = receipt.microsecondsSinceEpoch;
      final decoded = decodeIcingaStreamLine(
        text,
        request: _request,
        receivedAt: EventTimestamp.fromParts(
          micros ~/ 1000000,
          micros % 1000000 * 1000,
        ),
        policy: _policy,
        origin: IcingaStreamOrigin.sync,
      );
      if (document['type'] !=
          (projection == SyncProjection.hosts ? 'Host' : 'Service')) {
        throw const FormatException();
      }
      _lastObject = identifier ?? fallback;
      final size = switch (decoded) {
        IcingaStreamEvent(:final event) => CloudEvent(
          event: event,
        ).toJsonBytes().length,
        IcingaStreamSoftInfo() => 0,
      };
      final item = StreamAdmissionItem.text(
        receipt,
        text,
        redacted: safe.redacted,
      );
      final wasEmpty = !_rows.hasPending;
      final ready = _rows.add(item, size);
      if (ready.preceding != null || ready.ready != null) _resetFlush();
      if (ready.preceding case final row?) await _submit(row);
      if (ready.ready case final row?) await _submit(row);
      if (_ending == null &&
          _rows.hasPending &&
          (wasEmpty || ready.preceding != null)) {
        _cancelFlush = _schedule(streamFlushInterval, () {
          _flushDue = true;
          _cancelFlush = null;
          _notify();
        });
      }
    } on EventValidationError {
      _bad(SyncReadProblem.invalidObject, identifier ?? fallback);
    } on FormatException {
      _bad(SyncReadProblem.invalidObject, identifier ?? fallback);
    }
  }

  void _bad(SyncReadProblem problem, String identifier) {
    _badProblem ??= problem;
    final code = problem.wire;
    _counts[code] = (_counts[code] ?? 0) + 1;
    if (_samples.length < 20) {
      _samples.add(SyncBadObject(identifier, code));
      _log?.call('sync bad object $identifier: $code');
    }
  }

  String? _identifier(Map<String, Object?> object, SyncProjection projection) {
    final attrs = object['attrs'];
    if (attrs is! Map<String, Object?>) return null;
    final name = attrs['name'];
    if (!_safeName(name)) return null;
    if (projection == SyncProjection.hosts) return name as String;
    final host = attrs['host_name'];
    if (!_safeName(host)) return null;
    return '${host as String}!${name as String}';
  }

  bool _safeName(Object? value) {
    if (value is! String || value.isEmpty || utf8.encode(value).length > 255) {
      return false;
    }
    try {
      validateText(value, 'name', min: 1, max: 255);
    } on EventValidationError {
      return false;
    }
    for (final rune in value.runes) {
      if (rune < 32 ||
          (rune >= 127 && rune <= 159) ||
          (rune >= 0xd800 && rune <= 0xdfff)) {
        return false;
      }
    }
    return true;
  }

  void _resetFlush() {
    _cancelFlush?.call();
    _cancelFlush = null;
    _flushDue = false;
  }

  Future<void> _submit(List<StreamAdmissionItem>? row) async {
    if (row == null || _ending != null) return;
    _resetFlush();
    final batch = StreamRawBatch(
      id: const Uuid().v4(),
      connectionId: _connectionId,
      origin: IcingaStreamOrigin.sync,
      syncId: _syncId,
      rows: [row],
    );
    while (_ending == null) {
      try {
        final result = await _whileOpen(_admit(batch));
        switch (result) {
          case null || StreamAdmissionResult.committed:
            return;
          case StreamAdmissionResult.atCapacity:
            break;
          case StreamAdmissionResult.configChanged:
            _end(SyncReadProblem.configChanged);
            return;
          case StreamAdmissionResult.leaseLost:
            _end(SyncReadProblem.holderLost);
            return;
          case StreamAdmissionResult.receiptBehindCutoff:
            _end(SyncReadProblem.receiptBehindCutoff);
            return;
        }
      } on pg.ServerException catch (error) {
        if (!const {'55P03', '57014', '40001', '40P01'}.contains(error.code) &&
            !(error.code?.startsWith('08') ?? false)) {
          _end(SyncReadProblem.interrupted);
          return;
        }
      } on SocketException {
        // The same batch ID makes an unknown acknowledgement safe to retry.
      } on TimeoutException {
        // The database client's timeout is also an unknown acknowledgement.
      } on Object {
        _end(SyncReadProblem.interrupted);
        return;
      }
      if (_ending != null) return;
      final wait = Completer<void>();
      final cancel = _schedule(
        const Duration(seconds: 1),
        () => wait.complete(),
      );
      try {
        await _whileOpen(wait.future);
      } finally {
        cancel();
      }
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

final class _Frame {
  const _Frame(this.index, this.bytes);
  final int index;
  final Uint8List? bytes;
}

// Tracks structural framing independently from semantic JSON validation. Once
// the byte limit is crossed it scans the rest without retaining the element.
final class _SyncFramer {
  int _state = 0; // object, key, colon, array, element, separator, end, done
  final _key = StringBuffer();
  static const _maxDepth = 1 << 20;
  static const _stackPageBits = 10;
  static const _stackPageSize = 1 << _stackPageBits;
  static const _stackPageMask = _stackPageSize - 1;
  final _stack = <Uint8List>[];
  int _depth = 0;
  BytesBuilder? _bytes;
  int _length = 0;
  int _index = 0;
  bool _string = false;
  bool _escape = false;
  bool _primitive = false;
  bool _keyEscape = false;
  bool _afterComma = false;
  SyncReadProblem? problem;

  bool get complete => _state == 7 && problem == null;
  SyncReadProblem get eofProblem =>
      _string || _keyEscape || (_state == 1 && _key.isNotEmpty)
      ? SyncReadProblem.invalidFraming
      : SyncReadProblem.truncated;

  bool _space(int c) => c == 32 || c == 9 || c == 10 || c == 13;

  _Frame? add(int c) {
    if (problem != null) return null;
    switch (_state) {
      case 0:
        if (_space(c)) return null;
        if (c != 123) return _invalid();
        _state = 1;
      case 1:
        if (_key.isEmpty && _space(c)) return null;
        if (_key.isEmpty) {
          if (c != 34) return _invalid();
          _key.write('"');
        } else if (c == 34 && !_keyEscape) {
          if (_key.toString() != '"results') return _invalid();
          _state = 2;
        } else {
          if (_key.length > 32) return _invalid();
          _key.writeCharCode(c);
          _keyEscape = c == 92 && !_keyEscape;
        }
      case 2:
        if (_space(c)) return null;
        if (c != 58) return _invalid();
        _state = 3;
      case 3:
        if (_space(c)) return null;
        if (c != 91) return _invalid();
        _state = 4;
      case 4:
        if (_space(c)) return null;
        if (c == 93) {
          if (_afterComma) return _invalid();
          _state = 6;
          return null;
        }
        _afterComma = false;
        _bytes = BytesBuilder(copy: false);
        _length = 0;
        _depth = 0;
        _string = false;
        _escape = false;
        _primitive = c != 123 && c != 91 && c != 34;
        _state = 5;
        return _element(c);
      case 5:
        return _element(c);
      case 6:
        if (_space(c)) return null;
        if (c != 125) return _invalid();
        _state = 7;
      case 8:
        return _separator(c);
      case 7:
        if (!_space(c)) return _invalid();
    }
    return null;
  }

  _Frame? _element(int c) {
    if (_primitive &&
        _depth == 0 &&
        !_string &&
        (c == 44 || c == 93 || _space(c))) {
      final frame = _finish();
      if (c == 44) {
        _afterComma = true;
        _state = 4;
      } else if (c == 93) {
        _state = 6;
      } else {
        _state = 8;
      }
      return frame;
    }
    _length++;
    if (_length > streamLineLimit) {
      _bytes = null;
    } else {
      _bytes?.addByte(c);
    }
    if (_string) {
      if (_escape) {
        _escape = false;
      } else if (c == 92) {
        _escape = true;
      } else if (c == 34) {
        _string = false;
        if (_depth == 0 && !_primitive) {
          final frame = _finish();
          _state = 8;
          return frame;
        }
      }
      return null;
    }
    if (c == 34) {
      _string = true;
    } else if (c == 123 || c == 91) {
      if (_depth == _maxDepth) return _invalid();
      final page = _depth >> _stackPageBits;
      if (page == _stack.length) _stack.add(Uint8List(_stackPageSize));
      _stack[page][_depth++ & _stackPageMask] = c;
    } else if (c == 125 || c == 93) {
      if (_depth == 0) return _invalid();
      _depth--;
      if (_stack[_depth >> _stackPageBits][_depth & _stackPageMask] !=
          (c == 125 ? 123 : 91)) {
        return _invalid();
      }
      if (_depth == 0) {
        final frame = _finish();
        _state = 8;
        return frame;
      }
    }
    return null;
  }

  _Frame? _separator(int c) {
    if (_space(c)) return null;
    if (c == 44) {
      _afterComma = true;
      _state = 4;
      return null;
    }
    if (c == 93) {
      _state = 6;
      return null;
    }
    return _invalid();
  }

  _Frame _finish() => _Frame(_index++, _bytes?.takeBytes());
  _Frame? _invalid() {
    problem = SyncReadProblem.invalidFraming;
    return null;
  }
}
