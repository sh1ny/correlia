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
import 'package:correlia_server/src/generated/queue/queue_failure_filter.dart'
    as _irxla14l;
import 'package:correlia_server/src/generated/queue/queue_failure_kind.dart'
    as _ielmb4fd;
import 'package:serverpod/serverpod.dart' as _is;
import '../endpoints/alert_console_endpoint.dart' as _izj6k6t1;
import '../endpoints/dead_letter_endpoint.dart' as _icxsitlu;
import '../endpoints/icinga2_stream_endpoint.dart' as _i11286m8;
import '../endpoints/mapping_preview_endpoint.dart' as _idbsfgu3;
import '../endpoints/rule_simulator_endpoint.dart' as _if0vnxqm;

class Endpoints extends _is.EndpointDispatch {
  @override
  void initializeEndpoints(_is.Server server) {
    var endpoints = <String, _is.Endpoint>{
      'alertConsole': _izj6k6t1.AlertConsoleEndpoint()
        ..initialize(
          server,
          'alertConsole',
          null,
        ),
      'deadLetter': _icxsitlu.DeadLetterEndpoint()
        ..initialize(
          server,
          'deadLetter',
          null,
        ),
      'icinga2Stream': _i11286m8.Icinga2StreamEndpoint()
        ..initialize(
          server,
          'icinga2Stream',
          null,
        ),
      'mappingPreview': _idbsfgu3.MappingPreviewEndpoint()
        ..initialize(
          server,
          'mappingPreview',
          null,
        ),
      'ruleSimulator': _if0vnxqm.RuleSimulatorEndpoint()
        ..initialize(
          server,
          'ruleSimulator',
          null,
        ),
    };
    connectors['alertConsole'] = _is.EndpointConnector(
      name: 'alertConsole',
      endpoint: endpoints['alertConsole']!,
      methodConnectors: {
        'snapshot': _is.MethodConnector(
          name: 'snapshot',
          params: {},
          call:
              (
                _is.Session session,
                Map<String, dynamic> params,
              ) async =>
                  (endpoints['alertConsole'] as _izj6k6t1.AlertConsoleEndpoint)
                      .snapshot(session),
        ),
        'feed': _is.MethodConnector(
          name: 'feed',
          params: {
            'cursor': _is.ParameterDescription(
              name: 'cursor',
              type: _is.getType<String>(),
              nullable: false,
            ),
            'limit': _is.ParameterDescription(
              name: 'limit',
              type: _is.getType<int>(),
              nullable: false,
            ),
          },
          call:
              (
                _is.Session session,
                Map<String, dynamic> params,
              ) async =>
                  (endpoints['alertConsole'] as _izj6k6t1.AlertConsoleEndpoint)
                      .feed(
                        session,
                        params['cursor'],
                        params['limit'],
                      ),
        ),
        'wakeUps': _is.MethodStreamConnector(
          name: 'wakeUps',
          params: {},
          streamParams: {},
          returnType: _is.MethodStreamReturnType.streamType,
          call:
              (
                _is.Session session,
                Map<String, dynamic> params,
                Map<String, Stream> streamParams,
              ) => (endpoints['alertConsole'] as _izj6k6t1.AlertConsoleEndpoint)
                  .wakeUps(session),
        ),
      },
    );
    connectors['deadLetter'] = _is.EndpointConnector(
      name: 'deadLetter',
      endpoint: endpoints['deadLetter']!,
      methodConnectors: {
        'list': _is.MethodConnector(
          name: 'list',
          params: {
            'filter': _is.ParameterDescription(
              name: 'filter',
              type: _is.getType<_irxla14l.QueueFailureFilter>(),
              nullable: false,
            ),
            'limit': _is.ParameterDescription(
              name: 'limit',
              type: _is.getType<int>(),
              nullable: false,
            ),
            'continuation': _is.ParameterDescription(
              name: 'continuation',
              type: _is.getType<String?>(),
              nullable: true,
            ),
          },
          call:
              (
                _is.Session session,
                Map<String, dynamic> params,
              ) async =>
                  (endpoints['deadLetter'] as _icxsitlu.DeadLetterEndpoint)
                      .list(
                        session,
                        params['filter'],
                        limit: params['limit'],
                        continuation: params['continuation'],
                      ),
        ),
        'replay': _is.MethodConnector(
          name: 'replay',
          params: {
            'kind': _is.ParameterDescription(
              name: 'kind',
              type: _is.getType<_ielmb4fd.QueueFailureKind>(),
              nullable: false,
            ),
            'occurrence': _is.ParameterDescription(
              name: 'occurrence',
              type: _is.getType<int>(),
              nullable: false,
            ),
          },
          call:
              (
                _is.Session session,
                Map<String, dynamic> params,
              ) async =>
                  (endpoints['deadLetter'] as _icxsitlu.DeadLetterEndpoint)
                      .replay(
                        session,
                        params['kind'],
                        params['occurrence'],
                      ),
        ),
        'replayBatch': _is.MethodConnector(
          name: 'replayBatch',
          params: {
            'filter': _is.ParameterDescription(
              name: 'filter',
              type: _is.getType<_irxla14l.QueueFailureFilter>(),
              nullable: false,
            ),
            'limit': _is.ParameterDescription(
              name: 'limit',
              type: _is.getType<int>(),
              nullable: false,
            ),
            'continuation': _is.ParameterDescription(
              name: 'continuation',
              type: _is.getType<String?>(),
              nullable: true,
            ),
          },
          call:
              (
                _is.Session session,
                Map<String, dynamic> params,
              ) async =>
                  (endpoints['deadLetter'] as _icxsitlu.DeadLetterEndpoint)
                      .replayBatch(
                        session,
                        params['filter'],
                        limit: params['limit'],
                        continuation: params['continuation'],
                      ),
        ),
        'status': _is.MethodConnector(
          name: 'status',
          params: {},
          call:
              (
                _is.Session session,
                Map<String, dynamic> params,
              ) async =>
                  (endpoints['deadLetter'] as _icxsitlu.DeadLetterEndpoint)
                      .status(session),
        ),
      },
    );
    connectors['icinga2Stream'] = _is.EndpointConnector(
      name: 'icinga2Stream',
      endpoint: endpoints['icinga2Stream']!,
      methodConnectors: {
        'status': _is.MethodConnector(
          name: 'status',
          params: {
            'sourceId': _is.ParameterDescription(
              name: 'sourceId',
              type: _is.getType<_is.UuidValue>(),
              nullable: false,
            ),
          },
          call:
              (
                _is.Session session,
                Map<String, dynamic> params,
              ) async =>
                  (endpoints['icinga2Stream']
                          as _i11286m8.Icinga2StreamEndpoint)
                      .status(
                        session,
                        params['sourceId'],
                      ),
        ),
      },
    );
    connectors['mappingPreview'] = _is.EndpointConnector(
      name: 'mappingPreview',
      endpoint: endpoints['mappingPreview']!,
      methodConnectors: {
        'preview': _is.MethodConnector(
          name: 'preview',
          params: {
            'sourceId': _is.ParameterDescription(
              name: 'sourceId',
              type: _is.getType<String>(),
              nullable: false,
            ),
            'sample': _is.ParameterDescription(
              name: 'sample',
              type: _is.getType<String>(),
              nullable: false,
            ),
            'draftMapping': _is.ParameterDescription(
              name: 'draftMapping',
              type: _is.getType<String?>(),
              nullable: true,
            ),
          },
          call:
              (
                _is.Session session,
                Map<String, dynamic> params,
              ) async =>
                  (endpoints['mappingPreview']
                          as _idbsfgu3.MappingPreviewEndpoint)
                      .preview(
                        session,
                        params['sourceId'],
                        params['sample'],
                        draftMapping: params['draftMapping'],
                      ),
        ),
      },
    );
    connectors['ruleSimulator'] = _is.EndpointConnector(
      name: 'ruleSimulator',
      endpoint: endpoints['ruleSimulator']!,
      methodConnectors: {
        'simulate': _is.MethodConnector(
          name: 'simulate',
          params: {
            'eventJson': _is.ParameterDescription(
              name: 'eventJson',
              type: _is.getType<String?>(),
              nullable: true,
            ),
            'eventId': _is.ParameterDescription(
              name: 'eventId',
              type: _is.getType<String?>(),
              nullable: true,
            ),
            'observedAt': _is.ParameterDescription(
              name: 'observedAt',
              type: _is.getType<String?>(),
              nullable: true,
            ),
            'disposition': _is.ParameterDescription(
              name: 'disposition',
              type: _is.getType<String?>(),
              nullable: true,
            ),
            'draftMatcher': _is.ParameterDescription(
              name: 'draftMatcher',
              type: _is.getType<String?>(),
              nullable: true,
            ),
          },
          call:
              (
                _is.Session session,
                Map<String, dynamic> params,
              ) async =>
                  (endpoints['ruleSimulator']
                          as _if0vnxqm.RuleSimulatorEndpoint)
                      .simulate(
                        session,
                        eventJson: params['eventJson'],
                        eventId: params['eventId'],
                        observedAt: params['observedAt'],
                        disposition: params['disposition'],
                        draftMatcher: params['draftMatcher'],
                      ),
        ),
      },
    );
  }
}
