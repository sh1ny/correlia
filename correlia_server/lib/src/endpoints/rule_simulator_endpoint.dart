import 'package:serverpod/serverpod.dart';

import '../console/console_access_policy.dart';
import '../feed/feed_runtime.dart';
import '../generated/protocol.dart';
import '../simulator/rule_simulator.dart';

/// Read-only simulation of one event against the active or a draft matcher.
class RuleSimulatorEndpoint extends Endpoint {
  /// A simulation writes no session log, like the mapping preview.
  @override
  bool get logSessions => false;

  /// Shows every rule and condition decision for one event.
  ///
  /// The input is exactly one of [eventJson] (a CloudEvent JSON document) or
  /// [eventId] with [observedAt] and an optional [disposition] (a stored
  /// event). [draftMatcher] is an optional matcher section as JSON text; without
  /// it the active snapshot's rules run. Failures are a [SimulationError] in the
  /// result; only the console access policy throws.
  Future<RuleSimulationResult> simulate(
    Session session, {
    String? eventJson,
    String? eventId,
    String? observedAt,
    String? disposition,
    String? draftMatcher,
  }) {
    ConsoleAccessPolicy.check(
      session.serverpod.runMode,
      FeedRuntime.role,
      session.request,
    );
    return RuleSimulator().simulate(
      session,
      eventJson: eventJson,
      eventId: eventId,
      observedAt: observedAt,
      disposition: disposition,
      draftMatcher: draftMatcher,
    );
  }
}
