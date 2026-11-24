import 'package:serverpod/serverpod.dart';

import '../console/console_access_policy.dart';
import '../feed/feed_runtime.dart';
import '../generated/protocol.dart';
import '../ingest/mapping_preview.dart';

/// Read-only preview of an active or draft generic mapping on the local console.
class MappingPreviewEndpoint extends Endpoint {
  @override
  bool get logSessions => false;

  /// Maps [sample] against the active generic source or the supplied draft.
  Future<MappingPreviewResult> preview(
    Session session,
    String sourceId,
    String sample, {
    String? draftMapping,
  }) {
    ConsoleAccessPolicy.check(
      session.serverpod.runMode,
      FeedRuntime.role,
      session.request,
    );
    return previewMapping(
      session,
      sourceId,
      sample,
      draftMapping: draftMapping,
      now: DateTime.now().toUtc(),
    );
  }
}
