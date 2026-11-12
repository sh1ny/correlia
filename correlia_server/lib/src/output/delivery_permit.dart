import 'dart:async';

/// Tracks permits for one ready plugin generation.
final class DeliveryPermitSource {
  int _generation = 0;
  int _active = 0;
  bool _ready = true;
  Completer<void>? _drained;

  /// The number of permits not yet released.
  int get activeCount => _active;

  /// Acquires a permit if this generation is still ready.
  DeliveryPermit? acquire() {
    if (!_ready) return null;
    _active++;
    return DeliveryPermit._(this, _generation);
  }

  /// Invalidates outstanding permits and refuses new ones.
  void invalidate() {
    _ready = false;
    _generation++;
  }

  /// Completes when all acquired permits have been released.
  Future<void> drain() => _active == 0
      ? Future<void>.value()
      : (_drained ??= Completer<void>()).future;

  void _release() {
    _active--;
    if (_active == 0) {
      _drained?.complete();
      _drained = null;
    }
  }
}

/// A delivery right tied to one plugin generation.
final class DeliveryPermit {
  DeliveryPermit._(this._source, this._generation);
  final DeliveryPermitSource _source;
  final int _generation;
  bool _released = false;

  /// Whether the generation remains ready and this permit is held.
  bool get isValid =>
      !_released && _source._ready && _source._generation == _generation;

  /// Releases this permit exactly once.
  void release() {
    if (_released) return;
    _released = true;
    _source._release();
  }
}
