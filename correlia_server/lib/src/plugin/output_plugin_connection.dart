import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:fixnum/fixnum.dart';
import 'package:grpc/grpc.dart';
import 'package:meta/meta.dart';

import '../plugin_generated/correlia/plugin/v1/plugin.pbgrpc.dart' as v1;
import 'openssl_engine.dart';
import 'plugin_host.dart';
import 'plugin_rpc_connection.dart';
import 'plugin_tls.dart';

/// Classifies a health-call failure using the host's observed connection state.
///
/// Observed connection loss takes precedence over every timeout completion.
/// On a live connection, gRPC failures at or past [deadline] are timeouts.
@visibleForTesting
String classifyHealthFailure({
  required Object error,
  required Duration elapsed,
  required Duration deadline,
  required bool connectionFailed,
}) => switch (error) {
  _ when connectionFailed => 'plugin_connection_lost',
  TimeoutException() => 'plugin_health_timeout',
  GrpcError() when elapsed >= deadline => 'plugin_health_timeout',
  GrpcError(code: StatusCode.deadlineExceeded) => 'plugin_health_timeout',
  _ => 'plugin_connection_lost',
};

/// A bounded, value-free production plugin failure.
final class OutputPluginException implements Exception {
  /// Creates a failure with a stable error class.
  const OutputPluginException(
    this.errorClass, {
    this.fields = const [],
    this.pluginErrorClass,
  });

  /// The bounded error class.
  final String errorClass;

  /// Rejected configuration field names, never their values.
  final List<String> fields;

  /// The validated plugin class, unless it contains resolved secret bytes.
  final String? pluginErrorClass;

  @override
  String toString() => errorClass;
}

/// An immutable event snapshot for one delivery.
final class OutputPluginEvent {
  /// Copies the stored payload before handing it to the plugin.
  OutputPluginEvent(this.id, List<int> payload)
    : payload = List.unmodifiable(payload);

  /// The stable event identifier.
  final String id;

  /// The exact stored event bytes.
  final List<int> payload;
}

/// The outcome of a single event.
enum OutputPluginOutcome { acknowledged, retryable, rejected }

/// An immutable per-event delivery result.
final class OutputPluginResult {
  /// Creates an event outcome.
  const OutputPluginResult(this.id, this.outcome, this.errorClass);

  /// The event identifier.
  final String id;

  /// The plugin's outcome.
  final OutputPluginOutcome outcome;

  /// The bounded failure class, empty for an acknowledgement.
  final String errorClass;
}

/// The negotiated credit and batch bounds.
final class OutputPluginLimits {
  /// Creates delivery limits.
  const OutputPluginLimits(this.maxEvents, this.maxBytes, this.maxOutstanding);

  /// Maximum events in a batch.
  final int maxEvents;

  /// Maximum event payload bytes in a batch.
  final int maxBytes;

  /// Maximum unanswered batches.
  final int maxOutstanding;
}

/// Validated identifying metadata.
final class OutputPluginMetadata {
  /// Copies metadata returned by the plugin.
  OutputPluginMetadata(
    this.name,
    this.version,
    List<String> kinds,
    List<int> configSchemaJson,
    this.protocolMinor,
  ) : kinds = List.unmodifiable(kinds),
      configSchemaJson = List.unmodifiable(configSchemaJson);

  /// The reported plugin name.
  final String name;

  /// The reported plugin version.
  final String version;

  /// The reported plugin kinds.
  final List<String> kinds;

  /// The reported configuration schema bytes.
  final List<int> configSchemaJson;

  /// The reported protocol minor version.
  final int protocolMinor;
}

/// A bounded health response.
final class OutputPluginHealth {
  /// Creates a health result.
  const OutputPluginHealth(this.serving, this.reason);

  /// Whether the plugin is serving.
  final bool serving;

  /// The bounded reason.
  final String reason;
}

final class _Pending {
  _Pending(this.events);
  final Map<String, OutputPluginEvent> events;
  final completer = Completer<List<OutputPluginResult>>();
}

/// Owns a production output connection and its one delivery stream.
final class OutputPluginConnection {
  OutputPluginConnection._(
    this._core,
    this._client,
    this.metadata,
    this.limits,
    Map<String, String> information,
    this._shutdownGrace,
  ) : configurationInfo = Map.unmodifiable(information),
      _exit = _core.onExit!;

