// This is a generated file - do not edit.
//
// Generated from correlia/plugin/v1/plugin.proto.

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

import 'plugin.pb.dart' as $0;

export 'plugin.pb.dart';

/// PluginService identifies, configures and monitors a plugin.
@$pb.GrpcServiceName('correlia.plugin.v1.PluginService')
class PluginServiceClient extends $grpc.Client {
  /// The hostname for this service.
  static const $core.String defaultHost = '';

  /// OAuth scopes needed for the client.
  static const $core.List<$core.String> oauthScopes = [
    '',
  ];

  PluginServiceClient(super.channel, {super.options, super.interceptors});

  /// GetMetadata returns the plugin's identity and configuration schema.
  $grpc.ResponseFuture<$0.GetMetadataResponse> getMetadata(
    $0.GetMetadataRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$getMetadata, request, options: options);
  }

  /// Configure supplies configuration and separately resolved secrets.
  $grpc.ResponseFuture<$0.ConfigureResponse> configure(
    $0.ConfigureRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$configure, request, options: options);
  }

  /// CheckHealth reports the plugin's current serving state.
  $grpc.ResponseFuture<$0.CheckHealthResponse> checkHealth(
    $0.CheckHealthRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$checkHealth, request, options: options);
  }

  // method descriptors

  static final _$getMetadata =
      $grpc.ClientMethod<$0.GetMetadataRequest, $0.GetMetadataResponse>(
          '/correlia.plugin.v1.PluginService/GetMetadata',
          ($0.GetMetadataRequest value) => value.writeToBuffer(),
          $0.GetMetadataResponse.fromBuffer);
  static final _$configure =
      $grpc.ClientMethod<$0.ConfigureRequest, $0.ConfigureResponse>(
          '/correlia.plugin.v1.PluginService/Configure',
          ($0.ConfigureRequest value) => value.writeToBuffer(),
          $0.ConfigureResponse.fromBuffer);
  static final _$checkHealth =
      $grpc.ClientMethod<$0.CheckHealthRequest, $0.CheckHealthResponse>(
          '/correlia.plugin.v1.PluginService/CheckHealth',
          ($0.CheckHealthRequest value) => value.writeToBuffer(),
          $0.CheckHealthResponse.fromBuffer);
}

@$pb.GrpcServiceName('correlia.plugin.v1.PluginService')
abstract class PluginServiceBase extends $grpc.Service {
  $core.String get $name => 'correlia.plugin.v1.PluginService';

  PluginServiceBase() {
    $addMethod(
        $grpc.ServiceMethod<$0.GetMetadataRequest, $0.GetMetadataResponse>(
            'GetMetadata',
            getMetadata_Pre,
            false,
            false,
            ($core.List<$core.int> value) =>
                $0.GetMetadataRequest.fromBuffer(value),
            ($0.GetMetadataResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.ConfigureRequest, $0.ConfigureResponse>(
        'Configure',
        configure_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.ConfigureRequest.fromBuffer(value),
        ($0.ConfigureResponse value) => value.writeToBuffer()));
    $addMethod(
        $grpc.ServiceMethod<$0.CheckHealthRequest, $0.CheckHealthResponse>(
            'CheckHealth',
            checkHealth_Pre,
            false,
            false,
            ($core.List<$core.int> value) =>
                $0.CheckHealthRequest.fromBuffer(value),
            ($0.CheckHealthResponse value) => value.writeToBuffer()));
  }

  $async.Future<$0.GetMetadataResponse> getMetadata_Pre($grpc.ServiceCall $call,
      $async.Future<$0.GetMetadataRequest> $request) async {
    return getMetadata($call, await $request);
  }

  $async.Future<$0.GetMetadataResponse> getMetadata(
      $grpc.ServiceCall call, $0.GetMetadataRequest request);

  $async.Future<$0.ConfigureResponse> configure_Pre($grpc.ServiceCall $call,
      $async.Future<$0.ConfigureRequest> $request) async {
    return configure($call, await $request);
  }

  $async.Future<$0.ConfigureResponse> configure(
      $grpc.ServiceCall call, $0.ConfigureRequest request);

  $async.Future<$0.CheckHealthResponse> checkHealth_Pre($grpc.ServiceCall $call,
      $async.Future<$0.CheckHealthRequest> $request) async {
    return checkHealth($call, await $request);
  }

  $async.Future<$0.CheckHealthResponse> checkHealth(
      $grpc.ServiceCall call, $0.CheckHealthRequest request);
}

/// OutputService delivers batches of immutable event snapshots.
@$pb.GrpcServiceName('correlia.plugin.v1.OutputService')
class OutputServiceClient extends $grpc.Client {
  /// The hostname for this service.
  static const $core.String defaultHost = '';

  /// OAuth scopes needed for the client.
  static const $core.List<$core.String> oauthScopes = [
    '',
  ];

  OutputServiceClient(super.channel, {super.options, super.interceptors});

  /// Deliver exchanges batches and per-event outcomes on one connection.
  $grpc.ResponseStream<$0.DeliverResponse> deliver(
    $async.Stream<$0.DeliverRequest> request, {
    $grpc.CallOptions? options,
  }) {
    return $createStreamingCall(_$deliver, request, options: options);
  }

  // method descriptors

  static final _$deliver =
      $grpc.ClientMethod<$0.DeliverRequest, $0.DeliverResponse>(
          '/correlia.plugin.v1.OutputService/Deliver',
          ($0.DeliverRequest value) => value.writeToBuffer(),
          $0.DeliverResponse.fromBuffer);
}

@$pb.GrpcServiceName('correlia.plugin.v1.OutputService')
abstract class OutputServiceBase extends $grpc.Service {
  $core.String get $name => 'correlia.plugin.v1.OutputService';

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
