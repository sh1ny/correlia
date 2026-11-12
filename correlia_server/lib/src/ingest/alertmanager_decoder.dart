import 'dart:convert';
import 'dart:typed_data';

import '../event/canonical_event.dart';
import '../event/identity.dart';
import '../event_generated/correlia/event/v1/event_bounds.dart';

/// The complete decoded delivery, upstream omissions, and unknown group fields.
final class AlertmanagerBatch {
  AlertmanagerBatch._(
    List<CanonicalEvent> events,
    this.upstreamOmissions,
    List<String> unknownTopLevelFields,
    this.unknownTopLevelOverflow,
  ) : events = List.unmodifiable(events),
      unknownTopLevelFields = List.unmodifiable(unknownTopLevelFields);

  /// The supplied alerts in their original order.
  final List<CanonicalEvent> events;

  /// The number of alerts omitted upstream, not fabricated by the decoder.
  final int upstreamOmissions;

  /// The first 16 valid unknown top-level names in sorted order.
  final List<String> unknownTopLevelFields;

  /// The count of unknown names omitted from [unknownTopLevelFields].
  final int unknownTopLevelOverflow;
}

/// Decodes one Alertmanager v4 delivery using the existing event identity codec.
///
/// Throws [EventFieldError] for malformed or unsupported input. No partial
/// batch is returned. [rawRef] and [rawSha256] describe the persisted body;
/// [observedAt] is the ingress time and [processedAt] is the worker clock.
AlertmanagerBatch decodeAlertmanager({
  required Uint8List bytes,
  required String sourceInstance,
  String? namespace,
  List<String> excludedLabels = const [],
  required String rawRef,
  required String rawSha256,
  required EventTimestamp observedAt,
  required EventTimestamp processedAt,
  required String configVersion,
}) {
  _checkDepth(bytes);
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes));
  } on FormatException {
    throw const EventFieldError('body', 'invalid_json');
  }
  final group = _object(decoded, 'body');
  const knownGroupFields = {
    'version',
    'status',
    'alerts',
    'receiver',
    'groupKey',
    'groupLabels',
    'commonLabels',
    'commonAnnotations',
    'externalURL',
    'notification_reason',
    'routeLabels',
    'truncatedAlerts',
  };
  final unknownFields = <String>[];
  var unknownOverflow = 0;
  for (final name in group.keys) {
    if (knownGroupFields.contains(name)) continue;
    if (!_unknownNamePattern.hasMatch(name)) {
      unknownOverflow++;
      continue;
    }
    var index = 0;
    while (index < unknownFields.length &&
        unknownFields[index].compareTo(name) < 0) {
      index++;
    }
    if (index < 16) {
      unknownFields.insert(index, name);
      if (unknownFields.length > 16) {
        unknownFields.removeLast();
        unknownOverflow++;
      }
    } else {
      unknownOverflow++;
    }
  }
  if (_requiredString(group, 'version', '') != '4') {
    throw const EventFieldError('version', 'unsupported_version');
  }
  _status(_requiredString(group, 'status', ''), 'status');
  for (final name in [
    'receiver',
    'groupKey',
    'externalURL',
    'notification_reason',
  ]) {
    if (group.containsKey(name)) _requiredString(group, name, '');
  }
  for (final name in ['groupLabels', 'commonLabels', 'commonAnnotations']) {
    if (group.containsKey(name)) _stringMap(group[name], name);
  }
  if (group.containsKey('routeLabels')) {
    final labels = _object(group['routeLabels'], 'routeLabels');
    for (final value in labels.values) {
      _mapValue(value, 'routeLabels');
    }
  }
  final omissions = group['truncatedAlerts'] ?? 0;
  if (omissions is! int ||
      omissions < 0 ||
      (group.containsKey('truncatedAlerts') &&
          group['truncatedAlerts'] == null)) {
    throw const EventFieldError('truncatedAlerts', 'invalid_count');
  }
  final alerts = group['alerts'];
  if (alerts is! List<Object?>) {
    throw EventFieldError(
      'alerts',
      group.containsKey('alerts') ? 'invalid_type' : 'required',
    );
  }
  if (alerts.length > 1000) {
    throw const EventFieldError('alerts', 'batch_bound');
  }
  final source = SourceContext(
    sourceInstance: sourceInstance,
    sourceKind: 'alertmanager',
    namespace: namespace,
  );
  final raw = EventRawReference(
    ref: rawRef,
    sha256: rawSha256,
    size: bytes.length,
  );
  final pipeline = EventPipeline(version: configVersion);
  final externalUrl = group['externalURL'] as String?;
  final events = <CanonicalEvent>[];
  for (var i = 0; i < alerts.length; i++) {
    final path = 'alerts[$i]';
    try {
      events.add(
        _decodeAlert(
          _object(alerts[i], path),
          path,
          source,
          excludedLabels,
          raw,
          pipeline,
          observedAt,
          processedAt,
          externalUrl,
        ),
      );
    } on EventFieldError catch (error) {
      if (error.path.startsWith('$path.') || error.path == path) rethrow;
      throw EventFieldError('$path.${error.path}', error.code);
    }
  }
  return AlertmanagerBatch._(events, omissions, unknownFields, unknownOverflow);
}

