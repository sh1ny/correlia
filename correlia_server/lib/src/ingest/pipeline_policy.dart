part of 'bootstrap.dart';

/// How a destination handles a new intent that cannot fit.
enum OutputOverflowPolicy {
  discardNew('discard_new'),
  blockIngest('block_ingest');

  const OutputOverflowPolicy(this.wire);

  /// The value persisted in a snapshot.
  final String wire;
}

/// The current count and payload-byte caps for an output ID.
final class OutputBudget {
  const OutputBudget._(this.maxRows, this.maxPayloadBytes, this.overflow);

  static const defaults = OutputBudget._(
    500000,
    1073741824,
    OutputOverflowPolicy.discardNew,
  );

  final int maxRows;
  final int maxPayloadBytes;
  final OutputOverflowPolicy overflow;

  Map<String, Object> _nonDefaults() => {
    if (maxRows != defaults.maxRows) 'max_rows': maxRows,
    if (maxPayloadBytes != defaults.maxPayloadBytes)
      'max_payload_bytes': maxPayloadBytes,
    if (overflow != defaults.overflow) 'overflow_policy': overflow.wire,
  };
}

/// Operational limits persisted separately from output definitions.
final class PipelinePolicy {
  const PipelinePolicy._({
    this.pendingMaxRows = 50000,
    this.pendingMaxAgeSeconds = 30,
    this.diskBudgetBytes,
    this.diskWatermarkPercent = 85,
    this.rawRetentionDays = 30,
    this.eventRetentionDays = 90,
    this.outboxRetentionDays = 7,
    this.deadLetterRetentionDays = 14,
    this.outputBudgets = const {},
  });

  static const _defaults = PipelinePolicy._();
  static const _path = 'pipeline_operations';
  static const _int32Max = 2147483647;
  static const _int64Max = 9223372036854775807;

  final int pendingMaxRows;
  final int pendingMaxAgeSeconds;
  final int? diskBudgetBytes;
  final int diskWatermarkPercent;
  final int rawRetentionDays;
  final int eventRetentionDays;
  final int outboxRetentionDays;
  final int deadLetterRetentionDays;
  final Map<String, OutputBudget> outputBudgets;

  /// The nondefault limits; an empty section is not written to the snapshot.
  Map<String, Object> snapshotJson() {
    final outputs = <String, Object>{};
    for (final MapEntry(:key, :value) in outputBudgets.entries) {
      final budget = value._nonDefaults();
      if (budget.isNotEmpty) outputs[key] = budget;
    }
    return {
      if (pendingMaxRows != _defaults.pendingMaxRows)
        'pending_max_rows': pendingMaxRows,
      if (pendingMaxAgeSeconds != _defaults.pendingMaxAgeSeconds)
        'pending_max_age_seconds': pendingMaxAgeSeconds,
      'disk_budget_bytes': ?diskBudgetBytes,
      if (diskWatermarkPercent != _defaults.diskWatermarkPercent)
        'disk_watermark_percent': diskWatermarkPercent,
      if (rawRetentionDays != _defaults.rawRetentionDays)
        'raw_retention_days': rawRetentionDays,
      if (eventRetentionDays != _defaults.eventRetentionDays)
        'event_retention_days': eventRetentionDays,
      if (outboxRetentionDays != _defaults.outboxRetentionDays)
        'outbox_retention_days': outboxRetentionDays,
      if (deadLetterRetentionDays != _defaults.deadLetterRetentionDays)
        'dead_letter_retention_days': deadLetterRetentionDays,
      if (outputs.isNotEmpty) 'output_budgets': outputs,
    };
  }

  static PipelinePolicy _parse(Object? value, Set<String> outputIds) {
    final fields = _map(value, 'config', _path);
    _keys(
      fields,
      {
        'pending_max_rows',
        'pending_max_age_seconds',
        'disk_budget_bytes',
        'disk_watermark_percent',
        'raw_retention_days',
        'event_retention_days',
        'outbox_retention_days',
        'dead_letter_retention_days',
        'output_budgets',
      },
      'config',
      _path,
    );
    int positive(String key, int fallback, {int maximum = _int32Max}) =>
        fields.containsKey(key)
        ? _integer(fields[key], 1, maximum, '$_path.$key')
        : fallback;
    final budgets = <String, OutputBudget>{};
    if (fields.containsKey('output_budgets')) {
      const path = '$_path.output_budgets';
      final raw = _map(fields['output_budgets'], 'config', path);
      if (raw.length > outputIds.length) _bad('config', path, 'unknown_output');
      for (final MapEntry(:key, :value) in raw.entries) {
        final id = _uuid(key, path);
        if (!outputIds.contains(id)) _bad('config', path, 'unknown_output');
        if (budgets.containsKey(id)) _bad('config', path, 'duplicate');
        final row = _map(value, 'config', path);
        _keys(
          row,
          {'max_rows', 'max_payload_bytes', 'overflow_policy'},
          'config',
          path,
        );
        final mode = switch (row['overflow_policy']) {
          'discard_new' => OutputOverflowPolicy.discardNew,
          'block_ingest' => OutputOverflowPolicy.blockIngest,
          null when !row.containsKey('overflow_policy') =>
            OutputOverflowPolicy.discardNew,
          _ => _bad('config', '$path.overflow_policy', 'overflow_policy'),
        };
        final rows = row.containsKey('max_rows')
            ? _integer(row['max_rows'], 1, _int32Max, '$path.max_rows')
            : OutputBudget.defaults.maxRows;
        final bytes = row.containsKey('max_payload_bytes')
            ? _integer(
                row['max_payload_bytes'],
                1,
                _int64Max,
                '$path.max_payload_bytes',
              )
            : OutputBudget.defaults.maxPayloadBytes;
        if (mode == OutputOverflowPolicy.blockIngest &&
            (rows < 1000 || bytes < 16 * 1024 * 1024)) {
          _bad('config', path, 'blocking_output_bound');
        }
        budgets[id] = OutputBudget._(rows, bytes, mode);
      }
    }
    final budgetIds = budgets.keys.toList()..sort();
    return PipelinePolicy._(
      pendingMaxRows: positive('pending_max_rows', _defaults.pendingMaxRows),
      pendingMaxAgeSeconds: positive(
        'pending_max_age_seconds',
        _defaults.pendingMaxAgeSeconds,
      ),
      diskBudgetBytes: fields.containsKey('disk_budget_bytes')
          ? positive('disk_budget_bytes', 0, maximum: _int64Max)
          : null,
      diskWatermarkPercent: positive(
        'disk_watermark_percent',
        _defaults.diskWatermarkPercent,
        maximum: 100,
      ),
      rawRetentionDays: positive(
        'raw_retention_days',
        _defaults.rawRetentionDays,
        maximum: 36500,
      ),
      eventRetentionDays: positive(
        'event_retention_days',
        _defaults.eventRetentionDays,
        maximum: 36500,
      ),
      outboxRetentionDays: positive(
        'outbox_retention_days',
        _defaults.outboxRetentionDays,
        maximum: 36500,
      ),
      deadLetterRetentionDays: positive(
        'dead_letter_retention_days',
        _defaults.deadLetterRetentionDays,
        maximum: 36500,
      ),
      outputBudgets: Map.unmodifiable({
        for (final id in budgetIds) id: budgets[id]!,
      }),
    );
  }
}
