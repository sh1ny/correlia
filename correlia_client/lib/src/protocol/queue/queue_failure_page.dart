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
import '../queue/queue_failure.dart' as _iydk6fc2;

abstract class QueueFailurePage
    implements _isc.SerializableModel, _isc.ProtocolSerialization {
  QueueFailurePage._({
    required this.failures,
    this.continuation,
  });

  factory QueueFailurePage({
    required List<_iydk6fc2.QueueFailure> failures,
    String? continuation,
  }) = _QueueFailurePageImpl;

  factory QueueFailurePage.fromJson(Map<String, dynamic> jsonSerialization) {
    return QueueFailurePage(
      failures: _iowdjkrj.Protocol().deserialize<List<_iydk6fc2.QueueFailure>>(
        jsonSerialization['failures'],
      ),
      continuation: jsonSerialization['continuation'] as String?,
    );
  }

  List<_iydk6fc2.QueueFailure> failures;

  String? continuation;

  /// Returns a shallow copy of this [QueueFailurePage]
  /// with some or all fields replaced by the given arguments.
  @_isc.useResult
  QueueFailurePage copyWith({
    List<_iydk6fc2.QueueFailure>? failures,
    String? continuation,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'QueueFailurePage',
      'failures': failures.toJson(valueToJson: (v) => v.toJson()),
      if (continuation != null) 'continuation': continuation,
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {
      '__className__': 'QueueFailurePage',
      'failures': failures.toJson(valueToJson: (v) => v.toJsonForProtocol()),
      if (continuation != null) 'continuation': continuation,
    };
  }

  @override
  String toString() {
    return _isc.SerializationManager.encode(this);
  }
}

class _Undefined {}

class _QueueFailurePageImpl extends QueueFailurePage {
  _QueueFailurePageImpl({
    required List<_iydk6fc2.QueueFailure> failures,
    String? continuation,
  }) : super._(
         failures: failures,
         continuation: continuation,
       );

  /// Returns a shallow copy of this [QueueFailurePage]
  /// with some or all fields replaced by the given arguments.
  @_isc.useResult
  @override
  QueueFailurePage copyWith({
    List<_iydk6fc2.QueueFailure>? failures,
    Object? continuation = _Undefined,
  }) {
    return QueueFailurePage(
      failures: failures ?? this.failures.map((e0) => e0.copyWith()).toList(),
      continuation: continuation is String? ? continuation : this.continuation,
    );
  }
}
