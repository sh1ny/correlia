// This is a generated file - do not edit.

/// Bounds extracted from the canonical event validation rules.
abstract final class CanonicalEventBounds {
  /// The bound for `correlia.event.v1.CanonicalEvent.annotations`.
  static const ({int? min, int? max}) CanonicalEventAnnotationsKeyLength = (
    min: 1,
    max: 128,
  );

  /// The bound for `correlia.event.v1.CanonicalEvent.annotations`.
  static const ({int? min, int? max}) CanonicalEventAnnotationsLength = (
    min: 0,
    max: 128,
  );

  /// The bound for `correlia.event.v1.CanonicalEvent.annotations`.
  static const ({int? min, int? max}) CanonicalEventAnnotationsValueLength = (
    min: null,
    max: 1024,
  );

  /// The bound for `correlia.event.v1.CanonicalEvent.dedup_key`.
  static const ({int? min, int? max}) CanonicalEventDedupKeyLength = (
    min: null,
    max: 1024,
  );

  /// The bound for `correlia.event.v1.CanonicalEvent.description`.
  static const ({int? min, int? max}) CanonicalEventDescriptionLength = (
    min: null,
    max: 4096,
  );

  /// The bound for `correlia.event.v1.CanonicalEvent.event_id`.
  static const ({int? min, int? max}) CanonicalEventEventIdByteLength = (
    min: 36,
    max: 36,
  );

  /// The bound for `correlia.event.v1.CanonicalEvent.event_id`.
  static const ({int? min, int? max}) CanonicalEventEventIdLength = (
    min: 36,
    max: 36,
  );

  /// The bound for `correlia.event.v1.CanonicalEvent.event_id`.
  static const String CanonicalEventEventIdPattern =
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';

  /// The bound for `correlia.event.v1.CanonicalEvent.event_id`.
  static const bool CanonicalEventEventIdRequired = true;

  /// The bound for `correlia.event.v1.CanonicalEvent.extensions`.
  static const ({int? min, int? max}) CanonicalEventExtensionsKeyLength = (
    min: 1,
    max: 128,
  );

  /// The bound for `correlia.event.v1.CanonicalEvent.extensions`.
  static const String CanonicalEventExtensionsKeyPattern =
      r'^[a-z0-9][a-z0-9.-]*/[a-zA-Z0-9_.-]+$';

  /// The bound for `correlia.event.v1.CanonicalEvent.extensions`.
  static const ({int? min, int? max}) CanonicalEventExtensionsLength = (
    min: 0,
    max: 32,
  );

  /// The bound for `correlia.event.v1.CanonicalEvent.extensions`.
  static const ({int? min, int? max}) CanonicalEventExtensionsValueLength = (
    min: null,
    max: 1024,
  );

  /// The bound for `correlia.event.v1.CanonicalEvent.fingerprint`.
  static const ({int? min, int? max}) CanonicalEventFingerprintByteLength = (
    min: 64,
    max: 64,
  );

  /// The bound for `correlia.event.v1.CanonicalEvent.fingerprint`.
  static const ({int? min, int? max}) CanonicalEventFingerprintLength = (
    min: 64,
    max: 64,
  );

  /// The bound for `correlia.event.v1.CanonicalEvent.fingerprint`.
  static const String CanonicalEventFingerprintPattern = r'^[0-9a-f]{64}$';

  /// The bound for `correlia.event.v1.CanonicalEvent.fingerprint`.
  static const bool CanonicalEventFingerprintRequired = true;

  /// The bound for `correlia.event.v1.CanonicalEvent.identity_fields`.
  static const ({int? min, int? max}) CanonicalEventIdentityFieldsKeyLength = (
    min: 1,
    max: 128,
  );

  /// The bound for `correlia.event.v1.CanonicalEvent.identity_fields`.
  static const ({int? min, int? max}) CanonicalEventIdentityFieldsLength = (
    min: 1,
    max: 128,
  );

  /// The bound for `correlia.event.v1.CanonicalEvent.identity_fields`.
  static const bool CanonicalEventIdentityFieldsRequired = true;

