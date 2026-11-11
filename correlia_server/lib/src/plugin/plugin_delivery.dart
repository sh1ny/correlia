import 'dart:async';
import 'dart:collection';

import 'package:correlia_server/event.dart';
import 'package:fixnum/fixnum.dart';
import 'package:uuid/uuid.dart';

import '../plugin_generated/correlia/plugin/spike/v1/output.pb.dart' as wire;
import 'plugin_host.dart';

/// Limits on the retained canonical events and encoded delivery requests.
///
/// All limits must be positive and the encoded batch limit cannot exceed the
/// transport's 2 MiB message limit.
final class PluginDeliveryPolicy {
  /// Creates delivery limits.
  PluginDeliveryPolicy({
    this.maxPendingEvents = 1024,
    this.maxPendingBytes = 16777216,
    this.maxBatchEvents = 64,
    this.maxBatchBytes = 1048576,
    this.maxOutstandingBatches = 4,
    this.ackProgressTimeout = const Duration(seconds: 10),
  }) {
    if (maxPendingEvents <= 0 ||
        maxPendingBytes <= 0 ||
        maxBatchEvents <= 0 ||
        maxBatchBytes <= 0 ||
        maxBatchBytes > 2097152 ||
        maxOutstandingBatches <= 0 ||
        ackProgressTimeout <= Duration.zero) {
      throw ArgumentError(
        'Delivery limits must be positive and fit the wire bound',
      );
    }
  }

  /// Maximum number of retained events.
  final int maxPendingEvents;

  /// Maximum retained canonical bytes.
  final int maxPendingBytes;

  /// Maximum number of events in a batch.
  final int maxBatchEvents;

  /// Maximum encoded request bytes.
  final int maxBatchBytes;

  /// Maximum batches awaiting acknowledgement.
  final int maxOutstandingBatches;

  /// Maximum time without acknowledgement progress.
  final Duration ackProgressTimeout;
}

/// A cancellation signal for an admission waiting for capacity.
///
/// Cancellation does not retract an event once admission has succeeded.
final class PluginDeliveryCancellation {
  bool _cancelled = false;
  final Set<void Function()> _listeners = {};

  /// Whether cancellation has been requested.
  bool get isCancelled => _cancelled;

  /// Cancels waiting admissions.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in _listeners.toList()) {
      listener();
    }
    _listeners.clear();
  }
}

/// A receipt completed only when its entire batch is acknowledged.
final class PluginDeliveryReceipt {
  PluginDeliveryReceipt._(this.eventId, this._completion);

  /// The canonical event identifier.
  final String eventId;
  final Completer<void> _completion;

  /// Completion of the acknowledgement.
  Future<void> get acknowledged => _completion.future;
}

final class _Entry {
  _Entry(this.event)
    : bytes = event.toJsonBytes(),
      completion = Completer<void>();
  final CloudEvent event;
  final List<int> bytes;
  final Completer<void> completion;
}

int _varintBytes(int value) {
  var length = 1;
  while (value >= 128) {
    value >>= 7;
    length++;
  }
  return length;
}

int _eventWireBytes(_Entry entry) {
  // Canonical event identifiers are UUIDs and therefore ASCII.
  final idLength = entry.event.event.eventId.length;
  final bytesLength = entry.bytes.length;
  final body =
      1 +
      _varintBytes(idLength) +
      idLength +
      1 +
      _varintBytes(bytesLength) +
      bytesLength;
  return 1 + _varintBytes(body) + body;
}

sealed class _DeliveryState {
  const _DeliveryState();
}

final class _Idle extends _DeliveryState {
  const _Idle();
}

final class _Starting extends _DeliveryState {
  const _Starting();
}

final class _Running extends _DeliveryState {
  const _Running();
}

final class _Failed extends _DeliveryState {
  const _Failed();
}

final class _Stopping extends _DeliveryState {
  const _Stopping();
}

final class _Stopped extends _DeliveryState {
  const _Stopped();
}

/// Owns an authenticated delivery stream and its admitted events.
///
/// Events reuse their validated [CloudEvent.toJsonBytes] snapshots. Only a valid
/// acknowledgement completes a receipt; plugin failure preserves pending work
/// until an explicit [restart]. This provides at-least-once delivery while this
/// Dart owner survives, not durability across host death.
///
/// [stop] is terminal: it fails remaining receipts and waiting admissions, then
/// discards this owner's in-memory queue. Cancellation of an admission does not
/// retract work already admitted.
final class PluginDelivery {
  /// Creates an idle delivery owner.
  PluginDelivery({required this.createHost, PluginDeliveryPolicy? policy})
    : policy = policy ?? PluginDeliveryPolicy();

  /// Creates a fresh idle host for an attempt.
  final FutureOr<PluginHost> Function(int attempt) createHost;

