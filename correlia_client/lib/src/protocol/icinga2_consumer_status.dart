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
import 'icinga2_consumer_sync.dart' as _id40rhfu;

abstract class Icinga2ConsumerStatus
    implements _isc.SerializableModel, _isc.ProtocolSerialization {
  Icinga2ConsumerStatus._({
    required this.sourceId,
    required this.state,
    this.connectionId,
    required this.connectionSeq,
    this.connectedAt,
    this.lastEventAt,
    required this.gapCount,
    this.lastGapAt,
    required this.oversizeLines,
    this.lagMs,
    this.lastErrorClass,
    required this.unservedSyncRequest,
    required this.syncTimeoutsInARow,
    this.currentSync,
    this.lastSync,
  });

  factory Icinga2ConsumerStatus({
    required _isc.UuidValue sourceId,
    required String state,
    String? connectionId,
    required int connectionSeq,
    DateTime? connectedAt,
    DateTime? lastEventAt,
    required int gapCount,
    DateTime? lastGapAt,
    required int oversizeLines,
    int? lagMs,
    String? lastErrorClass,
    required bool unservedSyncRequest,
    required int syncTimeoutsInARow,
    _id40rhfu.Icinga2ConsumerSync? currentSync,
    _id40rhfu.Icinga2ConsumerSync? lastSync,
  }) = _Icinga2ConsumerStatusImpl;

  factory Icinga2ConsumerStatus.fromJson(
    Map<String, dynamic> jsonSerialization,
  ) {
    return Icinga2ConsumerStatus(
      sourceId: _isc.UuidValueJsonExtension.fromJson(
        jsonSerialization['sourceId'],
      ),
      state: jsonSerialization['state'] as String,
      connectionId: jsonSerialization['connectionId'] as String?,
      connectionSeq: jsonSerialization['connectionSeq'] as int,
      connectedAt: jsonSerialization['connectedAt'] == null
          ? null
          : _isc.DateTimeJsonExtension.fromJson(
              jsonSerialization['connectedAt'],
            ),
      lastEventAt: jsonSerialization['lastEventAt'] == null
          ? null
          : _isc.DateTimeJsonExtension.fromJson(
              jsonSerialization['lastEventAt'],
            ),
      gapCount: jsonSerialization['gapCount'] as int,
      lastGapAt: jsonSerialization['lastGapAt'] == null
          ? null
          : _isc.DateTimeJsonExtension.fromJson(jsonSerialization['lastGapAt']),
      oversizeLines: jsonSerialization['oversizeLines'] as int,
      lagMs: jsonSerialization['lagMs'] as int?,
      lastErrorClass: jsonSerialization['lastErrorClass'] as String?,
      unservedSyncRequest: _isc.BoolJsonExtension.fromJson(
        jsonSerialization['unservedSyncRequest'],
      ),
      syncTimeoutsInARow: jsonSerialization['syncTimeoutsInARow'] as int,
      currentSync: jsonSerialization['currentSync'] == null
          ? null
          : _iowdjkrj.Protocol().deserialize<_id40rhfu.Icinga2ConsumerSync>(
              jsonSerialization['currentSync'],
            ),
      lastSync: jsonSerialization['lastSync'] == null
          ? null
          : _iowdjkrj.Protocol().deserialize<_id40rhfu.Icinga2ConsumerSync>(
              jsonSerialization['lastSync'],
            ),
    );
  }

  _isc.UuidValue sourceId;

  String state;

  String? connectionId;

  int connectionSeq;

  DateTime? connectedAt;

  DateTime? lastEventAt;

  int gapCount;

  DateTime? lastGapAt;

  int oversizeLines;

  int? lagMs;

  String? lastErrorClass;

  bool unservedSyncRequest;

  int syncTimeoutsInARow;

  _id40rhfu.Icinga2ConsumerSync? currentSync;

  _id40rhfu.Icinga2ConsumerSync? lastSync;

  /// Returns a shallow copy of this [Icinga2ConsumerStatus]
  /// with some or all fields replaced by the given arguments.
  @_isc.useResult
  Icinga2ConsumerStatus copyWith({
    _isc.UuidValue? sourceId,
    String? state,
    String? connectionId,
    int? connectionSeq,
    DateTime? connectedAt = const _isc.$UndefinedDateTime(),
    DateTime? lastEventAt = const _isc.$UndefinedDateTime(),
    int? gapCount,
    DateTime? lastGapAt = const _isc.$UndefinedDateTime(),
    int? oversizeLines,
    int? lagMs,
    String? lastErrorClass,
    bool? unservedSyncRequest,
    int? syncTimeoutsInARow,
    _id40rhfu.Icinga2ConsumerSync? currentSync =
        const _UndefinedIcinga2ConsumerStatus$currentSync(),
    _id40rhfu.Icinga2ConsumerSync? lastSync =
        const _UndefinedIcinga2ConsumerStatus$currentSync(),
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'Icinga2ConsumerStatus',
      'sourceId': sourceId.toJson(),
      'state': state,
      if (connectionId != null) 'connectionId': connectionId,
      'connectionSeq': connectionSeq,
      if (connectedAt != null) 'connectedAt': connectedAt?.toJson(),
      if (lastEventAt != null) 'lastEventAt': lastEventAt?.toJson(),
      'gapCount': gapCount,
      if (lastGapAt != null) 'lastGapAt': lastGapAt?.toJson(),
      'oversizeLines': oversizeLines,
      if (lagMs != null) 'lagMs': lagMs,
      if (lastErrorClass != null) 'lastErrorClass': lastErrorClass,
      'unservedSyncRequest': unservedSyncRequest,
      'syncTimeoutsInARow': syncTimeoutsInARow,
      if (currentSync != null) 'currentSync': currentSync?.toJson(),
      if (lastSync != null) 'lastSync': lastSync?.toJson(),
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {
      '__className__': 'Icinga2ConsumerStatus',
      'sourceId': sourceId.toJson(),
      'state': state,
      if (connectionId != null) 'connectionId': connectionId,
      'connectionSeq': connectionSeq,
      if (connectedAt != null) 'connectedAt': connectedAt?.toJson(),
      if (lastEventAt != null) 'lastEventAt': lastEventAt?.toJson(),
      'gapCount': gapCount,
      if (lastGapAt != null) 'lastGapAt': lastGapAt?.toJson(),
      'oversizeLines': oversizeLines,
      if (lagMs != null) 'lagMs': lagMs,
      if (lastErrorClass != null) 'lastErrorClass': lastErrorClass,
      'unservedSyncRequest': unservedSyncRequest,
      'syncTimeoutsInARow': syncTimeoutsInARow,
      if (currentSync != null) 'currentSync': currentSync?.toJsonForProtocol(),
      if (lastSync != null) 'lastSync': lastSync?.toJsonForProtocol(),
    };
  }

  @override
  String toString() {
    return _isc.SerializationManager.encode(this);
  }
}

class _Undefined {}

class _UndefinedIcinga2ConsumerStatus$currentSync extends _isc.UndefinedSentinel
    implements _id40rhfu.Icinga2ConsumerSync {
  const _UndefinedIcinga2ConsumerStatus$currentSync();
}

class _Icinga2ConsumerStatusImpl extends Icinga2ConsumerStatus {
  _Icinga2ConsumerStatusImpl({
    required _isc.UuidValue sourceId,
    required String state,
    String? connectionId,
    required int connectionSeq,
    DateTime? connectedAt,
    DateTime? lastEventAt,
    required int gapCount,
    DateTime? lastGapAt,
    required int oversizeLines,
    int? lagMs,
    String? lastErrorClass,
    required bool unservedSyncRequest,
    required int syncTimeoutsInARow,
    _id40rhfu.Icinga2ConsumerSync? currentSync,
    _id40rhfu.Icinga2ConsumerSync? lastSync,
  }) : super._(
         sourceId: sourceId,
         state: state,
         connectionId: connectionId,
         connectionSeq: connectionSeq,
         connectedAt: connectedAt,
         lastEventAt: lastEventAt,
         gapCount: gapCount,
         lastGapAt: lastGapAt,
         oversizeLines: oversizeLines,
         lagMs: lagMs,
         lastErrorClass: lastErrorClass,
         unservedSyncRequest: unservedSyncRequest,
         syncTimeoutsInARow: syncTimeoutsInARow,
         currentSync: currentSync,
         lastSync: lastSync,
       );

  /// Returns a shallow copy of this [Icinga2ConsumerStatus]
  /// with some or all fields replaced by the given arguments.
  @_isc.useResult
  @override
  Icinga2ConsumerStatus copyWith({
    _isc.UuidValue? sourceId,
    String? state,
    Object? connectionId = _Undefined,
    int? connectionSeq,
    DateTime? connectedAt = const _isc.$UndefinedDateTime(),
    DateTime? lastEventAt = const _isc.$UndefinedDateTime(),
    int? gapCount,
    DateTime? lastGapAt = const _isc.$UndefinedDateTime(),
    int? oversizeLines,
    Object? lagMs = _Undefined,
    Object? lastErrorClass = _Undefined,
    bool? unservedSyncRequest,
    int? syncTimeoutsInARow,
    _id40rhfu.Icinga2ConsumerSync? currentSync =
        const _UndefinedIcinga2ConsumerStatus$currentSync(),
    _id40rhfu.Icinga2ConsumerSync? lastSync =
        const _UndefinedIcinga2ConsumerStatus$currentSync(),
  }) {
    return Icinga2ConsumerStatus(
      sourceId: sourceId ?? this.sourceId,
      state: state ?? this.state,
      connectionId: connectionId is String? ? connectionId : this.connectionId,
      connectionSeq: connectionSeq ?? this.connectionSeq,
      connectedAt: connectedAt is _isc.UndefinedSentinel
          ? this.connectedAt
          : connectedAt,
      lastEventAt: lastEventAt is _isc.UndefinedSentinel
          ? this.lastEventAt
          : lastEventAt,
      gapCount: gapCount ?? this.gapCount,
      lastGapAt: lastGapAt is _isc.UndefinedSentinel
          ? this.lastGapAt
          : lastGapAt,
      oversizeLines: oversizeLines ?? this.oversizeLines,
      lagMs: lagMs is int? ? lagMs : this.lagMs,
      lastErrorClass: lastErrorClass is String?
          ? lastErrorClass
          : this.lastErrorClass,
      unservedSyncRequest: unservedSyncRequest ?? this.unservedSyncRequest,
      syncTimeoutsInARow: syncTimeoutsInARow ?? this.syncTimeoutsInARow,
      currentSync: currentSync is _isc.UndefinedSentinel
          ? this.currentSync?.copyWith()
          : currentSync,
      lastSync: lastSync is _isc.UndefinedSentinel
          ? this.lastSync?.copyWith()
          : lastSync,
    );
  }
}
