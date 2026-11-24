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

abstract class MappingPreviewValidationError
    implements _isc.SerializableModel, _isc.ProtocolSerialization {
  MappingPreviewValidationError._({
    required this.fileKind,
    required this.field,
    required this.code,
  });

  factory MappingPreviewValidationError({
    required String fileKind,
    required String field,
    required String code,
  }) = _MappingPreviewValidationErrorImpl;

  factory MappingPreviewValidationError.fromJson(
    Map<String, dynamic> jsonSerialization,
  ) {
    return MappingPreviewValidationError(
      fileKind: jsonSerialization['fileKind'] as String,
      field: jsonSerialization['field'] as String,
      code: jsonSerialization['code'] as String,
    );
  }

  String fileKind;

  String field;

  String code;

  /// Returns a shallow copy of this [MappingPreviewValidationError]
  /// with some or all fields replaced by the given arguments.
  @_isc.useResult
  MappingPreviewValidationError copyWith({
    String? fileKind,
    String? field,
    String? code,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'MappingPreviewValidationError',
      'fileKind': fileKind,
      'field': field,
      'code': code,
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {
      '__className__': 'MappingPreviewValidationError',
      'fileKind': fileKind,
      'field': field,
      'code': code,
    };
  }

  @override
  String toString() {
    return _isc.SerializationManager.encode(this);
  }
}

class _MappingPreviewValidationErrorImpl extends MappingPreviewValidationError {
  _MappingPreviewValidationErrorImpl({
    required String fileKind,
    required String field,
    required String code,
  }) : super._(
         fileKind: fileKind,
         field: field,
         code: code,
       );

  /// Returns a shallow copy of this [MappingPreviewValidationError]
  /// with some or all fields replaced by the given arguments.
  @_isc.useResult
  @override
  MappingPreviewValidationError copyWith({
    String? fileKind,
    String? field,
    String? code,
  }) {
    return MappingPreviewValidationError(
      fileKind: fileKind ?? this.fileKind,
      field: field ?? this.field,
      code: code ?? this.code,
    );
  }
}
