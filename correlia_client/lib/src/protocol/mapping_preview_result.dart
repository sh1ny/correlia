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
import 'package:correlia_client/src/protocol/protocol.dart' as _iowdjkrj;
import 'package:serverpod_client/serverpod_client.dart' as _isc;
import 'mapping_preview_diagnostic.dart' as _ibaui0zg;
import 'mapping_preview_event.dart' as _i20s3xik;
import 'mapping_preview_validation_error.dart' as _i2ozkwub;

abstract class MappingPreviewResult
    implements _isc.SerializableModel, _isc.ProtocolSerialization {
  MappingPreviewResult._({
    required this.label,
    required this.events,
    required this.diagnostics,
    required this.overflow,
    required this.rowWouldFail,
    this.validationError,
  });

  factory MappingPreviewResult({
    required String label,
    required List<_i20s3xik.MappingPreviewEvent> events,
    required List<_ibaui0zg.MappingPreviewDiagnostic> diagnostics,
    required int overflow,
    required bool rowWouldFail,
    _i2ozkwub.MappingPreviewValidationError? validationError,
  }) = _MappingPreviewResultImpl;

  factory MappingPreviewResult.fromJson(
    Map<String, dynamic> jsonSerialization,
  ) {
    return MappingPreviewResult(
      label: jsonSerialization['label'] as String,
      events: _iowdjkrj.Protocol()
          .deserialize<List<_i20s3xik.MappingPreviewEvent>>(
            jsonSerialization['events'],
          ),
      diagnostics: _iowdjkrj.Protocol()
          .deserialize<List<_ibaui0zg.MappingPreviewDiagnostic>>(
            jsonSerialization['diagnostics'],
          ),
      overflow: jsonSerialization['overflow'] as int,
      rowWouldFail: _isc.BoolJsonExtension.fromJson(
        jsonSerialization['rowWouldFail'],
      ),
      validationError: jsonSerialization['validationError'] == null
          ? null
          : _iowdjkrj.Protocol()
                .deserialize<_i2ozkwub.MappingPreviewValidationError>(
                  jsonSerialization['validationError'],
                ),
    );
  }

  String label;

  List<_i20s3xik.MappingPreviewEvent> events;

  List<_ibaui0zg.MappingPreviewDiagnostic> diagnostics;

  int overflow;

  bool rowWouldFail;

  _i2ozkwub.MappingPreviewValidationError? validationError;

  /// Returns a shallow copy of this [MappingPreviewResult]
  /// with some or all fields replaced by the given arguments.
  @_isc.useResult
  MappingPreviewResult copyWith({
    String? label,
    List<_i20s3xik.MappingPreviewEvent>? events,
    List<_ibaui0zg.MappingPreviewDiagnostic>? diagnostics,
    int? overflow,
    bool? rowWouldFail,
    _i2ozkwub.MappingPreviewValidationError? validationError =
        const _UndefinedMappingPreviewResult$validationError(),
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'MappingPreviewResult',
      'label': label,
      'events': events.toJson(valueToJson: (v) => v.toJson()),
      'diagnostics': diagnostics.toJson(valueToJson: (v) => v.toJson()),
      'overflow': overflow,
      'rowWouldFail': rowWouldFail,
      if (validationError != null) 'validationError': validationError?.toJson(),
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {
      '__className__': 'MappingPreviewResult',
      'label': label,
      'events': events.toJson(valueToJson: (v) => v.toJsonForProtocol()),
      'diagnostics': diagnostics.toJson(
        valueToJson: (v) => v.toJsonForProtocol(),
      ),
      'overflow': overflow,
      'rowWouldFail': rowWouldFail,
      if (validationError != null)
        'validationError': validationError?.toJsonForProtocol(),
    };
  }

  @override
  String toString() {
    return _isc.SerializationManager.encode(this);
  }
}

class _UndefinedMappingPreviewResult$validationError
    extends _isc.UndefinedSentinel
    implements _i2ozkwub.MappingPreviewValidationError {
  const _UndefinedMappingPreviewResult$validationError();
}

class _MappingPreviewResultImpl extends MappingPreviewResult {
  _MappingPreviewResultImpl({
    required String label,
    required List<_i20s3xik.MappingPreviewEvent> events,
    required List<_ibaui0zg.MappingPreviewDiagnostic> diagnostics,
    required int overflow,
    required bool rowWouldFail,
    _i2ozkwub.MappingPreviewValidationError? validationError,
  }) : super._(
         label: label,
         events: events,
         diagnostics: diagnostics,
         overflow: overflow,
         rowWouldFail: rowWouldFail,
         validationError: validationError,
       );

  /// Returns a shallow copy of this [MappingPreviewResult]
  /// with some or all fields replaced by the given arguments.
  @_isc.useResult
  @override
  MappingPreviewResult copyWith({
    String? label,
    List<_i20s3xik.MappingPreviewEvent>? events,
    List<_ibaui0zg.MappingPreviewDiagnostic>? diagnostics,
    int? overflow,
    bool? rowWouldFail,
    _i2ozkwub.MappingPreviewValidationError? validationError =
        const _UndefinedMappingPreviewResult$validationError(),
  }) {
    return MappingPreviewResult(
      label: label ?? this.label,
      events: events ?? this.events.map((e0) => e0.copyWith()).toList(),
      diagnostics:
          diagnostics ?? this.diagnostics.map((e0) => e0.copyWith()).toList(),
      overflow: overflow ?? this.overflow,
      rowWouldFail: rowWouldFail ?? this.rowWouldFail,
      validationError: validationError is _isc.UndefinedSentinel
          ? this.validationError?.copyWith()
          : validationError,
    );
  }
}
