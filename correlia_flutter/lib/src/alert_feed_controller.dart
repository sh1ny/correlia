import 'dart:async';

import 'package:correlia_client/correlia_client.dart';
import 'package:flutter/foundation.dart';

import 'console_api.dart';

/// Creates a cancellable one-shot timer, injectable for deterministic tests.
typedef TimerFactory = Timer Function(Duration delay, void Function() callback);

/// Follows durable changes with serialized reads and version tombstones.
final class AlertFeedController extends ChangeNotifier {
  AlertFeedController({
    required this._api,
    DateTime Function()? clock,
    TimerFactory? timerFactory,
  }) : clock = clock ?? DateTime.now,
       _timerFactory = timerFactory ?? Timer.new;

  static const snapshotLimit = 500;
  final ConsoleApi _api;
  final DateTime Function() clock;
  final TimerFactory _timerFactory;
  final _alerts = <int, AlertView>{};
  final _tombstones = <int, int>{};
  StreamSubscription<FeedWakeUp>? _subscription;
  Timer? _safety;
  Timer? _retry;
  Future<void>? _flight;
  bool _started = false;
  bool _disposed = false;
  bool _pullAgain = false;
  bool _snapshotRequired = true;
  bool _streamFailed = false;
  bool _disconnected = false;
  int _generation = 0;
  int _retryAttempt = 0;
  int _omittedCount = 0;
  String? _cursor;

  /// The last successfully applied feed position.
  String? get cursor => _cursor;
  bool get disconnected => _disconnected;
  int get omittedCount => _omittedCount;
  bool get partial => _omittedCount > 0 || _alerts.length > snapshotLimit;

  /// The firing alerts by severity and newest firing, with unknown times last.
  List<AlertView> get alerts => _alerts.values.toList()
    ..sort((a, b) {
      final severity = _rank(a.severity).compareTo(_rank(b.severity));
      if (severity != 0) return severity;
      final aTime = a.firingSince;
      final bTime = b.firingSince;
      if (aTime == null) {
        return bTime == null ? a.id.compareTo(b.id) : 1;
      }
      if (bTime == null) return -1;
      final time = bTime.compareTo(aTime);
      return time == 0 ? a.id.compareTo(b.id) : time;
    });

  static int _rank(String severity) => switch (severity) {
    'critical' => 0,
    'error' => 1,
    'warning' => 2,
    'unknown' => 3,
    'info' => 4,
    _ => 3,
  };

  /// Starts the snapshot handover and safety pull once.
  Future<void> start() {
    if (_started || _disposed) return _flight ?? Future.value();
    _started = true;
    _openStream();
    _scheduleSafety();
    return pull();
  }

  void _scheduleSafety() {
    _safety = _timerFactory(const Duration(seconds: 10), () {
      if (_disposed) return;
      if (partial) _snapshotRequired = true;
      unawaited(pull());
      _scheduleSafety();
      notifyListeners();
    });
  }

  void _openStream() {
    _streamFailed = false;
    try {
      _subscription = _api.wakeUps().listen(
        (_) {
          if (!_disposed) unawaited(pull());
        },
        onError: (Object error, StackTrace stack) => _lostStream(),
        onDone: _lostStream,
      );
    } catch (_) {
      _lostStream();
    }
  }

  void _lostStream() {
    if (_disposed) return;
    _streamFailed = true;
    _markDisconnected();
  }

  void _markDisconnected() {
    if (_disposed) return;
    _disconnected = true;
    notifyListeners();
    if (_retry?.isActive ?? false) return;
    const seconds = [1, 2, 4, 10];
    final delay = seconds[_retryAttempt.clamp(0, seconds.length - 1)];
    _retryAttempt++;
    _retry = _timerFactory(Duration(seconds: delay), () {
      if (_disposed) return;
      if (_streamFailed) {
        final old = _subscription;
        _subscription = null;
        if (old != null) unawaited(old.cancel());
        _openStream();
      }
      unawaited(pull());
    });
  }

  /// Coalesces wake-ups while keeping at most one snapshot or feed in flight.
  Future<void> pull() {
    if (_disposed) return Future.value();
    _pullAgain = true;
    return _flight ??= _drain().whenComplete(() {
      _flight = null;
    });
  }

  Future<void> _drain() async {
    while (_pullAgain && !_disposed) {
      _pullAgain = false;
      try {
        if (_snapshotRequired) {
          final generation = ++_generation;
          final snapshot = await _api.snapshot();
          if (_disposed || generation != _generation) return;
          _alerts.clear();
          _tombstones.clear();
          for (final alert in snapshot.alerts) {
            _apply(alert);
          }
          _cursor = snapshot.cursor;
          _omittedCount = snapshot.omittedCount;
          _snapshotRequired = false;
        } else {
          final generation = _generation;
          final response = await _api.feed(_cursor!, 200);
          if (_disposed || generation != _generation) return;
          for (final alert in response.alerts) {
            _apply(alert);
          }
          _cursor = response.nextCursor;
          _pullAgain |= response.more;
        }
        if (!_streamFailed) {
          _disconnected = false;
          _retryAttempt = 0;
          _retry?.cancel();
        }
        notifyListeners();
      } on InvalidCursorException {
        _snapshotRequired = true;
        _pullAgain = true;
      } catch (_) {
        _pullAgain = false;
        _markDisconnected();
      }
    }
  }

  void _apply(AlertView alert) {
    final known = _alerts[alert.id]?.version ?? _tombstones[alert.id] ?? -1;
    if (alert.version <= known) return;
    if (alert.status == 'resolved') {
      _alerts.remove(alert.id);
      _tombstones.remove(alert.id);
      _tombstones[alert.id] = alert.version;
      if (_tombstones.length > 10000) {
        _tombstones.remove(_tombstones.keys.first);
      }
    } else {
      _tombstones.remove(alert.id);
      _alerts[alert.id] = alert;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _safety?.cancel();
    _retry?.cancel();
    final subscription = _subscription;
    if (subscription != null) unawaited(subscription.cancel());
    super.dispose();
  }
}