  /// The bound for `correlia.event.v1.CanonicalEvent.kind`.
  static const bool CanonicalEventKindRequired = true;

  /// The bound for `correlia.event.v1.CanonicalEvent.labels`.
  static const ({int? min, int? max}) CanonicalEventLabelsKeyLength = (
    min: 1,
    max: 128,
  );

  /// The bound for `correlia.event.v1.CanonicalEvent.labels`.
  static const ({int? min, int? max}) CanonicalEventLabelsLength = (
    min: 0,
    max: 128,
  );

  /// The bound for `correlia.event.v1.CanonicalEvent.labels_origin`.
  static const ({int? min, int? max}) CanonicalEventLabelsOriginKeyLength = (
    min: 1,
    max: 128,
  );

  /// The bound for `correlia.event.v1.CanonicalEvent.labels_origin`.
  static const ({int? min, int? max}) CanonicalEventLabelsOriginLength = (
    min: 0,
    max: 128,
  );

  /// The bound for `correlia.event.v1.CanonicalEvent.labels_origin`.
  static const ({int? min, int? max}) CanonicalEventLabelsOriginValueLength = (
    min: null,
    max: 1024,
  );

  /// The bound for `correlia.event.v1.CanonicalEvent.labels`.
  static const ({int? min, int? max}) CanonicalEventLabelsValueLength = (
    min: null,
    max: 1024,
  );

  /// The bound for `correlia.event.v1.CanonicalEvent.links`.
  static const ({int? min, int? max}) CanonicalEventLinksLength = (
    min: 0,
    max: 16,
  );

  /// The bound for `correlia.event.v1.CanonicalEvent.namespace`.
  static const ({int? min, int? max}) CanonicalEventNamespaceLength = (
    min: 1,
    max: 256,
  );

  /// The bound for `correlia.event.v1.CanonicalEvent.namespace`.
  static const bool CanonicalEventNamespaceRequired = true;

  /// The bound for `correlia.event.v1.CanonicalEvent.observation_key`.
  static const ({int? min, int? max}) CanonicalEventObservationKeyLength = (
    min: 1,
    max: 8192,
  );

  /// The bound for `correlia.event.v1.CanonicalEvent.observation_key`.
  static const bool CanonicalEventObservationKeyRequired = true;

  /// The bound for `correlia.event.v1.CanonicalEvent.observed_at`.
  static const bool CanonicalEventObservedAtRequired = true;

  /// The bound for `correlia.event.v1.CanonicalEvent.observer`.
  static const bool CanonicalEventObserverRequired = true;

  /// The bound for `correlia.event.v1.CanonicalEvent.pipeline`.
  static const bool CanonicalEventPipelineRequired = true;

  /// The bound for `correlia.event.v1.CanonicalEvent.processed_at`.
  static const bool CanonicalEventProcessedAtRequired = true;

  /// The bound for `correlia.event.v1.CanonicalEvent.raw`.
  static const bool CanonicalEventRawRequired = true;

  /// The bound for `correlia.event.v1.CanonicalEvent.reported_source_time`.
  static const ({int? min, int? max}) CanonicalEventReportedSourceTimeLength = (
    min: null,
    max: 64,
  );

  /// The bound for `correlia.event.v1.CanonicalEvent.resource`.
  static const ({int? min, int? max}) CanonicalEventResourceKeyLength = (
    min: 1,
    max: 128,
  );

  /// The bound for `correlia.event.v1.CanonicalEvent.resource`.
  static const ({int? min, int? max}) CanonicalEventResourceLength = (
    min: 0,
    max: 128,
  );

  /// The bound for `correlia.event.v1.CanonicalEvent.resource`.
  static const ({int? min, int? max}) CanonicalEventResourceValueLength = (
    min: null,
    max: 1024,
  );

  /// The bound for `correlia.event.v1.CanonicalEvent.severity_number`.
  static const ({int? min, int? max}) CanonicalEventSeverityNumberUint32 = (
    min: 1,
    max: 24,
  );

