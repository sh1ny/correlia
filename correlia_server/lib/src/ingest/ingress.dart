import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:serverpod/serverpod.dart';

import '../runtime/process_options.dart';
import '../runtime/subsystem.dart';
import '../secrets/secret_store.dart';
import 'admission.dart';
import 'bootstrap.dart';
import 'hmac_signing.dart';
import 'rate_limiter.dart';

/// Process-local admission totals for one currently registered source.
final class IngressCount {
  const IngressCount({
    this.received = 0,
    this.duplicate = 0,
    this.rejected = 0,
  });
  final int received;
  final int duplicate;
  final int rejected;
}

/// Bounded, non-authoritative counters for the active source registry.
final class IngressCounters {
  final Map<String, IngressCount> _counts = {};
  int _revision = 0;
  IngressCount _unknown = const IngressCount();

  /// Returns current counters, including the unknown-source bucket as `null`.
  Map<String?, IngressCount> snapshot() => {null: _unknown, ..._counts};

  void _rekey(Iterable<String> ids, int revision) {
    if (revision < _revision) return;
    _revision = revision;
    final active = ids.toSet();
    if (active.length > 64) throw StateError('source registry bound');
    _counts.removeWhere((key, _) => !active.contains(key));
    for (final id in active) {
      _counts.putIfAbsent(id, () => const IngressCount());
    }
  }

  void _increment(String? id, AdmissionOutcome? outcome) {
    final old = _counts[id] ?? _unknown;
    final next = IngressCount(
      received: old.received + (outcome == AdmissionOutcome.accepted ? 1 : 0),
      duplicate:
          old.duplicate + (outcome == AdmissionOutcome.duplicate ? 1 : 0),
      rejected:
          old.rejected +
          (outcome == null ||
                  outcome == AdmissionOutcome.unauthorized ||
                  outcome == AdmissionOutcome.conflict
              ? 1
              : 0),
    );
    if (_counts.containsKey(id)) {
      _counts[id!] = next;
    } else {
      _unknown = next;
    }
  }
}

/// Mounts session-independent Alertmanager admission before the console route.
final class IngressSubsystem extends Subsystem {
  IngressSubsystem({
    required this.pod,
    required this.bootstrap,
    required this.ready,
    required this.log,
    IngressCounters? counters,
    SecretLookupGate? lookupGate,
    Future<Uint8List> Function(String reference, String commitment)?
    secretResolver,
    DateTime Function()? clock,
    this._beforeBody,
  }) : counters = counters ?? IngressCounters(),
       _lookupGate = lookupGate ?? SecretLookupGate(),
       _resolve = secretResolver,
       _clock = clock ?? DateTime.now;

  final Serverpod pod;
  final IngestBootstrap? Function() bootstrap;
  final bool Function() ready;
  final void Function(String) log;
  final IngressCounters counters;
  bool _ready = false;
  int _inflight = 0;
  final SecretLookupGate _lookupGate;
  final Future<Uint8List> Function(String, String)? _resolve;
  final DateTime Function() _clock;
  final Future<void> Function()? _beforeBody;
  final _limiter = IngressRateLimiter();

  /// The number of requests occupying an admission slot.
  int get inFlight => _inflight;

  @override
  String get name => 'ingress';
  @override
  Set<ProcessRole> get roles => const {ProcessRole.api, ProcessRole.all};
  @override
  void mountRoutes(RouteHost host) {
    host.addRoute(_IngressRoute(this), '/hooks/**');
    host.addRoute(_IngressRoute(this), '/hooks');
  }

  @override
  Future<void> start() async {
    final input = bootstrap();
    counters._rekey(
      input?.sources.map((source) => source.id) ?? const <String>[],
      input?.revision ?? 0,
    );
    _ready = true;
  }

  @override
  Future<void> stop() async {
    _ready = false;
  }
}

