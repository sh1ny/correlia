import 'dart:async';

import 'package:correlia_server/src/plugin/output_plugin_connection.dart';
import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

void main() {
  const deadline = Duration(milliseconds: 100);
  const before = Duration(milliseconds: 99);
  const after = Duration(milliseconds: 101);

  test('non_deadline_status_at_or_past_deadline_is_health_timeout', () {
    for (final code in [
      StatusCode.unknown,
      StatusCode.cancelled,
      StatusCode.unavailable,
      StatusCode.internal,
    ]) {
      for (final elapsed in [deadline, after]) {
        expect(
          classifyHealthFailure(
            error: GrpcError.custom(code),
            elapsed: elapsed,
            deadline: deadline,
            connectionFailed: false,
          ),
          'plugin_health_timeout',
          reason: 'code=$code elapsed=$elapsed',
        );
      }
    }
  });

  test('observed_connection_loss_wins_for_every_completion', () {
    for (final error in <Object>[
      TimeoutException('deadline'),
      const GrpcError.deadlineExceeded(),
      const GrpcError.unavailable(),
    ]) {
      for (final elapsed in [before, deadline, after]) {
        expect(
          classifyHealthFailure(
            error: error,
            elapsed: elapsed,
            deadline: deadline,
            connectionFailed: true,
          ),
          'plugin_connection_lost',
          reason: 'error=$error elapsed=$elapsed',
        );
      }
    }
  });

  test('timeout_completions_on_live_connection_are_health_timeout', () {
    for (final error in <Object>[
      TimeoutException('deadline'),
      const GrpcError.deadlineExceeded(),
    ]) {
      expect(
        classifyHealthFailure(
          error: error,
          elapsed: before,
          deadline: deadline,
          connectionFailed: false,
        ),
        'plugin_health_timeout',
      );
    }
  });

  test('non_deadline_status_before_deadline_stays_connection_lost', () {
    expect(
      classifyHealthFailure(
        error: const GrpcError.unavailable(),
        elapsed: before,
        deadline: deadline,
        connectionFailed: false,
      ),
      'plugin_connection_lost',
    );
  });
}