  /// The bound for `correlia.event.v1.CanonicalEvent.severity_original`.
  static const ({int? min, int? max}) CanonicalEventSeverityOriginalLength = (
    min: null,
    max: 128,
  );

  /// The bound for `correlia.event.v1.CanonicalEvent.severity`.
  static const bool CanonicalEventSeverityRequired = true;

  /// The bound for `correlia.event.v1.CanonicalEvent.status`.
  static const bool CanonicalEventStatusRequired = true;

  /// The bound for `correlia.event.v1.CanonicalEvent.summary`.
  static const ({int? min, int? max}) CanonicalEventSummaryLength = (
    min: 1,
    max: 256,
  );

  /// The bound for `correlia.event.v1.CanonicalEvent.summary`.
  static const bool CanonicalEventSummaryRequired = true;

  /// The bound for `correlia.event.v1.CanonicalEvent.tenant`.
  static const String CanonicalEventTenantConst = 'default';

  /// The bound for `correlia.event.v1.CanonicalEvent.tenant`.
  static const bool CanonicalEventTenantRequired = true;

  /// The bound for `correlia.event.v1.EnrichmentError.code`.
  static const ({int? min, int? max}) EnrichmentErrorCodeLength = (
    min: 1,
    max: 64,
  );

  /// The bound for `correlia.event.v1.EnrichmentError.code`.
  static const bool EnrichmentErrorCodeRequired = true;

  /// The bound for `correlia.event.v1.EnrichmentError.message`.
  static const ({int? min, int? max}) EnrichmentErrorMessageLength = (
    min: 1,
    max: 256,
  );

  /// The bound for `correlia.event.v1.EnrichmentError.message`.
  static const bool EnrichmentErrorMessageRequired = true;

  /// The bound for `correlia.event.v1.EnrichmentError.stage`.
  static const ({int? min, int? max}) EnrichmentErrorStageLength = (
    min: 1,
    max: 64,
  );

  /// The bound for `correlia.event.v1.EnrichmentError.stage`.
  static const bool EnrichmentErrorStageRequired = true;

  /// The bound for `correlia.event.v1.EventKind`.
  static const List<int> EventKindValues = <int>[0, 1, 2, 3, 4, 5, 6];

  /// The bound for `correlia.event.v1.EventSeverity`.
  static const List<int> EventSeverityValues = <int>[0, 1, 2, 3, 4, 5];

  /// The bound for `correlia.event.v1.EventStatus`.
  static const List<int> EventStatusValues = <int>[0, 1, 2, 3];

  /// The bound for `correlia.event.v1.IdentityComponent.raw`.
  static const ({int? min, int? max}) IdentityComponentRawByteLength = (
    min: null,
    max: 1024,
  );

  /// The bound for `correlia.event.v1.IdentityComponent.raw`.
  static const ({int? min, int? max}) IdentityComponentRawLength = (
    min: 0,
    max: null,
  );

  /// The bound for `correlia.event.v1.IdentityComponent.sha256`.
  static const ({int? min, int? max}) IdentityComponentSha256Length = (
    min: 32,
    max: 32,
  );

  /// The bound for `correlia.event.v1.Link.href`.
  static const ({int? min, int? max}) LinkHrefLength = (min: 1, max: 2048);

  /// The bound for `correlia.event.v1.Link.href`.
  static const String LinkHrefPattern = r'^https?://.+$';

  /// The bound for `correlia.event.v1.Link.href`.
  static const bool LinkHrefRequired = true;

  /// The bound for `correlia.event.v1.Link.relation`.
  static const ({int? min, int? max}) LinkRelationLength = (min: 1, max: 64);

  /// The bound for `correlia.event.v1.Link.relation`.
  static const bool LinkRelationRequired = true;

  /// The bound for `correlia.event.v1.Link.text`.
  static const ({int? min, int? max}) LinkTextLength = (min: null, max: 256);

  /// The bound for `correlia.event.v1.Observer.name`.
  static const ({int? min, int? max}) ObserverNameLength = (
    min: null,
    max: 256,
  );

