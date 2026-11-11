import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../ingest/bootstrap.dart';
import 'output_relay.dart';

/// Sends a pinned delivery to its webhook without following redirects.
final class WebhookOutput implements Output {
  /// Creates a sender for the specified Serverpod run mode.
  WebhookOutput({
    required this.runMode,
    this.deadline = const Duration(seconds: 10),
  });

  /// The run mode used for URL validation.
  final String runMode;

  /// The total request and response deadline.
  final Duration deadline;
  final Set<HttpClient> _clients = {};
  bool _closed = false;

  /// Sends exactly the persisted structured CloudEvent bytes.
  @override
  Future<DeliveryOutcome> send(DeliveryIntent intent, Uint8List key) async {
    if (_closed) return const DeliveryRetryable('shutdown');
    final Uri uri;
    try {
      uri = validateWebhookUrl(intent.targetUrl, runMode: runMode);
    } on BootstrapError {
      return const DeliveryPermanent('invalid_url');
    }
    final client = HttpClient();
    _clients.add(client);
    try {
      return await (() async {
        final request = await client.postUrl(uri);
        request.followRedirects = false;
        request.headers.set(
          HttpHeaders.contentTypeHeader,
          'application/cloudevents+json',
        );
        request.headers.set('Idempotency-Key', intent.eventId);
        request.headers.set(
          'X-Correlia-Signature',
          'sha256=${Hmac(sha256, key).convert(intent.payload)}',
        );
        request.add(intent.payload);
        final response = await request.close();
        final status = response.statusCode;
        var bytes = 0;
        await for (final chunk in response) {
          bytes += chunk.length;
          if (bytes > 65536) {
            client.close(force: true);
            break;
          }
        }
        if (status >= 200 && status < 300) return const DeliveryAcknowledged();
        if (status == 408 || status == 429 || status >= 500 && status <= 599) {
          return const DeliveryRetryable('http_retryable');
        }
        return const DeliveryPermanent('http_permanent');
      })().timeout(
        deadline,
        onTimeout: () {
          client.close(force: true);
          return const DeliveryRetryable('timeout');
        },
      );
    } on SocketException {
      return const DeliveryRetryable('network');
    } on HttpException {
      return const DeliveryRetryable('network');
    } on TimeoutException {
      return const DeliveryRetryable('timeout');
    } finally {
      _clients.remove(client);
      client.close(force: true);
    }
  }

  /// Cancels all in-flight requests and prevents further sends.
  void close() {
    _closed = true;
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
  }
}
