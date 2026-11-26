import 'package:serverpod/serverpod.dart';

import '../generated/protocol.dart';
import '../pipeline/operator_runtime.dart';
import '../pipeline/queue_operations.dart';

/// Dedicated opt-in operator calls, separate from ingest and console access.
class DeadLetterEndpoint extends Endpoint {
  @override
  bool get logSessions => false;

  /// Lists a bounded page of sanitized active failures.
  Future<QueueFailurePage> list(
    Session session,
    QueueFailureFilter filter, {
    int limit = 50,
    String? continuation,
  }) => _authorized(
    session,
    (ops, _) => ops.list(filter, limit: limit, cursor: continuation),
  );

  /// Requeues one exact failure occurrence when still eligible.
  Future<QueueReplayResult> replay(
    Session session,
    QueueFailureKind kind,
    int occurrence,
  ) => _authorized(
    session,
    (ops, actor) => ops.replayOne(kind, occurrence, actor),
  );

  /// Requeues eligible failures in one filtered and bounded page.
  Future<QueueReplayResult> replayBatch(
    Session session,
    QueueFailureFilter filter, {
    int limit = 50,
    String? continuation,
  }) => _authorized(
    session,
    (ops, actor) =>
        ops.replayBatch(filter, actor, limit: limit, cursor: continuation),
  );

  /// Reports shared queue pressure and the last committed maintenance outcome.
  Future<QueueStatus> status(Session session) =>
      _authorized(session, (ops, _) => ops.status());

  Future<T> _authorized<T>(
    Session session,
    Future<T> Function(QueueOperations, String) call,
  ) async {
    final (actor, store) = OperatorRuntime.authorize(session);
    try {
      return await call(QueueOperations(session, secretStore: store), actor);
    } on QueueOperatorException {
      rethrow;
    } catch (_) {
      // Driver messages can include SQL parameters. Never reflect them.
      throw QueueOperatorException(code: 'operations_unavailable');
    }
  }
}
