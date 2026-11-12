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
import 'alert_view.dart' as _i897ft9c;
import 'feed_entry.dart' as _iywqxrq6;

abstract class FeedPage
    implements _is.SerializableModel, _is.ProtocolSerialization {
  FeedPage._({
    required this.entries,
    required this.alerts,
    required this.nextCursor,
    required this.more,
    required this.heldBack,
  });

  factory FeedPage({
    required List<_iywqxrq6.FeedEntry> entries,
    required List<_i897ft9c.AlertView> alerts,
    required String nextCursor,
    required bool more,
    required bool heldBack,
  }) = _FeedPageImpl;

  factory FeedPage.fromJson(Map<String, dynamic> jsonSerialization) {
    return FeedPage(
      entries: _i4dbeo9h.Protocol().deserialize<List<_iywqxrq6.FeedEntry>>(
        jsonSerialization['entries'],
      ),
      alerts: _i4dbeo9h.Protocol().deserialize<List<_i897ft9c.AlertView>>(
        jsonSerialization['alerts'],
      ),
      nextCursor: jsonSerialization['nextCursor'] as String,
      more: _is.BoolJsonExtension.fromJson(jsonSerialization['more']),
      heldBack: _is.BoolJsonExtension.fromJson(jsonSerialization['heldBack']),
    );
  }

  List<_iywqxrq6.FeedEntry> entries;

  List<_i897ft9c.AlertView> alerts;

  String nextCursor;

  bool more;

  bool heldBack;

  /// Returns a shallow copy of this [FeedPage]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  FeedPage copyWith({
    List<_iywqxrq6.FeedEntry>? entries,
    List<_i897ft9c.AlertView>? alerts,
    String? nextCursor,
    bool? more,
    bool? heldBack,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'FeedPage',
      'entries': entries.toJson(valueToJson: (v) => v.toJson()),
      'alerts': alerts.toJson(valueToJson: (v) => v.toJson()),
      'nextCursor': nextCursor,
      'more': more,
      'heldBack': heldBack,
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {
      '__className__': 'FeedPage',
      'entries': entries.toJson(valueToJson: (v) => v.toJsonForProtocol()),
      'alerts': alerts.toJson(valueToJson: (v) => v.toJsonForProtocol()),
      'nextCursor': nextCursor,
      'more': more,
      'heldBack': heldBack,
    };
  }

  @override
  String toString() {
    return _is.SerializationManager.encode(this);
  }
}

class _FeedPageImpl extends FeedPage {
  _FeedPageImpl({
    required List<_iywqxrq6.FeedEntry> entries,
    required List<_i897ft9c.AlertView> alerts,
    required String nextCursor,
    required bool more,
    required bool heldBack,
  }) : super._(
         entries: entries,
         alerts: alerts,
         nextCursor: nextCursor,
         more: more,
         heldBack: heldBack,
       );

  /// Returns a shallow copy of this [FeedPage]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  @override
  FeedPage copyWith({
    List<_iywqxrq6.FeedEntry>? entries,
    List<_i897ft9c.AlertView>? alerts,
    String? nextCursor,
    bool? more,
    bool? heldBack,
  }) {
    return FeedPage(
      entries: entries ?? this.entries.map((e0) => e0.copyWith()).toList(),
      alerts: alerts ?? this.alerts.map((e0) => e0.copyWith()).toList(),
      nextCursor: nextCursor ?? this.nextCursor,
      more: more ?? this.more,
      heldBack: heldBack ?? this.heldBack,
    );
  }
}
