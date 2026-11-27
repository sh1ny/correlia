import 'dart:convert';
import 'dart:typed_data';

import 'package:serverpod/serverpod.dart';

import '../ingest/bootstrap.dart' show sha256Digest;

/// The immutable destination and signing definition used at insertion.
final class QueueDestination {
  QueueDestination.fromSnapshot(Map<String, Object?> output)
    : id = output['id']! as String,
      kind = output['kind']! as String,
      definitionDigest = output['kind'] == 'plugin'
          ? sha256Digest(output)
          : null,
      url = output['url'] as String?,
      reference = output['signing_key_ref'] as String?,
      commitment = output['signing_key_commitment'] as String?;

  final String id;
  final String kind;
  final String? definitionDigest;
  final String? url;
  final String? reference;
  final String? commitment;
}

/// One staged intent. Its immutable payload can be shared across destinations.
typedef QueueIntent = ({
  DateTime observed,
  String event,
  String disposition,
  QueueDestination destination,
  Uint8List payload,
});

/// A capacity row read under its output-ID lock. The caller consumes slots in
/// semantic intent order while keeping that lock through the database write.
final class OutputCapacity {
  OutputCapacity._(this.rows, this.bytes, this.blocking);

  int rows;
  int bytes;
  final bool blocking;

  bool fits(int neededRows, int neededBytes) =>
      rows >= neededRows && bytes >= neededBytes;

  bool take(int size) {
    if (!fits(1, size)) return false;
    rows--;
    bytes -= size;
    return true;
  }
}

/// Locks output budgets in the same order as config publication and replay.
///
/// Only one-shot overflow notices skip locked capacity rows.
Future<Map<String, OutputCapacity>> lockOutputCapacity(
  Session session,
  Transaction tx,
  Iterable<String> outputs, {
  bool skipLocked = false,
}) async => {
  for (final row in await session.db.unsafeQuery(
    '''SELECT output_id::text,max_rows-used_rows,max_payload_bytes-used_bytes,
       overflow_policy='block_ingest'
       FROM pipeline_output_capacity WHERE output_id IN (
         SELECT value::uuid FROM jsonb_array_elements_text(@outputs::jsonb))
       ORDER BY output_id FOR UPDATE ${skipLocked ? 'SKIP LOCKED' : ''}''',
    parameters: QueryParameters.named({
      'outputs': jsonEncode(outputs.toList()),
    }),
    transaction: tx,
    timeoutInSeconds: 5,
  ))
    row[0]! as String: OutputCapacity._(
      row[1]! as int,
      row[2]! as int,
      row[3]! as bool,
    ),
};

/// Locks the distinct historical tuples a set of output definitions can use.
Future<void> lockOutputCommitments(
  Session session,
  Transaction tx,
  String pin,
  Iterable<String> outputs,
) async {
  await session.db.unsafeQuery(
    '''SELECT c.reference FROM pipeline_output_commitment c WHERE EXISTS (
      SELECT 1 FROM jsonb_array_elements_text(@outputs::jsonb) ids(id)
      CROSS JOIN LATERAL correlia_snapshot_output_commitments(@pin,ids.id::uuid) r
      WHERE (r.reference,r.commitment,r.kind)=(c.reference,c.commitment,c.kind))
      ORDER BY c.reference,c.commitment,c.kind FOR UPDATE''',
    parameters: QueryParameters.named({
      'pin': pin,
      'outputs': jsonEncode(outputs.toList()),
    }),
    transaction: tx,
    timeoutInSeconds: 5,
  );
}

/// Inserts one immutable intent. Parent triggers account its bytes and evidence.
Future<void> insertQueueIntent(
  Session session,
  Transaction tx,
  String pin,
  DateTime created,
  QueueIntent intent,
) => session.db.unsafeExecute(
  '''INSERT INTO outbox
    (created_at,delivery_id,event_observed_at,event_id,event_disposition,output_id,
     config_snapshot_id,output_kind,definition_digest,target_url,signing_key_ref,signing_key_commitment,payload)
    VALUES (@created,gen_random_uuid(),@observed,@event::uuid,@disposition,@output::uuid,
      @pin,@kind,@digest,@url,@ref,@commitment,@payload)''',
  parameters: QueryParameters.named({
    'created': created,
    'observed': intent.observed,
    'event': intent.event,
    'disposition': intent.disposition,
    'output': intent.destination.id,
    'pin': pin,
    'kind': intent.destination.kind,
    'digest': intent.destination.definitionDigest,
    'url': intent.destination.url,
    'ref': intent.destination.reference,
    'commitment': intent.destination.commitment,
    'payload': intent.payload,
  }),
  transaction: tx,
  timeoutInSeconds: 5,
);

/// Records a grouped refusal or exact saturation for one already locked lane.
Future<void> recordOutputOverflow(
  Session session,
  Transaction tx,
  String output,
  DateTime now, {
  required String reason,
  int discarded = 0,
}) async {
  await session.db.unsafeQuery(
    'SELECT correlia_mark_overflow(@output::uuid,@reason,@discarded,@now)',
    parameters: QueryParameters.named({
      'output': output,
      'reason': reason,
      'discarded': discarded,
      'now': now,
    }),
    transaction: tx,
    timeoutInSeconds: 5,
  );
}