final class _IngressRoute extends Route {
  _IngressRoute(this.owner) : super(methods: Method.values.toSet());
  final IngressSubsystem owner;
  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );
  static final _credential = RegExp(r'^[A-Za-z0-9_-]{43}$');

  static final _timestamp = RegExp(r'^[0-9]{1,10}$');
  static final _signature = RegExp(r'^sha256=[0-9a-f]{64}$');

  Response _response(int status, [int? retryAfter]) {
    final retry = retryAfter ?? (status == 503 ? 1 : null);
    return Response(
      status,
      headers: retry == null
          ? null
          : Headers.fromMap({
              'retry-after': ['$retry'],
            }),
    );
  }

  Response _reject(int status, String? source) {
    owner.counters._increment(source, null);
    try {
      owner.log('ingress source=${source ?? 'unknown'} outcome=$status');
    } catch (_) {}
    return _response(status);
  }

  @override
  Future<Result> call(Request request) async {
    if (owner.bootstrap() == null || !owner.ready() || !owner._ready) {
      return _response(503);
    }
    final observedAt = owner._clock().toUtc();
    final segments = request.url.pathSegments;
    if ((segments.length != 3 && segments.length != 4) ||
        segments.first != 'hooks') {
      return _reject(400, null);
    }
    final [_, kind, id, ...] = segments;
    final source = _uuid.hasMatch(id) ? id.toLowerCase() : null;
    if (request.method != Method.post) return _reject(405, source);
    if (request.url.hasQuery) return _reject(400, source);
    if (owner._inflight >= 16) return _reject(503, source);
    owner._inflight++;
    var result = const _Result(503);
    try {
      final assertion = _assertion(request, segments, observedAt);
      if (source == null || assertion == null) {
        result = const _Result(401);
      } else {
        final session = await owner.pod.createSession(enableLogging: false);
        try {
          result = await _authenticateAndAdmit(
            session,
            request,
            source,
            kind,
            assertion,
            observedAt,
          );
        } finally {
          await session.close();
        }
      }
    } catch (_) {
      result = const _Result(503);
    } finally {
      owner._inflight--;
      owner.counters._increment(source, result.outcome);
      try {
        owner.log(
          'ingress source=${source ?? 'unknown'} outcome=${result.status}',
        );
      } catch (_) {}
    }
    return _response(result.status, result.retryAfter);
  }

  _Assertion? _assertion(
    Request request,
    List<String> path,
    DateTime observedAt,
  ) {
    final auth = request.headers['authorization']?.toList();
    final timestamp = request.headers['x-correlia-timestamp']?.toList();
    final signature = request.headers['x-correlia-signature']?.toList();
    final pathToken = path.length == 4;
    if (timestamp != null || signature != null) {
      if (auth != null ||
          pathToken ||
          timestamp == null ||
          timestamp.length != 1 ||
          signature == null ||
          signature.length != 1 ||
          !_timestamp.hasMatch(timestamp.single) ||
          !_signature.hasMatch(signature.single)) {
        return null;
      }
      final epoch =
          int.parse(timestamp.single) * Duration.microsecondsPerSecond;
      if ((observedAt.microsecondsSinceEpoch - epoch).abs() >
          300 * Duration.microsecondsPerSecond) {
        return null;
      }
      return _Hmac(timestamp.single, signature.single.substring(7));
    }
    if (pathToken && auth != null) return null;
    final String token;
    if (pathToken) {
      token = path[3];
    } else if (auth case [final value] when value.startsWith('Bearer ')) {
      token = value.substring(7);
    } else {
      return null;
    }
    if (!_credential.hasMatch(token)) return null;
    try {
      final bytes = decodeCredential(
        token,
        fileKind: 'secrets',
        field: 'value',
      );
      return _Bearer(sha256.convert(bytes).toString(), pathToken);
    } on BootstrapError {
      return null;
    }
  }

  Future<_Result> _authenticateAndAdmit(
    Session session,
    Request request,
    String source,
    String kind,
    _Assertion assertion,
    DateTime observedAt,
  ) async {
    final rows = await owner._lookupGate.run(
      () => session.db.unsafeQuery(
        '''SELECT s.kind,s.enabled,s."allowPathToken",c."publicJson",c.revision,
             credential.reference,credential.digest,credential."notBefore",credential."notAfter"
           FROM ingest_active_config a JOIN ingest_config_snapshot c ON c."snapshotId"=a."snapshotId"
           LEFT JOIN ingest_source s ON s."sourceId"=CAST(@source AS uuid)
           LEFT JOIN ingest_source_credential credential
             ON credential."sourceId"=s."sourceId" AND credential.type=@type
           WHERE a.singleton=1 ORDER BY credential.reference LIMIT 4''',
        parameters: QueryParameters.named({
          'source': source,
          'type': assertion.type.name,
        }),
        timeoutInSeconds: 5,
      ),
    );
    if (rows.isEmpty) return const _Result(401);
    final first = rows.first;
    final revision = first[4]! as int;
    final config = jsonDecode(first[3]! as String) as Map<String, Object?>;
    final sources = (config['sources']! as List<Object?>)
        .cast<Map<String, Object?>>();
    owner.counters._rekey(sources.map((s) => s['id']! as String), revision);
    owner._limiter.rekey(revision);
    final pathToken = assertion is _Bearer && assertion.pathToken;
    if (first[0] != kind ||
        first[1] != true ||
        (pathToken && first[2] != true)) {
      return const _Result(401);
    }
    final entry = sources.where((s) => s['id'] == source).firstOrNull;
    if (entry == null) return const _Result(401);
    final rate = switch (entry['rate_limit']) {
      {'per_second': final int rate, 'burst': final int burst} =>
        SourceRateLimit(perSecond: rate, burst: burst),
      _ => const SourceRateLimit(), // Existing M1 public snapshots.
    };
    List<SourceCredential>? eligible;
    SourceCredential? matched;
    for (final row in rows) {
      if (row[5] case final String reference) {
        final credential = SourceCredential(
          reference,
          assertion.type,
          row[6]! as String,
          (row[7] as DateTime?)?.toUtc(),
          (row[8] as DateTime?)?.toUtc(),
        );
        if (!credential.validAt(observedAt)) continue;
        if (assertion case _Bearer(:final digest)) {
          if (constantTimeDigestEquals(credential.digest, digest)) {
            matched ??= credential;
          }
        } else {
          (eligible ??= []).add(credential);
        }
      }
    }
    if (matched == null && eligible == null) return const _Result(401);
    if (matched != null) {
      final retry = owner._limiter.take(source, revision, rate, owner._clock());
      if (retry != null) return _Result(429, retryAfter: retry);
    }
    final types = request.headers['content-type']?.toList();
    final encodings = request.headers['content-encoding']?.toList();
    if (types == null ||
        types.length != 1 ||
        types.single.split(';').first.trim().toLowerCase() !=
            'application/json' ||
        (encodings != null &&
            (encodings.length != 1 ||
                encodings.single.toLowerCase() != 'identity'))) {
      return const _Result(415);
    }
    final keys = request.headers['idempotency-key']?.toList();
    if (keys != null &&
        (keys.length != 1 ||
            keys.single.isEmpty ||
            utf8.encode(keys.single).length > 256)) {
      return const _Result(400);
    }
    final idempotencyKey = keys?.single;
    final body = await _readBody(request, entry['body_limit_bytes']! as int);
    if (body == null) return const _Result(413);
    if (assertion case _Hmac(:final timestamp, :final signature)) {
      final resolve = owner._resolve;
      if (resolve == null) return const _Result(503);
      final prefix = ingressSigningPrefix(timestamp, idempotencyKey);
      var unavailable = false;
      for (final credential in eligible!) {
        try {
          final key = await resolve(credential.reference, credential.digest);
          if (constantTimeDigestEquals(
            signIngress(key, prefix, body),
            signature,
          )) {
            matched ??= credential;
          }
        } on SecretResolutionError catch (error) {
          unavailable |= error.code == 'store_unavailable';
        }
      }
      if (matched == null) return _Result(unavailable ? 503 : 401);
      final retry = owner._limiter.take(source, revision, rate, owner._clock());
      if (retry != null) return _Result(429, retryAfter: retry);
    }
    final outcome = await IngestAdmission(session).admit(
      sourceId: source,
      kind: kind,
      credential: matched!,
      pathToken: pathToken,
      body: body,
      contentType: 'application/json',
      observedAt: observedAt,
      idempotencyKey: idempotencyKey,
    );
    return _Result(switch (outcome) {
      AdmissionOutcome.accepted || AdmissionOutcome.duplicate => 202,
      AdmissionOutcome.conflict => 409,
      AdmissionOutcome.unauthorized => 401,
    }, outcome: outcome);
  }

  Future<Uint8List?> _readBody(Request request, int limit) async {
    final iterator = StreamIterator(request.read());
    final bytes = BytesBuilder(copy: false);
    final watch = Stopwatch()..start();
    var overflow = false;
    var onFirstChunk = owner._beforeBody;
    try {
      while (await iterator.moveNext().timeout(
        const Duration(seconds: 10) - watch.elapsed,
      )) {
        // Drain without buffering until EOF or the deadline. Cancelling a
        // live HttpRequest stream aborts its response.
        if (overflow || bytes.length + iterator.current.length > limit) {
          overflow = true;
        } else {
          bytes.add(iterator.current);
        }
        if (onFirstChunk case final gate?) {
          onFirstChunk = null;
          await gate();
        }
      }
    } finally {
      await iterator.cancel();
    }
    return overflow ? null : bytes.takeBytes();
  }

  @override
  Result handleCall(Session session, Request request) => _response(503);
}

final class _Result {
  const _Result(this.status, {this.outcome, this.retryAfter});
  final int status;
  final AdmissionOutcome? outcome;
  final int? retryAfter;
}

sealed class _Assertion {
  SourceCredentialType get type;
}

final class _Bearer implements _Assertion {
  const _Bearer(this.digest, this.pathToken);
  final String digest;
  final bool pathToken;
  @override
  SourceCredentialType get type => SourceCredentialType.bearer;
}

final class _Hmac implements _Assertion {
  const _Hmac(this.timestamp, this.signature);
  final String timestamp;
  final String signature;
  @override
  SourceCredentialType get type => SourceCredentialType.hmac;
}
