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
import '../queue/queue_replay_item.dart' as _i98wfa4z;

abstract class QueueReplayResult
    implements _isc.SerializableModel, _isc.ProtocolSerialization {
  QueueReplayResult._({
    required this.queued,
    required this.refused,
    required this.items,
    this.continuation,
  });

  factory QueueReplayResult({
    required int queued,
    required int refused,
    required List<_i98wfa4z.QueueReplayItem> items,
    String? continuation,
  }) = _QueueReplayResultImpl;

  factory QueueReplayResult.fromJson(Map<String, dynamic> jsonSerialization) {
    return QueueReplayResult(
      queued: jsonSerialization['queued'] as int,
      refused: jsonSerialization['refused'] as int,
      items: _iowdjkrj.Protocol().deserialize<List<_i98wfa4z.QueueReplayItem>>(
        jsonSerialization['items'],
      ),
      continuation: jsonSerialization['continuation'] as String?,
    );
  }

  int queued;

  int refused;

  List<_i98wfa4z.QueueReplayItem> items;

  String? continuation;

  /// Returns a shallow copy of this [QueueReplayResult]
  /// with some or all fields replaced by the given arguments.
  @_isc.useResult
  QueueReplayResult copyWith({
    int? queued,
    int? refused,
    List<_i98wfa4z.QueueReplayItem>? items,
    String? continuation,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'QueueReplayResult',
      'queued': queued,
      'refused': refused,
      'items': items.toJson(valueToJson: (v) => v.toJson()),
      if (continuation != null) 'continuation': continuation,
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {
      '__className__': 'QueueReplayResult',
      'queued': queued,
      'refused': refused,
      'items': items.toJson(valueToJson: (v) => v.toJsonForProtocol()),
      if (continuation != null) 'continuation': continuation,
    };
  }

  @override
  String toString() {
    return _isc.SerializationManager.encode(this);
  }
}

class _Undefined {}

class _QueueReplayResultImpl extends QueueReplayResult {
  _QueueReplayResultImpl({
    required int queued,
    required int refused,
    required List<_i98wfa4z.QueueReplayItem> items,
    String? continuation,
  }) : super._(
         queued: queued,
         refused: refused,
         items: items,
         continuation: continuation,
       );

  /// Returns a shallow copy of this [QueueReplayResult]
  /// with some or all fields replaced by the given arguments.
  @_isc.useResult
  @override
  QueueReplayResult copyWith({
    int? queued,
    int? refused,
    List<_i98wfa4z.QueueReplayItem>? items,
    Object? continuation = _Undefined,
  }) {
    return QueueReplayResult(
      queued: queued ?? this.queued,
      refused: refused ?? this.refused,
      items: items ?? this.items.map((e0) => e0.copyWith()).toList(),
      continuation: continuation is String? ? continuation : this.continuation,
    );
  }
}
