import 'dart:async';

import 'package:correlia_server/src/runtime/process_options.dart';
import 'package:correlia_server/src/runtime/role_runtime.dart';
import 'package:correlia_server/src/runtime/startup_state.dart';
import 'package:correlia_server/src/runtime/subsystem.dart';
import 'package:serverpod/serverpod.dart' show Route;
import 'package:test/test.dart';

final class _FakeSubsystem extends Subsystem {
  _FakeSubsystem(
    this.name,
    this.roles,
    this.events, {
    this.failStart,
    this.failStop,
  });

  @override
  final String name;
  @override
  final Set<ProcessRole> roles;
  final List<String> events;
  final Object? failStart;
  final Object? failStop;
  Completer<void>? startGate;

  @override
  void mountRoutes(RouteHost host) => events.add('mount $name');

  @override
  Future<void> start() async {
    events.add('start $name');
    await startGate?.future;
    if (failStart case final Object error) throw error;
  }

  @override
  Future<void> stop() async {
    events.add('stop $name begin');
    await Future<void>.value();
    if (failStop case final Object error) throw error;
    events.add('stop $name end');
  }
}

final class _NoRoutes implements RouteHost {
  @override
  void addRoute(Route route, String path) {}
}

final class _FakePort implements ServerpodPort {
  _FakePort(this.events, {this.failStart});

  final List<String> events;
  final Object? failStart;
  final List<Future<void> Function()> shutdownTasks = [];

  @override
  void mountRoutes(Subsystem subsystem) => subsystem.mountRoutes(_NoRoutes());

  @override
  Future<void> start() async {
    events.add('pod start');
    if (failStart case final Object error) throw error;
  }

  @override
  void addShutdownTask(Future<void> Function() task) {
    events.add('register shutdown');
    shutdownTasks.add(task);
  }
}

const _api = {ProcessRole.api, ProcessRole.all};
const _worker = {ProcessRole.worker, ProcessRole.all};

({RoleRuntime runtime, _FakePort port, StartupState state, List<String> logs})
_build(
  ProcessRole role,
  List<Subsystem> Function(List<String> events) registry,
  List<String> events, {
  Object? podFailure,
}) {
  final port = _FakePort(events, failStart: podFailure);
  final state = StartupState();
  final logs = <String>[];
  final runtime = RoleRuntime(
    role: role,
    registry: registry(events),
    port: port,
    startup: state,
    log: logs.add,
  );
  return (runtime: runtime, port: port, state: state, logs: logs);
}

void main() {
  test('only the role subsystems start, in registry order', () async {
    final events = <String>[];
    final b = _build(
      ProcessRole.worker,
      (e) => [
        _FakeSubsystem('console', _api, e),
        _FakeSubsystem('background', _worker, e),
        _FakeSubsystem('other', _worker, e),
      ],
      events,
    );
    expect(await b.runtime.start(), isA<Started>());
    expect(events, [
      'mount background',
      'mount other',
      'pod start',
      'register shutdown',
      'start background',
      'start other',
    ]);
  });

  test(
    'all starts every subsystem and mounts routes before pod start',
    () async {
      final events = <String>[];
      final b = _build(
        ProcessRole.all,
        (e) => [
          _FakeSubsystem('console', _api, e),
          _FakeSubsystem('background', _worker, e),
        ],
        events,
      );
      await b.runtime.start();
      expect(events, [
        'mount console',
        'mount background',
        'pod start',
        'register shutdown',
        'start console',
        'start background',
      ]);
    },
  );

  test(
    'a failing start names the subsystem and maps to a non-zero exit',
    () async {
      final events = <String>[];
      final b = _build(
        ProcessRole.all,
        (e) => [
          _FakeSubsystem('console', _api, e),
          _FakeSubsystem(
            'background',
            _worker,
            e,
            failStart: StateError('boom'),
          ),
        ],
        events,
      );
      final result = await b.runtime.start();
      expect(result, isA<StartFailed>());
      final failed = result as StartFailed;
      expect(failed.component, 'background');
      expect(failed.message, contains('background'));
      expect(failed.exitCode, isNonZero);
      expect(b.state.isReady, isFalse);
    },
  );

  test('a failing Serverpod start is reported as serverpod', () async {
    final events = <String>[];
    final b = _build(
      ProcessRole.api,
      (e) => [],
      events,
      podFailure: StateError('x'),
    );
    final result = await b.runtime.start() as StartFailed;
    expect(result.component, 'serverpod');
    expect(b.port.shutdownTasks, isEmpty);
  });

  test(
    'registers exactly one shutdown callback, before the first start',
    () async {
      final events = <String>[];
      final b = _build(
        ProcessRole.all,
        (e) => [
          _FakeSubsystem('a', _api, e),
          _FakeSubsystem('b', _worker, e),
        ],
        events,
      );
      await b.runtime.start();
      expect(b.port.shutdownTasks, hasLength(1));
      expect(
        events.indexOf('register shutdown'),
        lessThan(events.indexOf('start a')),
      );
    },
  );

  test('stops subsystems one at a time in reverse start order', () async {
    final events = <String>[];
    final b = _build(
      ProcessRole.all,
      (e) => [
        _FakeSubsystem('a', _api, e),
        _FakeSubsystem('b', _api, e),
        _FakeSubsystem('c', _api, e),
      ],
      events,
    );
    await b.runtime.start();
    events.clear();
    await b.port.shutdownTasks.single();
    expect(events, [
      'stop c begin',
      'stop c end',
      'stop b begin',
      'stop b end',
      'stop a begin',
      'stop a end',
    ]);
  });

  test('only subsystems that started are stopped', () async {
    final events = <String>[];
    final b = _build(
      ProcessRole.all,
      (e) => [
        _FakeSubsystem('a', _api, e),
        _FakeSubsystem('b', _api, e, failStart: StateError('boom')),
        _FakeSubsystem('c', _api, e),
      ],
      events,
    );
    expect(await b.runtime.start(), isA<StartFailed>());
    events.clear();
    await b.port.shutdownTasks.single();
    expect(events, ['stop a begin', 'stop a end']);
  });

  test(
    'a failing stop is logged, the rest still stop, a combined error is rethrown',
    () async {
      final events = <String>[];
      final b = _build(
        ProcessRole.all,
        (e) => [
          _FakeSubsystem('a', _api, e),
          _FakeSubsystem('b', _api, e, failStop: StateError('b broke')),
          _FakeSubsystem('c', _api, e, failStop: StateError('c broke')),
        ],
        events,
      );
      await b.runtime.start();
      events.clear();
      final error = await b.port.shutdownTasks.single().then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      expect(events, contains('stop a end'));
      expect(error, isA<SubsystemStopException>());
      expect(
        error.toString(),
        allOf(contains('b'), contains('c'), contains('b broke')),
      );
      expect(b.logs.where((l) => l.contains('b')), isNotEmpty);
      expect(b.logs.where((l) => l.contains('c broke')), isNotEmpty);
    },
  );
}
