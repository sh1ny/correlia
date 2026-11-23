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
import 'package:correlia_server/src/generated/protocol.dart' as _i4dbeo9h;
import 'package:serverpod/serverpod.dart' as _is;

abstract class Icinga2ConsumerSync
    implements _is.SerializableModel, _is.ProtocolSerialization {
  Icinga2ConsumerSync._({
    required this.id,
    required this.phase,
    this.reason,
    required this.startedAt,
    this.readEndAt,
    this.endedAt,
    required this.rowsAdmitted,
    required this.rowsDone,
    required this.rowsFailed,
    required this.counts,
  });

  factory Icinga2ConsumerSync({
    required _is.UuidValue id,
    required String phase,
    String? reason,
    required DateTime startedAt,
    DateTime? readEndAt,
    DateTime? endedAt,
    required int rowsAdmitted,
    required int rowsDone,
    required int rowsFailed,
    required Map<String, int> counts,
  }) = _Icinga2ConsumerSyncImpl;

  factory Icinga2ConsumerSync.fromJson(Map<String, dynamic> jsonSerialization) {
    return Icinga2ConsumerSync(
      id: _is.UuidValueJsonExtension.fromJson(jsonSerialization['id']),
      phase: jsonSerialization['phase'] as String,
      reason: jsonSerialization['reason'] as String?,
      startedAt: _is.DateTimeJsonExtension.fromJson(
        jsonSerialization['startedAt'],
      ),
      readEndAt: jsonSerialization['readEndAt'] == null
          ? null
          : _is.DateTimeJsonExtension.fromJson(jsonSerialization['readEndAt']),
      endedAt: jsonSerialization['endedAt'] == null
          ? null
          : _is.DateTimeJsonExtension.fromJson(jsonSerialization['endedAt']),
      rowsAdmitted: jsonSerialization['rowsAdmitted'] as int,
      rowsDone: jsonSerialization['rowsDone'] as int,
      rowsFailed: jsonSerialization['rowsFailed'] as int,
      counts: _i4dbeo9h.Protocol().deserialize<Map<String, int>>(
        jsonSerialization['counts'],
      ),
    );
  }

  _is.UuidValue id;

  String phase;

  String? reason;

  DateTime startedAt;

  DateTime? readEndAt;

  DateTime? endedAt;

  int rowsAdmitted;

  int rowsDone;

  int rowsFailed;

  Map<String, int> counts;

  /// Returns a shallow copy of this [Icinga2ConsumerSync]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  Icinga2ConsumerSync copyWith({
    _is.UuidValue? id,
    String? phase,
    String? reason,
    DateTime? startedAt,
    DateTime? readEndAt = const _is.$UndefinedDateTime(),
    DateTime? endedAt = const _is.$UndefinedDateTime(),
    int? rowsAdmitted,
    int? rowsDone,
    int? rowsFailed,
    Map<String, int>? counts,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'Icinga2ConsumerSync',
      'id': id.toJson(),
      'phase': phase,
      if (reason != null) 'reason': reason,
      'startedAt': startedAt.toJson(),
      if (readEndAt != null) 'readEndAt': readEndAt?.toJson(),
      if (endedAt != null) 'endedAt': endedAt?.toJson(),
      'rowsAdmitted': rowsAdmitted,
      'rowsDone': rowsDone,
      'rowsFailed': rowsFailed,
      'counts': counts.toJson(),
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {
      '__className__': 'Icinga2ConsumerSync',
      'id': id.toJson(),
      'phase': phase,
      if (reason != null) 'reason': reason,
      'startedAt': startedAt.toJson(),
      if (readEndAt != null) 'readEndAt': readEndAt?.toJson(),
      if (endedAt != null) 'endedAt': endedAt?.toJson(),
      'rowsAdmitted': rowsAdmitted,
      'rowsDone': rowsDone,
      'rowsFailed': rowsFailed,
      'counts': counts.toJson(),
    };
  }

  @override
  String toString() {
    return _is.SerializationManager.encode(this);
  }
}

class _Undefined {}

class _Icinga2ConsumerSyncImpl extends Icinga2ConsumerSync {
  _Icinga2ConsumerSyncImpl({
    required _is.UuidValue id,
    required String phase,
    String? reason,
    required DateTime startedAt,
    DateTime? readEndAt,
    DateTime? endedAt,
    required int rowsAdmitted,
    required int rowsDone,
    required int rowsFailed,
    required Map<String, int> counts,
  }) : super._(
         id: id,
         phase: phase,
         reason: reason,
         startedAt: startedAt,
         readEndAt: readEndAt,
         endedAt: endedAt,
         rowsAdmitted: rowsAdmitted,
         rowsDone: rowsDone,
         rowsFailed: rowsFailed,
         counts: counts,
       );

  /// Returns a shallow copy of this [Icinga2ConsumerSync]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  @override
  Icinga2ConsumerSync copyWith({
    _is.UuidValue? id,
    String? phase,
    Object? reason = _Undefined,
    DateTime? startedAt,
    DateTime? readEndAt = const _is.$UndefinedDateTime(),
    DateTime? endedAt = const _is.$UndefinedDateTime(),
    int? rowsAdmitted,
    int? rowsDone,
    int? rowsFailed,
    Map<String, int>? counts,
  }) {
    return Icinga2ConsumerSync(
      id: id ?? this.id,
      phase: phase ?? this.phase,
      reason: reason is String? ? reason : this.reason,
      startedAt: startedAt ?? this.startedAt,
      readEndAt: readEndAt is _is.UndefinedSentinel
          ? this.readEndAt
          : readEndAt,
      endedAt: endedAt is _is.UndefinedSentinel ? this.endedAt : endedAt,
      rowsAdmitted: rowsAdmitted ?? this.rowsAdmitted,
      rowsDone: rowsDone ?? this.rowsDone,
      rowsFailed: rowsFailed ?? this.rowsFailed,
      counts:
          counts ??
          this.counts.map(
            (
              key0,
              value0,
            ) => MapEntry(
              key0,
              value0,
            ),
          ),
    );
  }
}
