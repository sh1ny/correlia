import 'dart:async';

/// Monotonic end-to-end budget for one claimed delivery batch.
final class RelayDeadline {
  /// Starts the deadline before entering the claim transaction.
  RelayDeadline({this._elapsed}) : _stopwatch = Stopwatch()..start();

  final Stopwatch _stopwatch;
  final Duration Function()? _elapsed;

  Duration get _spent => _elapsed?.call() ?? _stopwatch.elapsed;

  /// Rejects work that has exceeded the overall deadline.
  void check() {
    if (_spent >= const Duration(seconds: 27)) {
      throw TimeoutException('relay deadline');
    }
  }

  /// Rejects a claim that has exceeded its five-second phase.
  void checkClaim() {
    if (_spent >= const Duration(seconds: 5)) {
      throw TimeoutException('relay claim deadline');
    }
    check();
  }

  /// Remaining database statement budget, capped at five seconds.
  int remainingMillis({bool claim = false}) {
    if (claim) {
      checkClaim();
    } else {
      check();
    }
    final remaining =
        (claim ? const Duration(seconds: 5) : const Duration(seconds: 27)) -
        _spent;
    return remaining.inMilliseconds.clamp(1, 5000);
  }

  /// The delivery budget, preserving five seconds for completion.
  Duration get deliveryBudget {
    check();
    final remaining = const Duration(seconds: 22) - _spent;
    if (remaining <= Duration.zero) {
      throw TimeoutException('relay delivery deadline');
    }
    return remaining < const Duration(seconds: 20)
        ? remaining
        : const Duration(seconds: 20);
  }
}
