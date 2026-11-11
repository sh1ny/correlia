import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:serverpod/serverpod.dart';

import '../runtime/process_options.dart';
import '../runtime/subsystem.dart';
import 'admission.dart';
import 'bootstrap.dart';

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
  }) : counters = counters ?? IngressCounters();

  final Serverpod pod;
  final IngestBootstrap? Function() bootstrap;
  final bool Function() ready;
  final void Function(String) log;
  final IngressCounters counters;
  bool _ready = false;
  int _inflight = 0;
  int _authLookups = 0;
  final Queue<Completer<void>> _authWaiters = Queue();

  Future<T> _lookup<T>(Future<T> Function() operation) async {
    if (_authLookups >= 4) {
      final waiter = Completer<void>();
      _authWaiters.addLast(waiter);
      try {
        await waiter.future.timeout(const Duration(seconds: 5));
      } catch (_) {
        _authWaiters.remove(waiter);
        rethrow;
      }
    } else {
      _authLookups++;
    }
    try {
      return await operation();
    } finally {
      if (_authWaiters.isEmpty) {
        _authLookups--;
      } else {
        _authWaiters.removeFirst().complete();
      }
    }
  }

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

  Response _response(int status) => Response(
    status,
    headers: status == 503
        ? Headers.fromMap({
            'retry-after': ['1'],
          })
        : null,
  );

  Response _reject(int status, String? source) {
    owner.counters._increment(source, null);
    try {
      owner.log('ingress source=${source ?? 'unknown'} outcome=$status');
    } catch (_) {}
    return _response(status);
  }

  @override
  Future<Result> call(Request request) async {
    String? source;
    var acquired = false;
    Session? session;
    var status = 503;
    AdmissionOutcome? outcome;
    try {
      if (owner.bootstrap() == null || !owner.ready() || !owner._ready) {
        return _response(503);
      }
      final observedAt = DateTime.now().toUtc();
      final segments = request.url.pathSegments;
      if (segments
          case ['hooks', 'alertmanager', final id] ||
              ['hooks', 'alertmanager', final id, _]) {
        if (_uuid.hasMatch(id)) source = id.toLowerCase();
      } else {
        return _reject(400, null);
      }
      if (request.method != Method.post) return _reject(405, source);
      if (request.url.hasQuery) return _reject(400, source);
      if (owner._inflight >= 16) return _reject(503, source);
      owner._inflight++;
      acquired = true;
      final authorization = request.headers['authorization']?.toList();
      final pathToken = segments.length == 4;
      if (source == null ||
          (pathToken && authorization != null) ||
          (authorization != null && authorization.length != 1)) {
        status = 401;
      } else {
        final auth = authorization?.single;
        final token = pathToken
            ? segments[3]
            : (auth != null && auth.startsWith('Bearer ')
                  ? auth.substring(7)
                  : '');
        Uint8List? decoded;
        if (_credential.hasMatch(token)) {
          try {
            decoded = decodeCredential(
              token,
              fileKind: 'secrets',
              field: 'value',
            );
          } catch (_) {
            decoded = null;
          }
        }
        if (decoded == null) {
          status = 401;
        } else {
          final digest = sha256.convert(decoded).toString();
          session = await owner.pod.createSession(enableLogging: false);
          final rows = await owner._lookup(
            () => session!.db.unsafeQuery(
              '''SELECT s."tokenDigest",s.enabled,s."allowPathToken",c."publicJson",c.revision
            FROM ingest_active_config a JOIN ingest_config_snapshot c ON c."snapshotId"=a."snapshotId"
            LEFT JOIN ingest_source s ON s."sourceId"=CAST(@source AS uuid) WHERE a.singleton=1''',
              parameters: QueryParameters.named({'source': source}),
              timeoutInSeconds: 5,
            ),
          );
          if (rows.isNotEmpty) {
            final json =
                jsonDecode(rows.single[3]! as String) as Map<String, Object?>;
            final sources = (json['sources']! as List<Object?>)
                .cast<Map<String, Object?>>();
            owner.counters._rekey(
              sources.map((s) => s['id']! as String),
              rows.single[4]! as int,
            );
          }
          if (rows.isEmpty ||
              rows.single[1] != true ||
              (pathToken && rows.single[2] != true) ||
              !constantTimeDigestEquals(rows.single[0]! as String, digest)) {
            status = 401;
          } else {
            final config =
                jsonDecode(rows.single[3]! as String) as Map<String, Object?>;
            final sources = (config['sources']! as List<Object?>)
                .cast<Map<String, Object?>>();
            final matches = sources.where((entry) => entry['id'] == source);
            if (matches.isEmpty) {
              status = 401;
            } else {
              final limit = matches.single['body_limit_bytes']! as int;
              final types = request.headers['content-type']?.toList();
              final encodings = request.headers['content-encoding']?.toList();
              final keys = request.headers['idempotency-key']?.toList();
              if (types == null ||
                  types.length != 1 ||
                  types.single.split(';').first.trim().toLowerCase() !=
                      'application/json' ||
                  (encodings != null &&
                      (encodings.length != 1 ||
                          encodings.single.toLowerCase() != 'identity'))) {
                status = 415;
              } else if (keys != null &&
                  (keys.length != 1 ||
                      keys.single.isEmpty ||
                      utf8.encode(keys.single).length > 256)) {
                status = 400;
              } else {
                final iterator = StreamIterator(request.read());
                final bytes = BytesBuilder(copy: false);
                final watch = Stopwatch()..start();
                var overflow = false;
                try {
                  while (await iterator.moveNext().timeout(
                    const Duration(seconds: 10) - watch.elapsed,
                  )) {
                    if (overflow || bytes.length + iterator.current.length > limit) {
                      overflow = true;
                      // Drain without buffering until EOF or the total deadline.
                      // Cancelling a live HttpRequest stream aborts its response.
                      continue;
                    }
                    bytes.add(iterator.current);
                  }
                } finally {
                  await iterator.cancel();
                }
                if (overflow) {
                  status = 413;
                } else {
                  outcome = await IngestAdmission(session).admit(
                    sourceId: source,
                    tokenDigest: digest,
                    pathToken: pathToken,
                    body: bytes.takeBytes(),
                    contentType: 'application/json',
                    observedAt: observedAt,
                    idempotencyKey: keys?.single,
                  );
                  status = switch (outcome) {
                    AdmissionOutcome.accepted ||
                    AdmissionOutcome.duplicate => 202,
                    AdmissionOutcome.conflict => 409,
                    AdmissionOutcome.unauthorized => 401,
                  };
                }
              }
            }
          }
        }
      }
    } catch (_) {
      status = 503;
      outcome = null;
    } finally {
      if (session != null) {
        try {
          await session.close();
        } catch (_) {
          status = 503;
        }
      }
      if (acquired) {
        owner._inflight--;
        owner.counters._increment(source, outcome);
        try {
          owner.log('ingress source=${source ?? 'unknown'} outcome=$status');
        } catch (_) {}
      }
    }
    return _response(status);
  }

  @override
  Result handleCall(Session session, Request request) => _response(503);
}
