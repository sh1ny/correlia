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

abstract class ConditionTrace
    implements _is.SerializableModel, _is.ProtocolSerialization {
  ConditionTrace._({
    this.parentIndex,
    required this.kind,
    this.field,
    this.op,
    required this.outcome,
    this.failureCode,
  });

  factory ConditionTrace({
    int? parentIndex,
    required String kind,
    String? field,
    String? op,
    required String outcome,
    String? failureCode,
  }) = _ConditionTraceImpl;

  factory ConditionTrace.fromJson(Map<String, dynamic> jsonSerialization) {
    return ConditionTrace(
      parentIndex: jsonSerialization['parentIndex'] as int?,
      kind: jsonSerialization['kind'] as String,
      field: jsonSerialization['field'] as String?,
      op: jsonSerialization['op'] as String?,
      outcome: jsonSerialization['outcome'] as String,
      failureCode: jsonSerialization['failureCode'] as String?,
    );
  }

  int? parentIndex;

  String kind;

  String? field;

  String? op;

  String outcome;

  String? failureCode;

  /// Returns a shallow copy of this [ConditionTrace]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  ConditionTrace copyWith({
    int? parentIndex,
    String? kind,
    String? field,
    String? op,
    String? outcome,
    String? failureCode,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'ConditionTrace',
      if (parentIndex != null) 'parentIndex': parentIndex,
      'kind': kind,
      if (field != null) 'field': field,
      if (op != null) 'op': op,
      'outcome': outcome,
      if (failureCode != null) 'failureCode': failureCode,
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {
      '__className__': 'ConditionTrace',
      if (parentIndex != null) 'parentIndex': parentIndex,
      'kind': kind,
      if (field != null) 'field': field,
      if (op != null) 'op': op,
      'outcome': outcome,
      if (failureCode != null) 'failureCode': failureCode,
    };
  }

  @override
  String toString() {
    return _is.SerializationManager.encode(this);
  }
}

class _Undefined {}

class _ConditionTraceImpl extends ConditionTrace {
  _ConditionTraceImpl({
    int? parentIndex,
    required String kind,
    String? field,
    String? op,
    required String outcome,
    String? failureCode,
  }) : super._(
         parentIndex: parentIndex,
         kind: kind,
         field: field,
         op: op,
         outcome: outcome,
         failureCode: failureCode,
       );

  /// Returns a shallow copy of this [ConditionTrace]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  @override
  ConditionTrace copyWith({
    Object? parentIndex = _Undefined,
    String? kind,
    Object? field = _Undefined,
    Object? op = _Undefined,
    String? outcome,
    Object? failureCode = _Undefined,
  }) {
    return ConditionTrace(
      parentIndex: parentIndex is int? ? parentIndex : this.parentIndex,
      kind: kind ?? this.kind,
      field: field is String? ? field : this.field,
      op: op is String? ? op : this.op,
      outcome: outcome ?? this.outcome,
      failureCode: failureCode is String? ? failureCode : this.failureCode,
    );
  }
}
