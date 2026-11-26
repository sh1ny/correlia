/* AUTOMATICALLY GENERATED CODE DO NOT MODIFY */
/*   To generate run: "serverpod generate"    */

// ignore_for_file: implementation_imports
// ignore_for_file: library_private_types_in_public_api
// ignore_for_file: non_constant_identifier_names
// ignore_for_file: public_member_api_docs
// ignore_for_file: type_literal_in_constant_pattern
// ignore_for_file: use_super_parameters
// ignore_for_file: invalid_use_of_internal_member

// ignore_for_file: no_leading_underscores_for_library_prefixes
import 'package:correlia_server/src/generated/protocol.dart' as _i4dbeo9h;
import 'package:serverpod/serverpod.dart' as _is;
import '../queue/queue_maintenance_status.dart' as _ix8ewqul;
import '../queue/queue_output_status.dart' as _icspks5g;

abstract class QueueStatus
    implements _is.SerializableModel, _is.ProtocolSerialization {
  QueueStatus._({
    required this.pendingRows,
    required this.pendingMaxRows,
    this.oldestPendingAgeSeconds,
    required this.pendingMaxAgeSeconds,
    this.databaseBytes,
    this.diskBudgetBytes,
    required this.diskWatermarkPercent,
    this.pressure,
    required this.outputs,
    required this.outputsTruncated,
    required this.partitionDegraded,
    this.maintenance,
    required this.maintenanceFailures,
  });

  factory QueueStatus({
    required int pendingRows,
    required int pendingMaxRows,
    int? oldestPendingAgeSeconds,
    required int pendingMaxAgeSeconds,
    int? databaseBytes,
    int? diskBudgetBytes,
    required int diskWatermarkPercent,
    String? pressure,
    required List<_icspks5g.QueueOutputStatus> outputs,
    required bool outputsTruncated,
    required bool partitionDegraded,
    _ix8ewqul.QueueMaintenanceStatus? maintenance,
    required List<_ix8ewqul.QueueMaintenanceStatus> maintenanceFailures,
  }) = _QueueStatusImpl;

  factory QueueStatus.fromJson(Map<String, dynamic> jsonSerialization) {
    return QueueStatus(
      pendingRows: jsonSerialization['pendingRows'] as int,
      pendingMaxRows: jsonSerialization['pendingMaxRows'] as int,
      oldestPendingAgeSeconds:
          jsonSerialization['oldestPendingAgeSeconds'] as int?,
      pendingMaxAgeSeconds: jsonSerialization['pendingMaxAgeSeconds'] as int,
      databaseBytes: jsonSerialization['databaseBytes'] as int?,
      diskBudgetBytes: jsonSerialization['diskBudgetBytes'] as int?,
      diskWatermarkPercent: jsonSerialization['diskWatermarkPercent'] as int,
      pressure: jsonSerialization['pressure'] as String?,
      outputs: _i4dbeo9h.Protocol()
          .deserialize<List<_icspks5g.QueueOutputStatus>>(
            jsonSerialization['outputs'],
          ),
      outputsTruncated: _is.BoolJsonExtension.fromJson(
        jsonSerialization['outputsTruncated'],
      ),
      partitionDegraded: _is.BoolJsonExtension.fromJson(
        jsonSerialization['partitionDegraded'],
      ),
      maintenance: jsonSerialization['maintenance'] == null
          ? null
          : _i4dbeo9h.Protocol().deserialize<_ix8ewqul.QueueMaintenanceStatus>(
              jsonSerialization['maintenance'],
            ),
      maintenanceFailures: _i4dbeo9h.Protocol()
          .deserialize<List<_ix8ewqul.QueueMaintenanceStatus>>(
            jsonSerialization['maintenanceFailures'],
          ),
    );
  }

  int pendingRows;

  int pendingMaxRows;

  int? oldestPendingAgeSeconds;

  int pendingMaxAgeSeconds;

  int? databaseBytes;

  int? diskBudgetBytes;

  int diskWatermarkPercent;

  String? pressure;

  List<_icspks5g.QueueOutputStatus> outputs;

  bool outputsTruncated;

  bool partitionDegraded;

  _ix8ewqul.QueueMaintenanceStatus? maintenance;

  List<_ix8ewqul.QueueMaintenanceStatus> maintenanceFailures;

  /// Returns a shallow copy of this [QueueStatus]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  QueueStatus copyWith({
    int? pendingRows,
    int? pendingMaxRows,
    int? oldestPendingAgeSeconds,
    int? pendingMaxAgeSeconds,
    int? databaseBytes,
    int? diskBudgetBytes,
    int? diskWatermarkPercent,
    String? pressure,
    List<_icspks5g.QueueOutputStatus>? outputs,
    bool? outputsTruncated,
    bool? partitionDegraded,
    _ix8ewqul.QueueMaintenanceStatus? maintenance =
        const _UndefinedQueueStatus$maintenance(),
    List<_ix8ewqul.QueueMaintenanceStatus>? maintenanceFailures,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'QueueStatus',
      'pendingRows': pendingRows,
      'pendingMaxRows': pendingMaxRows,
      if (oldestPendingAgeSeconds != null)
        'oldestPendingAgeSeconds': oldestPendingAgeSeconds,
      'pendingMaxAgeSeconds': pendingMaxAgeSeconds,
      if (databaseBytes != null) 'databaseBytes': databaseBytes,
      if (diskBudgetBytes != null) 'diskBudgetBytes': diskBudgetBytes,
      'diskWatermarkPercent': diskWatermarkPercent,
      if (pressure != null) 'pressure': pressure,
      'outputs': outputs.toJson(valueToJson: (v) => v.toJson()),
      'outputsTruncated': outputsTruncated,
      'partitionDegraded': partitionDegraded,
      if (maintenance != null) 'maintenance': maintenance?.toJson(),
      'maintenanceFailures': maintenanceFailures.toJson(
        valueToJson: (v) => v.toJson(),
      ),
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {
      '__className__': 'QueueStatus',
      'pendingRows': pendingRows,
      'pendingMaxRows': pendingMaxRows,
      if (oldestPendingAgeSeconds != null)
        'oldestPendingAgeSeconds': oldestPendingAgeSeconds,
      'pendingMaxAgeSeconds': pendingMaxAgeSeconds,
      if (databaseBytes != null) 'databaseBytes': databaseBytes,
      if (diskBudgetBytes != null) 'diskBudgetBytes': diskBudgetBytes,
      'diskWatermarkPercent': diskWatermarkPercent,
      if (pressure != null) 'pressure': pressure,
      'outputs': outputs.toJson(valueToJson: (v) => v.toJsonForProtocol()),
      'outputsTruncated': outputsTruncated,
      'partitionDegraded': partitionDegraded,
      if (maintenance != null) 'maintenance': maintenance?.toJsonForProtocol(),
      'maintenanceFailures': maintenanceFailures.toJson(
        valueToJson: (v) => v.toJsonForProtocol(),
      ),
    };
  }

  @override
  String toString() {
    return _is.SerializationManager.encode(this);
  }
}

