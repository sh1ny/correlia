part of 'supervisor.dart';

final class _StreamHolder {
  _StreamHolder(this.owner, this.target, this.lease, Duration sentAt) {
    _deadline.acknowledge(sentAt);
  }

  final Icinga2StreamSupervisor owner;
  StreamTarget target;
  final StreamLease lease;
  late final _backoff = StreamBackoff(random: owner._backoffRandom);
  final _ended = _Interrupt();
  late final _deadline = StreamLeaseDeadline(
    now: owner._leaseNow,
    schedule: owner._leaseSchedule,
    onLost: () {
      unawaited(stop(leaseLost: true));
    },
  );
  pg.Connection? _db;
  void Function()? _cancelRenewal;
  Future<void>? _stopFuture;
  bool _closing = false;
  bool _lost = false;
  bool _renewing = false;
  _StreamAttempt? _attempt;
  Future<StreamAdmissionResult>? _pendingStream;
  Future<StreamAdmissionResult>? _pendingSync;
  bool get _live => !_closing && _deadline.isLive;

  Future<void> run() async {
    try {
      if (!_live) return;
      final opening = owner.openDatabase(_dbDeadline);
      owner._onConsumerOpen?.call(lease.sourceId, opening);
      final db = await opening;
      if (!_live) {
        await _forceClose(db);
        return;
      }
      _db = db;
      await owner._onConsumerConnection?.call(db);
      if (!_live) return;
      _scheduleRenew(db);
      while (_live) {
        final attempt = _StreamAttempt(this, db);
        _attempt = attempt;
        await attempt.run();
        if (!_live) break;
        if (attempt.reason == 'lease_lost') {
          await stop(leaseLost: true);
          return;
        }
        if (attempt.reason == 'config_changed') continue;
        final wait = _backoff.nextDelay(connectedFor: attempt.connectedFor);
        await _ended.wait(wait, schedule: owner._backoffSchedule);
      }
    } on Object {
      if (_live) owner.log('icinga2-stream source=${lease.sourceId} database');
    } finally {
      await stop();
    }
  }

  void _scheduleRenew(pg.Connection db) {
    _cancelRenewal = (owner._leaseSchedule ?? _scheduleTimer)(
      const Duration(seconds: 10),
      () {
        if (!_live) return;
        _scheduleRenew(db);
        if (!_renewing) unawaited(_renew(db));
      },
    );
  }

  Future<void> _renew(pg.Connection db) async {
    _renewing = true;
    final sent = owner._leaseNow();
    try {
      final renewed = await StreamLeaseStore(db).renew(lease);
      if (renewed) await owner._afterRenewCommit?.call();
      if (!renewed || !_deadline.acknowledge(sent)) {
        await stop(leaseLost: true);
      }
    } on Object {
      // An unknown acknowledgement cannot extend the already-armed deadline.
    } finally {
      _renewing = false;
    }
  }

  void update(StreamTarget next) {
    if (_closing || target.snapshotId == next.snapshotId) return;
    final equivalent = target._sameConnection(next);
    target = next;
    if (!equivalent) _attempt?.close('config_changed');
  }

  Future<StreamAdmissionResult> admit(
    ConsumerAdmission db,
    _StreamAttempt attempt,
    StreamRawBatch batch, {
    required bool sync,
  }) async {
    await owner._beforeAdmit?.call();
    var snapshot = target.snapshotId;
    while (_live && !attempt.closed) {
      final operation = db.admit(
        lease: lease,
        snapshotId: snapshot,
        batch: batch,
      );
      if (sync) {
        _pendingSync = operation;
      } else {
        _pendingStream = operation;
      }
      final StreamAdmissionResult result;
      try {
        result = await operation;
      } finally {
        if (sync) {
          _pendingSync = null;
        } else {
          _pendingStream = null;
        }
      }
      if (result == StreamAdmissionResult.configChanged &&
          _live &&
          !attempt.closed) {
        await owner._refresh();
        if (snapshot == target.snapshotId || attempt.closed) return result;
        snapshot = target.snapshotId;
        continue;
      }
      if (result == StreamAdmissionResult.atCapacity) {
        attempt.paused = true;
        await attempt.state(StreamConsumerState.paused);
      } else if (result == StreamAdmissionResult.committed && attempt.paused) {
        attempt.paused = false;
        await attempt.state(
          attempt.syncReader == null
              ? StreamConsumerState.connected
              : StreamConsumerState.syncing,
        );
      }
      return result;
    }
    return StreamAdmissionResult.leaseLost;
  }

