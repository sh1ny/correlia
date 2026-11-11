import 'dart:async';

import 'package:correlia_client/correlia_client.dart';
import 'package:correlia_flutter/src/console_api.dart';

final testNow = DateTime.utc(2026, 11, 12, 12);

AlertView alertView(
  int id, {
  int version = 1,
  String status = 'firing',
  String severity = 'warning',
  String summary = 'Disk full',
  String? generatorUrl,
}) => AlertView(
  id: id,
  version: version,
  status: status,
  severity: severity,
  summary: summary,
  sourceInstance: 'monitor-a',
  firingSince: testNow.subtract(const Duration(hours: 1)),
  lastObservedAt: testNow,
  generatorUrl: generatorUrl,
);

FeedPage page(
  List<AlertView> alerts, {
  String cursor = 'v1.2.1',
  bool more = false,
}) => FeedPage(
  entries: [],
  alerts: alerts,
  nextCursor: cursor,
  more: more,
  heldBack: false,
);

final class FakeConsoleApi implements ConsoleApi {
  AlertSnapshot initial = AlertSnapshot(
    alerts: [],
    omittedCount: 0,
    cursor: 'v1.1.0',
  );
  final pages = <FeedPage>[];
  final cursors = <String>[];
  final streams = <StreamController<FeedWakeUp>>[];
  int snapshots = 0;
  Object? failure;
  Completer<FeedPage>? pending;

  @override
  Future<AlertSnapshot> snapshot() async {
    snapshots++;
    if (failure case final Object error) throw error;
    return initial;
  }

  @override
  Future<FeedPage> feed(String cursor, int limit) async {
    cursors.add(cursor);
    if (failure case final Object error) throw error;
    if (pending case final Completer<FeedPage> request) return request.future;
    return pages.isEmpty ? page([], cursor: cursor) : pages.removeAt(0);
  }

  @override
  Stream<FeedWakeUp> wakeUps() {
    final stream = StreamController<FeedWakeUp>();
    streams.add(stream);
    return stream.stream;
  }

  Future<void> close() async {
    for (final stream in streams) {
      await stream.close();
    }
  }
}

final class FakeTimer implements Timer {
  FakeTimer(this.duration, this.callback);
  final Duration duration;
  final void Function() callback;
  bool _active = true;
  int _tick = 0;
  @override
  bool get isActive => _active;
  @override
  int get tick => _tick;
  @override
  void cancel() => _active = false;
  void fire() {
    if (!_active) return;
    _active = false;
    _tick++;
    callback();
  }
}

final class FakeTimers {
  final timers = <FakeTimer>[];
  Timer create(Duration duration, void Function() callback) {
    final timer = FakeTimer(duration, callback);
    timers.add(timer);
    return timer;
  }

  void fireSafety() => timers
      .firstWhere(
        (timer) =>
            timer.isActive && timer.duration == const Duration(seconds: 10),
      )
      .fire();
}

Future<void> flush() async {
  // A queued event runs after futures and stream delivery, without wall-clock sleeps.
  await Future<void>(() {});
}
