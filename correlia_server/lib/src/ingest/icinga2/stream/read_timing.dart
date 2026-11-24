import 'dart:math' as math;

/// The maximum continuous period for which a reader may be blocked.
const readerBlockedLimit = Duration(seconds: 30);

/// The excess over the smallest observed lag that starts the lag window.
const readerLagExcess = Duration(seconds: 60);

/// The continuous excess-lag period after which the connection is closed.
const readerLagWindow = Duration(seconds: 120);

/// The reason a stream reader ended.
enum StreamReadEnd {
  eof,
  backpressure,
  lag,
  stopped,
  leaseLost,
  configChanged,
  receiptBehindCutoff,
}

/// Computes jittered reconnect delays for consecutive connection failures.
final class StreamBackoff {
  /// Creates a backoff with an optional random sample source in [0, 1].
  StreamBackoff({double Function()? random})
    : _random = random ?? math.Random().nextDouble;

  final double Function() _random;
  int _baseSeconds = 1;

  /// Returns the next delay, resetting after five minutes connected.
  Duration nextDelay({Duration connectedFor = Duration.zero}) {
    if (connectedFor >= const Duration(minutes: 5)) _baseSeconds = 1;
    final base = _baseSeconds;
    _baseSeconds = math.min(base * 2, 60);
    final microseconds =
        (base * Duration.microsecondsPerSecond * (0.8 + 0.4 * _random()))
            .round();
    return Duration(microseconds: microseconds);
  }
}

/// Tracks reader stalls and event lag for one stream connection.
final class ReaderHealth {
  /// Creates a tracker using a monotonic clock and cancellable scheduler.
  ReaderHealth({
    required this._now,
    required this._schedule,
    required this._onClose,
  });

  final Duration Function() _now;
  final void Function() Function(Duration, void Function()) _schedule;
  final void Function(StreamReadEnd) _onClose;
  Duration? _blockedSince;
  Duration? _minimumLag;
  Duration? _excessSince;
  Duration? _lag;
  void Function()? _cancelBlocked;
  bool _closed = false;

  /// The most recently observed event lag, or null before the first event.
  Duration? get lag => _lag;

  /// Marks whether reading is prevented by admission or retained work.
  void setBlocked(bool blocked) {
    if (_closed || blocked == (_blockedSince != null)) return;
    if (!blocked) {
      _blockedSince = null;
      _cancelBlocked?.call();
      _cancelBlocked = null;
      return;
    }
    _blockedSince = _now();
    _armBlocked(readerBlockedLimit);
  }

  void _armBlocked(Duration delay) {
    _cancelBlocked = _schedule(delay, () {
      if (_closed || _blockedSince == null) return;
      final elapsed = _now() - _blockedSince!;
      if (elapsed < readerBlockedLimit) {
        _armBlocked(readerBlockedLimit - elapsed);
      } else {
        _end(StreamReadEnd.backpressure);
      }
    });
  }

  /// Records an event's receipt-time lag and closes on sustained excess.
  void observeLag(Duration lag) {
    if (_closed) return;
    _lag = lag;
    if (_minimumLag == null || lag < _minimumLag!) _minimumLag = lag;
    if (lag - _minimumLag! <= readerLagExcess) {
      _excessSince = null;
      return;
    }
    final now = _now();
    final since = _excessSince;
    if (since == null) {
      _excessSince = now;
    } else if (now - since >= readerLagWindow) {
      _end(StreamReadEnd.lag);
    }
  }

  void _end(StreamReadEnd reason) {
    close();
    _onClose(reason);
  }

  /// Stops tracking and cancels any outstanding stall timer.
  void close() {
    if (_closed) return;
    _closed = true;
    _cancelBlocked?.call();
    _cancelBlocked = null;
    _blockedSince = null;
  }
}
