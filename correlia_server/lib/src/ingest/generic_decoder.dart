import 'dart:convert';

import '../event/canonical_event.dart';
import '../event/identity.dart';
import '../event/validation.dart';
import '../event_generated/correlia/event/v1/event_bounds.dart';
import 'body_depth.dart';
import 'bootstrap.dart';
import 'source_decoder.dart';

part 'generic_preview_collector.dart';

const _decodeBudget = 16 * 1024 * 1024;
const _maxDeliveryAlerts = 1000;
const _maxPreviewAlerts = 100;

/// Maps a generic webhook delivery, returning no partial batch on failure.
DecodedBatch decodeGeneric(DecodeRequest request, GenericMapping mapping) =>
    _GenericDecoder(request, mapping, null).decode();

/// Maps the same body as delivery decoding, collecting bounded diagnostics.
GenericPreviewDecode previewGeneric(
  DecodeRequest request,
  GenericMapping mapping,
) {
  final diagnostics = _PreviewCollector();
  List<CanonicalEvent> events;
  try {
    events = _GenericDecoder(request, mapping, diagnostics).decode().events;
  } on EventValidationError catch (error) {
    diagnostics.error(error, null);
    events = const [];
  }
  return diagnostics.result(events);
}

final class _GenericDecoder {
  _GenericDecoder(this.request, this.mapping, this.collector);

  final DecodeRequest request;
  final GenericMapping mapping;
  final _PreviewCollector? collector;
  final _path = <EventPointerSegment>[];
  var _unmapped = 0;
  var _eventBytes = 0;
  int? _index;

  DecodedBatch decode() {
    final Object? body;
    final String text;
    try {
      checkBodyDepth(request.bytes);
      text = utf8.decode(request.bytes);
      body = jsonDecode(text);
    } on FormatException {
      throw EventPointerError(const [], 'invalid_json');
    } on EventFieldError catch (error) {
      throw EventPointerError(const [], error.code);
    }
    _DuplicateScan(text).value();
    final alerts = <CanonicalEvent>[];
    final covered = _Coverage.from(mapping.alertPointers);
    final source = SourceContext(
      sourceInstance: request.sourceInstance,
      namespace: request.namespace,
      sourceKind: SourceKind.generic.name,
    );
    final raw = EventRawReference(
      ref: request.rawRef,
      sha256: request.rawSha256,
      size: request.bytes.length,
    );
    final pipeline = EventPipeline(version: request.configVersion);
    if (mapping.items case final items?) {
      final selected = _select(body, items);
      if (selected is! List<Object?>) {
        throw EventPointerError(_traced(body, items), 'invalid_type');
      }
      if (selected.length >
          (collector == null ? _maxDeliveryAlerts : _maxPreviewAlerts)) {
        throw EventPointerError(_traced(body, items), 'items_bound');
      }
      _visit(body, _Coverage.from([items]));
      _path.addAll(_traced(body, items));
      for (final (index, alert) in selected.indexed) {
        _index = index;
        _path.add((token: '$index', arrayIndex: true));
        final event = _alert(alert, covered, source, raw, pipeline);
        if (event != null) alerts.add(event);
        _path.removeLast();
      }
    } else {
      final event = _alert(body, covered, source, raw, pipeline);
      if (event != null) alerts.add(event);
    }
    return DecodedBatch(events: alerts, unmappedFields: _unmapped);
  }

