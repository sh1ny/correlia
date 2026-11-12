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
import '../endpoints/alert_console_endpoint.dart' as _izj6k6t1;

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
  }
}