final _unknownNamePattern = RegExp(r'^[A-Za-z0-9_.-]{1,64}$');

CanonicalEvent _decodeAlert(
  Map<String, Object?> alert,
  String path,
  SourceContext source,
  List<String> excludedLabels,
  EventRawReference raw,
  EventPipeline pipeline,
  EventTimestamp observedAt,
  EventTimestamp processedAt,
  String? externalUrl,
) {
  _keys(alert, const {
    'status',
    'labels',
    'annotations',
    'startsAt',
    'endsAt',
    'generatorURL',
    'fingerprint',
  }, path);
  final statusText = _requiredString(alert, 'status', path);
  final status = _status(statusText, '$path.status');
  final labels = _stringMap(alert['labels'], '$path.labels');
  final annotations = _stringMap(alert['annotations'], '$path.annotations');
  final identity = selectAlertmanagerIdentity(
    labels,
    excludedLabels: excludedLabels,
  );
  final projectedLabels = _projectMap(
    labels,
    '$path.labels',
    CanonicalEventBounds.CanonicalEventLabelsLength.max!,
    CanonicalEventBounds.CanonicalEventLabelsKeyLength.max!,
    CanonicalEventBounds.CanonicalEventLabelsValueLength.max!,
  );
  final projectedAnnotations = _projectMap(
    annotations,
    '$path.annotations',
    CanonicalEventBounds.CanonicalEventAnnotationsLength.max!,
    CanonicalEventBounds.CanonicalEventAnnotationsKeyLength.max!,
    CanonicalEventBounds.CanonicalEventAnnotationsValueLength.max!,
  );
  final startText = _requiredString(alert, 'startsAt', path);
  final start = EventTimestamp.parse(startText, path: '$path.startsAt');
  if (_zero(start)) throw EventFieldError('$path.startsAt', 'zero_time');
  final endText = alert.containsKey('endsAt')
      ? _requiredString(alert, 'endsAt', path)
      : null;
  final end = endText == null
      ? null
      : EventTimestamp.parse(endText, path: '$path.endsAt');
  if (status == EventStatus.resolved && (end == null || _zero(end))) {
    throw EventFieldError('$path.endsAt', 'required_source_time');
  }
  if (end != null &&
      !_zero(end) &&
      (end.seconds < start.seconds ||
          (end.seconds == start.seconds && end.nanos < start.nanos))) {
    throw EventFieldError('$path.endsAt', 'reversed_interval');
  }
  final severityText = labels['severity'];
  final severity = switch (severityText) {
    'critical' => EventSeverity.critical,
    'error' => EventSeverity.error,
    'warning' => EventSeverity.warning,
    'info' => EventSeverity.info,
    _ => EventSeverity.unknown,
  };
  final summaryAnnotation = projectedAnnotations['summary'];
  final alertName = projectedLabels['alertname'];
  final summary = summaryAnnotation != null && summaryAnnotation.isNotEmpty
      ? summaryAnnotation
      : alertName != null && alertName.isNotEmpty
      ? alertName
      : 'Alertmanager alert';
  final links = <EventLink>[];
  if (externalUrl != null && externalUrl.isNotEmpty) {
    links.add(EventLink(href: externalUrl, relation: 'alertmanager'));
  }
  if (alert.containsKey('generatorURL')) {
    final url = _requiredString(alert, 'generatorURL', path);
    if (url.isNotEmpty) links.add(EventLink(href: url, relation: 'generator'));
  }
  final extensions = <String, String>{};
  if (alert.containsKey('fingerprint')) {
    extensions['correlia.io/alertmanager_fingerprint'] = _requiredString(
      alert,
      'fingerprint',
      path,
    );
  }
  final reported = status == EventStatus.firing ? startText : endText!;
  return CanonicalEvent.create(
    source: source,
    kind: EventKind.alert,
    status: status,
    severity: severity,
    summary: normalizeDisplayText(
      summary,
      maxScalars: CanonicalEventBounds.CanonicalEventSummaryLength.max!,
      singleLine: true,
    ),
    description: projectedAnnotations['description'] == null
        ? null
        : normalizeDisplayText(
            projectedAnnotations['description']!,
            maxScalars:
                CanonicalEventBounds.CanonicalEventDescriptionLength.max!,
          ),
    severityOriginal: severityText == null
        ? null
        : normalizeDisplayText(
            severityText,
            maxScalars:
                CanonicalEventBounds.CanonicalEventSeverityOriginalLength.max!,
          ),
    identityFields: identity,
    observationKey: ObservationKey.alertmanager(
      status: statusText,
      startsAt: startText,
      endsAt: endText,
    ),
    observedAt: observedAt,
    processedAt: processedAt,
    raw: raw,
    pipeline: pipeline,
    labels: projectedLabels,
    annotations: projectedAnnotations,
    links: links,
    startsAt: start,
    endsAt: end == null || _zero(end) ? null : end,
    sourceTime: status == EventStatus.firing ? start : end,
    reportedSourceTime: reported,
    extensions: extensions,
  );
}

