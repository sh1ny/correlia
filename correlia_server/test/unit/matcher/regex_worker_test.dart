import 'dart:isolate';

import 'package:correlia_server/src/matcher/matcher_regex_worker.dart';
import 'package:test/test.dart';

void _exitBeforeReady(SendPort owner) => Isolate.exit();

void main() {
  test('pre-ready exit and row regex exhaustion', () async {
    final exiting = MatcherRegexWorker(
      entryPoint: _exitBeforeReady,
      arm: (_, _) => () {},
    );
    try {
      await expectLater(
        exiting.newRow(() => const Duration(minutes: 1)).matches('a', 'a'),
        throwsA(isA<MatcherRegexUnavailable>()),
      );
    } finally {
      exiting.close();
    }
    var elapsed = Duration.zero;
    final worker = MatcherRegexWorker(
      elapsed: () => elapsed,
      arm: (limit, _) {
        if (limit <= const Duration(milliseconds: 20)) {
          elapsed += const Duration(milliseconds: 10);
        }
        return () {};
      },
    );
    try {
      final row = worker.newRow(() => const Duration(minutes: 1));
      expect(await row.matches('a', 'a'), isTrue);
      elapsed += const Duration(seconds: 1);
      for (var i = 0; i < 8; i++) {
        expect(await row.matches('a', 'a'), isTrue);
      }
      await expectLater(
        row.matches('a', 'b'),
        throwsA(isA<MatcherRegexUnavailable>()),
      );
      expect(
        await worker.newRow(() => const Duration(minutes: 1)).matches('a', 'a'),
        isTrue,
      );
    } finally {
      worker.close();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('late reply cannot beat an overdue timer', () async {
    var elapsed = Duration.zero;
    var arms = 0;
    final worker = MatcherRegexWorker(
      elapsed: () => elapsed,
      arm: (_, _) {
        if (++arms == 2) elapsed = const Duration(milliseconds: 20);
        return () {};
      },
    );
    addTearDown(worker.close);
    await expectLater(
      worker.newRow(() => const Duration(minutes: 1)).matches('a', 'a'),
      throwsA(
        isA<MatcherRegexUnavailable>().having(
          (e) => e.code,
          'code',
          'regex_timeout',
        ),
      ),
    );
    expect(
      await worker.newRow(() => const Duration(minutes: 1)).matches('a', 'a'),
      isTrue,
    );
  });
}
