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

/// One label of a simulation result, as its key and value.
///
/// Labels travel as a list of these, not as a map: the generated client reads
/// a map's `__className__` key as a model name before decoding the map, and
/// `__className__` is a valid label key.
abstract class SimulatedLabel
    implements _isc.SerializableModel, _isc.ProtocolSerialization {
  SimulatedLabel._({
    required this.key,
    required this.value,
  });

  factory SimulatedLabel({
    required String key,
    required String value,
  }) = _SimulatedLabelImpl;

  factory SimulatedLabel.fromJson(Map<String, dynamic> jsonSerialization) {
    return SimulatedLabel(
      key: jsonSerialization['key'] as String,
      value: jsonSerialization['value'] as String,
    );
  }

  /// The label key.
  String key;

  /// The label value, or for an origins list, the label's origin.
  String value;

  /// Returns a shallow copy of this [SimulatedLabel]
  /// with some or all fields replaced by the given arguments.
  @_isc.useResult
  SimulatedLabel copyWith({
    String? key,
    String? value,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'SimulatedLabel',
      'key': key,
      'value': value,
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {
      '__className__': 'SimulatedLabel',
      'key': key,
      'value': value,
    };
  }

  @override
  String toString() {
    return _isc.SerializationManager.encode(this);
  }
}

class _SimulatedLabelImpl extends SimulatedLabel {
  _SimulatedLabelImpl({
    required String key,
    required String value,
  }) : super._(
         key: key,
         value: value,
       );

  /// Returns a shallow copy of this [SimulatedLabel]
  /// with some or all fields replaced by the given arguments.
  @_isc.useResult
  @override
  SimulatedLabel copyWith({
    String? key,
    String? value,
  }) {
    return SimulatedLabel(
      key: key ?? this.key,
      value: value ?? this.value,
    );
  }
}