bool _zero(EventTimestamp time) =>
    time.seconds == -62135596800 && time.nanos == 0;

EventStatus _status(String value, String path) => switch (value) {
  'firing' => EventStatus.firing,
  'resolved' => EventStatus.resolved,
  _ => throw EventFieldError(path, 'invalid_status'),
};

Map<String, Object?> _object(Object? value, String path) {
  if (value is! Map<String, Object?>) {
    throw EventFieldError(path, 'invalid_type');
  }
  return value;
}

void _keys(Map<String, Object?> value, Set<String> allowed, String path) {
  for (final key in value.keys) {
    if (!allowed.contains(key)) {
      throw EventFieldError(path.isEmpty ? key : '$path.$key', 'unknown_field');
    }
  }
}

String _requiredString(Map<String, Object?> map, String key, String path) {
  final value = map[key];
  final field = path.isEmpty ? key : '$path.$key';
  if (value is! String) {
    throw EventFieldError(
      field,
      map.containsKey(key) ? 'invalid_type' : 'required',
    );
  }
  return value;
}

Map<String, String> _stringMap(Object? value, String path) {
  final map = _object(value, path);
  return {
    for (final entry in map.entries)
      entry.key: _mapValue(entry.value, '$path.${entry.key}'),
  };
}

String _mapValue(Object? value, String path) {
  if (value is! String) throw EventFieldError(path, 'invalid_type');
  return value;
}

Map<String, String> _projectMap(
  Map<String, String> input,
  String path,
  int maxCount,
  int maxKey,
  int maxValue,
) {
  if (input.length > maxCount) throw EventFieldError(path, 'invalid_count');
  final result = <String, String>{};
  for (final MapEntry(:key, :value) in input.entries) {
    validateText(key, '$path.key', min: 1, max: maxKey);
    result[key] = normalizeDisplayText(value, maxScalars: maxValue);
  }
  return result;
}

// Check nesting before jsonDecode so deeply nested input cannot overflow its parser.
void _checkDepth(Uint8List bytes) {
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (final byte in bytes) {
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (byte == 0x5c) {
        escaped = true;
      } else if (byte == 0x22) {
        inString = false;
      }
    } else if (byte == 0x22) {
      inString = true;
    } else if (byte == 0x7b || byte == 0x5b) {
      if (++depth > 32) throw const EventFieldError('body', 'depth_bound');
    } else if (byte == 0x7d || byte == 0x5d) {
      depth--;
    }
  }
}
