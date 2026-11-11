import 'dart:async';

import 'package:serverpod/serverpod.dart';

import '../generated/protocol.dart';
import '../runtime/process_options.dart';
import '../runtime/subsystem.dart';
import 'feed_cursor.dart';

/// Polls for newly readable activity while local stream subscribers exist.
final class FeedWatermarkSubsystem extends Subsystem {
  /// Creates a poller with its own sessions and an injectable interval.
  FeedWatermarkSubsystem({
    required this.openSession,
    required this.log,
    this.pollInterval = const Duration(milliseconds: 500),
    this.onPoll,
  });

  /// Opens an independent database session.
  final Future<Session> Function() openSession;

  /// Receives failure and long-held watermark warnings.
  final void Function(String) log;

  /// The interval between polls.
  final Duration pollInterval;

  /// Called after a successful poll, for deterministic tests.
  final void Function()? onPoll;

  final Set<_Subscriber> _subscribers = {};
  Timer? _timer;
  Future<void>? _inFlight;
  FeedCursor? _last;
  DateTime? _heldSince;
  bool _warned = false;
  bool _failed = false;
  bool _stopped = true;

  @override
  String get name => 'feed-watermark';
  @override
  Set<ProcessRole> get roles => const {ProcessRole.api, ProcessRole.all};

  @override
  Future<void> start() async {
    _stopped = false;
  }

  /// Subscribes to coalesced wake-ups until cancellation.
  Stream<FeedWakeUp> wakeUps() {
    late _Subscriber subscriber;
    late StreamController<FeedWakeUp> controller;
    controller = StreamController<FeedWakeUp>(
      sync: true,
      onListen: () {
        _subscribers.add(subscriber);
        _schedule(Duration.zero);
      },
      onPause: () {
        subscriber.paused = true;
      },
      onResume: () {
        subscriber.paused = false;
        if (subscriber.pending) {
          subscriber.pending = false;
          controller.add(FeedWakeUp());
        }
      },
      onCancel: () {
        _subscribers.remove(subscriber);
        if (_subscribers.isEmpty) {
          _timer?.cancel();
          _timer = null;
          _last = null;
          _heldSince = null;
          _warned = false;
        }
      },
    );
    subscriber = _Subscriber(controller);
    return controller.stream;
  }

  void _schedule(Duration delay) {
    if (_stopped || _subscribers.isEmpty || _timer != null || _inFlight != null) {
      return;
    }
    _timer = Timer(delay, () {
      _timer = null;
      final running = _poll();
      _inFlight = running;
      unawaited(
        running.whenComplete(() {
          _inFlight = null;
          _schedule(pollInterval);
        }),
      );
    });
  }

  Future<void> _poll() async {
    Session? session;
    try {
      session = await openSession();
      final water = await session.db.unsafeQuery(
        'SELECT pg_snapshot_xmin(pg_current_snapshot())::text',
        timeoutInSeconds: 2,
      );
      final watermark = water.single[0] as String;
      final rows = await session.db.unsafeQuery(
        '''
SELECT (SELECT txid::text FROM activity WHERE txid < CAST(@watermark AS xid8) ORDER BY txid DESC, id DESC LIMIT 1) AS tx,
       (SELECT id::text FROM activity WHERE txid < CAST(@watermark AS xid8) ORDER BY txid DESC, id DESC LIMIT 1) AS id,
       EXISTS(SELECT 1 FROM activity WHERE txid >= CAST(@watermark AS xid8)) AS held
''',
        parameters: QueryParameters.named({'watermark': watermark}),
        timeoutInSeconds: 2,
      );
      final row = rows.single.toColumnMap();
      final tx = row['tx'] as String?;
      final current = tx == null
          ? null
          : FeedCursor(BigInt.parse(tx), BigInt.parse(row['id'] as String));
      final previous = _last;
      if (current != null &&
          (previous == null ||
              current.txid > previous.txid ||
              (current.txid == previous.txid && current.id > previous.id))) {
        _last = current;
        for (final subscriber in _subscribers.toList()) {
          if (subscriber.paused) {
            subscriber.pending = true;
          } else {
            subscriber.controller.add(FeedWakeUp());
          }
        }
      }
      if (row['held'] as bool) {
        _heldSince ??= DateTime.now();
        if (!_warned &&
            DateTime.now().difference(_heldSince!) >=
                const Duration(seconds: 30)) {
          log('feed watermark held back for more than 30 seconds');
          _warned = true;
        }
      } else {
        _heldSince = null;
        _warned = false;
      }
      _failed = false;
      onPoll?.call();
    } catch (error) {
      if (!_failed) log('feed watermark poll failed: $error');
      _failed = true;
    } finally {
      await session?.close();
    }
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    await _inFlight;
    for (final subscriber in _subscribers.toList()) {
      unawaited(subscriber.controller.close());
    }
    _subscribers.clear();
  }
}

final class _Subscriber {
  _Subscriber(this.controller);
  final StreamController<FeedWakeUp> controller;
  bool paused = false;
  bool pending = false;
}
