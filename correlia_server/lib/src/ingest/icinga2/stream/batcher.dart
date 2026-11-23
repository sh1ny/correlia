import 'admission.dart';

/// Maximum size of a line excluding its newline delimiter.
const streamLineLimit = 1024 * 1024;

/// Ordinary encoded raw row budget (one larger item can stand alone).
const streamEncodedRowBudget = 256 * 1024;

/// Conservative fanout budget counting one event and eight output copies.
const streamFanoutBudget = 8 * 1024 * 1024;

/// The largest number of items in a raw row.
const streamItemsPerRow = 100;

/// Maximum time from the first item to flushing an ordinary row.
const streamFlushInterval = Duration(seconds: 1);

/// Collects already validated items, isolating invalid and oversized items.
final class StreamRowBatcher {
  StreamRowBatcher(
    this.envelopeBytes, {
    this.maxEncodedBytes = streamEncodedRowBudget,
  });

  final int envelopeBytes;
  final int maxEncodedBytes;
  List<StreamAdmissionItem> _items = [];
  int _itemBytes = 0;
  int _fanoutBytes = 0;

  bool get hasPending => _items.isNotEmpty;

  /// Returns up to two ready rows. A null canonical size marks invalid input.
  ({List<StreamAdmissionItem>? preceding, List<StreamAdmissionItem>? ready})
  add(
    StreamAdmissionItem item,
    int? canonicalBytes,
  ) {
    final bytes = item.encodedLength;
    final fanout = (canonicalBytes ?? 0) * 9;
    if (canonicalBytes == null || envelopeBytes + bytes > maxEncodedBytes) {
      return (preceding: take(), ready: [item]);
    }
    final preceding =
        hasPending &&
            (envelopeBytes + _itemBytes + 1 + bytes > maxEncodedBytes ||
                _fanoutBytes + fanout > streamFanoutBudget)
        ? take()
        : null;
    if (hasPending) _itemBytes++; // Comma between items.
    _items.add(item);
    _itemBytes += bytes;
    _fanoutBytes += fanout;
    return (
      preceding: preceding,
      ready: _items.length == streamItemsPerRow ? take() : null,
    );
  }

  /// Flushes the current row, transferring its items to the caller.
  List<StreamAdmissionItem>? take() {
    if (_items.isEmpty) return null;
    final row = _items;
    _items = [];
    _itemBytes = 0;
    _fanoutBytes = 0;
    return row;
  }
}
