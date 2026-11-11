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

abstract class AlertView
    implements _is.SerializableModel, _is.ProtocolSerialization {
  AlertView._({
    required this.id,
    required this.version,
    required this.status,
    required this.severity,
    required this.summary,
    required this.sourceInstance,
    this.firingSince,
    required this.lastObservedAt,
    this.generatorUrl,
  });

  factory AlertView({
    required int id,
    required int version,
    required String status,
    required String severity,
    required String summary,
    required String sourceInstance,
    DateTime? firingSince,
    required DateTime lastObservedAt,
    String? generatorUrl,
  }) = _AlertViewImpl;

  factory AlertView.fromJson(Map<String, dynamic> jsonSerialization) {
    return AlertView(
      id: jsonSerialization['id'] as int,
      version: jsonSerialization['version'] as int,
      status: jsonSerialization['status'] as String,
      severity: jsonSerialization['severity'] as String,
      summary: jsonSerialization['summary'] as String,
      sourceInstance: jsonSerialization['sourceInstance'] as String,
      firingSince: jsonSerialization['firingSince'] == null
          ? null
          : _is.DateTimeJsonExtension.fromJson(
              jsonSerialization['firingSince'],
            ),
      lastObservedAt: _is.DateTimeJsonExtension.fromJson(
        jsonSerialization['lastObservedAt'],
      ),
      generatorUrl: jsonSerialization['generatorUrl'] as String?,
    );
  }

  int id;

  int version;

  String status;

  String severity;

  String summary;

  String sourceInstance;

  DateTime? firingSince;

  DateTime lastObservedAt;

  String? generatorUrl;

  /// Returns a shallow copy of this [AlertView]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  AlertView copyWith({
    int? id,
    int? version,
    String? status,
    String? severity,
    String? summary,
    String? sourceInstance,
    DateTime? firingSince = const _is.$UndefinedDateTime(),
    DateTime? lastObservedAt,
    String? generatorUrl,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'AlertView',
      'id': id,
      'version': version,
      'status': status,
      'severity': severity,
      'summary': summary,
      'sourceInstance': sourceInstance,
      if (firingSince != null) 'firingSince': firingSince?.toJson(),
      'lastObservedAt': lastObservedAt.toJson(),
      if (generatorUrl != null) 'generatorUrl': generatorUrl,
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {
      '__className__': 'AlertView',
      'id': id,
      'version': version,
      'status': status,
      'severity': severity,
      'summary': summary,
      'sourceInstance': sourceInstance,
      if (firingSince != null) 'firingSince': firingSince?.toJson(),
      'lastObservedAt': lastObservedAt.toJson(),
      if (generatorUrl != null) 'generatorUrl': generatorUrl,
    };
  }

  @override
  String toString() {
    return _is.SerializationManager.encode(this);
  }
}

class _Undefined {}

class _AlertViewImpl extends AlertView {
  _AlertViewImpl({
    required int id,
    required int version,
    required String status,
    required String severity,
    required String summary,
    required String sourceInstance,
    DateTime? firingSince,
    required DateTime lastObservedAt,
    String? generatorUrl,
  }) : super._(
         id: id,
         version: version,
         status: status,
         severity: severity,
         summary: summary,
         sourceInstance: sourceInstance,
         firingSince: firingSince,
         lastObservedAt: lastObservedAt,
         generatorUrl: generatorUrl,
       );

  /// Returns a shallow copy of this [AlertView]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  @override
  AlertView copyWith({
    int? id,
    int? version,
    String? status,
    String? severity,
    String? summary,
    String? sourceInstance,
    DateTime? firingSince = const _is.$UndefinedDateTime(),
    DateTime? lastObservedAt,
    Object? generatorUrl = _Undefined,
  }) {
    return AlertView(
      id: id ?? this.id,
      version: version ?? this.version,
      status: status ?? this.status,
      severity: severity ?? this.severity,
      summary: summary ?? this.summary,
      sourceInstance: sourceInstance ?? this.sourceInstance,
      firingSince: firingSince is _is.UndefinedSentinel
          ? this.firingSince
          : firingSince,
      lastObservedAt: lastObservedAt ?? this.lastObservedAt,
      generatorUrl: generatorUrl is String? ? generatorUrl : this.generatorUrl,
    );
  }
}
