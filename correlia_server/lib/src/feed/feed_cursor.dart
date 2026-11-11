/// A lossless transaction and sequence position in the activity ledger.
final class FeedCursor {
  /// Creates a position from its transaction and sequence identifiers.
  const FeedCursor(this.txid, this.id);

  /// The PostgreSQL transaction identifier.
  final BigInt txid;

  /// The activity sequence identifier, or zero for a snapshot.
  final BigInt id;

  /// Parses a versioned decimal cursor, rejecting malformed or out-of-range IDs.
  factory FeedCursor.parse(String value) {
    final parts = value.split('.');
    if (parts case ['v1', final transaction, final sequence]) {
      final decimal = RegExp(r'^(0|[1-9][0-9]*)$');
      if (decimal.hasMatch(transaction) && decimal.hasMatch(sequence)) {
        final txid = BigInt.parse(transaction);
        final id = BigInt.parse(sequence);
        if (txid <= ((BigInt.one << 64) - BigInt.one) &&
            id <= ((BigInt.one << 63) - BigInt.one)) {
          return FeedCursor(txid, id);
        }
      }
    }
    throw FormatException('Invalid feed cursor');
  }

  /// Encodes this position without losing 64-bit precision on the web.
  String encode() => 'v1.$txid.$id';
}
