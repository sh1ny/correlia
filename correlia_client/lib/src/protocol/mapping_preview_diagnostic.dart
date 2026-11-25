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

abstract class MappingPreviewDiagnostic
    implements _isc.SerializableModel, _isc.ProtocolSerialization {
  MappingPreviewDiagnostic._({
    this.alertIndex,
    required this.path,
    required this.code,
    required this.unmapped,
  });

  factory MappingPreviewDiagnostic({
    int? alertIndex,
    required String path,
    required String code,
    required bool unmapped,
  }) = _MappingPreviewDiagnosticImpl;

  factory MappingPreviewDiagnostic.fromJson(
    Map<String, dynamic> jsonSerialization,
  ) {
    return MappingPreviewDiagnostic(
      alertIndex: jsonSerialization['alertIndex'] as int?,
      path: jsonSerialization['path'] as String,
      code: jsonSerialization['code'] as String,
      unmapped: _isc.BoolJsonExtension.fromJson(jsonSerialization['unmapped']),
    );
  }

  int? alertIndex;

  String path;

  String code;

  bool unmapped;

  /// Returns a shallow copy of this [MappingPreviewDiagnostic]
  /// with some or all fields replaced by the given arguments.
  @_isc.useResult
  MappingPreviewDiagnostic copyWith({
    int? alertIndex,
    String? path,
    String? code,
    bool? unmapped,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'MappingPreviewDiagnostic',
      if (alertIndex != null) 'alertIndex': alertIndex,
      'path': path,
      'code': code,
      'unmapped': unmapped,
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {
      '__className__': 'MappingPreviewDiagnostic',
      if (alertIndex != null) 'alertIndex': alertIndex,
      'path': path,
      'code': code,
      'unmapped': unmapped,
    };
  }

  @override
  String toString() {
    return _isc.SerializationManager.encode(this);
  }
}

class _Undefined {}

class _MappingPreviewDiagnosticImpl extends MappingPreviewDiagnostic {
  _MappingPreviewDiagnosticImpl({
    int? alertIndex,
    required String path,
    required String code,
    required bool unmapped,
  }) : super._(
         alertIndex: alertIndex,
         path: path,
         code: code,
         unmapped: unmapped,
       );

  /// Returns a shallow copy of this [MappingPreviewDiagnostic]
  /// with some or all fields replaced by the given arguments.
  @_isc.useResult
  @override
  MappingPreviewDiagnostic copyWith({
    Object? alertIndex = _Undefined,
    String? path,
    String? code,
    bool? unmapped,
  }) {
    return MappingPreviewDiagnostic(
      alertIndex: alertIndex is int? ? alertIndex : this.alertIndex,
      path: path ?? this.path,
      code: code ?? this.code,
      unmapped: unmapped ?? this.unmapped,
    );
  }
}