  CanonicalEvent? _alert(
    Object? alert,
    _Coverage covered,
    SourceContext source,
    EventRawReference raw,
    EventPipeline pipeline,
  ) {
    if (alert is! Map<String, Object?>) {
      _fail(EventPointerError(_path, 'invalid_type'));
      return null;
    }
    final firstError = collector?.errorCount;
    final identity = <String, String>{};
    for (final MapEntry(:key, :value) in mapping.identity.entries) {
      final field = _field(alert, value, (value) {
        if (value == null) throw const EventFieldError('', 'required');
        if (value is! String) throw const EventFieldError('', 'identity_type');
        return value;
      });
      if (field != null) identity[key] = field;
    }
    final observation = switch (mapping.observationId) {
      final GenericPointer pointer => _field(alert, pointer, (value) {
        if (value == null) throw const EventFieldError('', 'required');
        if (value is! String) throw const EventFieldError('', 'invalid_type');
        return ObservationKey.native(value);
      }),
      null => null,
    };
    final (:pointer, :format) = mapping.sourceTime;
    final time = _field(alert, pointer, (value) => _sourceTime(value, format));
    final status = _state(alert, mapping.status);
    final severity = _state(alert, mapping.severity);
    final summary = _display(
      alert,
      mapping.summary,
      CanonicalEventBounds.CanonicalEventSummaryLength.max!,
      required: true,
    );
    final description = switch (mapping.description) {
      final display? => _display(
        alert,
        display,
        CanonicalEventBounds.CanonicalEventDescriptionLength.max!,
      ),
      null => null,
    };
    final labels = <String, String>{};
    for (final MapEntry(:key, :value) in mapping.labels.entries) {
      final label = _display(
        alert,
        value,
        CanonicalEventBounds.CanonicalEventLabelsValueLength.max!,
      );
      if (label != null) labels[key] = label;
    }
    final links = <EventLink>[];
    for (final MapEntry(:key, :value) in mapping.links.entries) {
      final link = switch (value) {
        GenericDisplayConstant(:final value) => EventLink(
          href: value,
          relation: key,
        ),
        GenericDisplayCopy(:final pointer) => _field(alert, pointer, (
          selected,
        ) {
          final href = _text(selected);
          return href == null ? null : EventLink(href: href, relation: key);
        }),
      };
      if (link != null) links.add(link);
    }
    _visit(alert, covered);
    if (collector?.errorCount != firstError) return null;

    final CanonicalEvent event;
    try {
      event = CanonicalEvent.create(
        source: source,
        kind: EventKind.alert,
        status: status!,
        severity: severity!,
        summary: summary!,
        description: description,
        identityFields: identityComponents(identity),
        observationKey:
            observation ??
            ObservationKey.fallback(
              status: status.name,
              severity: severity.name,
              reportedSourceTime: time!.$2,
            ),
        observedAt: request.observedAt,
        processedAt: request.processedAt,
        raw: raw,
        pipeline: pipeline,
        labels: labels,
        links: links,
        sourceTime: time!.$1,
        reportedSourceTime: time.$2,
      );
    } on EventValidationError catch (error) {
      _fail(error);
      return null;
    }
    _eventBytes += defaultStructuredEventBytes(event).length;
    if (_eventBytes > _decodeBudget)
      throw EventPointerError(const [], 'decode_bound');
    return event;
  }

  T? _field<T>(
    Map<String, Object?> alert,
    GenericPointer pointer,
    T? Function(Object?) parse,
  ) {
    try {
      return parse(_select(alert, pointer));
    } on EventFieldError catch (error) {
      _fail(
        EventPointerError([..._path, ..._traced(alert, pointer)], error.code),
      );
      return null;
    }
  }

  T? _state<T extends Enum>(
    Map<String, Object?> alert,
    GenericStateValue<T> field,
  ) => switch (field) {
    GenericStateConstant<T>(:final value) => value,
    GenericValueTable<T>(:final pointer, :final values, :final defaultValue) =>
      _field(alert, pointer, (value) {
        final key = switch (value) {
          String() => value,
          int() => value.toString(),
          null => throw const EventFieldError('', 'required'),
          _ => throw const EventFieldError('', 'invalid_type'),
        };
        return values[key] ??
            defaultValue ??
            (throw const EventFieldError('', 'unlisted_value'));
      }),
  };

  String? _display(
    Map<String, Object?> alert,
    GenericDisplayValue field,
    int max, {
    bool required = false,
  }) => switch (field) {
    GenericDisplayConstant(:final value) => value,
    GenericDisplayCopy(:final pointer) => _field(alert, pointer, (value) {
      final text = _text(value);
      if (text == null || (required && text.isEmpty)) {
        if (required) throw const EventFieldError('', 'required');
        return null;
      }
      return normalizeDisplayText(text, maxScalars: max);
    }),
  };

  void _fail(EventValidationError error) {
    if (collector case final report?) {
      report.error(error, _index);
    } else {
      throw error;
    }
  }

  void _visit(Object? value, _Coverage? covered) {
    if (covered?.terminal ?? false) return;
    switch (value) {
      case Map<String, Object?>() when value.isNotEmpty:
        for (final MapEntry(:key, :value) in value.entries) {
          _visitChild(value, covered?.children[key], key, false);
        }
      case List<Object?>() when value.isNotEmpty:
        for (final (index, child) in value.indexed) {
          final key = '$index';
          _visitChild(child, covered?.children[key], key, true);
        }
      default:
        final reject = mapping.unmappedFields == GenericUnmappedFields.reject;
        if (collector case final report?) {
          report.unmapped(_path, _index, reject: reject);
        } else if (reject) {
          throw EventPointerError(_path, 'unmapped_field');
        }
        _unmapped++;
    }
  }

  void _visitChild(
    Object? value,
    _Coverage? covered,
    String token,
    bool arrayIndex,
  ) {
    if (collector == null &&
        mapping.unmappedFields == GenericUnmappedFields.count) {
      _visit(value, covered);
      return;
    }
    _path.add((token: token, arrayIndex: arrayIndex));
    _visit(value, covered);
    _path.removeLast();
  }
}

