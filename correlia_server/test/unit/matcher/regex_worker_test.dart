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
      arm: (_, _) => () {},
    );
    try {
      final row = worker.newRow(() => const Duration(minutes: 1));
      expect(await row.matches('a', 'a'), isTrue);
      elapsed = const Duration(milliseconds: 100);
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
}
