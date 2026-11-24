import 'dart:convert';
import 'dart:typed_data';

import '../../../event/canonical_event.dart';
import '../../../event/identity.dart';
import '../../../event_generated/correlia/event/v1/event_bounds.dart';
import '../../bootstrap.dart';
import '../../source_decoder.dart';
import '../facts.dart';
import '../mapper.dart';
import 'guarded_json.dart';
import 'keys.dart';

/// The persisted raw envelope understood by this decoder.
const icingaStreamFormat = 'correlia.icinga2.stream.v1';

/// The trusted origin of the admitted item.
enum IcingaStreamOrigin { stream, sync }

/// The mapped effect of a validated line, before persistence and routing.
sealed class IcingaStreamLineResult {
  const IcingaStreamLineResult();
}

/// An observation eligible for the durable pipeline.
final class IcingaStreamEvent extends IcingaStreamLineResult {
  const IcingaStreamEvent(this.event);

  /// The normalized observation with original key and receipt evidence.
  final CanonicalEvent event;
}

/// A SOFT non-OK observation skipped under the admission policy.
final class IcingaStreamSoftInfo extends IcingaStreamLineResult {
  const IcingaStreamSoftInfo();
}

const _check = {
  'active',
  'check_source',
  'command',
  'execution_end',
  'execution_start',
  'exit_status',
  'output',
  'performance_data',
  'previous_hard_state',
  'schedule_end',
  'schedule_start',
  'scheduling_source',
  'state',
  'ttl',
  'type',
  'vars_after',
  'vars_before',
};
const _vars = {'attempt', 'reachable', 'state', 'state_type'};
const _object = {'host', 'service', 'state', 'state_type', 'type', 'timestamp'};
const _members = <String, Set<String>>{
  'StateChange': {
    ..._object,
    'acknowledgement',
    'check_result',
    'downtime_depth',
  },
  'AcknowledgementSet': {
    ..._object,
    'acknowledgement_type',
    'author',
    'comment',
    'expiry',
    'notify',
    'persistent',
  },
  'AcknowledgementCleared': {
    ..._object,
    'acknowledgement_type',
    'author',
    'comment',
  },
  'DowntimeStarted': {'downtime', 'timestamp', 'type'},
  'DowntimeRemoved': {'downtime', 'timestamp', 'type'},
  'Flapping': {
    ..._object,
    'flapping_current',
    'is_flapping',
    'threshold_high',
    'threshold_low',
  },
};
const _downtime = {
  '__name',
  'author',
  'authoritative_zone',
  'comment',
  'config_owner',
  'config_owner_hash',
  'duration',
  'end_time',
  'entry_time',
  'fixed',
  'host_name',
  'legacy_id',
  'name',
  'package',
  'parent',
  'remove_time',
  'scheduled_by',
  'service_name',
  'source_location',
  'start_time',
  'templates',
  'trigger_time',
  'triggered_by',
  'triggers',
  'type',
  'version',
  'zone',
};
const _sourceLocation = {
  'first_column',
  'first_line',
  'last_column',
  'last_line',
  'path',
};
const _syncMembers = {
  '': {'attrs', 'joins', 'meta', 'name', 'type'},
  'attrs': {'host_name', 'last_check_result', 'name'},
  'attrs.last_check_result': _check,
  'attrs.last_check_result.vars_before': _vars,
  'attrs.last_check_result.vars_after': _vars,
};
const _rawMembers = {
  '': {'format', 'origin', 'connection', 'sync', 'items'},
  'items': {'received', 'line', 'line_b64', 'invalid_json', 'redacted'},
};

/// Reads one line with the same guarded parser for the consumer and pipeline.
IcingaStreamLineResult decodeIcingaStreamLine(
  String line, {
  required DecodeRequest request,
  required EventTimestamp receivedAt,
  required StreamStateTypePolicy policy,
  IcingaStreamOrigin origin = IcingaStreamOrigin.stream,
  void Function(EventTimestamp)? onUpstreamTime,
}) {
  final document = readStreamJson(line);
  if (origin == IcingaStreamOrigin.sync) {
    guardStreamMembers(line, _syncMembers);
    final type = _required<String>(document, 'type', 'type');
    final attrs = _required<Map<String, Object?>>(document, 'attrs', 'attrs');
    final name = _name(attrs, 'name', 'attrs.name');
    final object = switch (type) {
      'Host' => Icinga2Object(host: name),
      'Service' => Icinga2Object(
        host: _name(attrs, 'host_name', 'attrs.host_name'),
        service: name,
      ),
      _ => throw const EventFieldError('type', 'unsupported_type'),
    };
    return _checkObservation(
      attrs,
      'last_check_result',
      'attrs.last_check_result',
      object,
      policy,
      request,
      receivedAt,
    );
  }

  final type = _required<String>(document, 'type', 'type');
  final members = _members[type];
  if (members == null) throw const EventFieldError('type', 'unsupported_type');
  guardStreamMembers(line, {
    '': members,
    'check_result': _check,
    'check_result.vars_before': _vars,
    'check_result.vars_after': _vars,
    'downtime': _downtime,
    'downtime.source_location': _sourceLocation,
  });
  final upstream = _time(document, 'timestamp', 'timestamp');
  final IcingaStreamLineResult result;
  if (type == 'StateChange') {
    result = _checkObservation(
      document,
      'check_result',
      'check_result',
      _streamObject(document),
      policy,
      request,
      receivedAt,
    );
  } else {
    result = _infoObservation(type, document, request, receivedAt, upstream);
  }
  onUpstreamTime?.call(upstream.toTimestamp());
  return result;
}