  Future<void> stop({bool leaseLost = false}) {
    _lost |= leaseLost;
    return _stopFuture ??= _stop();
  }

  Future<void> _stop() async {
    _closing = true;
    _ended.close();
    _deadline.close();
    _cancelRenewal?.call();
    final attempt = _attempt;
    attempt?.close(_lost ? 'lease_lost' : 'stopped');
    final db = _db;
    if (db != null) {
      final pending = [
        _pendingStream,
        _pendingSync,
      ].whereType<Future<StreamAdmissionResult>>();
      try {
        await Future.wait(pending).timeout(_socketStop);
      } on Object {
        // Abort the dedicated socket even if admission never acknowledged.
      }
      unawaited(_forceClose(db));
    }
    if (_lost) return;
    pg.Connection? fresh;
    try {
      fresh = await owner.openDatabase(_dbDeadline);
      final statuses = StreamStatusStore(fresh);
      final progress = SyncProgressStore(fresh);
      if (attempt?.syncId case final id?) {
        await progress.finish(
          lease,
          id,
          const SyncReadReport(problem: SyncReadProblem.interrupted),
          timeout: _dbDeadline,
        );
      }
      final released = await statuses.stopAndRelease(lease);
      owner.log(
        'icinga2-stream source=${lease.sourceId} ${released ? 'stopped' : 'lease expires'}',
      );
    } on Object {
      owner.log('icinga2-stream source=${lease.sourceId} lease expires');
    } finally {
      if (fresh != null) unawaited(_forceClose(fresh));
    }
  }
}

// One waiter at a time. Timed-out polls must not stay attached to a connection
// that can remain quiet for days.
final class _Interrupt {
  bool closed = false;
  Completer<void>? _pending;

  Future<void> wait(Duration duration, {ReaderScheduler? schedule}) async {
    if (closed || duration <= Duration.zero) return;
    final done = _pending = Completer<void>();
    final cancel = (schedule ?? _scheduleTimer)(duration, done.complete);
    try {
      await done.future;
    } finally {
      cancel();
      _pending = null;
    }
  }

  void close() {
    closed = true;
    final pending = _pending;
    if (pending != null && !pending.isCompleted) pending.complete();
  }
}

void Function() _scheduleTimer(Duration duration, void Function() fire) =>
    Timer(duration, fire).cancel;

final class _StreamAttempt {
  _StreamAttempt(this.holder, this.db)
    : statuses = StreamStatusStore(db),
      progress = SyncProgressStore(db),
      admission = ConsumerAdmission(
        db,
        beforeCommit: holder.owner._beforeAdmissionCommit,
      );

  final _StreamHolder holder;
  final pg.Connection db;
  final StreamStatusStore statuses;
  final SyncProgressStore progress;
  final ConsumerAdmission admission;
  final _closed = _Interrupt();
  final id = const Uuid().v4();
  final _redactorBytes = Uint8List(0);
  IcingaStreamHttpClient? _http;
  StreamReader? _reader;
  SyncReader? syncReader;
  String? syncId;
  int? _seq;
  String? reason;
  bool paused = false;
  Future<void>? _numbering;
  Duration? _connectedAt;
  Duration connectedFor = Duration.zero;
  StreamConsumerState? _state;
  String? _stateProblem;
  bool _oversize = false;
  DateTime? _lastEvent;
  DateTime? _persistedEvent;
  Duration? _lastLag;
  bool get closed => _closed.closed;
  bool get _live => !closed && holder._live;
  StreamLease get _lease => holder.lease;