  final PluginLaunchCore _core;
  final Future<int> _exit;
  final Duration _shutdownGrace;
  final v1.PluginServiceClient _client;

  /// Validated plugin metadata.
  final OutputPluginMetadata metadata;

  /// Negotiated host and plugin delivery limits.
  final OutputPluginLimits limits;

  /// The immutable, non-secret information returned by Configure.
  final Map<String, String> configurationInfo;
  final _requests = StreamController<v1.DeliverRequest>();
  final _pending = <int, _Pending>{};
  final _failure = Completer<OutputPluginException>();
  ResponseStream<v1.DeliverResponse>? _responses;
  StreamSubscription<v1.DeliverResponse>? _subscription;
  int _sequence = 0;
  bool _stopped = false;
  static final _errorClass = RegExp(r'^[a-z][a-z0-9_]{0,63}$');
  static final _field = RegExp(r'^[a-zA-Z0-9_.-]{1,128}$');

  /// The first connection failure, including an unexpected process exit.
  Future<OutputPluginException> get failure => _failure.future;

  /// The child exit code.
  Future<int> get onExit => _exit;

  /// The child process identifier.
  int? get pid => _core.childPid;

  /// Whether stopping the process required a forced termination.
  bool get forcedStop => _core.forcedStop;

  /// The observed handshake facts.
  PluginHandshakeEvidence? get evidence => _core.evidence;

  /// The observed TLS facts.
  PluginTlsEvidence? get tlsEvidence => _core.tlsEvidence;

