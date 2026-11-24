import 'dart:async';
import 'dart:typed_data';

import 'package:postgres/postgres.dart' as pg;
import 'package:uuid/uuid.dart';

import '../../../event/event_timestamp.dart';
import '../../../state/tombstone_sweep.dart';
import '../../bootstrap.dart';
import '../../source_decoder.dart';
import 'admission.dart';
import 'database.dart';
import 'https_client.dart';
import 'lease.dart';
import 'read_timing.dart';
import 'redaction.dart';
import 'status.dart';
import 'stream_reader.dart';
import 'sync_progress.dart';
import 'sync_reader.dart';
import 'sync_result.dart';

part 'stream_holder.dart';

const _dbDeadline = Duration(seconds: 1);
const _socketStop = Duration(seconds: 4);
const _stopDeadline = Duration(seconds: 10);

/// One enabled, resolved source in the active immutable configuration.
final class StreamTarget {
  const StreamTarget({
    required this.sourceId,
    required this.snapshotId,
    required this.namespace,
    required this.options,
    required this.password,
    required this.ca,
    this.excludedLabels = const [],
  });

  final String sourceId;
  final String snapshotId;
  final String namespace;
  final IcingaStreamOptions options;
  final List<int> password;
  final List<int> ca;
  final List<String> excludedLabels;

  bool _sameConnection(StreamTarget other) =>
      namespace == other.namespace &&
      _same(excludedLabels, other.excludedLabels) &&
      options.url == other.options.url &&
      options.username == other.options.username &&
      options.passwordRef == other.options.passwordRef &&
      options.caRef == other.options.caRef &&
      options.syncInterval == other.options.syncInterval &&
      options.stateTypePolicy == other.options.stateTypePolicy &&
      options.maxPendingRows == other.options.maxPendingRows &&
      _same(password, other.password) &&
      _same(ca, other.ca);
}

bool _same<T>(List<T> left, List<T> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}

/// An active stream source lacks a stored password or CA commitment.
final class StreamTargetSecretMissing implements Exception {
  const StreamTargetSecretMissing(this.sourceId, this.credential);

  final String sourceId;
  final String credential;
}

/// Owns worker-local Icinga consumers and their dedicated database connections.
final class Icinga2StreamSupervisor {
  Icinga2StreamSupervisor({
    required this.loadTargets,
    required this.openDatabase,
    required this.holder,
    required this.log,
    this.revisionInterval = const Duration(seconds: 30),
    String runMode = 'production',
    Future<void> Function(pg.TxSession)? beforeAdmissionCommit,
    Future<void> Function(pg.Connection)? onConsumerConnection,
    Future<void> Function(pg.TxSession)? beforeSweepCommit,
    Duration Function()? readerClockForTest,
    ReaderScheduler? readerScheduleForTest,
    Duration Function()? leaseClockForTest,
    ReaderScheduler? leaseScheduleForTest,
    ReaderScheduler? backoffScheduleForTest,
    double Function()? backoffRandomForTest,
    Future<void> Function()? afterRenewCommitForTest,
    Future<void> Function()? beforeAdmitForTest,
    Future<void> Function()? beforeNumberCommitForTest,
    void Function(String, Future<pg.Connection>)? onConsumerOpenForTest,
    void Function(int)? afterAcquisitionScanForTest,
    void Function()? afterRevisionPassForTest,
    void Function(SyncStartDisposition)? onSyncDecisionForTest,
    ReaderScheduler? syncScheduleForTest,
    Duration? headerDeadlineForTest,
    Future<void> Function(pg.TxSession, StreamRawBatch)? beforeRawWriteForTest,
    void Function(StreamRawBatch, pg.ServerException)? rawWriteErrorForTest,
  }) : _beforeAdmissionCommit = runMode == 'test'
           ? beforeAdmissionCommit
           : null,
       _onConsumerConnection = runMode == 'test' ? onConsumerConnection : null,
       _beforeSweepCommit = runMode == 'test' ? beforeSweepCommit : null,
       _readerClock = runMode == 'test' ? readerClockForTest : null,
       _readerSchedule = runMode == 'test' ? readerScheduleForTest : null,
       _leaseClock = runMode == 'test' ? leaseClockForTest : null,
       _leaseSchedule = runMode == 'test' ? leaseScheduleForTest : null,
       _backoffSchedule = runMode == 'test' ? backoffScheduleForTest : null,
       _backoffRandom = runMode == 'test' ? backoffRandomForTest : null,
       _afterRenewCommit = runMode == 'test' ? afterRenewCommitForTest : null,
       _beforeAdmit = runMode == 'test' ? beforeAdmitForTest : null,
       _beforeNumberCommit = runMode == 'test'
           ? beforeNumberCommitForTest
           : null,
       _onConsumerOpen = runMode == 'test' ? onConsumerOpenForTest : null,
       _onSyncDecision = runMode == 'test' ? onSyncDecisionForTest : null,
       _syncSchedule = runMode == 'test' ? syncScheduleForTest : null,
       _afterAcquisitionScan = runMode == 'test'
           ? afterAcquisitionScanForTest
           : null,
       _afterRevisionPass = runMode == 'test' ? afterRevisionPassForTest : null,
       _beforeRawWrite = runMode == 'test' ? beforeRawWriteForTest : null,
       _rawWriteError = runMode == 'test' ? rawWriteErrorForTest : null,
       _headerDeadline =
           (runMode == 'test' ? headerDeadlineForTest : null) ??
           const Duration(seconds: 10);

