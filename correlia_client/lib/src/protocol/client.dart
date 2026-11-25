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
import 'dart:async' as _ida;
import 'package:correlia_client/src/protocol/alert_snapshot.dart' as _iwtce40m;
import 'package:correlia_client/src/protocol/feed_page.dart' as _ic2oo2k5;
import 'package:correlia_client/src/protocol/feed_wake_up.dart' as _in8k0z4e;
import 'package:correlia_client/src/protocol/icinga2_consumer_status.dart'
    as _ipqy5wv2;
import 'package:correlia_client/src/protocol/mapping_preview_result.dart'
    as _ioulm4x4;
import 'package:http/http.dart' as _i85jenna;
import 'package:serverpod_client/serverpod_client.dart' as _isc;
import 'protocol.dart' as _il2as5qe;

/// Development-only snapshot, durable feed and wake-up API.
/// {@category Endpoint}
class EndpointAlertConsole extends _isc.EndpointRef {
  EndpointAlertConsole(_isc.EndpointCaller caller) : super(caller);

  @override
  String get name => 'alertConsole';

  /// Returns a bounded firing-alert snapshot and its handover cursor.
  _ida.Future<_iwtce40m.AlertSnapshot> snapshot() =>
      caller.callServerEndpoint<_iwtce40m.AlertSnapshot>(
        'alertConsole',
        'snapshot',
        {},
      );

  /// Reads a page of durable activity and its current alert views.
  _ida.Future<_ic2oo2k5.FeedPage> feed(
    String cursor,
    int limit,
  ) => caller.callServerEndpoint<_ic2oo2k5.FeedPage>(
    'alertConsole',
    'feed',
    {
      'cursor': cursor,
      'limit': limit,
    },
  );

  /// Emits wake-ups while this client is subscribed.
  _ida.Stream<_in8k0z4e.FeedWakeUp> wakeUps() =>
      caller.callStreamingServerEndpoint<
        _ida.Stream<_in8k0z4e.FeedWakeUp>,
        _in8k0z4e.FeedWakeUp
      >(
        'alertConsole',
        'wakeUps',
        {},
        {},
      );
}

/// Local operator status for Icinga2 Event Streams.
/// {@category Endpoint}
class EndpointIcinga2Stream extends _isc.EndpointRef {
  EndpointIcinga2Stream(_isc.EndpointCaller caller) : super(caller);

  @override
  String get name => 'icinga2Stream';

  /// Reads one source without renewing its lease or changing any counters.
  _ida.Future<_ipqy5wv2.Icinga2ConsumerStatus?> status(
    _isc.UuidValue sourceId,
  ) => caller.callServerEndpoint<_ipqy5wv2.Icinga2ConsumerStatus?>(
    'icinga2Stream',
    'status',
    {'sourceId': sourceId},
  );
}

/// Read-only preview of an active or draft generic mapping on the local console.
/// {@category Endpoint}
class EndpointMappingPreview extends _isc.EndpointRef {
  EndpointMappingPreview(_isc.EndpointCaller caller) : super(caller);

  @override
  String get name => 'mappingPreview';

  /// Maps [sample] against the active generic source or the supplied draft.
  _ida.Future<_ioulm4x4.MappingPreviewResult> preview(
    String sourceId,
    String sample, {
    String? draftMapping,
  }) => caller.callServerEndpoint<_ioulm4x4.MappingPreviewResult>(
    'mappingPreview',
    'preview',
    {
      'sourceId': sourceId,
      'sample': sample,
      'draftMapping': draftMapping,
    },
  );
}

class Client extends _isc.ServerpodClientShared {
  Client(
    String host, {
    dynamic securityContext,
    Duration? streamingConnectionTimeout,
    Duration? connectionTimeout,
    Function(
      _isc.MethodCallContext,
      Object,
      StackTrace,
    )?
    onFailedCall,
    Function(_isc.MethodCallContext)? onSucceededCall,
    bool? disconnectStreamsOnLostInternetConnection,
    _i85jenna.Client? httpClientOverride,
  }) : super(
         host,
         _il2as5qe.Protocol(),
         securityContext: securityContext,
         streamingConnectionTimeout: streamingConnectionTimeout,
         connectionTimeout: connectionTimeout,
         onFailedCall: onFailedCall,
         onSucceededCall: onSucceededCall,
         disconnectStreamsOnLostInternetConnection:
             disconnectStreamsOnLostInternetConnection,
         httpClientOverride: httpClientOverride,
       ) {
    alertConsole = EndpointAlertConsole(this);
    icinga2Stream = EndpointIcinga2Stream(this);
    mappingPreview = EndpointMappingPreview(this);
  }

  late final EndpointAlertConsole alertConsole;

  late final EndpointIcinga2Stream icinga2Stream;

  late final EndpointMappingPreview mappingPreview;

  @override
  Map<String, _isc.EndpointRef> get endpointRefLookup => {
    'alertConsole': alertConsole,
    'icinga2Stream': icinga2Stream,
    'mappingPreview': mappingPreview,
  };

  @override
  Map<String, _isc.ModuleEndpointCaller> get moduleLookup => {};
}
