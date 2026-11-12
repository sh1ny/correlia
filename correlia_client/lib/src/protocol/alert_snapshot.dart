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
import 'alert_view.dart' as _i897ft9c;

abstract class AlertSnapshot
    implements _isc.SerializableModel, _isc.ProtocolSerialization {
  AlertSnapshot._({
    required this.alerts,
    required this.omittedCount,
    required this.cursor,
  });

  factory AlertSnapshot({
    required List<_i897ft9c.AlertView> alerts,
    required int omittedCount,
    required String cursor,
  }) = _AlertSnapshotImpl;

  factory AlertSnapshot.fromJson(Map<String, dynamic> jsonSerialization) {
    return AlertSnapshot(
      alerts: _iowdjkrj.Protocol().deserialize<List<_i897ft9c.AlertView>>(
        jsonSerialization['alerts'],
      ),
      omittedCount: jsonSerialization['omittedCount'] as int,
      cursor: jsonSerialization['cursor'] as String,
    );
  }

  List<_i897ft9c.AlertView> alerts;

  int omittedCount;

  String cursor;

  /// Returns a shallow copy of this [AlertSnapshot]
  /// with some or all fields replaced by the given arguments.
  @_isc.useResult
  AlertSnapshot copyWith({
    List<_i897ft9c.AlertView>? alerts,
    int? omittedCount,
    String? cursor,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'AlertSnapshot',
      'alerts': alerts.toJson(valueToJson: (v) => v.toJson()),
      'omittedCount': omittedCount,
      'cursor': cursor,
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {
      '__className__': 'AlertSnapshot',
      'alerts': alerts.toJson(valueToJson: (v) => v.toJsonForProtocol()),
      'omittedCount': omittedCount,
      'cursor': cursor,
    };
  }

  @override
  String toString() {
    return _isc.SerializationManager.encode(this);
  }
}

class _AlertSnapshotImpl extends AlertSnapshot {
  _AlertSnapshotImpl({
    required List<_i897ft9c.AlertView> alerts,
    required int omittedCount,
    required String cursor,
  }) : super._(
         alerts: alerts,
         omittedCount: omittedCount,
         cursor: cursor,
       );

  /// Returns a shallow copy of this [AlertSnapshot]
  /// with some or all fields replaced by the given arguments.
  @_isc.useResult
  @override
  AlertSnapshot copyWith({
    List<_i897ft9c.AlertView>? alerts,
    int? omittedCount,
    String? cursor,
  }) {
    return AlertSnapshot(
      alerts: alerts ?? this.alerts.map((e0) => e0.copyWith()).toList(),
      omittedCount: omittedCount ?? this.omittedCount,
      cursor: cursor ?? this.cursor,
    );
  }
}
