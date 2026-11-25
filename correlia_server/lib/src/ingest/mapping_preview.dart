import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:serverpod/serverpod.dart';

import '../event/event_timestamp.dart';
import '../generated/protocol.dart';
import 'bootstrap.dart';
import 'config_repository.dart';
import 'generic_decoder.dart';
import 'source_decoder.dart';

const _sampleLimit = 1024 * 1024;
const _draftLimit = 32 * 1024;
const _diagnosticLimit = 64 * 1024;
const _nilUuid = '00000000-0000-0000-0000-000000000000';
const _label = 'computed with preview metadata';

/// Maps a sample without admitting it or writing events, using [now] as receipt
/// time. The endpoint checks console access before calling this function.
Future<MappingPreviewResult> previewMapping(
  Session session,
  String sourceId,
  String sample, {
  String? draftMapping,
  required DateTime now,
}) async {
  try {
    if (sample.length > _sampleLimit) {
      throw const BootstrapError('preview', 'sample', 'too_large');
    }
    final bytes = utf8.encode(sample);
    if (bytes.length > _sampleLimit) {
      throw const BootstrapError('preview', 'sample', 'too_large');
    }
    final draft = draftMapping == null ? null : _parseDraft(draftMapping);
    final active = await IngestConfigRepository(session).activeSnapshot();
    if (active == null) {
      throw const BootstrapError(
        'preview',
        'sourceId',
        'source_not_configured',
      );
    }
    final snapshot =
        jsonDecode(active['publicJson']! as String) as Map<String, Object?>;
    final sources = (snapshot['sources']! as List<Object?>)
        .cast<Map<String, Object?>>();
    final source = sources
        .where((source) => source['id'] == sourceId)
        .singleOrNull;
    if (source == null || source['kind'] != SourceKind.generic.name) {
      throw const BootstrapError(
        'preview',
        'sourceId',
        'source_not_configured',
      );
    }
    final mapping =
        draft ?? GenericMapping.fromSnapshot(snapshot, source['mapping']);
    if (mapping == null) {
      throw const BootstrapError('preview', 'sourceId', 'unsupported_mapping');
    }
    final isoTime = now.toUtc().toIso8601String();
    final time = EventTimestamp.parse(isoTime);
    final decoded = previewGeneric(
      DecodeRequest(
        bytes: bytes,
        sourceInstance: sourceId,
        namespace: source['namespace']! as String,
        excludedLabels: const [],
        rawRef: 'raw:$isoTime/$_nilUuid',
        rawSha256: sha256.convert(bytes).toString(),
        observedAt: time,
        processedAt: time,
        configVersion: active['snapshotId']! as String,
      ),
      mapping,
    );
    final diagnostics = <MappingPreviewDiagnostic>[];
    var diagnosticBytes = 2; // JSON array brackets.
    for (final diagnostic in decoded.diagnostics) {
      final entry = MappingPreviewDiagnostic(
        alertIndex: diagnostic.alertIndex,
        path: diagnostic.path,
        code: diagnostic.code,
        unmapped: diagnostic.unmapped,
      );
      diagnosticBytes +=
          utf8.encode(jsonEncode(entry.toJsonForProtocol())).length +
          (diagnostics.isEmpty ? 0 : 1);
      if (diagnosticBytes > _diagnosticLimit) break;
      diagnostics.add(entry);
    }
    return MappingPreviewResult(
      label: _label,
      events: [
        for (final event in decoded.events)
          MappingPreviewEvent(
            fingerprint: event.fingerprint,
            eventId: event.eventId,
            status: event.status.name,
            severity: event.severity.name,
            summary: event.summary,
            sourceTime: event.sourceTime!.toRfc3339(),
          ),
      ],
      diagnostics: diagnostics,
      overflow:
          decoded.overflow + decoded.diagnostics.length - diagnostics.length,
      rowWouldFail: decoded.rowWouldFail,
    );
  } on BootstrapError catch (error) {
    return MappingPreviewResult(
      label: _label,
      events: [],
      diagnostics: [],
      overflow: 0,
      rowWouldFail: true,
      validationError: MappingPreviewValidationError(
        fileKind: error.fileKind,
        field: error.field,
        code: error.code,
      ),
    );
  }
}

GenericMapping _parseDraft(String draft) {
  if (draft.length > _draftLimit || utf8.encode(draft).length > _draftLimit) {
    throw const BootstrapError('config', 'draftMapping', 'too_large');
  }
  final Object? document;
  try {
    document = jsonDecode(draft);
  } on FormatException {
    throw const BootstrapError('config', 'draftMapping', 'invalid_json');
  }
  return GenericMapping.parse(document);
}