  final Future<List<StreamTarget>> Function() loadTargets;
  final Future<pg.Connection> Function(Duration timeout) openDatabase;
  final String holder;
  final void Function(String) log;
  final Duration revisionInterval;
  final Future<void> Function(pg.TxSession)? _beforeAdmissionCommit;
  final Future<void> Function(pg.Connection)? _onConsumerConnection;
  final Future<void> Function(pg.TxSession)? _beforeSweepCommit;
  final Duration Function()? _readerClock;
  final ReaderScheduler? _readerSchedule;
  final Duration Function()? _leaseClock;
  final ReaderScheduler? _leaseSchedule;
  final ReaderScheduler? _backoffSchedule;
  final double Function()? _backoffRandom;
  final Future<void> Function()? _afterRenewCommit;
  final Future<void> Function()? _beforeAdmit;
  final Future<void> Function()? _beforeNumberCommit;
  final void Function(String, Future<pg.Connection>)? _onConsumerOpen;
  final void Function(int)? _afterAcquisitionScan;
  final void Function()? _afterRevisionPass;
  final void Function(SyncStartDisposition)? _onSyncDecision;
  final ReaderScheduler? _syncSchedule;
  final Duration _headerDeadline;
  final Future<void> Function(pg.TxSession, StreamRawBatch)? _beforeRawWrite;
  final void Function(StreamRawBatch, pg.ServerException)? _rawWriteError;
  Duration _leaseNow() => _leaseClock?.call() ?? _watch.elapsed;
  final _watch = Stopwatch()..start();
  final _active = <String, _StreamHolder>{};
  Timer? _timer;
  pg.Connection? _maintenance;
  Future<void>? _refreshing;
  Future<void>? _pass;
  Future<void>? _shutdown;
  bool _stopping = false;

  /// Starts the revision check and acquisition loop, including an immediate pass.
  void start() {
    if (_timer != null || _stopping) return;
    _timer = Timer.periodic(revisionInterval, (_) => _schedulePass());
    _schedulePass();
  }

  void _schedulePass() {
    if (_stopping || _pass != null) return;
    _pass = _runPass().whenComplete(() {
      _pass = null;
      _afterRevisionPass?.call();
    });
  }

