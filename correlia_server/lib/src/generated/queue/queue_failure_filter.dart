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
import '../queue/queue_failure_kind.dart' as _iyovhql7;

abstract class QueueFailureFilter
    implements _is.SerializableModel, _is.ProtocolSerialization {
  QueueFailureFilter._({
    required this.kind,
    this.scopeId,
    this.errorClass,
    this.from,
    this.through,
  });

  factory QueueFailureFilter({
    required _iyovhql7.QueueFailureKind kind,
    String? scopeId,
    String? errorClass,
    DateTime? from,
    DateTime? through,
  }) = _QueueFailureFilterImpl;

  factory QueueFailureFilter.fromJson(Map<String, dynamic> jsonSerialization) {
    return QueueFailureFilter(
      kind: _iyovhql7.QueueFailureKind.fromJson(
        (jsonSerialization['kind'] as String),
      ),
      scopeId: jsonSerialization['scopeId'] as String?,
      errorClass: jsonSerialization['errorClass'] as String?,
      from: jsonSerialization['from'] == null
          ? null
          : _is.DateTimeJsonExtension.fromJson(jsonSerialization['from']),
      through: jsonSerialization['through'] == null
          ? null
          : _is.DateTimeJsonExtension.fromJson(jsonSerialization['through']),
    );
  }

  _iyovhql7.QueueFailureKind kind;

  String? scopeId;

  String? errorClass;

  DateTime? from;

  DateTime? through;

  /// Returns a shallow copy of this [QueueFailureFilter]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  QueueFailureFilter copyWith({
    _iyovhql7.QueueFailureKind? kind,
    String? scopeId,
    String? errorClass,
    DateTime? from = const _is.$UndefinedDateTime(),
    DateTime? through = const _is.$UndefinedDateTime(),
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'QueueFailureFilter',
      'kind': kind.toJson(),
      if (scopeId != null) 'scopeId': scopeId,
      if (errorClass != null) 'errorClass': errorClass,
      if (from != null) 'from': from?.toJson(),
      if (through != null) 'through': through?.toJson(),
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {
      '__className__': 'QueueFailureFilter',
      'kind': kind.toJson(),
      if (scopeId != null) 'scopeId': scopeId,
      if (errorClass != null) 'errorClass': errorClass,
      if (from != null) 'from': from?.toJson(),
      if (through != null) 'through': through?.toJson(),
    };
  }

  @override
  String toString() {
    return _is.SerializationManager.encode(this);
  }
}

class _Undefined {}

class _QueueFailureFilterImpl extends QueueFailureFilter {
  _QueueFailureFilterImpl({
    required _iyovhql7.QueueFailureKind kind,
    String? scopeId,
    String? errorClass,
    DateTime? from,
    DateTime? through,
  }) : super._(
         kind: kind,
         scopeId: scopeId,
         errorClass: errorClass,
         from: from,
         through: through,
       );

  /// Returns a shallow copy of this [QueueFailureFilter]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  @override
  QueueFailureFilter copyWith({
    _iyovhql7.QueueFailureKind? kind,
    Object? scopeId = _Undefined,
    Object? errorClass = _Undefined,
    DateTime? from = const _is.$UndefinedDateTime(),
    DateTime? through = const _is.$UndefinedDateTime(),
  }) {
    return QueueFailureFilter(
      kind: kind ?? this.kind,
      scopeId: scopeId is String? ? scopeId : this.scopeId,
      errorClass: errorClass is String? ? errorClass : this.errorClass,
      from: from is _is.UndefinedSentinel ? this.from : from,
      through: through is _is.UndefinedSentinel ? this.through : through,
    );
  }
}
