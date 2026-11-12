/// A definition's stable position in the admission order.
final class PluginKey implements Comparable<PluginKey> {
  const PluginKey(this.outputId, this.digest);
  final String outputId;
  final String digest;

  @override
  int compareTo(PluginKey other) {
    final output = outputId.compareTo(other.outputId);
    return output == 0 ? digest.compareTo(other.digest) : output;
  }

  @override
  bool operator ==(Object other) =>
      other is PluginKey &&
      outputId == other.outputId &&
      digest == other.digest;

  @override
  int get hashCode => Object.hash(outputId, digest);
}

final class _Slot {
  _Slot(this.started, this.probing) : lastDue = started;
  final DateTime started;
  final bool probing;
  DateTime lastDue;
  DateTime? readyAt;
}

/// Bounded running-slot state; durable health and waiting demand remain external.
final class SlotScheduler {
  SlotScheduler({
    required this.clock,
    this.workerLimit = 16,
    this.outputLimit = 4,
    this.hold = const Duration(seconds: 60),
    this.idle = const Duration(seconds: 60),
    this.probeReady = const Duration(seconds: 60),
  });
  final DateTime Function() clock;
  final int workerLimit, outputLimit;
  final Duration hold, idle, probeReady;
  final Map<PluginKey, _Slot> _slots = {};
  PluginKey? cursor;

  /// The currently occupied keys, bounded by the worker limit.
  Iterable<PluginKey> get running => _slots.keys;

  /// Whether a key can occupy a slot in both scopes.
  bool canAdmit(PluginKey key) =>
      !_slots.containsKey(key) &&
      _slots.length < workerLimit &&
      _slots.keys.where((other) => other.outputId == key.outputId).length <
          outputLimit;

  /// Occupies a slot and moves the round-robin cursor.
  void admit(PluginKey key, {bool probing = false}) {
    if (!canAdmit(key)) throw StateError('No slot available for $key');
    _slots[key] = _Slot(clock(), probing);
    cursor = key;
  }

  /// Marks the instance ready.
  void ready(PluginKey key) => _slots[key]!.readyAt = clock();

  /// Refreshes the time at which due work was last seen.
  void due(PluginKey key) => _slots[key]!.lastDue = clock();

  /// Whether the instance has been idle long enough to release.
  bool idleForRelease(PluginKey key) =>
      clock().difference(_slots[key]!.lastDue) >= idle;

  /// Selects the longest-held eligible instance in the waiting key's blocking scope.
  PluginKey? rotationFor(PluginKey waiting) {
    final outputBlocked =
        _slots.keys.where((key) => key.outputId == waiting.outputId).length >=
        outputLimit;
    if (!outputBlocked && _slots.length < workerLimit) return null;
    final now = clock();
    PluginKey? selected;
    DateTime? oldest;
    for (final entry in _slots.entries) {
      final slot = entry.value;
      final ready = slot.readyAt;
      if (outputBlocked && entry.key.outputId != waiting.outputId ||
          ready == null ||
          now.difference(slot.started) < hold ||
          slot.probing && now.difference(ready) < probeReady) {
        continue;
      }
      if (oldest == null || slot.started.isBefore(oldest)) {
        selected = entry.key;
        oldest = slot.started;
      }
    }
    return selected;
  }

  /// Frees a slot after its batch and durable health updates have completed.
  void release(PluginKey key) => _slots.remove(key);

  /// Selects the next eligible key from a supplied ordered demand source.
  PluginKey? nextFrom(Iterable<PluginKey> demand) {
    PluginKey? after;
    PluginKey? wrap;
    for (final key in demand) {
      if (!canAdmit(key)) continue;
      if (wrap == null || key.compareTo(wrap) < 0) wrap = key;
      if ((cursor == null || key.compareTo(cursor!) > 0) &&
          (after == null || key.compareTo(after) < 0)) {
        after = key;
      }
    }
    return after ?? wrap;
  }
}
