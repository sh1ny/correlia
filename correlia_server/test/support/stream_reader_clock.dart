/// A manual monotonic clock and timer scheduler for reader tests.
final class StreamReaderClock {
  Duration elapsed = Duration.zero;
  final _timers = <({Duration at, void Function() run})>[];
  void Function(Duration)? onSchedule;

  void Function() schedule(Duration delay, void Function() run) {
    final timer = (at: elapsed + delay, run: run);
    _timers.add(timer);
    onSchedule?.call(delay);
    return () => _timers.remove(timer);
  }

  void advance(Duration by) {
    final target = elapsed + by;
    while (true) {
      _timers.sort((a, b) => a.at.compareTo(b.at));
      if (_timers.isEmpty || _timers.first.at > target) break;
      final timer = _timers.removeAt(0);
      elapsed = timer.at;
      timer.run();
    }
    elapsed = target;
  }
}
