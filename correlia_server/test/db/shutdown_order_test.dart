@Tags(['db'])
library;

import 'dart:async';

import 'package:correlia_server/src/runtime/process_options.dart';
import 'package:correlia_server/src/runtime/role_runtime.dart';
import 'package:correlia_server/src/runtime/subsystem.dart';
import 'package:test/test.dart';

import '../support/pod_fixture.dart';

/// A subsystem whose [stop] runs [onStop] and then throws [failure], if set.
final class _Subsystem extends Subsystem {
  _Subsystem(this.name, this.events, {this.onStop, this.failure});

  @override
  final String name;
  final List<String> events;
  final Future<void> Function()? onStop;
  final Object? failure;

  @override
  Set<ProcessRole> get roles => {ProcessRole.all};

  @override
  Future<void> start() async => events.add('start $name');

  @override
  Future<void> stop() async {
    events.add('stop $name');
    await onStop?.call();
    if (failure case final Object error) throw error;
  }
}

void main() {
  group(
    'Given a started role whose subsystem queries the database on stop',
    () {
      late PodFixture fixture;
      final events = <String>[];

      setUp(() async {
        events.clear();
        fixture = await PodFixture.create([
          _Subsystem(
            'queries',
            events,
            onStop: () async {
              final session = await fixture.pod.createSession(
                enableLogging: false,
              );
              try {
                await session.db.unsafeQuery('SELECT 1');
                events.add('query ok');
              } finally {
                await session.close();
              }
            },
          ),
        ]);
        expect(await fixture.start(), isA<Started>());
      });
      tearDown(() => fixture.shutdown());

      test(
        'when the server shuts down then the stop callback runs before the '
        'pool closes',
        () async {
          await fixture.shutdown();

          expect(events, ['start queries', 'stop queries', 'query ok']);
          final late = await fixture.pod.createSession(enableLogging: false);
          await expectLater(late.db.unsafeQuery('SELECT 1'), throwsA(anything));
        },
      );
    },
  );

  group('Given a started role whose first-started subsystem fails to stop', () {
    late PodFixture fixture;
    final events = <String>[];

    setUp(() async {
      events.clear();
      fixture = await PodFixture.create([
        _Subsystem('first', events, failure: StateError('first is stuck')),
        _Subsystem('second', events),
      ]);
      expect(await fixture.start(), isA<Started>());
    });
    tearDown(() => fixture.shutdown());

    test(
      'a failing stop callback makes Serverpod report a failed shutdown',
      () async {
        await expectLater(
          fixture.shutdown(),
          throwsA(
            isA<SubsystemStopException>().having(
              (e) => e.failures.keys,
              'failed subsystems',
              ['first'],
            ),
          ),
        );

        expect(events, [
          'start first',
          'start second',
          'stop second',
          'stop first',
        ]);
        expect(
          fixture.logs,
          contains(startsWith('Failed to stop first:')),
          reason: 'the failure is logged with the subsystem name',
        );
        final late = await fixture.pod.createSession(enableLogging: false);
        await expectLater(late.db.unsafeQuery('SELECT 1'), throwsA(anything));
      },
    );
  });
}
