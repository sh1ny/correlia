import 'package:correlia_server/src/ingest/matcher_content_digest.dart';
import 'package:test/test.dart';

void main() {
  test('client_timeout_outlasts_the_lock_timeout', () {
    for (final lock in [
      defaultMatcherFillLockTimeout,
      const Duration(milliseconds: 200),
      const Duration(milliseconds: 60500),
      const Duration(minutes: 5),
    ]) {
      final client = Duration(seconds: matcherFillClientTimeoutSeconds(lock));
      expect(
        client - lock,
        greaterThanOrEqualTo(const Duration(seconds: 30)),
        reason: 'lock $lock',
      );
    }
  });
}
