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

abstract class FeedEntry
    implements _isc.SerializableModel, _isc.ProtocolSerialization {
  FeedEntry._({
    required this.entityKind,
    required this.entityId,
    required this.entityVersion,
    required this.changeKind,
    required this.occurredAt,
  });

  factory FeedEntry({
    required String entityKind,
    required int entityId,
    required int entityVersion,
    required String changeKind,
    required DateTime occurredAt,
  }) = _FeedEntryImpl;

  factory FeedEntry.fromJson(Map<String, dynamic> jsonSerialization) {
    return FeedEntry(
      entityKind: jsonSerialization['entityKind'] as String,
      entityId: jsonSerialization['entityId'] as int,
      entityVersion: jsonSerialization['entityVersion'] as int,
      changeKind: jsonSerialization['changeKind'] as String,
      occurredAt: _isc.DateTimeJsonExtension.fromJson(
        jsonSerialization['occurredAt'],
      ),
    );
  }

  String entityKind;

  int entityId;

  int entityVersion;

  String changeKind;

  DateTime occurredAt;

  /// Returns a shallow copy of this [FeedEntry]
  /// with some or all fields replaced by the given arguments.
  @_isc.useResult
  FeedEntry copyWith({
    String? entityKind,
    int? entityId,
    int? entityVersion,
    String? changeKind,
    DateTime? occurredAt,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'FeedEntry',
      'entityKind': entityKind,
      'entityId': entityId,
      'entityVersion': entityVersion,
      'changeKind': changeKind,
      'occurredAt': occurredAt.toJson(),
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {
      '__className__': 'FeedEntry',
      'entityKind': entityKind,
      'entityId': entityId,
      'entityVersion': entityVersion,
      'changeKind': changeKind,
      'occurredAt': occurredAt.toJson(),
    };
  }

  @override
  String toString() {
    return _isc.SerializationManager.encode(this);
  }
}

class _FeedEntryImpl extends FeedEntry {
  _FeedEntryImpl({
    required String entityKind,
    required int entityId,
    required int entityVersion,
    required String changeKind,
    required DateTime occurredAt,
  }) : super._(
         entityKind: entityKind,
         entityId: entityId,
         entityVersion: entityVersion,
         changeKind: changeKind,
         occurredAt: occurredAt,
       );

  /// Returns a shallow copy of this [FeedEntry]
  /// with some or all fields replaced by the given arguments.
  @_isc.useResult
  @override
  FeedEntry copyWith({
    String? entityKind,
    int? entityId,
    int? entityVersion,
    String? changeKind,
    DateTime? occurredAt,
  }) {
    return FeedEntry(
      entityKind: entityKind ?? this.entityKind,
      entityId: entityId ?? this.entityId,
      entityVersion: entityVersion ?? this.entityVersion,
      changeKind: changeKind ?? this.changeKind,
      occurredAt: occurredAt ?? this.occurredAt,
    );
  }
}