  /// The configured resource limits.
  final PluginDeliveryPolicy policy;
  final LinkedHashMap<String, _Entry> _pending = LinkedHashMap();
  final Map<int, List<_Entry>> _flight = {};
  PluginHost? _host;
  StreamController<wire.DeliverRequest>? _requests;
  StreamSubscription<wire.DeliverResponse>? _responses;
  Timer? _progress;
  String? _epoch;
  int _attempt = 0;
  int _sequence = 0;
  int _bytes = 0;
  Object? _failure;
  Completer<Object> _failed = Completer<Object>();
  _DeliveryState _state = const _Idle();
  bool _stopRequested = false;
  Future<void>? _operation;
  Future<void>? _stopFuture;
  bool get _running => switch (_state) {
    _Running() => !_stopRequested,
    _Idle() || _Starting() || _Failed() || _Stopping() || _Stopped() => false,
  };
  bool get _stopped => _stopRequested || _state is _Stopped;
  final List<Completer<void>> _changed = [];

  /// Number of retained events.
  int get pendingEventCount => _pending.length;

  /// Retained canonical byte count.
  int get pendingBytes => _bytes;

  /// An immutable snapshot of retained events.
  List<CloudEvent> get pendingEvents =>
      List.unmodifiable(_pending.values.map((e) => e.event));

  /// Number of batches awaiting acknowledgement.
  int get outstandingBatchCount => _flight.length;

  /// Available batch credits.
  int get availableCredits =>
      _running ? policy.maxOutstandingBatches - _flight.length : 0;

  /// Current connection epoch.
  String? get epoch => _epoch;

  /// Current child process identifier.
  int? get childPid => _host?.childPid;

  /// Most recent generation failure.
  Object? get failure => _failure;

  /// Completes with the current generation's failure.
  Future<Object> get whenFailed => _failed.future;

  /// Whether a generation is active.
  bool get isRunning => _running;

  /// Whether the current generation has failed.
  bool get isFailed => _state is _Failed;

  void _notify() {
    final waiters = List<Completer<void>>.of(_changed);
    _changed.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }

  /// Starts the first host.
  Future<void> start() {
    if (_state is! _Idle || _stopRequested) {
      throw StateError('Delivery has already started or stopped');
    }
    _state = const _Starting();
    final operation = _launch();
    _operation = operation;
    return operation;
  }

  Future<void> _launch() async {
    try {
      final host = await createHost(_attempt);
      _host = host;
      if (_stopRequested) return;
      await host.start();
      if (_stopRequested) return;
      _epoch = const Uuid().v4();
      _sequence = 0;
      _state = const _Running();
      _notify();
      _send();
    } on Object catch (error) {
      if (!_stopRequested) _fail(error);
      rethrow;
    }
  }

  /// Admits an event, waiting for queue capacity if necessary.
  Future<PluginDeliveryReceipt> admit(
    CloudEvent event, {
    PluginDeliveryCancellation? cancellation,
  }) async {
    if (_stopped || (cancellation?.isCancelled ?? false)) {
      throw StateError('Admission stopped or cancelled');
    }
    final entry = _Entry(event);
    final id = event.event.eventId;
    if (entry.bytes.length > policy.maxPendingBytes) {
      throw ArgumentError('Event exceeds pending capacity');
    }
    // Reserve the full uint64 sequence encoding so every admitted event can
    // still fit after a long-lived stream advances its sequence.
    if (38 + 1 + 10 + _eventWireBytes(entry) > policy.maxBatchBytes) {
      throw ArgumentError('Event exceeds encoded batch capacity');
    }
    while (true) {
      if (_stopped || (cancellation?.isCancelled ?? false)) {
        throw StateError('Admission stopped or cancelled');
      }
      if (_pending.containsKey(id)) {
        throw StateError('Duplicate pending event id');
      }
      if (_pending.length < policy.maxPendingEvents &&
          _bytes + entry.bytes.length <= policy.maxPendingBytes) {
        break;
      }
      final waiter = Completer<void>();
      _changed.add(waiter);
      void wake() {
        if (!waiter.isCompleted) waiter.complete();
      }

      cancellation?._listeners.add(wake);
      try {
        await waiter.future;
      } finally {
        cancellation?._listeners.remove(wake);
        _changed.remove(waiter);
      }
    }
    _pending[id] = entry;
    _bytes += entry.bytes.length;
    scheduleMicrotask(_send);
    return PluginDeliveryReceipt._(id, entry.completion);
  }

  void _send() {
    if (!_running ||
        _pending.isEmpty ||
        _flight.length >= policy.maxOutstandingBatches) {
      return;
    }
    try {
      _sendAvailable();
    } on Object catch (error) {
      _fail(error);
    }
  }

