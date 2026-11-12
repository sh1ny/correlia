@Tags(['plugin'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:correlia_server/src/plugin/output_plugin_connection.dart';
import 'package:test/test.dart';

import 'support/plugin_fixture_support.dart';

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

  Future<OutputPluginConnection> connect([String mode = 'normal']) async {
    final connection = await OutputPluginConnection.start(
      executable: executable,
      arguments: ['--mode', mode],
      configJson: config,
      secrets: secrets,
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

  test('health_call_stalls', () async {
    final connection = await connect('stall-health');
    await expectLater(
      connection.health(timeout: const Duration(milliseconds: 100)),
      throwsA(failure('plugin_health_timeout')),
    );
  });
}
