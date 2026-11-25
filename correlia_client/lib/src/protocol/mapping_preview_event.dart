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

abstract class MappingPreviewEvent
    implements _isc.SerializableModel, _isc.ProtocolSerialization {
  MappingPreviewEvent._({
    required this.fingerprint,
    required this.eventId,
    required this.status,
    required this.severity,
    required this.summary,
    required this.sourceTime,
  });

  factory MappingPreviewEvent({
    required String fingerprint,
    required String eventId,
    required String status,
    required String severity,
    required String summary,
    required String sourceTime,
  }) = _MappingPreviewEventImpl;

  factory MappingPreviewEvent.fromJson(Map<String, dynamic> jsonSerialization) {
    return MappingPreviewEvent(
      fingerprint: jsonSerialization['fingerprint'] as String,
      eventId: jsonSerialization['eventId'] as String,
      status: jsonSerialization['status'] as String,
      severity: jsonSerialization['severity'] as String,
      summary: jsonSerialization['summary'] as String,
      sourceTime: jsonSerialization['sourceTime'] as String,
    );
  }

  String fingerprint;

  String eventId;

  String status;

  String severity;

  String summary;

  String sourceTime;

  /// Returns a shallow copy of this [MappingPreviewEvent]
  /// with some or all fields replaced by the given arguments.
  @_isc.useResult
  MappingPreviewEvent copyWith({
    String? fingerprint,
    String? eventId,
    String? status,
    String? severity,
    String? summary,
    String? sourceTime,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'MappingPreviewEvent',
      'fingerprint': fingerprint,
      'eventId': eventId,
      'status': status,
      'severity': severity,
      'summary': summary,
      'sourceTime': sourceTime,
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {
      '__className__': 'MappingPreviewEvent',
      'fingerprint': fingerprint,
      'eventId': eventId,
      'status': status,
      'severity': severity,
      'summary': summary,
      'sourceTime': sourceTime,
    };
  }

  @override
  String toString() {
    return _isc.SerializationManager.encode(this);
  }
}

class _MappingPreviewEventImpl extends MappingPreviewEvent {
  _MappingPreviewEventImpl({
    required String fingerprint,
    required String eventId,
    required String status,
    required String severity,
    required String summary,
    required String sourceTime,
  }) : super._(
         fingerprint: fingerprint,
         eventId: eventId,
         status: status,
         severity: severity,
         summary: summary,
         sourceTime: sourceTime,
       );

  /// Returns a shallow copy of this [MappingPreviewEvent]
  /// with some or all fields replaced by the given arguments.
  @_isc.useResult
  @override
  MappingPreviewEvent copyWith({
    String? fingerprint,
    String? eventId,
    String? status,
    String? severity,
    String? summary,
    String? sourceTime,
  }) {
    return MappingPreviewEvent(
      fingerprint: fingerprint ?? this.fingerprint,
      eventId: eventId ?? this.eventId,
      status: status ?? this.status,
      severity: severity ?? this.severity,
      summary: summary ?? this.summary,
      sourceTime: sourceTime ?? this.sourceTime,
    );
  }
}
