import 'dart:async';
import 'dart:isolate';

/// One unavailable regex computation, with a code safe for activity records.
final class MatcherRegexUnavailable implements Exception {
  const MatcherRegexUnavailable(this.code);

  /// A bounded runtime error code.
  final String code;
}

/// Arms a deadline and returns a callback that cancels it.
typedef MatcherDeadline = void Function() Function(Duration, void Function());

void Function() _timer(Duration delay, void Function() fire) =>
    Timer(delay, fire).cancel;

/// A lazy reusable isolate for bounded matching and extraction.
final class MatcherRegexWorker {
  MatcherRegexWorker({
    void Function(SendPort)? entryPoint,
    Duration Function()? elapsed,
    MatcherDeadline? arm,
  }) : _entryPoint = entryPoint ?? _serve,
       _now = elapsed ?? (Stopwatch()..start()).elapsedValue,
       _arm = arm ?? _timer;

  final void Function(SendPort) _entryPoint;
  final Duration Function() _now;
  final MatcherDeadline _arm;
  ReceivePort? _receiver;
  SendPort? _request;
  Isolate? _isolate;
  Completer<SendPort>? _ready;
  Completer<Object?>? _response;
  bool _closed = false;

  /// Creates the shared regex allowance for one raw row.
  MatcherRegexRow newRow(Duration Function() remainingOptional) =>
      MatcherRegexRow._(this, remainingOptional);

  /// Kills the isolate and rejects pending calls.
  void close() {
    _closed = true;
    _reset('regex_worker_closed');
  }

  void _reset(String code) {
    final ready = _ready;
    final response = _response;
    _ready = null;
    _response = null;
    _request = null;
    _receiver?.close();
    _receiver = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(MatcherRegexUnavailable(code));
    }
    if (response != null && !response.isCompleted) {
      response.completeError(MatcherRegexUnavailable(code));
    }
  }

  Future<SendPort> _start(Duration limit) async {
    if (_closed) throw const MatcherRegexUnavailable('regex_worker_closed');
    if (_request case final port?) return port;
    if (_ready != null) throw StateError('Concurrent matcher regex startup');
    if (limit <= Duration.zero) {
      throw const MatcherRegexUnavailable('regex_timeout');
    }
    final receiver = ReceivePort();
    _receiver = receiver;
    final ready = _ready = Completer<SendPort>();
    receiver.listen((Object? event) {
      if (!identical(_receiver, receiver)) return;
      switch (event) {
        case final SendPort port when !ready.isCompleted:
          _request = port;
          ready.complete(port);
        case (value: final Object? value) when _response != null:
          final response = _response!;
          _response = null;
          response.complete(value);
        case null || List<Object?>():
          _reset('regex_worker_exit');
        default:
          _reset('regex_worker_protocol');
      }
    });
    final cancel = _arm(limit, () => _reset('regex_timeout'));
    unawaited(
      Isolate.spawn(
        _entryPoint,
        receiver.sendPort,
        onExit: receiver.sendPort,
        onError: receiver.sendPort,
        errorsAreFatal: true,
        debugName: 'correlia-matcher-regex',
      ).then<void>(
        (isolate) {
          if (identical(_receiver, receiver)) {
            _isolate = isolate;
          } else {
            isolate.kill(priority: Isolate.immediate);
          }
        },
        onError: (Object _) {
          if (identical(_receiver, receiver)) _reset('regex_worker_spawn');
        },
      ),
    );
    try {
      return await ready.future;
    } finally {
      cancel();
    }
  }

  Future<Object?> _run(
    SendPort port,
    String pattern,
    String input,
    int? group,
    Duration limit,
  ) async {
    if (limit <= Duration.zero) {
      throw const MatcherRegexUnavailable('regex_timeout');
    }
    if (_response != null) throw StateError('Concurrent matcher regex request');
    if (!identical(_request, port)) {
      throw const MatcherRegexUnavailable('regex_worker_exit');
    }
    final expiresAt = _now() + limit;
    final response = _response = Completer<Object?>();
    final cancel = _arm(limit, () => _reset('regex_timeout'));
    port.send((pattern, input, group));
    try {
      final value = await response.future;
      if (_now() >= expiresAt) {
        _reset('regex_timeout');
        throw const MatcherRegexUnavailable('regex_timeout');
      }
      return value;
    } finally {
      cancel();
    }
  }
}

extension on Stopwatch {
  Duration elapsedValue() => elapsed;
}

/// The total allowance shared by all optional regex calls in one raw row.
final class MatcherRegexRow {
  MatcherRegexRow._(this._worker, this._optional);
  final MatcherRegexWorker _worker;
  final Duration Function() _optional;
  bool _unavailable = false;
  Duration _spent = Duration.zero;

  /// Tests an expression in the isolate.
  Future<bool> matches(String pattern, String input) async =>
      (await _call(pattern, input, null))! as bool;

  /// Extracts a numbered capture in the isolate.
  Future<String?> capture(String pattern, String input, int group) async =>
      (await _call(pattern, input, group)) as String?;

  Future<Object?> _call(String pattern, String input, int? group) async {
    if (_unavailable) throw const MatcherRegexUnavailable('regex_budget');
    final startedAt = _worker._now();
    Duration remaining() => _min(
      const Duration(milliseconds: 100) - _spent - (_worker._now() - startedAt),
      _optional(),
    );
    try {
      final available = remaining();
      if (available <= Duration.zero) {
        throw const MatcherRegexUnavailable('regex_budget');
      }
      final port = await _worker._start(available);
      return await _worker._run(
        port,
        pattern,
        input,
        group,
        _min(remaining(), const Duration(milliseconds: 20)),
      );
    } on MatcherRegexUnavailable {
      _unavailable = true;
      rethrow;
    } finally {
      _spent += _worker._now() - startedAt;
    }
  }
}

Duration _min(Duration a, Duration b) => a <= b ? a : b;

void _serve(SendPort owner) {
  final port = ReceivePort();
  owner.send(port.sendPort);
  port.listen((Object? raw) {
    final (pattern, input, group) = raw! as (String, String, int?);
    final expression = RegExp(pattern, unicode: true, dotAll: true);
    final value = group == null
        ? expression.hasMatch(input)
        : expression.firstMatch(input)?.group(group);
    owner.send((value: value));
  });
}
