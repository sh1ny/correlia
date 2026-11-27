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

abstract class QueueReplayItem
    implements _isc.SerializableModel, _isc.ProtocolSerialization {
  QueueReplayItem._({
    required this.occurrence,
    required this.outcome,
  });

  factory QueueReplayItem({
    required int occurrence,
    required String outcome,
  }) = _QueueReplayItemImpl;

  factory QueueReplayItem.fromJson(Map<String, dynamic> jsonSerialization) {
    return QueueReplayItem(
      occurrence: jsonSerialization['occurrence'] as int,
      outcome: jsonSerialization['outcome'] as String,
    );
  }

  int occurrence;

  String outcome;

  /// Returns a shallow copy of this [QueueReplayItem]
  /// with some or all fields replaced by the given arguments.
  @_isc.useResult
  QueueReplayItem copyWith({
    int? occurrence,
    String? outcome,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'QueueReplayItem',
      'occurrence': occurrence,
      'outcome': outcome,
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {
      '__className__': 'QueueReplayItem',
      'occurrence': occurrence,
      'outcome': outcome,
    };
  }

  @override
  String toString() {
    return _isc.SerializationManager.encode(this);
  }
}

class _QueueReplayItemImpl extends QueueReplayItem {
  _QueueReplayItemImpl({
    required int occurrence,
    required String outcome,
  }) : super._(
         occurrence: occurrence,
         outcome: outcome,
       );

  /// Returns a shallow copy of this [QueueReplayItem]
  /// with some or all fields replaced by the given arguments.
  @_isc.useResult
  @override
  QueueReplayItem copyWith({
    int? occurrence,
    String? outcome,
  }) {
    return QueueReplayItem(
      occurrence: occurrence ?? this.occurrence,
      outcome: outcome ?? this.outcome,
    );
  }
}