IcingaStreamLineResult _checkObservation(
  Map<String, Object?> parent,
  String key,
  String path,
  Icinga2Object object,
  StreamStateTypePolicy policy,
  DecodeRequest request,
  EventTimestamp receivedAt,
) {
  final check = _required<Map<String, Object?>>(parent, key, path);
  final after = _required<Map<String, Object?>>(
    check,
    'vars_after',
    '$path.vars_after',
  );
  final start = _time(check, 'execution_start', '$path.execution_start');
  final end = _time(check, 'execution_end', '$path.execution_end');
  final rawState = _required<num>(after, 'state', '$path.vars_after.state');
  final rawType = _required<num>(
    after,
    'state_type',
    '$path.vars_after.state_type',
  );
  final type = switch (rawType) {
    0 => Icinga2StateType.soft,
    1 => Icinga2StateType.hard,
    _ => throw EventFieldError(
      '$path.vars_after.state_type',
      'invalid_state_type',
    ),
  };
  final state = _state(
    rawState,
    object.service == null,
    _required<bool>(after, 'reachable', '$path.vars_after.reachable'),
    '$path.vars_after.state',
  );
  final output = _optionalString(check, 'output', '$path.output');
  if (!state.isRecovered &&
      type == Icinga2StateType.soft &&
      policy == StreamStateTypePolicy.hardOnly) {
    return const IcingaStreamSoftInfo();
  }
  return IcingaStreamEvent(
    _event(
      object: object,
      request: request,
      receivedAt: receivedAt,
      sourceTime: start.toTimestamp(),
      key: icingaCheckKey(state, type, start, end),
      kind: EventKind.alert,
      status: state.isRecovered ? EventStatus.resolved : EventStatus.firing,
      severity: icinga2StateSeverity(state),
      original: state.wire,
      summary: icinga2StateSummary(object, state),
      description: output,
      type: 'StateChange',
    ),
  );
}

Icinga2State _state(num raw, bool host, bool reachable, String path) =>
    switch ((host, raw)) {
      (true, 0 || 1) => Icinga2State.up,
      (true, 2 || 3) =>
        reachable ? Icinga2State.down : Icinga2State.unreachable,
      (false, 0) => Icinga2State.ok,
      (false, 1) => Icinga2State.warning,
      (false, 2) => Icinga2State.critical,
      (false, 3) => Icinga2State.unknown,
      _ => throw EventFieldError(path, 'invalid_state'),
    };

IcingaStreamEvent _infoObservation(
  String type,
  Map<String, Object?> document,
  DecodeRequest request,
  EventTimestamp receivedAt,
  StreamKeyTime timestamp,
) {
  // Parsed once for both event ordering and the reader's lag observation.
  final Icinga2Object object;
  final EventKind kind;
  final Object? extra;
  final String? author;
  final String? comment;
  switch (type) {
    case 'AcknowledgementSet' || 'AcknowledgementCleared':
      object = _streamObject(document);
      kind = EventKind.ack;
      author = type == 'AcknowledgementSet'
          ? _required<String>(document, 'author', 'author')
          : _optionalString(document, 'author', 'author');
      comment = _optionalString(document, 'comment', 'comment');
      extra = author;
    case 'DowntimeStarted' || 'DowntimeRemoved':
      final downtime = _required<Map<String, Object?>>(
        document,
        'downtime',
        'downtime',
      );
      final service = _optionalString(
        downtime,
        'service_name',
        'downtime.service_name',
      );
      object = Icinga2Object(
        host: _name(downtime, 'host_name', 'downtime.host_name'),
        service: service == null || service.isEmpty ? null : service,
      );
      kind = EventKind.downtime;
      author = _optionalString(downtime, 'author', 'downtime.author');
      comment = _optionalString(downtime, 'comment', 'downtime.comment');
      extra = _name(downtime, 'name', 'downtime.name');
    case 'Flapping':
      object = _streamObject(document);
      kind = EventKind.state;
      author = null;
      comment = null;
      extra = _required<bool>(document, 'is_flapping', 'is_flapping');
    default:
      throw const EventFieldError('type', 'unsupported_type');
  }
  return IcingaStreamEvent(
    _event(
      object: object,
      request: request,
      receivedAt: receivedAt,
      sourceTime: timestamp.toTimestamp(),
      key: icingaStreamEventKey(type, timestamp, extra),
      kind: kind,
      status: EventStatus.info,
      severity: EventSeverity.info,
      summary: normalizeDisplayText(
        '${icinga2ObjectName(object)} $type',
        maxScalars: CanonicalEventBounds.CanonicalEventSummaryLength.max!,
        singleLine: true,
      ),
      description: comment,
      author: author,
      type: type,
    ),
  );
}

