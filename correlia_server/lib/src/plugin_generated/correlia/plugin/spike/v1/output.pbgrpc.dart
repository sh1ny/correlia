// This is a generated file - do not edit.
//
// Generated from correlia/plugin/spike/v1/output.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:async' as $async;
import 'dart:core' as $core;

import 'package:grpc/service_api.dart' as $grpc;
import 'package:protobuf/protobuf.dart' as $pb;

import 'output.pb.dart' as $0;

export 'output.pb.dart';

/// OutputService is an experimental output-only interoperability probe.
@$pb.GrpcServiceName('correlia.plugin.spike.v1.OutputService')
class OutputServiceClient extends $grpc.Client {
  /// The hostname for this service.
  static const $core.String defaultHost = '';

  /// OAuth scopes needed for the client.
  static const $core.List<$core.String> oauthScopes = [
    '',
  ];

  OutputServiceClient(super.channel, {super.options, super.interceptors});

  /// Deliver accepts immutable canonical event batches and acknowledges whole batches.
  $grpc.ResponseStream<$0.DeliverResponse> deliver(
    $async.Stream<$0.DeliverRequest> request, {
    $grpc.CallOptions? options,
  }) {
    return $createStreamingCall(_$deliver, request, options: options);
  }

  // method descriptors

  static final _$deliver =
      $grpc.ClientMethod<$0.DeliverRequest, $0.DeliverResponse>(
          '/correlia.plugin.spike.v1.OutputService/Deliver',
          ($0.DeliverRequest value) => value.writeToBuffer(),
          $0.DeliverResponse.fromBuffer);
}

@$pb.GrpcServiceName('correlia.plugin.spike.v1.OutputService')
abstract class OutputServiceBase extends $grpc.Service {
  $core.String get $name => 'correlia.plugin.spike.v1.OutputService';

  OutputServiceBase() {
    $addMethod($grpc.ServiceMethod<$0.DeliverRequest, $0.DeliverResponse>(
        'Deliver',
        deliver,
        true,
        true,
        ($core.List<$core.int> value) => $0.DeliverRequest.fromBuffer(value),
        ($0.DeliverResponse value) => value.writeToBuffer()));
  }

  $async.Stream<$0.DeliverResponse> deliver(
      $grpc.ServiceCall call, $async.Stream<$0.DeliverRequest> request);
}