  /// Launches, identifies and configures a fresh output plugin.
  static Future<OutputPluginConnection> start({
    required String executable,
    List<String> arguments = const [],
    required List<int> configJson,
    required Map<String, List<int>> secrets,
    Duration timeout = const Duration(seconds: 10),
    Duration shutdownGrace = const Duration(seconds: 5),
  }) async {
    if (timeout <= Duration.zero) throw ArgumentError.value(timeout, 'timeout');
    if (shutdownGrace.isNegative) {
      throw ArgumentError.value(shutdownGrace, 'shutdownGrace');
    }
    final deadline = timeout < const Duration(seconds: 10)
        ? timeout
        : const Duration(seconds: 10);
    final watch = Stopwatch()..start();
    Duration remaining() {
      final left = deadline - watch.elapsed;
      if (left <= Duration.zero) {
        throw const OutputPluginException('plugin_start_timeout');
      }
      return left;
    }

    final identity = mintPluginIdentity();
    final core = PluginLaunchCore(
      PluginHostConfig(
        executable: executable,
        arguments: arguments,
        identity: PluginClientIdentity(
          certificatePem: identity.certificatePem,
          privateKeyPem: identity.privateKeyPem,
        ),
        timeout: remaining(),
        cookie: 'correlia.plugin.v1',
      ),
    );
    try {
      await core.start().timeout(remaining());
      final client = v1.PluginServiceClient(core.channel);
      final response = await client.getMetadata(
        v1.GetMetadataRequest(),
        options: CallOptions(timeout: remaining()),
      );
      if (response.writeToBuffer().length > 65536 ||
          !response.kinds.contains('output') ||
          response.name.isEmpty ||
          response.version.isEmpty) {
        throw const OutputPluginException('plugin_metadata_invalid');
      }
      final metadata = OutputPluginMetadata(
        response.name,
        response.version,
        response.kinds,
        response.configSchemaJson,
        response.protocolMinor,
      );
      final configured = await client.configure(
        v1.ConfigureRequest(
          configJson: configJson,
          secrets: secrets.entries,
          limits: v1.DeliveryLimits(
            maxEventsPerBatch: 64,
            maxBytesPerBatch: Int64(1048576),
            maxOutstandingBatches: 4,
          ),
        ),
        options: CallOptions(timeout: remaining()),
      );
      if (configured.writeToBuffer().length > 65536) {
        throw const OutputPluginException('plugin_metadata_invalid');
      }
      final pluginClass = configured.errorClass;
      final info = configured.configurationInfo;
      if ((pluginClass.isNotEmpty && !_errorClass.hasMatch(pluginClass)) ||
          info.length > 8 ||
          info.entries.any(
            (entry) =>
                !_errorClass.hasMatch(entry.key) ||
                utf8.encode(entry.value).length > 256,
          ) ||
          (configured.accepted &&
              (pluginClass.isNotEmpty || configured.fieldErrors.isNotEmpty)) ||
          (!configured.accepted && info.isNotEmpty)) {
        throw const OutputPluginException('plugin_protocol_error');
      }
      if (!configured.accepted) {
        final secretValues = secrets.values
            .map((value) => utf8.decode(value, allowMalformed: true))
            .where((value) => value.isNotEmpty);
        final fields = configured.fieldErrors
            .map((e) => e.field_1)
            .where(
              (field) =>
                  _field.hasMatch(field) && !secretValues.any(field.contains),
            )
            .toSet()
            .toList(growable: false);
        final classBytes = ascii.encode(pluginClass);
        final containsSecret = secrets.values.any(
          (secret) => _containsBytes(classBytes, secret),
        );
        throw OutputPluginException(
          'plugin_config_rejected',
          fields: List.unmodifiable(fields),
          pluginErrorClass: pluginClass.isEmpty || containsSecret
              ? null
              : pluginClass,
        );
      }
      final advertised = configured.limits;
      final events = math.min(64, advertised.maxEventsPerBatch);
      final bytes = math.min(1048576, advertised.maxBytesPerBatch.toInt());
      final outstanding = math.min(4, advertised.maxOutstandingBatches);
      if (events <= 0 || bytes <= 0 || outstanding <= 0) {
        throw const OutputPluginException('plugin_protocol_error');
      }
      final connection = OutputPluginConnection._(
        core,
        client,
        metadata,
        OutputPluginLimits(events, bytes, outstanding),
        configured.configurationInfo,
        shutdownGrace,
      );
      final responses = v1.OutputServiceClient(
        core.channel,
      ).deliver(connection._requests.stream);
      connection._responses = responses;
      connection._subscription = responses.listen(
        connection._receive,
        onError: (Object _, StackTrace _) {
          connection._fail(
            OutputPluginException(
              core.frameFailure == null
                  ? 'plugin_connection_lost'
                  : 'plugin_protocol_error',
            ),
          );
        },
        onDone: () => connection._fail(
          OutputPluginException(
            core.frameFailure == null
                ? 'plugin_connection_lost'
                : 'plugin_protocol_error',
          ),
        ),
      );
      unawaited(
        connection._exit.then(
          (_) => connection._fail(
            const OutputPluginException('plugin_connection_lost'),
          ),
        ),
      );
      return connection;
    } on Object catch (error) {
      final frameFailure = core.frameFailure;
      await core.stop();
      if (error is OutputPluginException) rethrow;
      if (frameFailure != null) {
        throw const OutputPluginException('plugin_metadata_invalid');
      }
      if (error is TimeoutException ||
          error is GrpcError && error.code == StatusCode.deadlineExceeded) {
        throw const OutputPluginException('plugin_start_timeout');
      }
      if (error is PluginStartupException) {
        throw const OutputPluginException('plugin_handshake_error');
      }
      throw const OutputPluginException('plugin_connection_lost');
    }
  }

