import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A local TLS Icinga2 API with an open event response and projected sync data.
final class IcingaConsumerLoopback {
  IcingaConsumerLoopback._(this.server, this.ca);

  final HttpServer server;
  final List<int> ca;
  final disconnected = Completer<void>();
  final subscriptions = <Socket>[];
  final firstSubscription = Completer<void>();
  final serviceQueries = StreamController<int>.broadcast();
  List<Object?> hosts = const [];
  List<Object?> services = const [];
  int reads = 0;
  String? expectedAuthorization;
  int hostsStatus = HttpStatus.ok;
  int servicesStatus = HttpStatus.ok;
  String? servicesBody;
  int subscriptionsReady = 0;
  Future<void> Function(HttpResponse response)? serveServices;

  Uri get url => Uri.https('127.0.0.1:${server.port}');

  static Future<IcingaConsumerLoopback> start() async {
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
    );
    server.listen((request) async {
      try {
        await fixture._serve(request);
      } on SocketException catch (error) {
        // During stop the peer may close a socket while an object query writes.
        if (error.osError?.errorCode case 32 || 104) return;
        rethrow;
      }
    });
    return fixture;
  }

  Future<void> _serve(HttpRequest request) async {
    await request.drain<void>();
    final response = request.response;
    response.headers.contentType = ContentType.json;
    switch (request.uri.path) {
      case '/v1/events':
        if (expectedAuthorization case final expected?
            when request.headers.value(HttpHeaders.authorizationHeader) !=
                expected) {
          response.statusCode = HttpStatus.unauthorized;
          await response.close();
          return;
        }
        final socket = await response.detachSocket(writeHeaders: false);
        subscriptions.add(socket);
        socket.listen(
          (_) {},
          onDone: () {
            if (!disconnected.isCompleted) disconnected.complete();
          },
          onError: (Object _, StackTrace _) {
            // A reader that stops with unread TLS output may reset the peer.
            if (!disconnected.isCompleted) disconnected.complete();
          },
        );
        unawaited(
          socket.done.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
        );
        // Close-delimited NDJSON headers, without a fake heartbeat or a blank line.
        socket.write(
          'HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n',
        );
        try {
          await socket.flush();
        } on SocketException {
          return; // The peer stopped during the header write.
        }
        subscriptionsReady++;
        if (!firstSubscription.isCompleted) firstSubscription.complete();
      case '/v1/objects/hosts':
        response.statusCode = hostsStatus;
        response.write(jsonEncode({'results': hosts}));
        await response.close();
      case '/v1/objects/services':
        response.statusCode = servicesStatus;
        if (serveServices case final serve?) {
          await serve(response);
          if (!serviceQueries.isClosed) serviceQueries.add(++reads);
          return;
        }
        response.write(servicesBody ?? jsonEncode({'results': services}));
        await response.close();
        if (!serviceQueries.isClosed) serviceQueries.add(++reads);
      default:
        response.statusCode = HttpStatus.notFound;
        await response.close();
    }
  }

  Future<void> send(Object? value) async {
    await firstSubscription.future.timeout(const Duration(seconds: 10));
    final response = subscriptions.last;
    response.writeln(jsonEncode(value));
    await response.flush();
  }

  Future<void> close() async {
    for (final socket in subscriptions) {
      socket.destroy();
    }
    await server.close(force: true);
    await serviceQueries.close();
  }
}
