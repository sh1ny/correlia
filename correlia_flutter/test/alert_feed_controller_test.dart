import 'dart:async';

import 'package:correlia_client/correlia_client.dart';
import 'package:correlia_flutter/src/alert_feed_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'console_fakes.dart';

void main() {
  late FakeConsoleApi api;
  late FakeTimers timers;
  late AlertFeedController controller;
  setUp(() {
    api = FakeConsoleApi();
    timers = FakeTimers();
    controller = AlertFeedController(
      api: api,
      clock: () => testNow,
      timerFactory: timers.create,
    );
  });
  tearDown(() async {
    controller.dispose();
    await api.close();
  });

  test('wake_up_stream_silent', () async {
    await controller.start();
    api.pages.add(page([alertView(1)]));
    timers.fireSafety();
    await flush();
    expect(controller.alerts.single.summary, 'Disk full');
  });

  test('unknown_firing_times_sort_last_without_using_freshness', () async {
    final known = alertView(1);
    final older = alertView(4).copyWith(
      firingSince: testNow.subtract(const Duration(hours: 2)),
    );
    final unknown = alertView(2).copyWith(firingSince: null);
    final fresherUnknown = alertView(3).copyWith(
      firingSince: null,
      lastObservedAt: testNow.add(const Duration(hours: 1)),
    );
    api.initial = AlertSnapshot(
      alerts: [fresherUnknown, older, unknown, known],
      omittedCount: 0,
      cursor: 'v1.1.0',
    );
    await controller.start();
    expect(controller.alerts.map((alert) => alert.id), [1, 4, 2, 3]);
  });

  test('older_version_after_newer_one', () async {
    api.initial = AlertSnapshot(
      alerts: [alertView(1, version: 3, severity: 'critical')],
      omittedCount: 0,
      cursor: 'v1.1.0',
    );
    await controller.start();
    api.pages.add(page([alertView(1, version: 2)]));
    await controller.pull();
    expect(controller.alerts.single.version, 3);
    expect(controller.alerts.single.severity, 'critical');
  });

  test('delayed_older_response_after_resolution', () async {
    api.initial = AlertSnapshot(
      alerts: [alertView(1, version: 2)],
      omittedCount: 0,
      cursor: 'v1.1.0',
    );
    await controller.start();
    api.pages.add(page([alertView(1, version: 3, status: 'resolved')]));
    await controller.pull();
    api.pages.add(page([alertView(1, version: 2)]));
    await controller.pull();
    expect(controller.alerts, isEmpty);
  });

  test('complete_list_grows_past_limit', () async {
    api.initial = AlertSnapshot(
      alerts: [for (var i = 1; i <= 500; i++) alertView(i)],
      omittedCount: 0,
      cursor: 'v1.1.0',
    );
    await controller.start();
    api.pages.add(page([alertView(501)]));
    await controller.pull();
    expect(controller.partial, isTrue);
    api.initial = AlertSnapshot(
      alerts: [for (var i = 2; i <= 501; i++) alertView(i)],
      omittedCount: 1,
      cursor: 'v1.3.0',
    );
    timers.fireSafety();
    await flush();
    expect(controller.alerts.map((a) => a.id), isNot(contains(1)));
    expect(controller.omittedCount, 1);
    expect(api.snapshots, 2);
  });

  test('partial_list_refills_after_resolution', () async {
    api.initial = AlertSnapshot(
      alerts: [alertView(1)],
      omittedCount: 1,
      cursor: 'v1.1.0',
    );
    await controller.start();
    api.pages.add(page([alertView(1, version: 2, status: 'resolved')]));
    await controller.pull();
    api.initial = AlertSnapshot(
      alerts: [alertView(2)],
      omittedCount: 0,
      cursor: 'v1.3.0',
    );
    timers.fireSafety();
    await flush();
    expect(controller.alerts.single.id, 2);
    expect(controller.partial, isFalse);
  });

  test('rejected_cursor_takes_new_snapshot', () async {
    await controller.start();
    // Fail only the next feed, so the recovery snapshot can complete.
    api.failure = InvalidCursorException(message: 'Invalid feed cursor');
    api.initial = AlertSnapshot(
      alerts: [alertView(2)],
      omittedCount: 0,
      cursor: 'v1.3.0',
    );
    final pending = controller.pull();
    api.failure = null;
    await pending;
    expect(controller.alerts.single.id, 2);
    expect(controller.cursor, 'v1.3.0');
  });

  test(
    'wakeups during a read serialize and resume from returned cursor',
    () async {
      await controller.start();
      final pending = Completer<FeedPage>();
      api.pending = pending;
      final pull = controller.pull();
      api.streams.single.add(FeedWakeUp());
      api.streams.single.add(FeedWakeUp());
      await flush();
      expect(api.cursors, ['v1.1.0']);
      api.pending = null;
      api.pages.add(
        page([alertView(1, version: 2, status: 'resolved')], cursor: 'v1.3.2'),
      );
      pending.complete(page([alertView(1)], cursor: 'v1.2.1'));
      await pull;
      expect(api.cursors, ['v1.1.0', 'v1.2.1']);
      expect(controller.alerts, isEmpty);
      expect(controller.cursor, 'v1.3.2');
    },
  );

  test('read failure retains rows and retries with bounded backoff', () async {
    api.initial = AlertSnapshot(
      alerts: [alertView(1)],
      omittedCount: 0,
      cursor: 'v1.1.0',
    );
    await controller.start();
    api.failure = StateError('offline');
    await controller.pull();
    expect(controller.disconnected, isTrue);
    expect(controller.alerts.single.id, 1);
    for (final seconds in [1, 2, 4, 10]) {
      final retry = timers.timers.last;
      expect(retry.duration, Duration(seconds: seconds));
      retry.fire();
      await flush();
    }
    api.failure = null;
    api.pages.add(
      page([alertView(1, version: 2, status: 'resolved')], cursor: 'v1.4.2'),
    );
    timers.timers.last.fire();
    await flush();
    expect(controller.disconnected, isFalse);
    expect(controller.alerts, isEmpty);
    expect(api.cursors.last, 'v1.1.0');
  });
  test(
    'stream loss retries the stream and pulls from the retained cursor',
    () async {
      api.initial = AlertSnapshot(
        alerts: [alertView(1)],
        omittedCount: 0,
        cursor: 'v1.1.0',
      );
      await controller.start();
      api.streams.single.addError(StateError('socket closed'));
      await flush();
      expect(controller.disconnected, isTrue);
      expect(controller.alerts.single.id, 1);
      api.pages.add(
        page([alertView(1, version: 2, status: 'resolved')], cursor: 'v1.4.1'),
      );
      timers.timers.last.fire();
      await flush();
      expect(api.streams, hasLength(2));
      expect(api.cursors.last, 'v1.1.0');
      expect(controller.alerts, isEmpty);
      expect(controller.disconnected, isFalse);
    },
  );
}