  void _sendAvailable() {
    final requests = _requests ??= StreamController<wire.DeliverRequest>();
    if (_responses == null) {
      final generation = _epoch;
      _responses = openPluginDeliver(_host!, requests.stream).listen(
        (response) {
          if (!_running || _epoch != generation) return;
          final sequence = response.sequence.toInt();
          if (response.epoch != generation || !_flight.containsKey(sequence)) {
            _fail(FormatException('Invalid delivery acknowledgement'));
            return;
          }
          final batch = _flight.remove(sequence)!;
          for (final entry in batch) {
            _pending.remove(entry.event.event.eventId);
            _bytes -= entry.bytes.length;
            entry.completion.complete();
          }
          _armProgress();
          _notify();
          _send();
        },
        onError: (Object error, StackTrace stack) {
          if (_running && _epoch == generation) _fail(error);
        },
        onDone: () {
          if (_running && _epoch == generation) {
            _fail(StateError('Delivery stream closed'));
          }
        },
      );
    }
    final inFlight = _flight.values.expand((batch) => batch).toSet();
    final available = _pending.values
        .where((entry) => !inFlight.contains(entry))
        .iterator;
    while (_flight.length < policy.maxOutstandingBatches) {
      final sequence = _sequence + 1;
      var size = 38 + 1 + _varintBytes(sequence);
      final entries = <_Entry>[];
      while (entries.length < policy.maxBatchEvents && available.moveNext()) {
        final entry = available.current;
        final eventSize = _eventWireBytes(entry);
        if (size + eventSize > policy.maxBatchBytes) {
          // This event begins the next batch; leave it pending for the next
          // flush rather than consuming it from an iterator.
          break;
        }
        entries.add(entry);
        size += eventSize;
      }
      if (entries.isEmpty) break;
      if (sequence <= 0) {
        throw StateError('Delivery sequence exhausted; restart required');
      }
      _sequence = sequence;
      _flight[sequence] = entries;
      if (_flight.length == 1) _armProgress();
      requests.add(
        wire.DeliverRequest(
          epoch: _epoch,
          sequence: Int64(sequence),
          events: entries.map(
            (entry) => wire.Event(
              eventId: entry.event.event.eventId,
              canonicalJson: entry.bytes,
            ),
          ),
        ),
      );
      // Rescan pending on the next turn so the first event which did not fit
      // is not lost, while preserving admission order.
      if (_flight.length < policy.maxOutstandingBatches) {
        scheduleMicrotask(_send);
      }
      break;
    }
  }

  void _armProgress() {
    _progress?.cancel();
    _progress = null;
    if (!_running || _flight.isEmpty) return;
    final generation = _epoch;
    _progress = Timer(policy.ackProgressTimeout, () {
      if (_running && _epoch == generation && _flight.isNotEmpty) {
        _fail(TimeoutException('Delivery acknowledgement progress timed out'));
      }
    });
  }

  void _retire() {
    _progress?.cancel();
    _progress = null;
    _epoch = null;
    _flight.clear();
    final responses = _responses;
    final requests = _requests;
    _responses = null;
    _requests = null;
    if (responses != null) responses.cancel().ignore();
    if (requests != null) requests.close().ignore();
  }

  void _fail(Object error) {
    if (_state is _Failed || _stopRequested) return;
    _state = const _Failed();
    _retire();
    _failure = error;
    if (!_failed.isCompleted) _failed.complete(error);
    _notify();
  }

  /// Waits until all admitted events are acknowledged.
  Future<void> drain() async {
    if (_failure != null) throw _failure!;
    while (_pending.isNotEmpty) {
      if (_failure != null) throw _failure!;
      if (_stopped) throw StateError('Delivery stopped');
      final waiter = Completer<void>();
      _changed.add(waiter);
      await waiter.future;
    }
  }

  /// Retires the current host and starts a new generation.
  Future<void> restart() {
    if (_stopRequested || (_state is! _Running && _state is! _Failed)) {
      throw StateError('Delivery cannot restart in its current state');
    }
    _state = const _Starting();
    _retire();
    _failure = null;
    _failed = Completer<Object>();
    _attempt++;
    final operation = _restart();
    _operation = operation;
    return operation;
  }

  Future<void> _restart() async {
    try {
      await _host?.stop();
      _host = null;
      if (_stopRequested) return;
      await _launch();
    } on Object catch (error) {
      if (!_stopRequested && _state is! _Failed) _fail(error);
      rethrow;
    }
  }

  /// Stops the delivery owner and releases waiting callers.
  Future<void> stop() {
    final existing = _stopFuture;
    if (existing != null) return existing;
    _stopRequested = true;
    _state = const _Stopping();
    _retire();
    _notify();
    for (final entry in _pending.values) {
      entry.completion.future.ignore();
      if (!entry.completion.isCompleted) {
        entry.completion.completeError(StateError('Delivery stopped'));
      }
    }
    _pending.clear();
    _bytes = 0;
    final stopped = _finishStop();
    _stopFuture = stopped;
    return stopped;
  }

  Future<void> _finishStop() async {
    try {
      try {
        await _operation;
      } on Object {
        // The caller of the lifecycle operation receives its original error.
      }
      await _host?.stop();
    } finally {
      _state = const _Stopped();
    }
  }
}
