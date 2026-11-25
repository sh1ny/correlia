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

abstract class SimulatedLink
    implements _is.SerializableModel, _is.ProtocolSerialization {
  SimulatedLink._({
    required this.href,
    required this.relation,
    this.text,
  });

  factory SimulatedLink({
    required String href,
    required String relation,
    String? text,
  }) = _SimulatedLinkImpl;

  factory SimulatedLink.fromJson(Map<String, dynamic> jsonSerialization) {
    return SimulatedLink(
      href: jsonSerialization['href'] as String,
      relation: jsonSerialization['relation'] as String,
      text: jsonSerialization['text'] as String?,
    );
  }

  String href;

  String relation;

  String? text;

  /// Returns a shallow copy of this [SimulatedLink]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  SimulatedLink copyWith({
    String? href,
    String? relation,
    String? text,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'SimulatedLink',
      'href': href,
      'relation': relation,
      if (text != null) 'text': text,
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {
      '__className__': 'SimulatedLink',
      'href': href,
      'relation': relation,
      if (text != null) 'text': text,
    };
  }

  @override
  String toString() {
    return _is.SerializationManager.encode(this);
  }
}

class _Undefined {}

class _SimulatedLinkImpl extends SimulatedLink {
  _SimulatedLinkImpl({
    required String href,
    required String relation,
    String? text,
  }) : super._(
         href: href,
         relation: relation,
         text: text,
       );

  /// Returns a shallow copy of this [SimulatedLink]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  @override
  SimulatedLink copyWith({
    String? href,
    String? relation,
    Object? text = _Undefined,
  }) {
    return SimulatedLink(
      href: href ?? this.href,
      relation: relation ?? this.relation,
      text: text is String? ? text : this.text,
    );
  }
}
