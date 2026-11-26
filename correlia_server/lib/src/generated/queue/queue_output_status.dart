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
import 'package:serverpod/serverpod.dart' as _is;

abstract class QueueOutputStatus
    implements _is.SerializableModel, _is.ProtocolSerialization {
  QueueOutputStatus._({
    required this.outputId,
    required this.maxRows,
    required this.maxPayloadBytes,
    required this.overflowPolicy,
    required this.usedRows,
    required this.usedBytes,
    required this.discardedCount,
    this.overflowActivityId,
    required this.blocksIngress,
  });

  factory QueueOutputStatus({
    required String outputId,
    required int maxRows,
    required int maxPayloadBytes,
    required String overflowPolicy,
    required int usedRows,
    required int usedBytes,
    required int discardedCount,
    int? overflowActivityId,
    required bool blocksIngress,
  }) = _QueueOutputStatusImpl;

  factory QueueOutputStatus.fromJson(Map<String, dynamic> jsonSerialization) {
    return QueueOutputStatus(
      outputId: jsonSerialization['outputId'] as String,
      maxRows: jsonSerialization['maxRows'] as int,
      maxPayloadBytes: jsonSerialization['maxPayloadBytes'] as int,
      overflowPolicy: jsonSerialization['overflowPolicy'] as String,
      usedRows: jsonSerialization['usedRows'] as int,
      usedBytes: jsonSerialization['usedBytes'] as int,
      discardedCount: jsonSerialization['discardedCount'] as int,
      overflowActivityId: jsonSerialization['overflowActivityId'] as int?,
      blocksIngress: _is.BoolJsonExtension.fromJson(
        jsonSerialization['blocksIngress'],
      ),
    );
  }

  String outputId;

  int maxRows;

  int maxPayloadBytes;

  String overflowPolicy;

  int usedRows;

  int usedBytes;

  int discardedCount;

  int? overflowActivityId;

  bool blocksIngress;

  /// Returns a shallow copy of this [QueueOutputStatus]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  QueueOutputStatus copyWith({
    String? outputId,
    int? maxRows,
    int? maxPayloadBytes,
    String? overflowPolicy,
    int? usedRows,
    int? usedBytes,
    int? discardedCount,
    int? overflowActivityId,
    bool? blocksIngress,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'QueueOutputStatus',
      'outputId': outputId,
      'maxRows': maxRows,
      'maxPayloadBytes': maxPayloadBytes,
      'overflowPolicy': overflowPolicy,
      'usedRows': usedRows,
      'usedBytes': usedBytes,
      'discardedCount': discardedCount,
      if (overflowActivityId != null) 'overflowActivityId': overflowActivityId,
      'blocksIngress': blocksIngress,
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {
      '__className__': 'QueueOutputStatus',
      'outputId': outputId,
      'maxRows': maxRows,
      'maxPayloadBytes': maxPayloadBytes,
      'overflowPolicy': overflowPolicy,
      'usedRows': usedRows,
      'usedBytes': usedBytes,
      'discardedCount': discardedCount,
      if (overflowActivityId != null) 'overflowActivityId': overflowActivityId,
      'blocksIngress': blocksIngress,
    };
  }

  @override
  String toString() {
    return _is.SerializationManager.encode(this);
  }
}

class _Undefined {}

class _QueueOutputStatusImpl extends QueueOutputStatus {
  _QueueOutputStatusImpl({
    required String outputId,
    required int maxRows,
    required int maxPayloadBytes,
    required String overflowPolicy,
    required int usedRows,
    required int usedBytes,
    required int discardedCount,
    int? overflowActivityId,
    required bool blocksIngress,
  }) : super._(
         outputId: outputId,
         maxRows: maxRows,
         maxPayloadBytes: maxPayloadBytes,
         overflowPolicy: overflowPolicy,
         usedRows: usedRows,
         usedBytes: usedBytes,
         discardedCount: discardedCount,
         overflowActivityId: overflowActivityId,
         blocksIngress: blocksIngress,
       );

  /// Returns a shallow copy of this [QueueOutputStatus]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  @override
  QueueOutputStatus copyWith({
    String? outputId,
    int? maxRows,
    int? maxPayloadBytes,
    String? overflowPolicy,
    int? usedRows,
    int? usedBytes,
    int? discardedCount,
    Object? overflowActivityId = _Undefined,
    bool? blocksIngress,
  }) {
    return QueueOutputStatus(
      outputId: outputId ?? this.outputId,
      maxRows: maxRows ?? this.maxRows,
      maxPayloadBytes: maxPayloadBytes ?? this.maxPayloadBytes,
      overflowPolicy: overflowPolicy ?? this.overflowPolicy,
      usedRows: usedRows ?? this.usedRows,
      usedBytes: usedBytes ?? this.usedBytes,
      discardedCount: discardedCount ?? this.discardedCount,
      overflowActivityId: overflowActivityId is int?
          ? overflowActivityId
          : this.overflowActivityId,
      blocksIngress: blocksIngress ?? this.blocksIngress,
    );
  }
}
