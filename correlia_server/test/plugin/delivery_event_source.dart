import 'package:correlia_server/event.dart';

import '../unit/event/fixture.dart';

final _template = CanonicalEvent.fromJson(
  eventFixture()['data']! as Map<String, Object?>,
);

/// Creates a validated canonical observation with a deterministic unique id.
CloudEvent pluginDeliveryEvent(int index) => CloudEvent(
  event: CanonicalEvent.create(
    source: _template.source,
    kind: _template.kind,
    status: _template.status,
    severity: _template.severity,
    summary: 'Plugin spike observation $index',
    identityFields: _template.identityFields,
    observationKey: ObservationKey.native('plugin-spike-$index'),
    observedAt: _template.observedAt,
    processedAt: _template.processedAt,
    raw: _template.raw,
    pipeline: _template.pipeline,
  ),
);

/// Produces canonical events only when the delivery consumer advances.
Iterable<CloudEvent> pluginDeliveryEvents(int count) sync* {
  for (var index = 0; index < count; index++) {
    yield pluginDeliveryEvent(index);
  }
}