  Future<void> _runPass() async {
    try {
      await _refresh();
      if (_stopping) return;
      final db = await openDatabase(_dbDeadline);
      _maintenance = db;
      try {
        if (_stopping) return;
        if (!db.isOpen) return;
        final targets = _targets;
        final available = await db.execute('''
          SELECT s."sourceId"::text FROM ingest_source s
          LEFT JOIN icinga2_stream_lease l USING ("sourceId")
          WHERE s.enabled AND s.mode='event_streams'
            AND coalesce(l."expiresAt", '-infinity'::timestamp)<=clock_timestamp()
          ORDER BY s."sourceId"
        ''');
        final leases = StreamLeaseStore(db);
        for (final row in available) {
          if (_stopping) return;
          final id = row[0]! as String;
          final target = targets[id];
          if (target == null || _active.containsKey(id)) continue;
          final sentAt = _leaseNow();
          final lease = await leases.acquire(id, holder);
          if (lease == null) continue;
          if (_stopping) {
            await leases.release(lease);
            return;
          }
          final worker = _StreamHolder(this, target, lease, sentAt);
          _active[id] = worker;
          unawaited(worker.run().whenComplete(() => _active.remove(id)));
        }
        _afterAcquisitionScan?.call(targets.length);
        if (_stopping) return;
        await _prune(db);
        if (!_stopping && db.isOpen) {
          await TombstoneSweep(db, beforeCommit: _beforeSweepCommit).runOnce();
        }
      } finally {
        _maintenance = null;
        if (db.isOpen) await db.close(force: true);
      }
    } on StreamTargetSecretMissing catch (error) {
      if (!_stopping) {
        log(
          'icinga2-stream source=${error.sourceId} '
          'missing_secret_pin credential=${error.credential}',
        );
      }
    } on Object {
      if (!_stopping) log('icinga2-stream supervisor database_or_config');
    }
  }

  Map<String, StreamTarget> _targets = const {};

  Future<void> _refresh() =>
      _refreshing ??= _load().whenComplete(() => _refreshing = null);

  Future<void> _load() async {
    final targets = await loadTargets();
    if (_stopping) return;
    _targets = {for (final target in targets) target.sourceId: target};
    for (final worker in _active.values) {
      final next = _targets[worker.lease.sourceId];
      if (next == null) {
        unawaited(worker.stop());
      } else {
        worker.update(next);
      }
    }
  }

  /// Prune expired batch IDs and fully accounted syncs, not lease, status or
  /// resync rows. A re-added source continues every sequence.
  Future<void> _prune(pg.Connection db) async {
    await runStreamWrite(
      db,
      (tx) => tx.execute('''
      DELETE FROM icinga2_admitted_batch
      WHERE "admittedAt"<=clock_timestamp()-interval '1 hour'
    '''),
    );
    if (_stopping) return;
    final retired = await db.execute('''
      SELECT l."sourceId"::text, l.generation
      FROM icinga2_stream_lease l
      LEFT JOIN ingest_source s USING ("sourceId")
      LEFT JOIN icinga2_stream_status st USING ("sourceId")
      WHERE NOT coalesce(s.enabled,false) AND l."expiresAt"<=clock_timestamp()
        AND (st.state NOT IN ('retired','stopped') OR EXISTS (
          SELECT 1 FROM icinga2_sync_progress p
          WHERE p.source_id=l."sourceId" AND p.read_end_at IS NULL
        ))
    ''');
    final progress = SyncProgressStore(db);
    for (final row in retired) {
      if (_stopping) return;
      await progress.retire(row[0]! as String, generation: row[1]! as int);
    }
    if (_stopping) return;
    await runStreamWrite(
      db,
      (tx) => tx.execute('''
      DELETE FROM icinga2_sync_progress
      WHERE read_end_at IS NOT NULL AND ended_at<=clock_timestamp()-interval '$streamSyncRetentionDays days'
        AND rows_done+rows_failed=rows_admitted
    '''),
    );
  }

  /// Cancels maintenance and all consumers concurrently, with one local deadline.
  Future<void> stop() => _shutdown ??= _stop();

  Future<void> _stop() async {
    _stopping = true;
    _timer?.cancel();
    final maintenance = _maintenance;
    if (maintenance != null) unawaited(_forceClose(maintenance));
    final stopping = [for (final worker in _active.values) worker.stop()];
    try {
      await Future.wait(stopping).timeout(_stopDeadline);
    } on TimeoutException {
      log('icinga2-stream stop deadline');
    }
  }
}

Future<void> _forceClose(pg.Connection connection) async {
  try {
    if (connection.isOpen) await connection.close(force: true);
  } on Object {
    // The socket is already unusable. Lease expiry is the safe fallback.
  }
}