String? _text(Object? value) => switch (value) {
  String() => value,
  num() when value.isFinite => jsonEncode(value),
  bool() => jsonEncode(value),
  null => null,
  _ => throw const EventFieldError('', 'invalid_type'),
};

(EventTimestamp, String) _sourceTime(Object? value, GenericTimeFormat format) {
  if (value == null) throw const EventFieldError('', 'required');
  switch (format) {
    case GenericTimeFormat.rfc3339:
      if (value is! String)
        throw const EventFieldError('', 'invalid_timestamp');
      return (EventTimestamp.parse(value), value);
    case GenericTimeFormat.epochSeconds || GenericTimeFormat.epochMillis:
      final millis = format == GenericTimeFormat.epochMillis;
      if (value is! int ||
          value < 0 ||
          value > (millis ? 253402300799999 : 253402300799)) {
        throw const EventFieldError('', 'invalid_timestamp');
      }
      final date = DateTime.fromMillisecondsSinceEpoch(
        millis ? value : value * 1000,
        isUtc: true,
      );
      final iso = date.toIso8601String();
      final text = millis ? iso : '${iso.substring(0, 19)}Z';
      final seconds = millis ? value ~/ 1000 : value;
      return (
        EventTimestamp.fromParts(
          seconds,
          millis ? (value % 1000) * 1000000 : 0,
        ),
        text,
      );
  }
}

final _indexToken = RegExp(r'^(?:0|[1-9][0-9]*)$');

int? _arrayIndex(String token, int length) {
  if (token.length > 10 || !_indexToken.hasMatch(token)) return null;
  final index = int.tryParse(token);
  return index != null && index < length ? index : null;
}

Object? _step(Object? value, String token) => switch (value) {
  Map<String, Object?>() => value[token],
  List<Object?>() => switch (_arrayIndex(token, value.length)) {
    final int index => value[index],
    null => null,
  },
  _ => null,
};

Object? _select(Object? root, GenericPointer pointer) {
  var value = root;
  for (final token in pointer.segments) {
    value = _step(value, token);
    if (value == null) break;
  }
  return value;
}

Iterable<EventPointerSegment> _traced(
  Object? root,
  GenericPointer pointer,
) sync* {
  var value = root;
  for (final token in pointer.segments) {
    yield (
      token: token,
      arrayIndex:
          value is List<Object?> && _arrayIndex(token, value.length) != null,
    );
    value = _step(value, token);
  }
}

final class _Coverage {
  _Coverage();

  factory _Coverage.from(Iterable<GenericPointer> pointers) {
    final root = _Coverage();
    for (final pointer in pointers) {
      var node = root;
      for (final token in pointer.segments) {
        node = node.children.putIfAbsent(token, _Coverage.new);
      }
      node.terminal = true;
    }
    return root;
  }

  final children = <String, _Coverage>{};
  var terminal = false;
}

// jsonDecode verifies syntax before this lexical pass; all it loses is member
// multiplicity. A stack keeps object keys and array indexes distinguishable.
final class _DuplicateScan {
  _DuplicateScan(this.text);
  final String text;
  final path = <EventPointerSegment>[];
  var offset = 0;

  void _space() {
    while (offset < text.length && text.codeUnitAt(offset) <= 0x20) {
      offset++;
    }
  }

  String? _string({required bool member}) {
    final start = offset++;
    var escaped = false;
    while (true) {
      switch (text.codeUnitAt(offset++)) {
        case 0x5c:
          escaped = true;
          offset++;
        case 0x22:
          if (!member) return null;
          return escaped
              ? jsonDecode(text.substring(start, offset)) as String
              : text.substring(start + 1, offset - 1);
      }
    }
  }

  void value() {
    _space();
    switch (text.codeUnitAt(offset)) {
      case 0x7b:
        offset++;
        _space();
        if (text.codeUnitAt(offset) == 0x7d) {
          offset++;
          return;
        }
        final keys = <String>{};
        while (true) {
          final key = _string(member: true)!;
          path.add((token: key, arrayIndex: false));
          if (!keys.add(key)) throw EventPointerError(path, 'duplicate_field');
          _space();
          offset++; // Colon.
          value();
          path.removeLast();
          _space();
          if (text.codeUnitAt(offset++) == 0x7d) return;
          _space();
        }
      case 0x5b:
        offset++;
        _space();
        if (text.codeUnitAt(offset) == 0x5d) {
          offset++;
          return;
        }
        for (var index = 0; ; index++) {
          path.add((token: '$index', arrayIndex: true));
          value();
          path.removeLast();
          _space();
          if (text.codeUnitAt(offset++) == 0x5d) return;
        }
      case 0x22:
        _string(member: false);
      default:
        while (offset < text.length) {
          final byte = text.codeUnitAt(offset);
          if (byte <= 0x20 || byte == 0x2c || byte == 0x5d || byte == 0x7d)
            return;
          offset++;
        }
    }
  }
}
