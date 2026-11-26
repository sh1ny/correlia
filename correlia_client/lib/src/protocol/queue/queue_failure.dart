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
import 'package:serverpod_client/serverpod_client.dart' as _isc;
import '../queue/queue_failure_kind.dart' as _iyovhql7;

abstract class QueueFailure
    implements _isc.SerializableModel, _isc.ProtocolSerialization {
  QueueFailure._({
    required this.occurrence,
    required this.kind,
    required this.scopeId,
    required this.workId,
    required this.workAt,
    required this.failedAt,
    required this.ageSeconds,
    required this.errorClass,
    this.snapshotId,
    this.fieldPath,
  });

  factory QueueFailure({
    required int occurrence,
    required _iyovhql7.QueueFailureKind kind,
    required String scopeId,
    required String workId,
    required DateTime workAt,
    required DateTime failedAt,
    required int ageSeconds,
    required String errorClass,
    String? snapshotId,
    String? fieldPath,
  }) = _QueueFailureImpl;

  factory QueueFailure.fromJson(Map<String, dynamic> jsonSerialization) {
    return QueueFailure(
      occurrence: jsonSerialization['occurrence'] as int,
      kind: _iyovhql7.QueueFailureKind.fromJson(
        (jsonSerialization['kind'] as String),
      ),
      scopeId: jsonSerialization['scopeId'] as String,
      workId: jsonSerialization['workId'] as String,
      workAt: _isc.DateTimeJsonExtension.fromJson(jsonSerialization['workAt']),
      failedAt: _isc.DateTimeJsonExtension.fromJson(
        jsonSerialization['failedAt'],
      ),
      ageSeconds: jsonSerialization['ageSeconds'] as int,
      errorClass: jsonSerialization['errorClass'] as String,
      snapshotId: jsonSerialization['snapshotId'] as String?,
      fieldPath: jsonSerialization['fieldPath'] as String?,
    );
  }

  int occurrence;

  _iyovhql7.QueueFailureKind kind;

  String scopeId;

  String workId;

  DateTime workAt;

  DateTime failedAt;

  int ageSeconds;

  String errorClass;

  String? snapshotId;

  String? fieldPath;

  /// Returns a shallow copy of this [QueueFailure]
  /// with some or all fields replaced by the given arguments.
  @_isc.useResult
  QueueFailure copyWith({
    int? occurrence,
    _iyovhql7.QueueFailureKind? kind,
    String? scopeId,
    String? workId,
    DateTime? workAt,
    DateTime? failedAt,
    int? ageSeconds,
    String? errorClass,
    String? snapshotId,
    String? fieldPath,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'QueueFailure',
      'occurrence': occurrence,
      'kind': kind.toJson(),
      'scopeId': scopeId,
      'workId': workId,
      'workAt': workAt.toJson(),
      'failedAt': failedAt.toJson(),
      'ageSeconds': ageSeconds,
      'errorClass': errorClass,
      if (snapshotId != null) 'snapshotId': snapshotId,
      if (fieldPath != null) 'fieldPath': fieldPath,
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {
      '__className__': 'QueueFailure',
      'occurrence': occurrence,
      'kind': kind.toJson(),
      'scopeId': scopeId,
      'workId': workId,
      'workAt': workAt.toJson(),
      'failedAt': failedAt.toJson(),
      'ageSeconds': ageSeconds,
      'errorClass': errorClass,
      if (snapshotId != null) 'snapshotId': snapshotId,
      if (fieldPath != null) 'fieldPath': fieldPath,
    };
  }

  @override
  String toString() {
    return _isc.SerializationManager.encode(this);
  }
}

class _Undefined {}

class _QueueFailureImpl extends QueueFailure {
  _QueueFailureImpl({
    required int occurrence,
    required _iyovhql7.QueueFailureKind kind,
    required String scopeId,
    required String workId,
    required DateTime workAt,
    required DateTime failedAt,
    required int ageSeconds,
    required String errorClass,
    String? snapshotId,
    String? fieldPath,
  }) : super._(
         occurrence: occurrence,
         kind: kind,
         scopeId: scopeId,
         workId: workId,
         workAt: workAt,
         failedAt: failedAt,
         ageSeconds: ageSeconds,
         errorClass: errorClass,
         snapshotId: snapshotId,
         fieldPath: fieldPath,
       );

  /// Returns a shallow copy of this [QueueFailure]
  /// with some or all fields replaced by the given arguments.
  @_isc.useResult
  @override
  QueueFailure copyWith({
    int? occurrence,
    _iyovhql7.QueueFailureKind? kind,
    String? scopeId,
    String? workId,
    DateTime? workAt,
    DateTime? failedAt,
    int? ageSeconds,
    String? errorClass,
    Object? snapshotId = _Undefined,
    Object? fieldPath = _Undefined,
  }) {
    return QueueFailure(
      occurrence: occurrence ?? this.occurrence,
      kind: kind ?? this.kind,
      scopeId: scopeId ?? this.scopeId,
      workId: workId ?? this.workId,
      workAt: workAt ?? this.workAt,
      failedAt: failedAt ?? this.failedAt,
      ageSeconds: ageSeconds ?? this.ageSeconds,
      errorClass: errorClass ?? this.errorClass,
      snapshotId: snapshotId is String? ? snapshotId : this.snapshotId,
      fieldPath: fieldPath is String? ? fieldPath : this.fieldPath,
    );
  }
}
