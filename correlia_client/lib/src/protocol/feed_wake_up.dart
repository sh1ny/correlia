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

abstract class FeedWakeUp
    implements _isc.SerializableModel, _isc.ProtocolSerialization {
  FeedWakeUp._();

  factory FeedWakeUp() = _FeedWakeUpImpl;

  factory FeedWakeUp.fromJson(Map<String, dynamic> jsonSerialization) {
    return FeedWakeUp();
  }

  /// Returns a shallow copy of this [FeedWakeUp]
  /// with some or all fields replaced by the given arguments.
  @_isc.useResult
  FeedWakeUp copyWith();
  @override
  Map<String, dynamic> toJson() {
    return {'__className__': 'FeedWakeUp'};
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {'__className__': 'FeedWakeUp'};
  }

  @override
  String toString() {
    return _isc.SerializationManager.encode(this);
  }
}

class _FeedWakeUpImpl extends FeedWakeUp {
  _FeedWakeUpImpl() : super._();

  /// Returns a shallow copy of this [FeedWakeUp]
  /// with some or all fields replaced by the given arguments.
  @_isc.useResult
  @override
  FeedWakeUp copyWith() {
    return FeedWakeUp();
  }
}
