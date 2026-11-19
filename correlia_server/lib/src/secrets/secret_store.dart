import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:serverpod/serverpod.dart';

import '../generated/protocol.dart';
import '../ingest/bootstrap.dart';
import 'aead.dart';
import 'commitments.dart';

const _algorithm = 'aes-256-gcm-v1';

/// A fixed failure code safe to report without record or database details.
final class SecretResolutionError implements Exception {
  /// Creates a sanitized secret-resolution failure.
  const SecretResolutionError(this.code);

  /// The fixed reason for the failure.
  final String code;

  @override
  String toString() => code;
}

/// Coordinates bounded database lookups within one process.
final class SecretLookupGate {
  final _waiters = Queue<Completer<void>>();
  int _running = 0;

  /// Runs [operation] with at most four concurrent lookups.
  Future<T> run<T>(Future<T> Function() operation) async {
    if (_running == 4) {
      final waiter = Completer<void>();
      _waiters.addLast(waiter);
      try {
        await waiter.future.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        if (_waiters.remove(waiter)) rethrow;
      }
    } else {
      _running++;
    }
    try {
      return await operation();
    } finally {
      if (_waiters.isEmpty) {
        _running--;
      } else {
        _waiters.removeFirst().complete();
      }
    }
  }
}

/// Encrypts and verifies immutable records under one external key.
final class SecretStore {
  /// Derives the commitment key and initializes AES-GCM.
  SecretStore(Uint8List key)
    : commitments = SecretCommitments(key),
      _aead = SecretAead(key);

  /// The scheme-aware verification primitives for this store.
  final SecretCommitments commitments;
  final SecretAead _aead;

  /// Rejects startup with the wrong key even if active references changed.
  Future<void> checkKey(Session session, Transaction transaction) async {
    final rows = await session.db.unsafeQuery(
      'SELECT 1 FROM secret_record WHERE "keyCommitment" <> @key LIMIT 1',
      parameters: QueryParameters.named({'key': commitments.keyCommitment}),
      transaction: transaction,
      timeoutInSeconds: 5,
    );
    if (rows.isNotEmpty) {
      throw const BootstrapError('secret_key', r'$', 'key_mismatch');
    }
  }

  /// Reads and authenticates one stored record, or returns null if absent.
  Future<Uint8List?> read(
    Session session,
    String reference, {
    Transaction? transaction,
  }) async {
    final rows = await session.db.unsafeQuery(
      '''SELECT algorithm,nonce,ciphertext,commitment,"keyCommitment"
      FROM secret_record WHERE reference = @reference''',
      parameters: QueryParameters.named({'reference': reference}),
      transaction: transaction,
      timeoutInSeconds: 5,
    );
    return rows.isEmpty ? null : _open(reference, rows.single);
  }

  /// Reads and authenticates a publication's stored references in one query.
  Future<Map<String, Uint8List>> readMany(
    Session session,
    Iterable<String> references, {
    required Transaction? transaction,
  }) async {
    if (references.isEmpty) return const {};
    final rows = await session.db.unsafeQuery(
      '''SELECT algorithm,nonce,ciphertext,commitment,"keyCommitment",reference
      FROM secret_record
      WHERE reference IN (SELECT jsonb_array_elements_text(CAST(@refs AS jsonb)))''',
      parameters: QueryParameters.named({
        'refs': jsonEncode(references.toList()),
      }),
      transaction: transaction,
      timeoutInSeconds: 5,
    );
    return {
      for (final row in rows)
        (row[5]! as String): _open(row[5]! as String, row),
    };
  }

  Uint8List _open(String reference, DatabaseResultRow row) {
    final commitment = row[3]! as String;
    final keyCommitment = row[4]! as String;
    if (keyCommitment != commitments.keyCommitment) {
      throw const SecretResolutionError('key_mismatch');
    }
    if (row[0] != _algorithm) {
      throw const SecretResolutionError('secret_integrity');
    }
    try {
      final bytes = _aead.open(
        row[1]! as Uint8List,
        row[2]! as Uint8List,
        _aad(reference, commitment, keyCommitment),
      );
      if (!commitments.verify(reference, commitment, bytes)) {
        throw const SecretResolutionError('secret_integrity');
      }
      return bytes.asUnmodifiableView();
    } on SecretIntegrityError {
      throw const SecretResolutionError('secret_integrity');
    }
  }

  /// Inserts a previously absent reference in the locked publication.
  Future<void> insert(
    Session session,
    Transaction transaction,
    String reference,
    Uint8List bytes, {
    required bool plugin,
  }) async {
    final commitment = plugin
        ? commitments.plugin(reference, bytes)
        : legacySecretCommitment(bytes);
    final keyCommitment = commitments.keyCommitment;
    final record = _aead.seal(
      bytes,
      _aad(reference, commitment, keyCommitment),
    );
    await SecretRecord.db.insertRow(
      session,
      SecretRecord(
        reference: reference,
        algorithm: _algorithm,
        nonce: ByteData.sublistView(record.nonce),
        ciphertext: ByteData.sublistView(record.ciphertext),
        commitment: commitment,
        keyCommitment: keyCommitment,
        createdAt: DateTime.now().toUtc(),
      ),
      transaction: transaction,
    );
  }
}

