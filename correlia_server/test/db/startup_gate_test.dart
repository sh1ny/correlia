@Tags(['db'])
library;

import 'dart:async';
import 'dart:io';

import 'package:correlia_server/src/runtime/process_options.dart';
import 'package:correlia_server/src/runtime/role_runtime.dart';
import 'package:correlia_server/src/runtime/subsystem.dart';
import 'package:test/test.dart';

import '../support/pod_fixture.dart';

/// A subsystem whose [start] blocks until the test releases [gate].
final class _GatedSubsystem extends Subsystem {
  final Completer<void> entered = Completer<void>();
  final Completer<void> gate = Completer<void>();

  @override
  String get name => 'gated';

  @override
  Set<ProcessRole> get roles => {ProcessRole.all};

  @override
  Future<void> start() async {
    entered.complete();
    await gate.future;
  }

  @override
  Future<void> stop() async {}
}

Future<int> _statusOf(int port, String path) async {
  final client = HttpClient();
  try {
    final request = await client.get('localhost', port, path);
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

void main() {
  group('Given a role with a subsystem that is still starting', () {
    late PodFixture fixture;
    final subsystem = _GatedSubsystem();

    setUp(() async => fixture = await PodFixture.create([subsystem]));
    tearDown(() => fixture.shutdown());

    test('startupz stays 503 until the gated subsystem has started', () async {
      final started = fixture.start();
      await subsystem.entered.future.timeout(const Duration(seconds: 120));

      expect(await _statusOf(fixture.apiPort, '/startupz'), 503);

      subsystem.gate.complete();
      expect(await started, isA<Started>());
      expect(await _statusOf(fixture.apiPort, '/startupz'), 200);
    });
  });
}
