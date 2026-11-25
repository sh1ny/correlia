/// Bounded canonical events, portable identities and structured CloudEvents.
library;

export 'src/event/canonical_event.dart'
    show
        CanonicalEvent,
        EventKind,
        EventStatus,
        EventSeverity,
        ValidationScope,
        EventObserver,
        EventRawReference,
        EventPipeline,
        EventLink,
        EventEnrichmentError,
        normalizeDisplayText;
export 'src/event/cloud_event.dart' show CloudEvent;
export 'src/event/identity.dart' hide IdentityFieldsBuilder;
