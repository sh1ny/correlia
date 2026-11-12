import 'package:correlia_server/src/feed/feed_cursor.dart';
import 'package:test/test.dart';

void main() {
  test('cursor round trip retains 64-bit values', () {
    final cursor = FeedCursor(
      BigInt.parse('18446744073709551615'),
      BigInt.parse('9223372036854775807'),
    );
    expect(cursor.encode(), 'v1.18446744073709551615.9223372036854775807');
    final decoded = FeedCursor.parse(cursor.encode());
    expect(decoded.txid, cursor.txid);
    expect(decoded.id, cursor.id);
  });

  test('malformed_cursor', () {
    for (final value in [
      '',
      'v2.1.2',
      'v1.1',
      'v1.1.2.3',
      'v1.-1.0',
      'v1.1.-1',
      'v1.a.1',
      'v1.1. 2',
    ]) {
      expect(
        () => FeedCursor.parse(value),
        throwsFormatException,
        reason: value,
      );
    }
  });
}
