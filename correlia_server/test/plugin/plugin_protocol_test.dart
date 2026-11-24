@Tags(['plugin'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:correlia_server/src/plugin/output_plugin_connection.dart';
import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

import 'support/plugin_fixture_support.dart';

final class _HealthOptionsProbe extends ClientInterceptor {
  Duration? deadline;
  Future<void> Function()? cancel;

  @override
  ResponseFuture<R> interceptUnary<Q, R>(
    ClientMethod<Q, R> method,
    Q request,
    CallOptions options,
    ClientUnaryInvoker<Q, R> invoker,
  ) {
    if (!method.path.endsWith('/CheckHealth')) {
      return invoker(method, request, options);
    }
    deadline = options.timeout;
    // Keep the real call open while the test drives the normal Dart watchdog.
    final rpc = invoker(
      method,
      request,
      CallOptions(metadata: options.metadata),
    );
    cancel = rpc.cancel;
    return rpc;
  }
}

final class _ManualTimer implements Timer {
  _ManualTimer(this._run);

  void Function()? _run;

  void fire() {
    final run = _run!;
    cancel();
    run();
  }

  @override
  void cancel() => _run = null;

  @override
  bool get isActive => _run != null;

  @override
  int get tick => isActive ? 0 : 1;
}

void main() {
  late PluginFixtureSuite suite;
  late String executable;
  late String spike;
  final connections = <OutputPluginConnection>[];
  final config = utf8.encode('{"subject":"alerts"}');
  final secrets = <String, List<int>>{'token': utf8.encode('fixture-secret')};

  setUpAll(() async {
    suite = PluginFixtureSuite.create();
    final build = await suite.build();
    executable = build.binaries[PluginFixtureBinary.outputProduction]!.path;
    spike = build.binaries[PluginFixtureBinary.plainStock]!.path;
  });
  tearDown(() async {
    for (final connection in connections.reversed) {
      await connection.stop();
    }
    connections.clear();
  });
  tearDownAll(() async => suite.dispose());

  Future<OutputPluginConnection> connect([
    String mode = 'normal',
    String? healthMarker,
    _HealthOptionsProbe? healthOptions,
  ]) async {
    final connection = await OutputPluginConnection.start(
      executable: executable,
      arguments: [
        '--mode',
        mode,
        if (healthMarker != null) ...['--health-marker', healthMarker],
      ],
      configJson: config,
      secrets: secrets,
      healthInterceptorForTest: healthOptions,
    );
    connections.add(connection);
    return connection;
  }

  OutputPluginEvent event(String id) =>
      OutputPluginEvent(id, utf8.encode('bytes-$id'));
  Matcher failure(String name) => isA<OutputPluginException>().having(
    (e) => e.errorClass,
    'error class',
    name,
  );

  test('output_plugin_identifies_itself', () async {
    final connection = await connect();
    expect(connection.metadata.name, 'fixture');
    expect(connection.metadata.version, '1.0');
    expect(connection.metadata.kinds, contains('output'));
  });

  test('plugin_without_output_kind', () async {
    for (final mode in ['source', 'large-metadata']) {
      await expectLater(
        connect(mode),
        throwsA(failure('plugin_metadata_invalid')),
      );
    }
  });

  test('spike_probe_cookie_rejected', () async {
    final journal = File('${suite.scratchDirectory.path}/spike-rejected.jsonl');
    final arguments = PluginFixtureArguments(
      journalPath: journal.path,
      tlsMode: PluginFixtureTlsMode.required,
    );
    await expectLater(
      OutputPluginConnection.start(
        executable: spike,
        arguments: arguments.toArguments(),
        configJson: config,
        secrets: secrets,
      ),
      throwsA(failure('plugin_handshake_error')),
    );
    expect(await journal.exists() ? await journal.readAsString() : '', isEmpty);
  });

  test('accepted_configuration', () async {
    final connection = await connect();
    expect(connection.limits.maxEvents, 64);
    expect(connection.limits.maxBytes, 1048576);
    expect(connection.limits.maxOutstanding, 2);
    expect(connection.configurationInfo, {
      'stream': 'ALERTS',
      'duplicate_window_ms': '120000',
    });
    expect(
      () => connection.configurationInfo['stream'] = 'changed',
      throwsUnsupportedError,
    );
    final result = await connection.deliver([event('one')]);
    expect(result.single.outcome, OutputPluginOutcome.acknowledged);
    final boundary = await connect('info-boundary');
    expect(boundary.configurationInfo.length, 8);
    expect(utf8.encode(boundary.configurationInfo['a' * 64]!).length, 256);
    for (final mode in [
      'info-count',
      'info-key',
      'info-long-key',
      'info-value',
      'accept-class',
      'accept-fields',
    ]) {
      await expectLater(
        connect(mode),
        throwsA(failure('plugin_protocol_error')),
      );
    }
    await expectLater(
      connect('info-oversized'),
      throwsA(failure('plugin_metadata_invalid')),
    );
  });

  test('rejected_configuration', () async {
    await expectLater(
      OutputPluginConnection.start(
        executable: executable,
        configJson: config,
        secrets: const {},
      ),
      throwsA(
        isA<OutputPluginException>()
            .having((e) => e.errorClass, 'class', 'plugin_config_rejected')
            .having((e) => e.fields, 'fields', contains('token')),
      ),
    );
    await expectLater(
      OutputPluginConnection.start(
        executable: executable,
        configJson: utf8.encode('{"subject":"alerts","unknown":true}'),
        secrets: secrets,
      ),
      throwsA(
        isA<OutputPluginException>()
            .having((e) => e.errorClass, 'class', 'plugin_config_rejected')
            .having((e) => e.fields, 'fields', contains('unknown')),
      ),
    );
    await expectLater(
      connect('reject-class'),
      throwsA(
        isA<OutputPluginException>()
            .having((e) => e.errorClass, 'class', 'plugin_config_rejected')
            .having(
              (e) => e.pluginErrorClass,
              'plugin class',
              'stream_missing',
            ),
      ),
    );
    await expectLater(
      OutputPluginConnection.start(
        executable: executable,
        arguments: ['--mode', 'reject-secret'],
        configJson: config,
        secrets: {...secrets, 'sensitive': utf8.encode('auth')},
      ),
      throwsA(
        isA<OutputPluginException>()
            .having((e) => e.errorClass, 'class', 'plugin_config_rejected')
            .having((e) => e.pluginErrorClass, 'secret-scrubbed class', isNull),
      ),
    );
    for (final mode in ['reject-invalid-class', 'reject-info']) {
      await expectLater(
        connect(mode),
        throwsA(failure('plugin_protocol_error')),
      );
    }
  });

  test('batches_within_limits', () async {
    final connection = await connect('hold-two');
    final first = connection.deliver([
      for (var i = 0; i < 64; i++) event('first-$i'),
    ]);
    final second = connection.deliver([event('second')]);
    expect(() => connection.deliver([event('third')]), throwsStateError);
    expect((await first).length, 64);
    expect((await second).single.outcome, OutputPluginOutcome.acknowledged);
    expect(
      () =>
          connection.deliver([for (var i = 0; i < 65; i++) event('large-$i')]),
      throwsArgumentError,
    );
    expect(
      () => connection.deliver([
        OutputPluginEvent('bytes', List.filled(1048577, 0)),
      ]),
      throwsArgumentError,
    );
  });

  test('plugin_limits_above_host_bounds', () async {
    final connection = await connect('large-limits');
    expect(connection.limits.maxEvents, 64);
    expect(
      () => connection.deliver([for (var i = 0; i < 65; i++) event('$i')]),
      throwsArgumentError,
    );
    expect(
      await connection.deliver([for (var i = 0; i < 64; i++) event('$i')]),
      hasLength(64),
    );
  });

  test('mixed_outcomes_in_one_batch', () async {
    final connection = await connect('mixed');
    final results = await connection.deliver([
      event('one'),
      event('two'),
      event('three'),
    ]);
    expect(results.map((r) => r.outcome), [
      OutputPluginOutcome.acknowledged,
      OutputPluginOutcome.retryable,
      OutputPluginOutcome.rejected,
    ]);
    expect(results.map((r) => r.errorClass), [
      '',
      'publish_timeout',
      'payload_too_large',
    ]);
    expect(results.map((r) => r.id), ['one', 'two', 'three']);
  });

  test('malformed_batch_answer', () async {
    for (final mode in ['missing', 'unknown', 'duplicate']) {
      final connection = await connect(mode);
      await expectLater(
        connection.deliver([event('one'), event('two')]),
        throwsA(failure('plugin_protocol_error')),
      );
      expect((await connection.failure).errorClass, 'plugin_protocol_error');
    }
    final repeated = await connect('repeated-sequence');
    await repeated.deliver([event('one')]);
    expect((await repeated.failure).errorClass, 'plugin_protocol_error');
  });

  test('plugin_reports_serving', () async {
    final connection = await connect();
    expect((await connection.health()).serving, isTrue);
  });

  Future<File> watchHealthMarker() async {
    final directory = await suite.scratchDirectory.createTemp('health-');
    return File('${directory.path}/entered');
  }

  Future<void> waitForHealthMarker(
    File marker,
    OutputPluginConnection connection,
    Future<void> result,
  ) async {
    final events = StreamIterator(marker.parent.watch());
    var next = events.moveNext();
    addTearDown(events.cancel);
    final ended = result.then<bool>(
      (_) => throw StateError('Health finished before Go entered the RPC'),
    )..ignore();
    try {
      while (!marker.existsSync()) {
        if (!await Future.any([next, ended])) fail('Go RPC observer closed');
        next = events.moveNext();
      }
      expect(await marker.readAsString(), '${connection.pid}');
    } finally {
      await events.cancel();
    }
  }

  Future<void> stagedHealth({
    required Duration requested,
    required Duration expected,
    bool loseConnection = false,
  }) async {
    final marker = await watchHealthMarker();
    final connection = await connect('stall-health', marker.path);
    var transportFailed = false;
    unawaited(connection.failure.then<void>((_) => transportFailed = true));
    var nativeCompleted = false;
    var watchdogFired = false;
    final fire = Completer<void>();
    final watchdog = TimeoutException('fixture health watchdog');
    final result = expectLater(
      connection.health(
        timeout: requested,
        observeCallForTest: (rpc, deadline) async {
          expect(deadline, expected);
          unawaited(
            rpc.then<void>(
              (_) => nativeCompleted = true,
              onError: (Object _, StackTrace _) => nativeCompleted = true,
            ),
          );
          await fire.future;
          watchdogFired = true;
          throw watchdog;
        },
      ),
      throwsA(
        failure(
          loseConnection ? 'plugin_connection_lost' : 'plugin_health_timeout',
        ),
      ),
    );
    result.ignore();
    Future<void> finish() async {
      if (!fire.isCompleted) fire.complete();
      await result;
    }

    addTearDown(finish);
    try {
      await waitForHealthMarker(marker, connection, result);
      expect(nativeCompleted, isFalse);
      expect(transportFailed, isFalse);
      if (loseConnection) {
        expect(Process.killPid(connection.pid!, ProcessSignal.sigkill), isTrue);
        expect(await connection.failure, failure('plugin_connection_lost'));
      }
    } finally {
      await finish();
    }
    expect(watchdogFired, isTrue);
  }

  test(
    'health_call_stalls',
    () => stagedHealth(
      requested: const Duration(milliseconds: 100),
      expected: const Duration(milliseconds: 100),
    ),
  );

  for (final (requested, deadline) in [
    (const Duration(milliseconds: 321), const Duration(milliseconds: 321)),
    (const Duration(seconds: 20), const Duration(seconds: 2)),
  ]) {
    test(
      'normal_health_applies_rpc_and_watchdog_deadlines_$requested',
      () async {
        final marker = await watchHealthMarker();
        final probe = _HealthOptionsProbe();
        final connection = await connect('stall-health', marker.path, probe);
        _ManualTimer? timer;
        final health = runZoned(
          () => connection.health(timeout: requested),
          zoneSpecification: ZoneSpecification(
            createTimer: (self, parent, zone, delay, run) {
              if (delay != deadline) {
                return parent.createTimer(zone, delay, run);
              }
              expect(timer, isNull, reason: 'exactly one Dart health watchdog');
              return timer = _ManualTimer(run);
            },
          ),
        );
        final result = expectLater(
          health,
          throwsA(failure('plugin_health_timeout')),
        );
        result.ignore();
        addTearDown(() async {
          timer?.cancel();
          await probe.cancel?.call();
        });
        await waitForHealthMarker(marker, connection, result);
        expect(probe.deadline, deadline);
        expect(timer?.isActive, isTrue);
        timer!.fire();
        await result;
      },
    );
  }

  test(
    'health_connection_lost_during_call',
    () => stagedHealth(
      requested: const Duration(seconds: 2),
      expected: const Duration(seconds: 2),
      loseConnection: true,
    ),
  );
}
