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

abstract class QueueMaintenanceStatus
    implements _is.SerializableModel, _is.ProtocolSerialization {
  QueueMaintenanceStatus._({
    required this.lane,
    required this.outcome,
    required this.finishedAt,
    required this.affected,
  });

  factory QueueMaintenanceStatus({
    required String lane,
    required String outcome,
    required DateTime finishedAt,
    required int affected,
  }) = _QueueMaintenanceStatusImpl;

  factory QueueMaintenanceStatus.fromJson(
    Map<String, dynamic> jsonSerialization,
  ) {
    return QueueMaintenanceStatus(
      lane: jsonSerialization['lane'] as String,
      outcome: jsonSerialization['outcome'] as String,
      finishedAt: _is.DateTimeJsonExtension.fromJson(
        jsonSerialization['finishedAt'],
      ),
      affected: jsonSerialization['affected'] as int,
    );
  }

  String lane;

  String outcome;

  DateTime finishedAt;

  int affected;

  /// Returns a shallow copy of this [QueueMaintenanceStatus]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  QueueMaintenanceStatus copyWith({
    String? lane,
    String? outcome,
    DateTime? finishedAt,
    int? affected,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'QueueMaintenanceStatus',
      'lane': lane,
      'outcome': outcome,
      'finishedAt': finishedAt.toJson(),
      'affected': affected,
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {
      '__className__': 'QueueMaintenanceStatus',
      'lane': lane,
      'outcome': outcome,
      'finishedAt': finishedAt.toJson(),
      'affected': affected,
    };
  }

  @override
  String toString() {
    return _is.SerializationManager.encode(this);
  }
}

class _QueueMaintenanceStatusImpl extends QueueMaintenanceStatus {
  _QueueMaintenanceStatusImpl({
    required String lane,
    required String outcome,
    required DateTime finishedAt,
    required int affected,
  }) : super._(
         lane: lane,
         outcome: outcome,
         finishedAt: finishedAt,
         affected: affected,
       );

  /// Returns a shallow copy of this [QueueMaintenanceStatus]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  @override
  QueueMaintenanceStatus copyWith({
    String? lane,
    String? outcome,
    DateTime? finishedAt,
    int? affected,
  }) {
    return QueueMaintenanceStatus(
      lane: lane ?? this.lane,
      outcome: outcome ?? this.outcome,
      finishedAt: finishedAt ?? this.finishedAt,
      affected: affected ?? this.affected,
    );
  }
}
