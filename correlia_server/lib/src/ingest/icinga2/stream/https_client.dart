import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'subscription.dart';
import 'sync_reader.dart';
import 'tls_socket.dart';

/// A bounded, non-diagnostic transport failure.
final class StreamHttpFailure implements Exception {
  const StreamHttpFailure(this.code);

  final String code;

  @override
  String toString() => 'StreamHttpFailure($code)';
}

/// Exclusive-CA HTTPS transport for one leased Event Streams consumer.
final class IcingaStreamHttpClient {
  IcingaStreamHttpClient({
    required this.endpoint,
    required this.username,
    required List<int> password,
    required List<int> ca,
    bool Function()? isLive,
    this.headerDeadline = const Duration(seconds: 10),
  }) : _password = List<int>.of(password),
       _isLive = isLive ?? _alwaysLive,
       _context = SecurityContext(withTrustedRoots: false)
         ..setTrustedCertificatesBytes(ca)
         ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_2 {
    if (endpoint.scheme != 'https' ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty) {
      throw ArgumentError.value(
        endpoint,
        'endpoint',
        'HTTPS endpoint required',
      );
    }
  }

  final Uri endpoint;
  final String username;
  final List<int> _password;
  final bool Function() _isLive;
  final SecurityContext _context;
  final Duration headerDeadline;
  final _transactions = <_HttpTransaction>{};
  bool _closed = false;

  static bool _alwaysLive() => true;
  bool get _live => !_closed && _isLive();

  /// Opens the streaming event subscription.
  Future<SyncResponse> subscribe(
    String queue, {
    Future<void> Function()? authorize,
  }) => _request(
    '/v1/events',
    {'queue': queue, 'types': streamTypes},
    rejectStatus: true,
    authorize: authorize,
  );

  /// Opens one projected object query, including non-success HTTP statuses.
  Future<SyncResponse> query(SyncProjection projection) => _request(
    projection.path,
    {'attrs': projection.attrs},
    overrideGet: true,
  );
  Future<SyncResponse> _request(
    String path,
    Map<String, Object> body, {
    bool overrideGet = false,
    bool rejectStatus = false,
    Future<void> Function()? authorize,
  }) async {
    if (!_live) throw const StreamHttpFailure('interrupted');
    final transaction = _HttpTransaction(_context, _liveCheck, authorize);
    _transactions.add(transaction);
    final timer = Timer(headerDeadline, () => transaction.abort('timeout'));
    try {
      final response = await Future.any([
        _send(transaction, path, body, overrideGet),
        transaction.cancelled,
      ]);
      timer.cancel();
      if (rejectStatus && response.statusCode != HttpStatus.ok) {
        transaction.abort('interrupted');
        _transactions.remove(transaction);
        throw StreamHttpFailure(switch (response.statusCode) {
          HttpStatus.unauthorized => 'unauthorized',
          HttpStatus.forbidden => 'forbidden',
          _ => 'http_status',
        });
      }
      if (!_live) {
        transaction.abort('interrupted');
        throw const StreamHttpFailure('interrupted');
      }
      return SyncResponse(response.statusCode, _body(response, transaction));
    } on StreamHttpFailure catch (error) {
      timer.cancel();
      transaction.abort('interrupted');
      _transactions.remove(transaction);
      if (overrideGet && error.code == 'timeout') {
        throw TimeoutException('Icinga query header deadline');
      }
      rethrow;
    } on Object catch (error) {
      timer.cancel();
      transaction.abort('interrupted');
      _transactions.remove(transaction);
      throw StreamHttpFailure(
        error is HandshakeException || error is TlsException
            ? 'tls'
            : 'connection',
      );
    }
  }

  bool _liveCheck() => _live;

  Future<HttpClientResponse> _send(
    _HttpTransaction transaction,
    String path,
    Map<String, Object> body,
    bool overrideGet,
  ) async {
    final request = await transaction.client.postUrl(
      Uri(
        scheme: 'https',
        host: endpoint.host,
        port: endpoint.hasPort ? endpoint.port : null,
        path: path,
      ),
    );
    if (!_live) throw const StreamHttpFailure('interrupted');
    request.followRedirects = false;
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.acceptHeader, ContentType.json.mimeType);
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Basic ${base64.encode([...utf8.encode('$username:'), ..._password])}',
    );
    if (overrideGet) request.headers.set('X-HTTP-Method-Override', 'GET');
    request.write(jsonEncode(body));
    return request.close();
  }

  Stream<List<int>> _body(
    HttpClientResponse response,
    _HttpTransaction transaction,
  ) {
    void release() {
      transaction.abort('interrupted');
      _transactions.remove(transaction);
    }

    StreamSubscription<List<int>>? subscription;
    late final StreamController<List<int>> output;
    output = StreamController<List<int>>(
      sync: true,
      onListen: () {
        subscription = response.listen(
          output.add,
          onError: output.addError,
          onDone: () {
            unawaited(output.close());
            release();
          },
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () async {
        release();
        await subscription?.cancel();
      },
    );
    return output.stream;
  }

  /// Aborts pending requests and streams already returned to callers.
  void close() {
    if (_closed) return;
    _closed = true;
    for (final transaction in _transactions.toList()) {
      transaction.abort('interrupted');
    }
    _transactions.clear();
    _password.fillRange(0, _password.length, 0);
  }
}

final class _HttpTransaction {
  _HttpTransaction(
    SecurityContext context,
    this.live,
    Future<void> Function()? authorize,
  ) {
    client = HttpClient(context: context)
      ..findProxy = ((_) => 'DIRECT')
      ..connectionFactory = (uri, _, _) async {
        if (_aborted || !live()) throw const StreamHttpFailure('interrupted');
        final attempt = TlsAttempt(
          uri.host,
          uri.port,
          context,
          () => !_aborted && live(),
        );
        _attempt = attempt;
        final task = attempt.start();
        if (authorize == null) return task;
        final ready = _authorizationSocket = Completer<Socket>();
        unawaited(_authorize(task, authorize, ready));
        return ConnectionTask.fromSocket(
          ready.future,
          () => abort('interrupted'),
        );
      };
  }

  final bool Function() live;
  late final HttpClient client;
  final _cancelled = Completer<HttpClientResponse>();
  Completer<Socket>? _authorizationSocket;
  TlsAttempt? _attempt;
  bool _aborted = false;
  Future<HttpClientResponse> get cancelled => _cancelled.future;

  Future<void> _authorize(
    ConnectionTask<Socket> task,
    Future<void> Function() authorize,
    Completer<Socket> ready,
  ) async {
    try {
      final socket = await task.socket;
      if (!_aborted && live()) await authorize();
      if (_aborted || !live()) {
        socket.destroy();
        throw const StreamHttpFailure('interrupted');
      }
      if (!ready.isCompleted) ready.complete(socket);
    } on Object catch (error, stack) {
      if (!ready.isCompleted) ready.completeError(error, stack);
    } finally {
      _authorizationSocket = null;
    }
  }

  void abort(String code) {
    if (_aborted) return;
    _aborted = true;
    final ready = _authorizationSocket;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(StreamHttpFailure(code));
    }
    _attempt?.abort();
    client.close(force: true);
    if (!_cancelled.isCompleted) {
      _cancelled.completeError(StreamHttpFailure(code));
    }
  }
}
