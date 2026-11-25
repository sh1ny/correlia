import 'dart:convert';
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

/// Fills the digest table for snapshots stored before it existed.
///
/// The caller holds the publication advisory lock in [transaction]. When the
/// completion row is present this does nothing. Otherwise it reads the
/// snapshots in keyset pages, each starting after the last table ID read, so
/// memory stays bounded and one pass suffices. It inserts every digest and, as
/// its last statement, the completion row, so a failure that rolls the
/// transaction back leaves no partial fill visible.
///
/// PostgreSQL never parses the stored JSON: the text is decoded here, so a
/// U+0000 escape in a plugin configuration cannot block the fill.
///
/// The three `ForTest` hooks observe the page reads, each insert, and the
/// moment before the completion row is written.
Future<void> ensureMatcherDigestFill(
  Session session,
  Transaction transaction, {
  void Function(int rows)? onPageForTest,
  Future<void> Function(int inserted)? afterInsertForTest,
  Future<void> Function()? beforeCompletionForTest,
}) async {
  final done = await session.db.unsafeQuery(
    'SELECT 1 FROM matcher_content_digest_fill WHERE singleton = 1',
    transaction: transaction,
    timeoutInSeconds: 5,
  );
  if (done.isNotEmpty) return;
  var after = 0;
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
      final document = jsonDecode(row[2]! as String);
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
  await beforeCompletionForTest?.call();
  await session.db.unsafeExecute(
    'INSERT INTO matcher_content_digest_fill (singleton) VALUES (1)',
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
    onPageForTest: onPageForTest,
    afterInsertForTest: afterInsertForTest,
    beforeCompletionForTest: beforeCompletionForTest,
  );
});