  DecodeRequest _request() {
    final target = holder.target;
    final now = DateTime.now().toUtc();
    final at = EventTimestamp.parse(now.toIso8601String());
    return DecodeRequest(
      bytes: _redactorBytes,
      sourceInstance: target.sourceId,
      namespace: target.namespace,
      excludedLabels: target.excludedLabels,
      rawRef:
          'raw:2000-01-01T00:00:00.999999Z/00000000-0000-4000-8000-000000000000',
      rawSha256:
          '0000000000000000000000000000000000000000000000000000000000000000',
      observedAt: at,
      processedAt: at,
      configVersion: target.snapshotId,
    );
  }

  Future<void> run() async {
    Future<void>? sync;
    try {
      await state(StreamConsumerState.connecting);
      if (!_live) return;
      final target = holder.target;
      final http = _http = IcingaStreamHttpClient(
        endpoint: target.options.url,
        username: target.options.username,
        password: target.password,
        ca: target.ca,
        isLive: () => _live,
        headerDeadline: holder.owner._headerDeadline,
      );
      final response = await http.subscribe(
        _lease.sourceId,
        authorize: () => _numbering = _numberConnection(),
      );
      if (!_live) return;
      final password = target.password;
      final redactor = PasswordRedactor(
        password is Uint8List ? password : Uint8List.fromList(password),
        basicToken: http.basicToken,
      );
      _reader = StreamReader(
        request: _request(),
        policy: target.options.stateTypePolicy,
        redactor: redactor,
        monotonic: holder.owner._readerClock,
        schedule: holder.owner._readerSchedule,
        connectionId: id,
        admit: (batch) => holder.admit(admission, this, batch, sync: false),
        onObservation: (at, lag) {
          _lastEvent = at;
          _lastLag = lag;
        },
        onOversize: () async {
          _oversize = true;
          await statuses.recordOversize(_lease);
        },
      );
      final reading = _reader!.run(response.body);
      sync = _syncLoop(http, redactor);
      final ended = await reading;
      close(switch (ended) {
        StreamReadEnd.leaseLost => 'lease_lost',
        StreamReadEnd.configChanged => 'config_changed',
        StreamReadEnd.receiptBehindCutoff => 'receipt_behind_cutoff',
        _ => ended.name,
      });
    } on StreamHttpFailure catch (error) {
      close(error.code);
    } on Object {
      close('transport');
    } finally {
      close('stopped');
      if (holder._live) {
        try {
          await _numbering?.timeout(_dbDeadline);
        } on TimeoutException {
          // A successor may not race a still-committing sequence allocation.
          await holder.stop(leaseLost: true);
        } on Object {
          // A future allocation consults the durable watermark, not our ack.
        }
      }
      if (holder._live) {
        await sync;
        if (_seq case final seq?) await statuses.recordGap(_lease, seq);
        await state(StreamConsumerState.backoff, error: reason);
      }
      if (_connectedAt case final connected?) {
        connectedFor = holder.owner._watch.elapsed - connected;
      }
    }
  }

  Future<void> _numberConnection() async {
    while (_live) {
      final expected = holder.target.snapshotId;
      try {
        _seq = await statuses.startConnection(
          _lease,
          id,
          snapshotId: expected,
          beforeCommit: holder.owner._beforeNumberCommit,
        );
        if (_seq == null) throw const StreamHttpFailure('lease_lost');
        return;
      } on StreamTargetChanged {
        await holder.owner._refresh();
        if (closed || holder.target.snapshotId == expected) {
          throw const StreamHttpFailure('config_changed');
        }
      }
    }
    throw const StreamHttpFailure('interrupted');
  }

