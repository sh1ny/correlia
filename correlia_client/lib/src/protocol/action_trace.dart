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

abstract class ActionTrace
    implements _isc.SerializableModel, _isc.ProtocolSerialization {
  ActionTrace._({
    required this.index,
    required this.type,
    required this.detail,
    required this.effect,
    required this.applied,
  });

  factory ActionTrace({
    required int index,
    required String type,
    required String detail,
    required String effect,
    required bool applied,
  }) = _ActionTraceImpl;

  factory ActionTrace.fromJson(Map<String, dynamic> jsonSerialization) {
    return ActionTrace(
      index: jsonSerialization['index'] as int,
      type: jsonSerialization['type'] as String,
      detail: jsonSerialization['detail'] as String,
      effect: jsonSerialization['effect'] as String,
      applied: _isc.BoolJsonExtension.fromJson(jsonSerialization['applied']),
    );
  }

  int index;

  String type;

  String detail;

  String effect;

  bool applied;

  /// Returns a shallow copy of this [ActionTrace]
  /// with some or all fields replaced by the given arguments.
  @_isc.useResult
  ActionTrace copyWith({
    int? index,
    String? type,
    String? detail,
    String? effect,
    bool? applied,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'ActionTrace',
      'index': index,
      'type': type,
      'detail': detail,
      'effect': effect,
      'applied': applied,
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {
      '__className__': 'ActionTrace',
      'index': index,
      'type': type,
      'detail': detail,
      'effect': effect,
      'applied': applied,
    };
  }

  @override
  String toString() {
    return _isc.SerializationManager.encode(this);
  }
}

class _ActionTraceImpl extends ActionTrace {
  _ActionTraceImpl({
    required int index,
    required String type,
    required String detail,
    required String effect,
    required bool applied,
  }) : super._(
         index: index,
         type: type,
         detail: detail,
         effect: effect,
         applied: applied,
       );

  /// Returns a shallow copy of this [ActionTrace]
  /// with some or all fields replaced by the given arguments.
  @_isc.useResult
  @override
  ActionTrace copyWith({
    int? index,
    String? type,
    String? detail,
    String? effect,
    bool? applied,
  }) {
    return ActionTrace(
      index: index ?? this.index,
      type: type ?? this.type,
      detail: detail ?? this.detail,
      effect: effect ?? this.effect,
      applied: applied ?? this.applied,
    );
  }
}
