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

abstract class MatcherFailureView
    implements _is.SerializableModel, _is.ProtocolSerialization {
  MatcherFailureView._({
    required this.snapshotId,
    required this.ruleId,
    required this.failureCount,
  });

  factory MatcherFailureView({
    required String snapshotId,
    required String ruleId,
    required int failureCount,
  }) = _MatcherFailureViewImpl;

  factory MatcherFailureView.fromJson(Map<String, dynamic> jsonSerialization) {
    return MatcherFailureView(
      snapshotId: jsonSerialization['snapshotId'] as String,
      ruleId: jsonSerialization['ruleId'] as String,
      failureCount: jsonSerialization['failureCount'] as int,
    );
  }

  String snapshotId;

  String ruleId;

  int failureCount;

  /// Returns a shallow copy of this [MatcherFailureView]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  MatcherFailureView copyWith({
    String? snapshotId,
    String? ruleId,
    int? failureCount,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'MatcherFailureView',
      'snapshotId': snapshotId,
      'ruleId': ruleId,
      'failureCount': failureCount,
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {
      '__className__': 'MatcherFailureView',
      'snapshotId': snapshotId,
      'ruleId': ruleId,
      'failureCount': failureCount,
    };
  }

  @override
  String toString() {
    return _is.SerializationManager.encode(this);
  }
}

class _MatcherFailureViewImpl extends MatcherFailureView {
  _MatcherFailureViewImpl({
    required String snapshotId,
    required String ruleId,
    required int failureCount,
  }) : super._(
         snapshotId: snapshotId,
         ruleId: ruleId,
         failureCount: failureCount,
       );

  /// Returns a shallow copy of this [MatcherFailureView]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  @override
  MatcherFailureView copyWith({
    String? snapshotId,
    String? ruleId,
    int? failureCount,
  }) {
    return MatcherFailureView(
      snapshotId: snapshotId ?? this.snapshotId,
      ruleId: ruleId ?? this.ruleId,
      failureCount: failureCount ?? this.failureCount,
    );
  }
}
