/// A bounded diagnostic class, never a message copied from the upstream.
enum SyncReadProblem {
  invalidObject('invalid_object'),
  objectError('object_error'),
  objectTooLarge('object_too_large'),
  invalidFraming('invalid_framing'),
  truncated('truncated'),
  forbidden('forbidden'),
  httpStatus('http_status'),
  timeout('timeout'),
  configChanged('config_changed'),
  receiptBehindCutoff('receipt_behind_cutoff'),
  interrupted('interrupted'),
  holderLost('holder_lost'),
  sourceRetired('source_retired');

  const SyncReadProblem(this.wire);

  /// Durable code exposed in operator status and logs.
  final String wire;
}

/// A safe identifier and bounded validation code from a bad sync object.
final class SyncBadObject {
  const SyncBadObject(this.identifier, this.code);

  final String identifier;
  final String code;
}

/// The reader's part of sync progress, separate from pipeline-owned counts.
final class SyncReadReport {
  const SyncReadReport({
    this.problem,
    this.counts = const {},
    this.samples = const [],
    this.lastObject,
  });

  final SyncReadProblem? problem;
  final Map<String, int> counts;
  final List<SyncBadObject> samples;
  final String? lastObject;
}