  /// Checks application health with a bounded deadline.
  ///
  /// Observed connection loss wins over timeout completions. Otherwise, a gRPC
  /// failure at or past the deadline is a health timeout, regardless of status.
  Future<OutputPluginHealth> health({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    if (timeout <= Duration.zero) throw ArgumentError.value(timeout, 'timeout');
    final deadline = timeout < const Duration(seconds: 2)
        ? timeout
        : const Duration(seconds: 2);
    if (_stopped || _failure.isCompleted) {
      throw const OutputPluginException('plugin_connection_lost');
    }
    final stopwatch = Stopwatch()..start();
    try {
      final response = await _client
          .checkHealth(
            v1.CheckHealthRequest(),
            options: CallOptions(timeout: deadline),
          )
          .timeout(deadline);
      if (utf8.encode(response.reason).length > 256) {
        _fail(const OutputPluginException('plugin_protocol_error'));
        throw const OutputPluginException('plugin_protocol_error');
      }
      return OutputPluginHealth(response.serving, response.reason);
    } on TimeoutException catch (error) {
      throw OutputPluginException(
        classifyHealthFailure(
          error: error,
          elapsed: stopwatch.elapsed,
          deadline: deadline,
          connectionFailed: _stopped || _failure.isCompleted,
        ),
      );
    } on GrpcError catch (error) {
      throw OutputPluginException(
        classifyHealthFailure(
          error: error,
          elapsed: stopwatch.elapsed,
          deadline: deadline,
          connectionFailed: _stopped || _failure.isCompleted,
        ),
      );
    }
  }

  /// Sends one batch when a negotiated credit is available.
  Future<List<OutputPluginResult>> deliver(List<OutputPluginEvent> events) {
    if (_stopped || _failure.isCompleted) {
      throw const OutputPluginException('plugin_connection_lost');
    }
    if (_pending.length >= limits.maxOutstanding) {
      throw StateError('Plugin delivery credit exhausted');
    }
    final indexed = <String, OutputPluginEvent>{};
    var bytes = 0;
    for (final event in events) {
      if (event.id.isEmpty || indexed.containsKey(event.id)) {
        throw ArgumentError('Invalid event identifiers');
      }
      indexed[event.id] = event;
      bytes += event.payload.length;
    }
    if (events.isEmpty ||
        events.length > limits.maxEvents ||
        bytes > limits.maxBytes) {
      throw ArgumentError('Batch exceeds negotiated limits');
    }
    final sequence = ++_sequence;
    final request = v1.DeliverRequest(
      sequence: Int64(sequence),
      events: [
        for (final event in events)
          v1.Event(eventId: event.id, payload: event.payload),
      ],
    );
    if (request.writeToBuffer().length > 2 * 1024 * 1024) {
      throw ArgumentError('Batch exceeds gRPC limit');
    }
    final pending = _Pending(indexed);
    _pending[sequence] = pending;
    _requests.add(request);
    return pending.completer.future;
  }

  void _receive(v1.DeliverResponse response) {
    if (_stopped || _failure.isCompleted) return;
    final sequence = response.sequence.toInt();
    final pending = _pending[sequence];
    if (pending == null || response.results.length != pending.events.length) {
      _fail(const OutputPluginException('plugin_protocol_error'));
      return;
    }
    final seen = <String>{};
    final results = <OutputPluginResult>[];
    for (final result in response.results) {
      final outcome = switch (result.outcome) {
        v1.DeliveryOutcome.DELIVERY_OUTCOME_ACKNOWLEDGED =>
          OutputPluginOutcome.acknowledged,
        v1.DeliveryOutcome.DELIVERY_OUTCOME_RETRYABLE =>
          OutputPluginOutcome.retryable,
        v1.DeliveryOutcome.DELIVERY_OUTCOME_REJECTED =>
          OutputPluginOutcome.rejected,
        _ => null,
      };
      if (!pending.events.containsKey(result.eventId) ||
          !seen.add(result.eventId) ||
          outcome == null ||
          (outcome == OutputPluginOutcome.acknowledged
              ? result.errorClass.isNotEmpty
              : !_errorClass.hasMatch(result.errorClass))) {
        _fail(const OutputPluginException('plugin_protocol_error'));
        return;
      }
      results.add(
        OutputPluginResult(result.eventId, outcome, result.errorClass),
      );
    }
    _pending.remove(sequence);
    pending.completer.complete(List.unmodifiable(results));
  }

  void _fail(OutputPluginException error, {Duration? grace}) {
    if (_stopped || _failure.isCompleted) return;
    _failure.complete(error);
    for (final pending in _pending.values) {
      pending.completer.completeError(error);
    }
    _pending.clear();
    unawaited(_requests.close());
    unawaited(
      _core
          .stopWithGrace(grace ?? _shutdownGrace)
          .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }

  /// Cancels outstanding work and gracefully stops or forcibly reaps the child.
  Future<void> stop({Duration? grace}) async {
    final effectiveGrace = grace ?? _shutdownGrace;
    if (effectiveGrace.isNegative) {
      throw ArgumentError.value(effectiveGrace, 'grace');
    }
    if (_stopped) return;
    _fail(
      const OutputPluginException('plugin_connection_lost'),
      grace: effectiveGrace,
    );
    _stopped = true;
    await _subscription?.cancel();
    await _responses?.cancel();
    await _requests.close();
    await _core.stopWithGrace(effectiveGrace);
  }
}

bool _containsBytes(List<int> value, List<int> needle) {
  if (needle.isEmpty || needle.length > value.length) return false;
  for (var start = 0; start <= value.length - needle.length; start++) {
    var match = true;
    for (var i = 0; i < needle.length; i++) {
      if (value[start + i] != needle[i]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}