final _aadDomain = utf8.encode('correlia-secret-v1');

Uint8List _aad(String reference, String commitment, String keyCommitment) {
  final fields = [
    _aadDomain,
    utf8.encode(reference),
    utf8.encode(commitment),
    utf8.encode(keyCommitment),
  ];
  final result = Uint8List(
    fields.fold(0, (length, field) => length + 4 + field.length),
  );
  final view = ByteData.sublistView(result);
  var offset = 0;
  for (final field in fields) {
    view.setUint32(offset, field.length);
    offset += 4;
    result.setRange(offset, offset + field.length, field);
    offset += field.length;
  }
  return result;
}

/// Resolves and checks immutable stored material through a bounded local LRU.
final class SecretResolver {
  /// Creates a resolver sharing [gate] with the ingress lookup path.
  SecretResolver({
    required this._store,
    required this._openSession,
    required this._log,
    SecretLookupGate? gate,
    this._maxEntries = 1024,
    this._maxBytes = 16 * 1024 * 1024,
  }) : _gate = gate ?? SecretLookupGate();

  final SecretStore _store;
  final Future<Session> Function() _openSession;
  final void Function(String) _log;
  final SecretLookupGate _gate;
  final int _maxEntries;
  final int _maxBytes;
  final _entries = <String, Uint8List>{};
  int _size = 0;

  /// Prefills remaining capacity from the active references and live pins.
  Future<void> prefill(Session session, Iterable<String> active) async {
    final rows = await session.db.unsafeQuery(
      '''WITH candidates AS (
        SELECT value AS reference, true AS active FROM jsonb_array_elements_text(CAST(@active AS jsonb))
        UNION ALL
        SELECT signing_key_ref, false FROM outbox
        WHERE output_kind='webhook' AND status IN ('queued','delivering')
        UNION ALL
        SELECT entry.value->>'reference', false FROM outbox o
        JOIN ingest_config_snapshot s ON s."snapshotId"=o.config_snapshot_id
        CROSS JOIN LATERAL jsonb_array_elements(s."publicJson"::jsonb->'outputs') output
        CROSS JOIN LATERAL jsonb_each(COALESCE(output->'secret_refs','{}'::jsonb)) entry
        WHERE o.output_kind='plugin' AND o.status IN ('queued','delivering')
          AND output->>'id'=o.output_id::text
      ), wanted AS (
        SELECT reference, bool_or(active) AS active FROM candidates GROUP BY reference
      )
      SELECT algorithm, nonce, ciphertext, commitment, "keyCommitment", r.reference
      FROM wanted JOIN secret_record r USING (reference)
      ORDER BY wanted.active DESC, r.reference LIMIT @limit''',
      parameters: QueryParameters.named({
        'active': jsonEncode(active.toSet().toList()),
        'limit': _maxEntries,
      }),
      timeoutInSeconds: 5,
    );
    for (final row in rows) {
      final reference = row[5]! as String;
      try {
        final bytes = _store._open(reference, row);
        if (_size + bytes.length > _maxBytes) break;
        _size += bytes.length - (_entries[reference]?.length ?? 0);
        _entries[reference] = bytes;
      } on SecretResolutionError catch (error) {
        _log('secrets reference=$reference code=${error.code}');
      }
    }
  }

  /// Resolves [reference] if it matches the caller's pinned [commitment].
  Future<Uint8List> resolve(String reference, String commitment) async {
    try {
      var bytes = _entries.remove(reference);
      if (bytes == null) {
        bytes = await _gate.run(() async {
          final session = await _openSession();
          try {
            return await _store.read(session, reference);
          } finally {
            await session.close();
          }
        });
        if (bytes == null) throw const SecretResolutionError('missing_secret');
        // A concurrent miss may have filled this entry while the read ran.
        _size -= _entries.remove(reference)?.length ?? 0;
        _size += bytes.length;
      }
      _entries[reference] = bytes;
      while (_entries.length > _maxEntries || _size > _maxBytes) {
        _size -= _entries.remove(_entries.keys.first)!.length;
      }
      if (!_store.commitments.verify(reference, commitment, bytes)) {
        throw const SecretResolutionError('secret_integrity');
      }
      return bytes;
    } on SecretResolutionError catch (error) {
      _log('secrets reference=$reference code=${error.code}');
      rethrow;
    } catch (_) {
      const error = SecretResolutionError('store_unavailable');
      _log('secrets reference=$reference code=${error.code}');
      throw error;
    }
  }
}
