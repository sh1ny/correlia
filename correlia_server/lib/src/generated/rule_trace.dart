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
import 'action_trace.dart' as _ikn0wxo5;
import 'condition_trace.dart' as _i0ehnxud;

abstract class RuleTrace
    implements _is.SerializableModel, _is.ProtocolSerialization {
  RuleTrace._({
    required this.ruleId,
    required this.outcome,
    this.failureCode,
    required this.conditions,
    required this.actions,
  });

  factory RuleTrace({
    required String ruleId,
    required String outcome,
    String? failureCode,
    required List<_i0ehnxud.ConditionTrace> conditions,
    required List<_ikn0wxo5.ActionTrace> actions,
  }) = _RuleTraceImpl;

  factory RuleTrace.fromJson(Map<String, dynamic> jsonSerialization) {
    return RuleTrace(
      ruleId: jsonSerialization['ruleId'] as String,
      outcome: jsonSerialization['outcome'] as String,
      failureCode: jsonSerialization['failureCode'] as String?,
      conditions: _i4dbeo9h.Protocol()
          .deserialize<List<_i0ehnxud.ConditionTrace>>(
            jsonSerialization['conditions'],
          ),
      actions: _i4dbeo9h.Protocol().deserialize<List<_ikn0wxo5.ActionTrace>>(
        jsonSerialization['actions'],
      ),
    );
  }

  String ruleId;

  String outcome;

  String? failureCode;

  List<_i0ehnxud.ConditionTrace> conditions;

  List<_ikn0wxo5.ActionTrace> actions;

  /// Returns a shallow copy of this [RuleTrace]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  RuleTrace copyWith({
    String? ruleId,
    String? outcome,
    String? failureCode,
    List<_i0ehnxud.ConditionTrace>? conditions,
    List<_ikn0wxo5.ActionTrace>? actions,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'RuleTrace',
      'ruleId': ruleId,
      'outcome': outcome,
      if (failureCode != null) 'failureCode': failureCode,
      'conditions': conditions.toJson(valueToJson: (v) => v.toJson()),
      'actions': actions.toJson(valueToJson: (v) => v.toJson()),
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {
      '__className__': 'RuleTrace',
      'ruleId': ruleId,
      'outcome': outcome,
      if (failureCode != null) 'failureCode': failureCode,
      'conditions': conditions.toJson(
        valueToJson: (v) => v.toJsonForProtocol(),
      ),
      'actions': actions.toJson(valueToJson: (v) => v.toJsonForProtocol()),
    };
  }

  @override
  String toString() {
    return _is.SerializationManager.encode(this);
  }
}

class _Undefined {}

class _RuleTraceImpl extends RuleTrace {
  _RuleTraceImpl({
    required String ruleId,
    required String outcome,
    String? failureCode,
    required List<_i0ehnxud.ConditionTrace> conditions,
    required List<_ikn0wxo5.ActionTrace> actions,
  }) : super._(
         ruleId: ruleId,
         outcome: outcome,
         failureCode: failureCode,
         conditions: conditions,
         actions: actions,
       );

  /// Returns a shallow copy of this [RuleTrace]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  @override
  RuleTrace copyWith({
    String? ruleId,
    String? outcome,
    Object? failureCode = _Undefined,
    List<_i0ehnxud.ConditionTrace>? conditions,
    List<_ikn0wxo5.ActionTrace>? actions,
  }) {
    return RuleTrace(
      ruleId: ruleId ?? this.ruleId,
      outcome: outcome ?? this.outcome,
      failureCode: failureCode is String? ? failureCode : this.failureCode,
      conditions:
          conditions ?? this.conditions.map((e0) => e0.copyWith()).toList(),
      actions: actions ?? this.actions.map((e0) => e0.copyWith()).toList(),
    );
  }
}
