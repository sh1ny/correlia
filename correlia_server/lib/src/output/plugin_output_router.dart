import 'delivery_permit.dart';
import 'output_relay.dart';

/// Routes claimed events to a ready, pinned plugin instance.
abstract interface class PluginOutputRouter {
  /// Ready definition digests grouped by output identity.
  Map<String, Set<String>> get readyDefinitions;

  /// Acquires a delivery permit for the currently ready generation.
  DeliveryPermit? tryAcquire(String outputId, String digest);

  /// The instance's negotiated event-count limit.
  int eventLimit(String outputId, String digest);

  /// The instance's negotiated aggregate payload-byte limit.
  int byteLimit(String outputId, String digest);

  /// Delivers a whole batch through the instance protected by [permit].
  Future<List<DeliveryOutcome>> deliver(
    DeliveryPermit permit,
    DeliveryBatch batch,
  );
}

/// Resolves unanswered events to a retryable connection-loss outcome.
Future<List<DeliveryOutcome>> deliverPluginBatch(
  PluginOutputRouter router,
  DeliveryPermit permit,
  DeliveryBatch batch,
) async {
  try {
    if (!permit.isValid) throw StateError('plugin connection lost');
    final outcomes = await router
        .deliver(permit, batch)
        .timeout(batch.deadline.deliveryBudget);
    if (outcomes.length != batch.claims.length) {
      throw StateError('invalid plugin response');
    }
    return outcomes;
  } catch (_) {
    return List.filled(
      batch.claims.length,
      const DeliveryRetryable('plugin_connection_lost'),
    );
  }
}