Icinga2Object _streamObject(Map<String, Object?> document) => Icinga2Object(
  host: _name(document, 'host', 'host'),
  service: document.containsKey('service')
      ? _name(document, 'service', 'service')
      : null,
);

CanonicalEvent _event({
  required Icinga2Object object,
  required DecodeRequest request,
  required EventTimestamp receivedAt,
  required EventTimestamp sourceTime,
  required String key,
  required EventKind kind,
  required EventStatus status,
  required EventSeverity severity,
  required String summary,
  required String type,
  String? original,
  String? description,
  String? author,
}) => CanonicalEvent.create(
  source: SourceContext(
    sourceInstance: request.sourceInstance,
    sourceKind: 'icinga2',
    namespace: request.namespace,
  ),
  kind: kind,
  status: status,
  severity: severity,
  summary: summary,
  description: description == null || description.isEmpty
      ? null
      : normalizeDisplayText(
          description,
          maxScalars: CanonicalEventBounds.CanonicalEventDescriptionLength.max!,
        ),
  severityOriginal: original,
  identityFields: identityComponents({
    'host': object.host,
    'service': ?object.service,
  }),
  observationKey: ObservationKey.native(key),
  observedAt: receivedAt,
  processedAt: request.processedAt,
  raw: EventRawReference(
    ref: request.rawRef,
    sha256: request.rawSha256,
    size: request.bytes.length,
  ),
  pipeline: EventPipeline(version: request.configVersion),
  annotations: {
    'icinga2.event_type': type,
    if (author != null && author.isNotEmpty)
      'icinga2.notification_author': normalizeDisplayText(
        author,
        maxScalars:
            CanonicalEventBounds.CanonicalEventAnnotationsValueLength.max!,
      ),
  },
  sourceTime: sourceTime,
  reportedSourceTime: sourceTime.toRfc3339(),
);

T _required<T>(Map<String, Object?> document, String key, String path) {
  if (!document.containsKey(key)) throw EventFieldError(path, 'missing_field');
  final value = document[key];
  if (value is! T) throw EventFieldError(path, 'invalid_type');
  return value;
}

String? _optionalString(
  Map<String, Object?> document,
  String key,
  String path,
) => document[key] == null ? null : _required<String>(document, key, path);

String _name(Map<String, Object?> document, String key, String path) {
  final value = _required<String>(document, key, path);
  if (value.isEmpty || value.contains('\u0000')) {
    throw EventFieldError(path, 'invalid_text');
  }
  return value;
}

StreamKeyTime _time(Map<String, Object?> document, String key, String path) =>
    StreamKeyTime.read(document, key, path);

/// A validated row envelope. Its format is checked before item decoding.
final class IcingaStreamRow {
  IcingaStreamRow._(this._document);

  /// Reads the persisted raw envelope without interpreting any lines yet.
  factory IcingaStreamRow.parse(Uint8List bytes) {
    final String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      throw const EventFieldError('body', 'invalid_json');
    }
    final document = readStreamJson(text);
    if (document['format'] != icingaStreamFormat) {
      throw const EventFieldError('format', 'unsupported_format');
    }
    guardStreamMembers(text, _rawMembers);
    return IcingaStreamRow._(document);
  }

  final Map<String, Object?> _document;

  /// Decodes with the trusted admission origin and snapshot policy.
  DecodedBatch decode(
    DecodeRequest request,
    IcingaStreamOrigin origin,
    StreamStateTypePolicy policy,
  ) {
    if (_document['origin'] != origin.name) {
      throw const EventFieldError('origin', 'invalid_origin');
    }
    final items = _required<List<Object?>>(_document, 'items', 'items');
    if (items.isEmpty || items.length > 100) {
      throw const EventFieldError('items', 'invalid_count');
    }
    final events = <CanonicalEvent>[];
    var softInfo = 0;
    for (final item in items) {
      if (item is! Map<String, Object?>) {
        throw const EventFieldError('items', 'invalid_type');
      }
      if (item['invalid_json'] == true || item.containsKey('line_b64')) {
        throw const EventFieldError('body', 'invalid_json');
      }
      final receipt = _required<int>(item, 'received', 'items.received');
      final time = EventTimestamp.fromParts(
        receipt ~/ 1000000,
        receipt % 1000000 * 1000,
        path: 'items.received',
      );
      switch (decodeIcingaStreamLine(
        _required<String>(item, 'line', 'items.line'),
        request: request,
        receivedAt: time,
        policy: policy,
        origin: origin,
      )) {
        case IcingaStreamEvent(:final event):
          events.add(event);
        case IcingaStreamSoftInfo():
          softInfo++;
      }
    }
    return DecodedBatch(events: events, softInfo: softInfo);
  }
}
