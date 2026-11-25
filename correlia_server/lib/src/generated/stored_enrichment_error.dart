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

abstract class StoredEnrichmentError
    implements _is.SerializableModel, _is.ProtocolSerialization {
  StoredEnrichmentError._({
    required this.stage,
    required this.code,
    required this.message,
  });

  factory StoredEnrichmentError({
    required String stage,
    required String code,
    required String message,
  }) = _StoredEnrichmentErrorImpl;

  factory StoredEnrichmentError.fromJson(
    Map<String, dynamic> jsonSerialization,
  ) {
    return StoredEnrichmentError(
      stage: jsonSerialization['stage'] as String,
      code: jsonSerialization['code'] as String,
      message: jsonSerialization['message'] as String,
    );
  }

  String stage;

  String code;

  String message;

  /// Returns a shallow copy of this [StoredEnrichmentError]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  StoredEnrichmentError copyWith({
    String? stage,
    String? code,
    String? message,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'StoredEnrichmentError',
      'stage': stage,
      'code': code,
      'message': message,
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {
      '__className__': 'StoredEnrichmentError',
      'stage': stage,
      'code': code,
      'message': message,
    };
  }

  @override
  String toString() {
    return _is.SerializationManager.encode(this);
  }
}

class _StoredEnrichmentErrorImpl extends StoredEnrichmentError {
  _StoredEnrichmentErrorImpl({
    required String stage,
    required String code,
    required String message,
  }) : super._(
         stage: stage,
         code: code,
         message: message,
       );

  /// Returns a shallow copy of this [StoredEnrichmentError]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  @override
  StoredEnrichmentError copyWith({
    String? stage,
    String? code,
    String? message,
  }) {
    return StoredEnrichmentError(
      stage: stage ?? this.stage,
      code: code ?? this.code,
      message: message ?? this.message,
    );
  }
}
