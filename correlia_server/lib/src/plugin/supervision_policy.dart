/// Durable circuit state for one pinned definition.
enum PluginCircuit { closed, open, probing }

/// Runtime state of an instance.
enum PluginState { starting, ready, backoff, degraded, stopped }

/// Supervision timing defaults, injectable for deterministic tests.
final class SupervisionDurations {
  const SupervisionDurations({
    this.startTimeout = const Duration(seconds: 10),
    this.healthInterval = const Duration(seconds: 5),
    this.healthDeadline = const Duration(seconds: 2),
    this.backoffInitial = const Duration(seconds: 1),
    this.backoffMaximum = const Duration(seconds: 60),
    this.backoffReset = const Duration(minutes: 10),
    this.crashWindow = const Duration(minutes: 10),
    this.probeInterval = const Duration(minutes: 5),
    this.probeReady = const Duration(seconds: 60),
    this.shutdownGrace = const Duration(seconds: 5),
  });

  final Duration startTimeout, healthInterval, healthDeadline;
  final Duration backoffInitial, backoffMaximum, backoffReset, crashWindow;
  final Duration probeInterval, probeReady, shutdownGrace;
}

/// Tracks the bounded failure history and readiness transitions of a definition.
final class SupervisionPolicy {
  SupervisionPolicy({
    required this.clock,
    this.durations = const SupervisionDurations(),
    this.circuit = PluginCircuit.closed,
    this.backoffStep = 0,
    this.nextStartAt,
    this.nextProbeAt,
    this.lastError,
    Iterable<DateTime> failures = const [],
  }) : failures = List.of(failures);

  final DateTime Function() clock;
  final SupervisionDurations durations;
  final List<DateTime> failures;
  PluginCircuit circuit;
  PluginState state = PluginState.stopped;
  int backoffStep;
  DateTime? nextStartAt, nextProbeAt, readySince;
  String? lastError;
  int healthFailures = 0;

  /// Begins a normal launch or a due circuit probe.
  void start() {
    if (circuit == PluginCircuit.open) {
      circuit = PluginCircuit.probing;
      nextProbeAt = clock().add(durations.probeInterval);
    }
    state = PluginState.starting;
    readySince = null;
    healthFailures = 0;
  }

  /// Records successful handshake, configuration and serving health.
  void ready() {
    state = PluginState.ready;
    readySince = clock();
    healthFailures = 0;
    nextStartAt = null;
  }

  /// Records a failed launch or crash, opening the circuit if its budget is exhausted.
  void failed(String error) {
    final now = clock();
    final since = readySince;
    if (state == PluginState.ready &&
        since != null &&
        now.difference(since) >= durations.backoffReset) {
      backoffStep = 0;
    }
    failures.removeWhere(
      (time) => now.difference(time) > durations.crashWindow,
    );
    failures.add(now);
    if (failures.length > 6) failures.removeAt(0);
    lastError = error;
    final exponent = backoffStep < 30 ? backoffStep : 30;
    final micros = durations.backoffInitial.inMicroseconds * (1 << exponent);
    final capped = micros < durations.backoffMaximum.inMicroseconds
        ? micros
        : durations.backoffMaximum.inMicroseconds;
    backoffStep++;
    if (circuit == PluginCircuit.probing || failures.length > 5) {
      circuit = PluginCircuit.open;
      nextProbeAt = now.add(durations.probeInterval);
      nextStartAt = nextProbeAt;
      state = PluginState.degraded;
    } else {
      nextStartAt = now.add(Duration(microseconds: capped));
      state = PluginState.backoff;
    }
    readySince = null;
  }

  /// Records one health response and returns whether it exhausted the budget.
  bool health(bool serving) {
    healthFailures = serving ? 0 : healthFailures + 1;
    if (healthFailures < 3) return false;
    failed('plugin_health_failed');
    return true;
  }

  /// Advances time-dependent transitions and returns whether a probe recovered.
  bool tick() {
    final since = readySince;
    if (state != PluginState.ready || since == null) return false;
    final elapsed = clock().difference(since);
    if (elapsed >= durations.backoffReset) backoffStep = 0;
    if (circuit == PluginCircuit.probing && elapsed >= durations.probeReady) {
      circuit = PluginCircuit.closed;
      nextProbeAt = null;
      return true;
    }
    return false;
  }

  /// Stops voluntarily without counting a failure or advancing the probe time.
  void stop() {
    if (circuit == PluginCircuit.probing) {
      circuit = PluginCircuit.open;
      nextStartAt = nextProbeAt;
    }
    state = PluginState.stopped;
    readySince = null;
  }
}
