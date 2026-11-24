import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A local TLS Icinga2 API with an open event response and projected sync data.
///
/// With strict socket errors, only a peer close on a socket explicitly marked
/// for shutdown is expected. Other transport errors fail waits and teardown.
final class IcingaConsumerLoopback {
  IcingaConsumerLoopback._(this.server, this.ca, this._strictSocketErrors) {
    _failure.future.ignore();
  }

  final HttpServer server;
  final List<int> ca;
  final disconnected = Completer<void>();
  final subscriptions = <Socket>[];
  final firstSubscription = Completer<void>();
  final serviceQueries = StreamController<int>.broadcast();
  List<Object?> hosts = const [];
  List<Object?> services = const [];
  int reads = 0;
  final eventRequests = <(String, String)>[];
  int? subscriptionStatus = HttpStatus.ok;
  bool chunked = false;
  String? expectedAuthorization;
  int hostsStatus = HttpStatus.ok;
  int servicesStatus = HttpStatus.ok;
  String? servicesBody;
  int subscriptionsReady = 0;
  final bool _strictSocketErrors;
  final _failure = Completer<Never>();
  final _expectedDisconnects = <Socket>{};
  var _changed = Completer<void>();
  int _hostsResponses = 0;
  int _disconnects = 0;
  Future<void> Function(HttpResponse response)? serveServices;

  Uri get url => Uri.https('127.0.0.1:${server.port}');

  static Future<IcingaConsumerLoopback> start({
    bool strictSocketErrors = false,
  }) async {
    const path = '../correlia_icinga2_notify/test/fixtures';
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      SecurityContext()
        ..useCertificateChain('$path/server_one.pem')
        ..usePrivateKey('$path/server_one.key'),
    );
    final fixture = IcingaConsumerLoopback._(
      server,
      await File('$path/ca_one.pem').readAsBytes(),
      strictSocketErrors,
    );
    server.listen((request) async {
      try {
        await fixture._serve(request);
      } catch (error, stack) {
        fixture._socketError(error, stack);
      }
    }, onError: fixture._reportError);
    return fixture;
  }

  void _reportError(Object error, StackTrace stack) {
    if (!_strictSocketErrors) {
      Zone.current.handleUncaughtError(error, stack);
    } else if (!_failure.isCompleted) {
      _failure.completeError(error, stack);
    }
  }

  void _socketError(Object error, StackTrace stack, {Socket? socket}) {
    // Linux EPIPE / ECONNRESET, not arbitrary socket or TLS errors.
    final peerClosed =
        error is SocketException &&
        (error.osError?.errorCode == 32 || error.osError?.errorCode == 104);
    if (peerClosed &&
        (!_strictSocketErrors || _expectedDisconnects.contains(socket))) {
      return;
    }
    _reportError(error, stack);
  }

  void _signalChange() {
    final changed = _changed;
    _changed = Completer<void>();
    changed.complete();
  }

  Future<void> _until(bool Function() ready) async {
    while (!ready()) {
      await checked(_changed.future);
    }
    if (_failure.isCompleted) await _failure.future;
  }

  /// Waits for [barrier] or an earlier unexpected fixture error.
  Future<T> checked<T>(Future<T> barrier) =>
      _strictSocketErrors ? Future.any<T>([barrier, _failure.future]) : barrier;

  /// Waits for [count] flushed subscription headers.
  Future<void> waitForSubscriptions(int count) =>
      _until(() => subscriptionsReady >= count);

  /// Waits for both projected object routes to have sent [count] responses.
  Future<void> waitForObjectResponses(int count) =>
      _until(() => _hostsResponses >= count && reads >= count);

  /// Allows peer-close errors on the established event sockets about to stop.
  void expectSubscriptionDisconnects() =>
      _expectedDisconnects.addAll(subscriptions);

  /// Waits for [count] event sockets to observe the other side closing.
  Future<void> waitForDisconnects(int count) =>
      _until(() => _disconnects >= count);

  Future<void> _serve(HttpRequest request) async {
    if (request.uri.path == '/v1/events') {
      eventRequests.add((
        request.method,
        await utf8.decoder.bind(request).join(),
      ));
    } else {
      await request.drain<void>();
    }
    final response = request.response;
    response.headers.contentType = ContentType.json;
    if (request.headers.value(HttpHeaders.acceptHeader) !=
        ContentType.json.mimeType) {
      response.statusCode = HttpStatus.badRequest;
      await response.close();
      return;
    }
    switch (request.uri.path) {
      case '/v1/events':
        if (expectedAuthorization case final expected?
            when request.headers.value(HttpHeaders.authorizationHeader) !=
                expected) {
          response.statusCode = HttpStatus.unauthorized;
          await response.close();
          return;
        }
        if (subscriptionStatus case final status?
            when status != HttpStatus.ok) {
          response.statusCode = status;
          await response.close();
          return;
        }
        final socket = await response.detachSocket(writeHeaders: false);
        subscriptions.add(socket);
        var readEnded = false;
        void disconnect() {
          if (readEnded) return;
          readEnded = true;
          _disconnects++;
          if (!disconnected.isCompleted) disconnected.complete();
          _signalChange();
        }

        socket.listen(
          (_) {},
          onDone: disconnect,
          onError: (Object error, StackTrace stack) {
            _socketError(error, stack, socket: socket);
            disconnect();
          },
        );
        unawaited(
          socket.done.then<void>(
            (_) {},
            onError: (Object error, StackTrace stack) =>
                _socketError(error, stack, socket: socket),
          ),
        );
        if (subscriptionStatus == null) return;
        socket.write(
          chunked
              ? 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n'
              : 'HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n',
        );
        try {
          await socket.flush();
        } on SocketException catch (error, stack) {
          _socketError(error, stack, socket: socket);
          return;
        }
        subscriptionsReady++;
        _signalChange();
        if (!firstSubscription.isCompleted) firstSubscription.complete();
      case '/v1/objects/hosts':
        response.statusCode = hostsStatus;
        response.write(jsonEncode({'results': hosts}));
        await Future.wait([response.close(), response.done]);
        _hostsResponses++;
        _signalChange();
      case '/v1/objects/services':
        response.statusCode = servicesStatus;
        if (serveServices case final serve?) {
          await serve(response);
          if (!serviceQueries.isClosed) serviceQueries.add(++reads);
          _signalChange();
          return;
        }
        response.write(servicesBody ?? jsonEncode({'results': services}));
        await Future.wait([response.close(), response.done]);
        if (!serviceQueries.isClosed) serviceQueries.add(++reads);
        _signalChange();
      default:
        response.statusCode = HttpStatus.notFound;
        await response.close();
    }
  }

  Future<void> send(Object? value) => sendLine(jsonEncode(value));

  Future<void> sendLine(String line) async {
    await waitForSubscriptions(1);
    final response = subscriptions.last;
    if (chunked) {
      final body = utf8.encode('$line\n');
      response.write('${body.length.toRadixString(16)}\r\n');
      response.add(body);
      response.write('\r\n');
    } else {
      response.writeln(line);
    }
    await response.flush();
  }

  Future<void> close() async {
    for (final socket in subscriptions) {
      socket.destroy();
    }
    await server.close(force: true);
    await serviceQueries.close();
    if (_failure.isCompleted) await _failure.future;
  }
}
