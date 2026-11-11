import 'dart:async';

import 'package:serverpod/serverpod.dart';

import '../ingest/bootstrap.dart';
import '../runtime/process_options.dart';
import '../runtime/subsystem.dart';
import 'output_relay.dart';
import 'webhook_output.dart';

/// Runs bounded independent output lanes for a worker process.
final class RelaySubsystem extends Subsystem {
  /// Creates a relay using immutable process-local bootstrap secrets.
  RelaySubsystem({
    required this.pod,
    required this.bootstrap,
    required String runMode,
    this.beforeAcquire,
    this.onUnavailable,
    this.pollInterval = const Duration(milliseconds: 250),
  }) : _webhook = WebhookOutput(runMode: runMode);
  final Serverpod pod;
  final IngestBootstrap bootstrap;

  /// Optional test barrier before acquisition; never used to configure delivery.
  final Future<void> Function()? beforeAcquire;

  /// Receives fixed unavailable-key diagnostics without secret material.
  final void Function(String, String)? onUnavailable;
  final Duration pollInterval;
  final WebhookOutput _webhook;
  final Set<String> _busy = {};
  final Set<Future<void>> _lanes = {};
  final Completer<void> _stopped = Completer<void>();
  Future<void>? _loop;
  Timer? _timer;
  Completer<void>? _wake;

  @override
  String get name => 'output-relay';
  @override
  Set<ProcessRole> get roles => {ProcessRole.worker, ProcessRole.all};

  @override
  Future<void> start() async {
    _loop = _run();
  }

  Future<void> _run() async {
    final session = await pod.createSession(enableLogging: false);
    try {
      final repository = OutputRelayRepository(
        session,
        bootstrap.secret,
        loadedReferences: bootstrap.loadedReferences,
        onUnavailable: onUnavailable,
      );
      while (!_stopped.isCompleted) {
        if (beforeAcquire != null) {
          await Future.any([beforeAcquire!(), _stopped.future]);
          if (_stopped.isCompleted) break;
        }
        try {
          await repository.recoverExpired();
          final available = await repository.discover(_busy);
          for (final output in available) {
            if (_stopped.isCompleted ||
                _lanes.length >= 64 ||
                !_busy.add(output)) {
              continue;
            }
            late Future<void> lane;
            lane = _deliver(output).whenComplete(() {
              _busy.remove(output);
              _lanes.remove(lane);
            });
            _lanes.add(lane);
          }
        } catch (_) {
          // The durable queue remains authoritative; retry on the next poll.
        }
        if (_stopped.isCompleted) break;
        _wake = Completer<void>();
        _timer = Timer(pollInterval, _wake!.complete);
        await _wake!.future;
        _timer = null;
        _wake = null;
      }
    } finally {
      await session.close();
    }
  }

  Future<void> _deliver(String output) async {
    final session = await pod.createSession(enableLogging: false);
    try {
      final repository = OutputRelayRepository(
        session,
        bootstrap.secret,
        loadedReferences: bootstrap.loadedReferences,
      );
      final claim = await repository.claim(output);
      if (claim == null || _stopped.isCompleted) return;
      final outcome = await _webhook.send(claim.intent, claim.key);
      if (!_stopped.isCompleted) await repository.complete(claim, outcome);
    } catch (_) {
      // A started claim remains durable and will be recovered after its lease.
    } finally {
      await session.close();
    }
  }

  @override
  Future<void> stop() async {
    if (!_stopped.isCompleted) _stopped.complete();
    _timer?.cancel();
    if (_wake != null && !_wake!.isCompleted) _wake!.complete();
    _webhook.close();
    await _loop;
    await Future.wait(_lanes.toList());
  }
}