class _Undefined {}

class _UndefinedQueueStatus$maintenance extends _is.UndefinedSentinel
    implements _ix8ewqul.QueueMaintenanceStatus {
  const _UndefinedQueueStatus$maintenance();
}

class _QueueStatusImpl extends QueueStatus {
  _QueueStatusImpl({
    required int pendingRows,
    required int pendingMaxRows,
    int? oldestPendingAgeSeconds,
    required int pendingMaxAgeSeconds,
    int? databaseBytes,
    int? diskBudgetBytes,
    required int diskWatermarkPercent,
    String? pressure,
    required List<_icspks5g.QueueOutputStatus> outputs,
    required bool outputsTruncated,
    required bool partitionDegraded,
    _ix8ewqul.QueueMaintenanceStatus? maintenance,
    required List<_ix8ewqul.QueueMaintenanceStatus> maintenanceFailures,
  }) : super._(
         pendingRows: pendingRows,
         pendingMaxRows: pendingMaxRows,
         oldestPendingAgeSeconds: oldestPendingAgeSeconds,
         pendingMaxAgeSeconds: pendingMaxAgeSeconds,
         databaseBytes: databaseBytes,
         diskBudgetBytes: diskBudgetBytes,
         diskWatermarkPercent: diskWatermarkPercent,
         pressure: pressure,
         outputs: outputs,
         outputsTruncated: outputsTruncated,
         partitionDegraded: partitionDegraded,
         maintenance: maintenance,
         maintenanceFailures: maintenanceFailures,
       );

  /// Returns a shallow copy of this [QueueStatus]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  @override
  QueueStatus copyWith({
    int? pendingRows,
    int? pendingMaxRows,
    Object? oldestPendingAgeSeconds = _Undefined,
    int? pendingMaxAgeSeconds,
    Object? databaseBytes = _Undefined,
    Object? diskBudgetBytes = _Undefined,
    int? diskWatermarkPercent,
    Object? pressure = _Undefined,
    List<_icspks5g.QueueOutputStatus>? outputs,
    bool? outputsTruncated,
    bool? partitionDegraded,
    _ix8ewqul.QueueMaintenanceStatus? maintenance =
        const _UndefinedQueueStatus$maintenance(),
    List<_ix8ewqul.QueueMaintenanceStatus>? maintenanceFailures,
  }) {
    return QueueStatus(
      pendingRows: pendingRows ?? this.pendingRows,
      pendingMaxRows: pendingMaxRows ?? this.pendingMaxRows,
      oldestPendingAgeSeconds: oldestPendingAgeSeconds is int?
          ? oldestPendingAgeSeconds
          : this.oldestPendingAgeSeconds,
      pendingMaxAgeSeconds: pendingMaxAgeSeconds ?? this.pendingMaxAgeSeconds,
      databaseBytes: databaseBytes is int? ? databaseBytes : this.databaseBytes,
      diskBudgetBytes: diskBudgetBytes is int?
          ? diskBudgetBytes
          : this.diskBudgetBytes,
      diskWatermarkPercent: diskWatermarkPercent ?? this.diskWatermarkPercent,
      pressure: pressure is String? ? pressure : this.pressure,
      outputs: outputs ?? this.outputs.map((e0) => e0.copyWith()).toList(),
      outputsTruncated: outputsTruncated ?? this.outputsTruncated,
      partitionDegraded: partitionDegraded ?? this.partitionDegraded,
      maintenance: maintenance is _is.UndefinedSentinel
          ? this.maintenance?.copyWith()
          : maintenance,
      maintenanceFailures:
          maintenanceFailures ??
          this.maintenanceFailures.map((e0) => e0.copyWith()).toList(),
    );
  }
}
