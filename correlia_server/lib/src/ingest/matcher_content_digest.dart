import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:serverpod/serverpod.dart';

import 'bootstrap.dart';

/// The advisory lock that serializes publication and the digest fill.
const publicationLockKey = 1129271884;

/// How many snapshots the fill reads per keyset page.
const matcherFillPageSize = 100;

/// How long startup waits for the publication lock before it fails.
const defaultMatcherFillLockTimeout = Duration(seconds: 60);

/// The lookup that tells stored matcher content from new content.
///
/// It is one probe of the primary key, however long the history grows.
const matcherDigestLookupSql =
    'SELECT 1 FROM matcher_content_digest WHERE digest = @digest';

/// Returns the lookup key of [matcher], the stored matcher JSON of a snapshot.
///
/// It is the digest the publication guard computes, as bytes.
Uint8List matcherContentDigest(Object? matcher) {
  final hex = sha256Digest(matcher);
  return Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}

/// Whether some stored snapshot has the same matcher content as [matcher].
///
/// [matcher] is the `matcher` entry of a snapshot's public JSON.
Future<bool> matcherContentIsStored(
  Session session,
  Transaction transaction,
  Object? matcher,
) async => (await session.db.unsafeQuery(
  matcherDigestLookupSql,
  parameters: QueryParameters.named({'digest': matcherContentDigest(matcher)}),
  transaction: transaction,
  timeoutInSeconds: 5,
)).isNotEmpty;

/// Records the digest of a snapshot written in [transaction].
///
/// Only a snapshot with matcher rules has content a restore can repeat.
Future<void> recordMatcherContent(
  Session session,
  Transaction transaction,
  String snapshotId,
  Object? matcher,
) async {
  if (matcher == null) return;
  await session.db.unsafeExecute(
    '''INSERT INTO matcher_content_digest (digest, first_snapshot_id)
    VALUES (@digest, @id) ON CONFLICT (digest) DO NOTHING''',
    parameters: QueryParameters.named({
      'digest': matcherContentDigest(matcher),
      'id': snapshotId,
    }),
    transaction: transaction,
  );
}

/// Fills the digest table for snapshots it has not read yet.
///
/// The caller holds the publication advisory lock in [transaction]. The fill
/// row's `filled_through` is the snapshot table ID it last read, or there is no
/// row before the first fill. Only snapshots after it are read, in keyset
/// pages, each starting after the last table ID read, so memory stays bounded
/// and one pass suffices. A snapshot that a previous binary stored after an
/// earlier fill, during an offline downgrade, is therefore still recorded. The
/// fill inserts every digest and, as its last statement, the new watermark, so
/// a failure that rolls the transaction back leaves no partial fill visible.
///
/// PostgreSQL never parses the stored JSON: the text is decoded here, so a
/// U+0000 escape in a plugin configuration cannot block the fill.
///
/// A snapshot whose stored text is not JSON gets no digest, so its content
/// counts as new, and the fill goes on: one damaged inactive snapshot cannot
/// block every start. [onUnreadable] receives its snapshot ID, never its text;
/// by default the ID is written to standard error.
///
/// The three `ForTest` hooks observe the page reads, each insert, and the
/// moment before the watermark is written.
Future<void> ensureMatcherDigestFill(
  Session session,
  Transaction transaction, {
  void Function(String snapshotId)? onUnreadable,
  void Function(int rows)? onPageForTest,
  Future<void> Function(int inserted)? afterInsertForTest,
  Future<void> Function()? beforeCompletionForTest,
}) async {
  final state = await session.db.unsafeQuery(
    'SELECT filled_through FROM matcher_content_digest_fill WHERE singleton = 1',
    transaction: transaction,
    timeoutInSeconds: 5,
  );
  final through = state.isEmpty ? null : state.single[0]! as int;
  var after = through ?? 0;
  var inserted = 0;
  while (true) {
    final page = await session.db.unsafeQuery(
      '''SELECT id, "snapshotId", "publicJson" FROM ingest_config_snapshot
      WHERE id > @after ORDER BY id LIMIT $matcherFillPageSize''',
      parameters: QueryParameters.named({'after': after}),
      transaction: transaction,
      timeoutInSeconds: 60,
    );
    if (page.isEmpty) break;
    onPageForTest?.call(page.length);
    for (final row in page) {
      after = row[0]! as int;
      final Object? document;
      try {
        document = jsonDecode(row[2]! as String);
      } on FormatException {
        (onUnreadable ?? _reportUnreadable)(row[1]! as String);
        continue;
      }
      final matcher = document is Map<String, Object?>
          ? document['matcher']
          : null;
      if (matcher == null) continue;
      await recordMatcherContent(
        session,
        transaction,
        row[1]! as String,
        matcher,
      );
      await afterInsertForTest?.call(++inserted);
    }
    if (page.length < matcherFillPageSize) break;
  }
  if (through == after) return;
  await beforeCompletionForTest?.call();
  await session.db.unsafeExecute(
    '''INSERT INTO matcher_content_digest_fill (singleton, filled_through)
    VALUES (1, @after) ON CONFLICT (singleton)
    DO UPDATE SET filled_through = EXCLUDED.filled_through, completed_at = now()''',
    parameters: QueryParameters.named({'after': after}),
    transaction: transaction,
  );
}

/// The client timeout, in seconds, of the fill's lock query for [lockTimeout].
///
/// Serverpod cancels a query after 60 seconds unless told otherwise, which is
/// no longer than the default lock timeout. The client must outlast the server
/// by a margin, so a lock wait that runs out fails with SQLSTATE 55P03 rather
/// than a driver cancellation.
int matcherFillClientTimeoutSeconds(Duration lockTimeout) =>
    (lockTimeout.inMilliseconds / 1000).ceil() + 30;

/// Runs the fill in its own transaction under the publication lock.
///
/// A wait for the lock longer than [lockTimeout] fails with SQLSTATE 55P03; the
/// next start retries. A second starter that waited finds the completion row.
Future<void> runMatcherDigestFill(
  Session session, {
  Duration lockTimeout = defaultMatcherFillLockTimeout,
  void Function(String snapshotId)? onUnreadable,
  void Function(int rows)? onPageForTest,
  Future<void> Function(int inserted)? afterInsertForTest,
  Future<void> Function()? beforeCompletionForTest,
}) => session.db.transaction((transaction) async {
  await session.db.unsafeSimpleExecute(
    "SET LOCAL lock_timeout = '${lockTimeout.inMilliseconds}ms'",
    transaction: transaction,
  );
  await session.db.unsafeQuery(
    'SELECT pg_advisory_xact_lock($publicationLockKey)',
    transaction: transaction,
    timeoutInSeconds: matcherFillClientTimeoutSeconds(lockTimeout),
  );
  await ensureMatcherDigestFill(
    session,
    transaction,
    onUnreadable: onUnreadable,
    onPageForTest: onPageForTest,
    afterInsertForTest: afterInsertForTest,
    beforeCompletionForTest: beforeCompletionForTest,
  );
});

void _reportUnreadable(String snapshotId) => stderr.writeln(
  'Matcher digest fill skipped snapshot $snapshotId: its stored JSON does '
  'not read, so its matcher content counts as new.',
);
