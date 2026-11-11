import 'package:serverpod/serverpod.dart';

import '../console/console_access_policy.dart';
import '../feed/feed_reader.dart';
import '../feed/feed_runtime.dart';
import '../generated/protocol.dart';

/// Development-only snapshot, durable feed and wake-up API.
class AlertConsoleEndpoint extends Endpoint {
  void _check(Session session) {
    ConsoleAccessPolicy.check(
      session.serverpod.runMode,
      FeedRuntime.role,
      session.request,
    );
  }

  /// Returns a bounded firing-alert snapshot and its handover cursor.
  Future<AlertSnapshot> snapshot(Session session) async {
    _check(session);
    return FeedReader(session).snapshot();
  }

  /// Reads a page of durable activity and its current alert views.
  Future<FeedPage> feed(Session session, String cursor, int limit) async {
    _check(session);
    return FeedReader(session).feed(cursor, limit);
  }

  /// Emits wake-ups while this client is subscribed.
  Stream<FeedWakeUp> wakeUps(Session session) {
    _check(session);
    return FeedRuntime.watermark!.wakeUps();
  }
}