  void close(String cause) {
    if (closed) return;
    reason = cause;
    _closed.close();
    _reader?.stop();
    syncReader?.stop();
    _http?.close();
  }

  Future<void> state(StreamConsumerState value, {String? error}) async {
    if (!holder._live || (_state == value && _stateProblem == error)) return;
    _state = value;
    _stateProblem = error;
    if (await statuses.setState(
      _lease,
      value,
      errorClass: error,
      connectionId: _seq == null ? null : id,
    )) {
      holder.owner.log(
        'icinga2-stream source=${_lease.sourceId} ${value.name}${error == null ? '' : ' $error'}',
      );
    } else {
      close('lease_lost');
    }
  }

  Future<void> _syncLoop(
    IcingaStreamHttpClient http,
    PasswordRedactor redactor,
  ) async {
    var due = true;
    var next = Duration.zero;
    try {
      while (_live) {
        final now = holder.owner._watch.elapsed;
        var waitFor = holder.owner.revisionInterval;
        await progress.markStalled(_lease);
        if (!_live) return;
        if (_lastEvent case final at? when at != _persistedEvent) {
          if (!await statuses.recordObservation(_lease, at, _lastLag)) {
            close('lease_lost');
            return;
          }
          _persistedEvent = at;
        }
        if (!paused &&
            (due || _oversize || now >= next || await _requested())) {
          final start = await progress.start(_lease, connectionId: id);
          holder.owner._onSyncDecision?.call(start.disposition);
          if (!_live) return;
          switch (start.disposition) {
            case SyncStartDisposition.leaseLost:
              close('lease_lost');
              return;
            case SyncStartDisposition.started:
              _oversize = false;
              due = false;
              final started = holder.owner._watch.elapsed;
              final target = holder.target;
              next = started + target.options.syncInterval;
              final current = syncId = start.syncId!;
              await state(StreamConsumerState.syncing);
              if (!_live) return;
              final reader = syncReader = SyncReader(
                request: _request(),
                policy: target.options.stateTypePolicy,
                redactor: redactor,
                monotonic: holder.owner._readerClock,
                schedule: holder.owner._readerSchedule,
                connectionId: id,
                syncId: current,
                open: http.query,
                admit: (batch) =>
                    holder.admit(admission, this, batch, sync: true),
                log: (message) => holder.owner.log(
                  'icinga2-stream source=${_lease.sourceId} $message',
                ),
              );
              final report = await reader.run();
              syncReader = null;
              if (!holder._live) return;
              if (!await progress.finish(_lease, current, report)) {
                close('lease_lost');
                return;
              }
              syncId = null;
              final String? closeCode = switch (report.problem) {
                null ||
                SyncReadProblem.invalidObject ||
                SyncReadProblem.objectError ||
                SyncReadProblem.objectTooLarge => null,
                final problem => problem.wire,
              };
              if (closeCode != null) {
                close(closeCode);
                return;
              }
              if (!_live) return;
              _connectedAt ??= holder.owner._watch.elapsed;
              await state(
                paused
                    ? StreamConsumerState.paused
                    : StreamConsumerState.connected,
                error: report.problem?.wire,
              );
            case SyncStartDisposition.tooSoon:
              if (start.retryAfter case final remaining?
                  when remaining < waitFor) {
                waitFor = remaining;
              }
            case SyncStartDisposition.busy || SyncStartDisposition.paused:
              break;
          }
        }
        await _closed.wait(waitFor);
      }
    } on Object {
      close('database');
    }
  }

  Future<bool> _requested() async {
    final rows = await db.execute(
      pg.Sql.named('''
      SELECT 1 FROM icinga2_stream_resync r JOIN icinga2_stream_status s USING ("sourceId")
      WHERE r."sourceId"=@source:uuid AND r."requestSeq">s."servedResyncSeq"
    '''),
      parameters: {'source': _lease.sourceId},
    );
    return rows.isNotEmpty;
  }
}