  /// The bound for `correlia.event.v1.Observer.source_instance`.
  static const ({int? min, int? max}) ObserverSourceInstanceByteLength = (
    min: 36,
    max: 36,
  );

  /// The bound for `correlia.event.v1.Observer.source_instance`.
  static const ({int? min, int? max}) ObserverSourceInstanceLength = (
    min: 36,
    max: 36,
  );

  /// The bound for `correlia.event.v1.Observer.source_instance`.
  static const String ObserverSourceInstancePattern =
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';

  /// The bound for `correlia.event.v1.Observer.source_instance`.
  static const bool ObserverSourceInstanceRequired = true;

  /// The bound for `correlia.event.v1.Observer.source_kind`.
  static const ({int? min, int? max}) ObserverSourceKindLength = (
    min: 1,
    max: 64,
  );

  /// The bound for `correlia.event.v1.Observer.source_kind`.
  static const String ObserverSourceKindPattern = r'^[a-z][a-z0-9_]*$';

  /// The bound for `correlia.event.v1.Observer.source_kind`.
  static const bool ObserverSourceKindRequired = true;

  /// The bound for `correlia.event.v1.Observer.version`.
  static const ({int? min, int? max}) ObserverVersionLength = (
    min: null,
    max: 256,
  );

  /// The bound for `correlia.event.v1.Pipeline.enrichment_errors`.
  static const ({int? min, int? max}) PipelineEnrichmentErrorsLength = (
    min: 0,
    max: 32,
  );

  /// The bound for `correlia.event.v1.Pipeline.generation`.
  static const ({int? min, int? max}) PipelineGenerationUint32 = (
    min: 0,
    max: 4294967295,
  );

  /// The bound for `correlia.event.v1.Pipeline.original_event_id`.
  static const ({int? min, int? max}) PipelineOriginalEventIdByteLength = (
    min: 36,
    max: 36,
  );

  /// The bound for `correlia.event.v1.Pipeline.original_event_id`.
  static const ({int? min, int? max}) PipelineOriginalEventIdLength = (
    min: 36,
    max: 36,
  );

  /// The bound for `correlia.event.v1.Pipeline.original_event_id`.
  static const String PipelineOriginalEventIdPattern =
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';

  /// The bound for `correlia.event.v1.Pipeline.stages_applied`.
  static const ({int? min, int? max}) PipelineStagesAppliedItemLength = (
    min: 1,
    max: 64,
  );

  /// The bound for `correlia.event.v1.Pipeline.stages_applied`.
  static const ({int? min, int? max}) PipelineStagesAppliedLength = (
    min: 0,
    max: 32,
  );

  /// The bound for `correlia.event.v1.Pipeline.version`.
  static const ({int? min, int? max}) PipelineVersionLength = (
    min: 1,
    max: 128,
  );

  /// The bound for `correlia.event.v1.Pipeline.version`.
  static const bool PipelineVersionRequired = true;

  /// The bound for `correlia.event.v1.RawReference.ref`.
  static const ({int? min, int? max}) RawReferenceRefLength = (
    min: 1,
    max: 256,
  );

  /// The bound for `correlia.event.v1.RawReference.ref`.
  static const bool RawReferenceRefRequired = true;

  /// The bound for `correlia.event.v1.RawReference.sha256`.
  static const ({int? min, int? max}) RawReferenceSha256ByteLength = (
    min: 64,
    max: 64,
  );

  /// The bound for `correlia.event.v1.RawReference.sha256`.
  static const ({int? min, int? max}) RawReferenceSha256Length = (
    min: 64,
    max: 64,
  );

  /// The bound for `correlia.event.v1.RawReference.sha256`.
  static const String RawReferenceSha256Pattern = r'^[0-9a-f]{64}$';

  /// The bound for `correlia.event.v1.RawReference.sha256`.
  static const bool RawReferenceSha256Required = true;

  /// The bound for `correlia.event.v1.RawReference.size`.
  static const ({int? min, int? max}) RawReferenceSizeUint32 = (
    min: 0,
    max: 4294967295,
  );
}
