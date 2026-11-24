part of 'generic_decoder.dart';

/// One bounded, non-persisted diagnostic from the mapping preview.
final class GenericPreviewDiagnostic {
  GenericPreviewDiagnostic._(
    this.alertIndex,
    this.path,
    this.code,
    this.unmapped,
  ) : _pathBytes = utf8.encode(path);

  /// The alert position or `null` for a body-level diagnostic.
  final int? alertIndex;

  /// The preview path, unredacted and bounded by segment.
  final String path;

  /// The stable failure or warning code.
  final String code;

  /// Whether the entry names an unmapped leaf rather than a field failure.
  final bool unmapped;

  final List<int> _pathBytes;

  /// The diagnostic fields as serialized in the preview.
  Map<String, Object?> toJson() => {
    'alertIndex': ?alertIndex,
    'path': path,
    'code': code,
    'unmapped': unmapped,
  };
}

/// Independent alert results and bounded diagnostics, never persisted.
final class GenericPreviewDecode {
  GenericPreviewDecode._(
    this.events,
    this.diagnostics,
    this.overflow,
    this.rowWouldFail,
    this.retainedHighWater,
  );

  /// Events that decoded successfully under the supplied preview metadata.
  final List<CanonicalEvent> events;

  /// Diagnostics in body-first, index, UTF-8 path and code order.
  final List<GenericPreviewDiagnostic> diagnostics;

  /// The number of diagnostics omitted by the entry or byte bound.
  final int overflow;

  /// Whether at least one diagnostic is a delivery failure.
  final bool rowWouldFail;

  /// The largest number of entries retained while collecting diagnostics.
  final int retainedHighWater;
}

final class _PreviewCollector {
  static const _maxEntries = 100;
  static const _maxBytes = 64 * 1024;

  final _heap = <GenericPreviewDiagnostic>[];
  var _total = 0;
  var errorCount = 0;

  void error(EventValidationError error, int? index) {
    errorCount++;
    _add(
      GenericPreviewDiagnostic._(
        index,
        error is EventPointerError
            ? boundedEventPointer(error.segments)
            : error.path,
        error.code,
        false,
      ),
    );
  }

  void unmapped(
    List<EventPointerSegment> path,
    int? index, {
    required bool reject,
  }) {
    if (reject) errorCount++;
    _add(
      GenericPreviewDiagnostic._(
        index,
        boundedEventPointer(path),
        'unmapped_field',
        true,
      ),
    );
  }

  void _add(GenericPreviewDiagnostic value) {
    _total++;
    if (_heap.length < _maxEntries) {
      var index = _heap.length;
      _heap.add(value);
      while (index > 0) {
        final parent = (index - 1) ~/ 2;
        if (_compare(_heap[parent], value) >= 0) break;
        _heap[index] = _heap[parent];
        index = parent;
      }
      _heap[index] = value;
      return;
    }
    if (_compare(value, _heap.first) >= 0) return;
    var index = 0;
    while (true) {
      var child = index * 2 + 1;
      if (child >= _heap.length) break;
      final right = child + 1;
      if (right < _heap.length && _compare(_heap[right], _heap[child]) > 0)
        child = right;
      if (_compare(value, _heap[child]) >= 0) break;
      _heap[index] = _heap[child];
      index = child;
    }
    _heap[index] = value;
  }

  GenericPreviewDecode result(List<CanonicalEvent> events) {
    _heap.sort(_compare);
    var bytes = 2; // Enclosing JSON array brackets.
    var count = 0;
    for (final diagnostic in _heap) {
      bytes +=
          utf8.encode(jsonEncode(diagnostic.toJson())).length +
          (count == 0 ? 0 : 1);
      if (bytes > _maxBytes) break;
      count++;
    }
    return GenericPreviewDecode._(
      events,
      List.unmodifiable(_heap.take(count)),
      _total - count,
      errorCount != 0,
      _heap.length,
    );
  }

  static int _compare(GenericPreviewDiagnostic a, GenericPreviewDiagnostic b) {
    final index = (a.alertIndex ?? -1).compareTo(b.alertIndex ?? -1);
    if (index != 0) return index;
    final aBytes = a._pathBytes;
    final bBytes = b._pathBytes;
    final min = aBytes.length < bBytes.length ? aBytes.length : bBytes.length;
    for (var i = 0; i < min; i++) {
      final diff = aBytes[i] - bBytes[i];
      if (diff != 0) return diff;
    }
    final length = aBytes.length - bBytes.length;
    return length != 0 ? length : a.code.compareTo(b.code);
  }
}
