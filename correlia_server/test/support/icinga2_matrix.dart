import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:correlia_server/event.dart';
import 'package:crypto/crypto.dart';

import 'icinga2_delivery.dart';

/// The Icinga2 source the capture's Correlia child served.
const matrixSource = '33333333-3333-4333-8333-333333333333';

/// Where the committed captures live.
const matrixFixtureRoot = 'test/unit/ingest/fixtures/icinga2';

/// Where the supported-release statement lives.
const matrixStatementFile = '../docs/ingest-pipeline.md';

/// The text the sender appends to a cut text.
const truncationMarker = '…[truncated by correlia]';

const _begin = '<!-- icinga2-supported-releases:begin -->';
const _end = '<!-- icinga2-supported-releases:end -->';

/// The gates a release and architecture pair has to pass, by name.
abstract final class Gate {
  static const service = 'same-second service state';
  static const host = 'same-second host state';
  static const notificationTime = 'same-second notification time';
  static const clock = 'production notification clock';
  static const downtime = 'downtime removal';
  static const firstProblem = 'first problem of a new object';
  static const delivery = 'recorded 202 and decoded event';
  static const decode = 'capture decodes';
  static const manifest = 'capture manifest';

  static const six = [
    service,
    host,
    notificationTime,
    clock,
    downtime,
    firstProblem,
  ];
}

/// One failing check of a pair, naming the gate and what is wrong.
final class Failure {
  const Failure(this.pair, this.gate, this.detail);

  final String pair;
  final String gate;
  final String detail;

  @override
  String toString() => '$pair: $gate: $detail';
}

/// A release and architecture the statement lists.
final class Pair {
  const Pair(this.release, this.architecture, this.directory);

  final String release;
  final String architecture;
  final Directory directory;

  String get name => '$release/$architecture';

  /// The committed capture directory of [release] and [architecture].
  factory Pair.committed(String release, String architecture) => Pair(
    release,
    architecture,
    Directory('$matrixFixtureRoot/$release/$architecture'),
  );
}

/// The pairs the supported-release statement in [markdown] lists.
///
/// The statement is the table between two HTML comment markers; each row names
/// a release and an architecture. A document without the markers lists
/// nothing. Throws a [FormatException] for a table without its header or with
/// a line that is not a readable row, so a row the rendered table shows (with
/// or without its outer pipes) is never skipped.
List<Pair> parseStatement(String markdown, {String? root}) {
  final start = markdown.indexOf(_begin);
  final end = markdown.indexOf(_end);
  if (start < 0 || end < start) return const [];
  final pairs = <Pair>[];
  final lines = markdown
      .substring(start + _begin.length, end)
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
  // The header and its delimiter row come first; every other line is a
  // pair. A line that is neither is refused, so no row the rendered table
  // shows can go unread.
  if (lines.length < 2 ||
      !RegExp(
        r'^\|?\s*Release\s*\|\s*Architecture\s*\|?$',
      ).hasMatch(lines[0]) ||
      !RegExp(r'^\|?\s*:?-+:?\s*\|\s*:?-+:?\s*\|?$').hasMatch(lines[1])) {
    throw const FormatException('the supported releases table has no header');
  }
  final row = RegExp(
    r'^\|?\s*(\d+\.\d+\.\d+)\s*\|\s*(linux-[a-z0-9]+)\s*\|?$',
  );
  for (final line in lines.skip(2)) {
    final m = row.firstMatch(line);
    if (m == null) {
      throw FormatException('unreadable supported releases row: $line');
    }
    final (release, architecture) = (m.group(1)!, m.group(2)!);
    pairs.add(
      root == null
          ? Pair.committed(release, architecture)
          : Pair(
              release,
              architecture,
              Directory('$root/$release/$architecture'),
            ),
    );
  }
  return pairs;
}

/// Removes the previous publication in [release], then reads the statement in
/// [markdown]. A statement that cannot be read ([FormatException]) therefore
/// leaves no earlier bundle at the installation path.
List<Pair> statementForPublishing(Directory release, String markdown) {
  if (release.existsSync()) release.deleteSync(recursive: true);
  return parseStatement(markdown);
}

/// The statement of the repository's docs, or an empty list.
List<Pair> committedStatement() {
  final file = File(matrixStatementFile);
  return file.existsSync() ? parseStatement(file.readAsStringSync()) : const [];
}

/// One recorded item of a capture file.
extension type Rec(Map<String, Object?> json) {
  String get kind => json['kind']! as String;
  String get id => (json['id'] as String?) ?? '';

  Map<String, Object?> get _request => json['request']! as Map<String, Object?>;

  String get bodyText => _request['body']! as String;

  /// The request body as a JSON object.
  Map<String, Object?> get body => jsonDecode(bodyText) as Map<String, Object?>;

  int get status => json['response_status']! as int;
  String get auth => (json['auth'] as String?) ?? '';

  Map<String, Object?> get raw => json['raw']! as Map<String, Object?>;

  Map<String, Object?> get outcome =>
      (raw['outcome'] as Map<String, Object?>?) ?? const {};

  List<Map<String, Object?>> get events =>
      ((json['events'] as List<Object?>?) ?? const [])
          .cast<Map<String, Object?>>();

  /// The `data` part of the [index]th recorded canonical event.
  Map<String, Object?> data([int index = 0]) =>
      (events[index]['cloud_event']! as Map<String, Object?>)['data']!
          as Map<String, Object?>;

  String get eventId => data()['event_id']! as String;

  String? get notificationType => body['notification_type'] as String?;
}

/// The committed capture files of a pair.
final class Capture {
  Capture(this.pair);

  final Pair pair;
  final Map<String, List<Rec>> _cache = {};

  File file(String name) => File('${pair.directory.path}/$name.json');

  bool has(String name) => file(name).existsSync();

  /// The records of the capture file [name]; throws [MissingCapture] if it is
  /// not committed.
  List<Rec> records(String name) => _cache.putIfAbsent(name, () {
    final f = file(name);
    if (!f.existsSync()) throw MissingCapture(pair.name, '$name.json');
    final json = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
    return [
      for (final r in (json['records']! as List<Object?>))
        Rec(r! as Map<String, Object?>),
    ];
  });

  /// Every capture file name (without the extension) except the manifest.
  List<String> get names =>
      pair.directory.existsSync()
            ? [
                for (final f in pair.directory.listSync().whereType<File>())
                  if (f.path.endsWith('.json') &&
                      !f.path.endsWith('manifest.json'))
                    f.uri.pathSegments.last.replaceAll('.json', ''),
              ]
            : <String>[]
        ..sort();

  Map<String, Object?> get manifest {
    final f = File('${pair.directory.path}/manifest.json');
    if (!f.existsSync()) throw MissingCapture(pair.name, 'manifest.json');
    return jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
  }

  List<Rec> of(String name, String kind) => [
    for (final r in records(name))
      if (r.kind == kind) r,
  ];

  /// The deliveries (any kind of request record) of [name], in order.
  List<Rec> requests(String name) => [
    for (final r in records(name))
      if ({
        'admitted',
        'transport_duplicate',
        'rejected',
        'recorder_only',
      }.contains(r.kind))
        r,
  ];

  List<Rec> admitted(String name) => of(name, 'admitted');
}

/// Raised when a capture file the statement relies on is not committed.
final class MissingCapture implements Exception {
  const MissingCapture(this.pair, this.file);

  final String pair;
  final String file;

  @override
  String toString() => '$pair: missing capture $file';
}

/// Decodes a delivery body through the pipeline's Icinga2 decoder.
CanonicalEvent decodeBody(String bodyText) => decodeOne(
  Uint8List.fromList(utf8.encode(bodyText)),
  sourceInstance: matrixSource,
);

/// The Unix time text `seconds.micros` as an ISO-8601 UTC string.
String isoOf(String time) {
  final parts = time.split('.');
  final micros = int.parse(parts[0]) * 1000000 + int.parse(parts[1]);
  return DateTime.fromMicrosecondsSinceEpoch(
    micros,
    isUtc: true,
  ).toIso8601String();
}

/// The Unix time text `seconds.micros` as whole microseconds, the order of
/// the instants it names (unlike ISO text, whose fraction width varies).
int microsOf(String time) {
  final parts = time.split('.');
  return int.parse(parts[0]) * 1000000 + int.parse(parts[1]);
}

String _second(String time) => time.split('.').first;

/// Names a pair's failures; the checks return plain details.
typedef Check = List<String> Function(Capture capture);

/// Runs [check] and turns a missing capture or any error into a detail.
List<String> guarded(Check check, Capture capture) {
  try {
    return check(capture);
  } on MissingCapture catch (error) {
    return ['missing capture ${error.file}'];
  } on Object catch (error) {
    return ['evidence unreadable: $error'];
  }
}

// --- Gates ----------------------------------------------------------------

List<String> _sameSecond(Capture c, String file, {required bool service}) {
  final out = <String>[];
  final results = c.of(file, 'result');
  final deliveries = c.admitted(file);
  if (deliveries.length != 3) {
    return ['expected 3 admitted deliveries, found ${deliveries.length}'];
  }
  // Every result and delivery is the one object of this gate's command: a
  // capture of the other command, or a mixed one, proves nothing here.
  final kind = service ? 'service' : 'host';
  String objectOf(Map<String, Object?> m, String hostKey, String serviceKey) =>
      service ? '${m[hostKey]}/${m[serviceKey]}' : '${m[hostKey]}';
  final objects = <String>{};
  for (final r in results) {
    if (r.json['object_type'] != kind) {
      out.add(
        'result ${r.id} has object_type ${r.json['object_type']}, '
        'not $kind',
      );
    }
    // The driver's results name services on the lab host by their id.
    final object = service ? 'lab/${r.json['cap_id']}' : '${r.json['cap_id']}';
    objects.add(object);
    for (final d in deliveries) {
      final named = objectOf(d.body, 'host', 'service');
      if (named != object) {
        out.add('result ${r.id} is $object, delivery ${d.id} is $named');
      }
    }
  }
  for (final d in deliveries) {
    if (d.body['object_type'] != kind) {
      out.add(
        'delivery ${d.id} has object_type ${d.body['object_type']}, '
        'not $kind',
      );
    }
    if (objects.isEmpty) objects.add(objectOf(d.body, 'host', 'service'));
  }
  for (final s in c.of(file, 'state')) {
    final o = s.json['object'] as Map<String, Object?>? ?? const {};
    final named = objectOf(o, 'host', 'service');
    if (!objects.contains(named) || (!service && o.containsKey('service'))) {
      out.add('state after ${s.json['after']} is for $named');
    }
  }
  final times = [
    for (final d in deliveries) d.body['last_state_change']! as String,
  ];
  if (times.toSet().length != 3) {
    out.add('state change times are not three distinct microsecond values');
  }
  if (times.map(_second).toSet().length != 1) {
    out.add('the three state change times are not in one second');
  }
  final ids = {for (final d in deliveries) d.eventId};
  if (ids.length != 3) {
    out.add('${ids.length} distinct event ids for three observations');
  }
  if (results.length == 3) {
    for (var i = 0; i < 3; i++) {
      if (results[i].json['execution_end'] != times[i]) {
        out.add(
          'delivery ${i + 1} carries ${times[i]}, the driver recorded '
          '${results[i].json['execution_end']}',
        );
      }
    }
  } else {
    out.add('the driver recorded ${results.length} execution ends, not 3');
  }
  final notified = {for (final d in deliveries) d.body['notification_time']};
  if (notified.length != 3) out.add('notification times are not distinct');
  // Problem, recovery, refire: the refire is the newest observation and must
  // win, so the committed alert ends firing with the third event at its fence.
  const sequence = [
    'EVENT_STATUS_FIRING',
    'EVENT_STATUS_RESOLVED',
    'EVENT_STATUS_FIRING',
  ];
  final statuses = [
    for (final d in deliveries)
      d.events.length == 1 ? d.data()['status'] : '${d.events.length} events',
  ];
  if (jsonEncode(statuses) != jsonEncode(sequence)) {
    out.add('event statuses are $statuses, not $sequence');
  }
  final states = c.of(file, 'state');
  final last = states.isEmpty ? null : states.last.json;
  final alert = last?['alert'] as Map<String, Object?>?;
  if (last == null || last['after'] != deliveries.last.id) {
    out.add('no committed state after the refire');
  } else if (alert == null ||
      alert['status'] != 'firing' ||
      alert['fence_event_id'] != deliveries.last.eventId) {
    out.add(
      'the refire did not win: the alert is ${alert?['status']} at '
      '${alert?['fence_event_id']}, not firing at ${deliveries.last.eventId}',
    );
  }
  return out;
}

/// Gate: same-second service state.
List<String> gateService(Capture c) =>
    _sameSecond(c, 'two_problems_within_one_second', service: true);

/// Gate: same-second host state.
List<String> gateHost(Capture c) =>
    _sameSecond(c, 'host_command_keeps_sub_second_precision', service: false);

/// Gate: same-second notification time.
List<String> gateNotificationTime(Capture c) {
  final deliveries = c.admitted('two_comments_from_one_author');
  if (deliveries.length != 2) {
    return ['expected 2 admitted deliveries, found ${deliveries.length}'];
  }
  final times = [
    for (final d in deliveries) d.body['notification_time']! as String,
  ];
  final out = <String>[];
  // Two CUSTOM comments by one author on the one service the scenario
  // targets, in the order it sent them.
  const comments = ['first', 'second'];
  for (var i = 0; i < 2; i++) {
    final b = deliveries[i].body;
    final object = '${b['host']}/${b['service']}';
    if (b['object_type'] != 'service' || object != 'lab/two') {
      out.add(
        'delivery ${i + 1} is $object (${b['object_type']}), not lab/two',
      );
    }
    if (b['notification_type'] != 'CUSTOM' ||
        b['notification_author'] != 'alice' ||
        b['notification_comment'] != comments[i]) {
      out.add(
        'delivery ${i + 1} is ${b['notification_type']} by '
        '${b['notification_author']} "${b['notification_comment']}", not '
        'CUSTOM by alice "${comments[i]}"',
      );
    }
    if (deliveries[i].events.length != 1) {
      out.add('delivery ${i + 1} has ${deliveries[i].events.length} events');
    }
  }
  if (times.toSet().length != 2) out.add('notification times are not distinct');
  if (times.map(_second).toSet().length != 1) {
    out.add('the two notification times are not in one second');
  }
  if (times.toSet().length == 2 && microsOf(times[0]) >= microsOf(times[1])) {
    out.add('the notification times do not increase: $times');
  }
  if ({for (final d in deliveries) d.eventId}.length != 2) {
    out.add('the two notifications share an event id');
  }
  return out;
}

const _clockFile = 'production_notification_clock_keeps_microseconds';

/// Least number of emitted samples per command the clock gate measures.
const emittedClockSamples = 20;

/// The notification times the unmodified commands put on the wire keep
/// whole microseconds: for each command, among at least
/// [emittedClockSamples] CUSTOM deliveries, distinct times, one whose
/// microsecond part is not a multiple of 10 and one that is odd. A command
/// that rounded its clock to 10 us (or to any even step) fails.
List<String> _emittedClock(Capture c) {
  final out = <String>[];
  final deliveries = {for (final d in c.admitted(_clockFile)) d.id: d};
  final emitted = c.of(_clockFile, 'emitted');
  for (final (command, objectType) in [
    ('correlia-service', 'service'),
    ('correlia-host', 'host'),
  ]) {
    final times = <String>[];
    for (final e in emitted.where((e) => e.json['command'] == command)) {
      final d = deliveries[e.json['delivery']];
      if (d == null ||
          d.body['object_type'] != objectType ||
          d.body['notification_type'] != 'CUSTOM') {
        out.add(
          '$command: emitted sample ${e.json['delivery']} is not a '
          'CUSTOM $objectType delivery',
        );
        continue;
      }
      times.add(d.body['notification_time']! as String);
    }
    final micros = [for (final t in times) int.parse(t.split('.')[1])];
    if (times.length < emittedClockSamples ||
        times.toSet().length != times.length ||
        !micros.any((m) => m % 10 != 0) ||
        !micros.any((m) => m.isOdd)) {
      out.add(
        '$command: ${times.length} emitted notification times do not show '
        'whole microseconds',
      );
    }
  }
  return out;
}

/// Gate: production notification clock.
List<String> gateClock(Capture c) {
  final out = <String>[];
  final consoles = c.of(_clockFile, 'console');
  final literals = [
    for (final r in consoles)
      if ((r.json['expression']! as String).startsWith(
        'correlia_time_literal(',
      ))
        r,
  ];
  if (literals.length != 10) {
    out.add('expected 10 microsecond literals, found ${literals.length}');
  }
  for (final r in literals) {
    if (r.json['result'] != '"${r.json['input']}"') {
      out.add(
        'literal ${r.json['input']} came back as ${r.json['result']}',
      );
    }
  }
  final samples = [
    for (final r in consoles)
      if ((r.json['expression']! as String).contains('get_time()')) r,
  ];
  if (samples.isEmpty) {
    out.add('no clock sample recorded');
  } else {
    final values = (samples.single.json['result']! as List<Object?>)
        .cast<String>();
    final fine = values.where(
      (v) => int.parse(v.split('.')[1]) % 10 != 0,
    );
    if (values.length < 20 || fine.isEmpty) {
      out.add(
        'no clock sample has a microsecond part that is not a multiple of '
        '10 (${values.length} samples)',
      );
    }
  }
  out.addAll(_emittedClock(c));
  final known = c.of(_clockFile, 'known');
  // Exactly one known input per shipped command and converted field.
  final covered = [
    for (final k in known) '${k.json['command']} ${k.json['field']}',
  ];
  for (final command in ['correlia-service', 'correlia-host']) {
    for (final field in ['last_state_change', 'notification_time']) {
      final n = covered.where((x) => x == '$command $field').length;
      if (n != 1) out.add('$command $field: $n known inputs, not one');
    }
  }
  if (known.length != 4) out.add('expected 4 known timestamps');
  final deliveries = {for (final d in c.admitted(_clockFile)) d.id: d};
  for (final k in known) {
    final d = deliveries[k.json['delivery']];
    final field = k.json['field']! as String;
    final value = k.json['value']! as String;
    final command = k.json['command'];
    if (d == null) {
      out.add('$command $field: no delivery');
      continue;
    }
    final objectType = command == 'correlia-host' ? 'host' : 'service';
    if (d.body['object_type'] != objectType) {
      out.add(
        '$command $field: delivery ${d.id} is a '
        '${d.body['object_type']} notification',
      );
      continue;
    }
    final seen = d.body[field];
    if (seen != value) {
      out.add('$command $field: committed input $value, delivered $seen');
      continue;
    }
    // The committed event's source time is the known input itself, for the
    // state change of a PROBLEM and the notification time of a CUSTOM alike,
    // in the stored event and in the published canonical event.
    if (d.events.length != 1) {
      out.add('$command $field: delivery ${d.id} committed no single event');
      continue;
    }
    for (final decoded in [
      d.events.single['source_time'],
      d.data()['source_time'],
    ]) {
      if (decoded != isoOf(value)) {
        out.add(
          '$command $field: committed input $value decodes to $decoded',
        );
      }
    }
  }
  return out;
}

const _downtimeFile = 'captured_downtime_removal';
const removalTypes = {'DOWNTIMEEND', 'DOWNTIMECANCELLED'};

/// The comment of the capture's downtime that expires.
const downtimeExpires = 'expires';

/// The comment of the capture's downtime that is removed by hand.
const downtimeRemoved = 'removed by hand';

/// Gate: downtime removal.
///
/// The capture schedules two downtimes, told apart by their comments: one
/// that expires and one removed by hand at the recorded
/// `manual_removal_requested` time. Each must produce exactly one removal
/// notification, the expiry's before that time and the manual one after
/// it, and each removal must commit an informational downtime event with an
/// outbox intent for the capture's output, leaving the alert unchanged.
List<String> gateDowntime(Capture c) {
  final out = <String>[];
  final infos = {
    for (final r in c.of(_downtimeFile, 'info'))
      r.json['name']: r.json['value'],
  };
  final outputId = infos['output_id'];
  final requested = infos['manual_removal_requested'];
  if (outputId is! String || requested is! num) {
    return ['no recorded output or manual removal time'];
  }
  final removals = [
    for (final d in c.admitted(_downtimeFile))
      if (removalTypes.contains(d.notificationType)) d,
  ];
  for (final (comment, beforeRemoval) in [
    (downtimeExpires, true),
    (downtimeRemoved, false),
  ]) {
    final matching = [
      for (final d in removals)
        if (d.body['notification_comment'] == comment) d,
    ];
    if (matching.length != 1) {
      out.add(
        'expected one removal of the "$comment" downtime, '
        'found ${matching.length}',
      );
      continue;
    }
    final d = matching.single;
    final time = double.tryParse(d.body['notification_time'] as String? ?? '');
    if (time == null || (time < requested) != beforeRemoval) {
      out.add(
        'the "$comment" removal at $time is not '
        '${beforeRemoval ? 'before' : 'after'} the manual removal at '
        '$requested',
      );
    }
    final data = d.data();
    if (data['kind'] != 'EVENT_KIND_DOWNTIME' ||
        data['status'] != 'EVENT_STATUS_INFO') {
      out.add('the "$comment" removal is not an informational downtime event');
    }
    final event = d.events.single;
    final intents = (event['outbox'] as List<Object?>?) ?? const [];
    final routed = intents.any(
      (i) => i is Map<String, Object?> && i['output_id'] == outputId,
    );
    if (event['disposition'] != 'ready' || !routed) {
      out.add('the "$comment" removal has no output intent');
    }
  }
  final states = c.of(_downtimeFile, 'state');
  if (states.length < 2) return [...out, 'no committed state before and after'];
  final before = states.first.json['alert'];
  final after = states.last.json['alert'];
  if (before == null || jsonEncode(before) != jsonEncode(after)) {
    out.add('the alert changed: $before -> $after');
  }
  if (before is Map<String, Object?> && before['status'] != 'firing') {
    out.add('the alert was not firing');
  }
  return out;
}

const _firstFile = 'first_check_result_of_a_new_host_is_down';
const _volatileFile = 'volatile_host_with_no_state_change_yet';
const _multilineFile =
    'multiline_recovery_and_custom_notification_without_output';

Map<String, Object?>? _alertOf(Rec state) =>
    state.json['alert'] as Map<String, Object?>?;

List<Rec> _statesOf(Capture c, String file, String host) => [
  for (final s in c.of(file, 'state'))
    if ((s.json['object']! as Map<String, Object?>)['host'] == host) s,
];

List<Rec> _hostRequests(Capture c, String file, String host) => [
  for (final r in c.requests(file))
    if (r.body['host'] == host) r,
];

/// The startup and runtime hosts of the first-problem gate.
List<String> firstProblemHosts(Capture c) {
  final out = <String>[];
  for (final host in ['fp-startup', 'fp-runtime']) {
    final results = {
      for (final r in c.of(_firstFile, 'result'))
        if (r.json['cap_id'] == host) r.json['label']: r,
    };
    final first = results['first_hard'];
    final second = results['second_hard'];
    final requests = _hostRequests(c, _firstFile, host);
    if (first == null || second == null || requests.length < 2) {
      out.add(
        '$host: needs both HARD DOWN results, its first delivery and a '
        'reminder',
      );
      continue;
    }
    // The reminder that proves the key survives the second check is one
    // Icinga 2 sent after accepting it, and the final state follows it.
    final records = c.records(_firstFile);
    final secondAt = records.indexOf(second);
    final accepted = second.json['accepted_us'];
    final after = [
      for (final r in requests.skip(1))
        if (records.indexOf(r) > secondAt &&
            accepted is int &&
            microsOf(r.body['notification_time']! as String) >= accepted)
          r,
    ];
    final states = _statesOf(c, _firstFile, host);
    if (records.indexOf(first) > records.indexOf(requests.first) ||
        records.indexOf(requests.first) > secondAt) {
      out.add('$host: the first delivery does not lie between the results');
    }
    if (after.isEmpty) {
      out.add('$host: no reminder was sent after the second HARD DOWN result');
    } else if (states.isEmpty ||
        records.indexOf(states.last) < records.indexOf(after.last)) {
      out.add('$host: the final state was not taken after the reminder');
    }
    final d1 = requests.first;
    if (d1.kind != 'admitted') {
      out.add('$host: the first delivery is ${d1.kind}');
      continue;
    }
    if (d1.body['last_state_change'] != first.json['execution_end']) {
      out.add(
        '$host: the first HARD DOWN delivery carries '
        '${d1.body['last_state_change']}, the driver recorded '
        '${first.json['execution_end']}',
      );
    }
    if (host == 'fp-runtime') {
      out.addAll(_runtimeHostTime(c, d1.body['last_state_change']));
    }
    if (d1.raw['status'] != 'done' ||
        d1.outcome['late'] != 0 ||
        d1.outcome['applied'] != 1) {
      out.add(
        '$host: the first delivery is not an applied firing row: '
        '${d1.outcome}',
      );
    }
    if (d1.events.length != 1 || d1.data()['status'] != 'EVENT_STATUS_FIRING') {
      out.add('$host: the first delivery has no firing event');
    }
    final id = decodeBody(d1.bodyText).eventId;
    for (final r in requests.skip(1)) {
      if (r.kind != 'admitted') {
        out.add('$host: reminder evidence is a ${r.kind}, not a committed row');
        continue;
      }
      if (r.events.isNotEmpty) {
        out.add('$host: a reminder stored a new event');
      }
      if (r.outcome['duplicate_observation'] != 1) {
        out.add(
          '$host: a reminder committed no duplicate_observation outcome '
          '(${r.outcome['duplicate_observation']})',
        );
      }
      if (decodeBody(r.bodyText).eventId != id) {
        out.add('$host: a reminder decodes to a different event id');
      }
    }
    final last = states.isEmpty ? null : states.last;
    final alert = last == null ? null : _alertOf(last);
    if (alert == null || alert['status'] != 'firing') {
      out.add('$host: no firing alert');
    }
    final counts = last?.json['events'] as Map<String, Object?>?;
    final byStatus = counts?['by_status'] as Map<String, Object?>?;
    if (counts?['total'] != 1 || byStatus?['firing'] != 1) {
      out.add('$host: events are $counts, not one firing event');
    }
  }
  return out;
}

/// Checks that the runtime host's first delivery, [delivered], is not the
/// daemon's start time, which Icinga 2 gives a runtime-created object as its
/// initial state change time (D13).
List<String> _runtimeHostTime(Capture c, Object? delivered) {
  final starts = [
    for (final r in c.of(_firstFile, 'info'))
      if (r.json['name'] == 'daemon_program_start') r.json['value'],
  ];
  if (starts case [final num start]) {
    final time = delivered is String ? double.tryParse(delivered) : null;
    if (time != null && (time - start).abs() < 0.0000005) {
      return [
        'fp-runtime: the first HARD DOWN delivery carries the daemon start '
            'time $start',
      ];
    }
    return const [];
  }
  return ['fp-runtime: no daemon start time recorded'];
}

/// The volatile host of the first-problem gate.
List<String> firstProblemVolatile(Capture c) {
  final out = <String>[];
  final requests = _hostRequests(c, _volatileFile, 'fp-volatile');
  if (requests.length < 3) {
    return ['fp-volatile: needs two deliveries and a reminder'];
  }
  final d1 = requests[0];
  final d2 = requests[1];
  final d3 = requests[2];
  if (d1.kind != 'admitted' || d2.kind != 'admitted' || d3.kind != 'admitted') {
    return ['fp-volatile: a delivery is not a committed row'];
  }
  if (d1.events.length != 1 || d2.events.length != 1) {
    out.add('fp-volatile: the two deliveries are not two events');
  } else if (d1.eventId == d2.eventId) {
    out.add('fp-volatile: the two deliveries share an event id');
  }
  if (d1.data()['status'] != 'EVENT_STATUS_FIRING' ||
      d2.data()['status'] != 'EVENT_STATUS_FIRING') {
    out.add('fp-volatile: both events are not firing');
  }
  // Each delivery carries the execution end of the result that produced it,
  // as the driver submitted it, and its event's source time is that instant.
  final ends = {
    for (final r in c.of(_volatileFile, 'result'))
      if (r.json['cap_id'] == 'fp-volatile')
        r.json['label']: r.json['execution_end'] as String?,
  };
  for (final (d, label) in [
    (d1, 'first_hard'),
    (d2, 'second_hard'),
    (d3, 'second_hard'),
  ]) {
    final end = ends[label];
    if (end == null) {
      out.add('fp-volatile: no recorded $label result');
      continue;
    }
    if (d.body['last_state_change'] != end) {
      out.add(
        'fp-volatile: ${d.id} carries ${d.body['last_state_change']}, not the '
        '$label execution end $end',
      );
    }
    if (d.events.length == 1 && d.events.single['source_time'] != isoOf(end)) {
      out.add(
        'fp-volatile: ${d.id} source time ${d.events.single['source_time']} '
        'is not $label at ${isoOf(end)}',
      );
    }
  }
  final states = _statesOf(c, _volatileFile, 'fp-volatile');
  if (states.length < 2) {
    out.add('fp-volatile: no committed state after each delivery');
  } else {
    final a = _alertOf(states[0]);
    final b = _alertOf(states[1]);
    if (a == null || b == null) {
      out.add('fp-volatile: no alert');
    } else {
      final second = ends['second_hard'];
      if (d2.events.length == 1 &&
          (b['fence_event_id'] != d2.eventId ||
              (second != null &&
                  (b['fence_effective_seconds']! as int) * 1000000000 +
                          (b['fence_effective_nanos']! as int) !=
                      microsOf(second) * 1000))) {
        out.add(
          'fp-volatile: the fence after the second delivery is '
          '${b['fence_event_id']} at ${b['fence_effective_seconds']}.'
          '${b['fence_effective_nanos']}, not ${d2.eventId} at $second',
        );
      }
      if (a['version'] != b['version']) {
        out.add('fp-volatile: the second delivery changed the version');
      }
      if (jsonEncode([
            a['fence_event_id'],
            a['fence_effective_seconds'],
            a['fence_effective_nanos'],
          ]) ==
          jsonEncode([
            b['fence_event_id'],
            b['fence_effective_seconds'],
            b['fence_effective_nanos'],
          ])) {
        out.add('fp-volatile: the second delivery did not move the fence');
      }
    }
  }
  if (d3.events.isNotEmpty || d3.outcome['duplicate_observation'] != 1) {
    out.add('fp-volatile: the reminder is not a duplicate_observation');
  }
  if (decodeBody(d3.bodyText).eventId != decodeBody(d2.bodyText).eventId) {
    out.add('fp-volatile: the reminder does not repeat the second observation');
  }
  return out;
}

/// The unchecked service's CUSTOM notification of the first-problem gate.
List<String> firstProblemCustom(Capture c) {
  final out = <String>[];
  final customs = [
    for (final d in c.requests(_multilineFile))
      if (d.notificationType == 'CUSTOM' && d.body['service'] == 'unchecked') d,
  ];
  if (customs.length != 1) {
    return ['expected one CUSTOM for the unchecked service'];
  }
  final d = customs.single;
  if (d.body.containsKey('output') || d.body.containsKey('last_state_change')) {
    out.add('the CUSTOM carries output or last_state_change');
  }
  if (d.kind != 'admitted' || d.status != 202) {
    out.add('the CUSTOM was not accepted with 202');
    return out;
  }
  if (d.events.length != 1 ||
      d.data()['kind'] != 'EVENT_KIND_COMMENT' ||
      d.data()['status'] != 'EVENT_STATUS_INFO') {
    out.add('the CUSTOM did not store one comment event with status info');
  }
  final states = [
    for (final s in c.of(_multilineFile, 'state'))
      if ((s.json['object']! as Map<String, Object?>)['service'] == 'unchecked')
        s,
  ];
  if (states.isEmpty || _alertOf(states.last) != null) {
    out.add('the CUSTOM created an alert');
  }
  return out;
}

/// Gate: first problem of a new object.
List<String> gateFirstProblem(Capture c) => [
  ...firstProblemHosts(c),
  ...firstProblemVolatile(c),
  ...firstProblemCustom(c),
];

const _authFile = 'notification_from_a_real_icinga_2_in_both_auth_modes';

/// The recorded 202 of each auth mode and the event the pipeline decoded.
List<String> gateDelivery(Capture c) {
  final out = <String>[];
  final admitted = c.admitted(_authFile);
  final modes = {for (final d in admitted) d.auth};
  if (!modes.containsAll(['bearer', 'hmac'])) {
    out.add('no recorded 202 for both auth modes (saw $modes)');
  }
  for (final d in admitted) {
    if (d.status != 202) out.add('${d.auth} delivery was ${d.status}');
    if (d.raw['status'] != 'done') out.add('${d.auth} row is not done');
    if (d.events.length != 1) {
      out.add('${d.auth} delivery has no decoded event');
    }
  }
  return out;
}

/// Ties admitted delivery [d] to the raw row its 202 created: the decoded
/// text is the exact bytes the proxy saw, the row stored those bytes, and
/// every stored event names that row and digest. An event copied from
/// another delivery of the same observation names another row.
List<String> _rawLink(String name, Rec d) {
  final request = d.json['request']! as Map<String, Object?>;
  final digest = request['body_sha256'];
  final size = request['body_size'];
  final rawId = d.raw['id'];
  final out = <String>[];
  if (digest is! String || size is! int || rawId is! String) {
    return ['$name.json ${d.id}: no recorded raw row id or body digest'];
  }
  final bytes = utf8.encode(d.bodyText);
  if (sha256.convert(bytes).toString() != digest || bytes.length != size) {
    out.add('$name.json ${d.id}: the recorded body is not the bytes sent');
  }
  if (d.raw['body_sha256'] != digest) {
    out.add('$name.json ${d.id}: raw row $rawId stored another body');
  }
  for (final e in d.events) {
    final data =
        (e['cloud_event']! as Map<String, Object?>)['data']!
            as Map<String, Object?>;
    final raw = data['raw'] as Map<String, Object?>? ?? const {};
    final ref = raw['ref'];
    if (ref is! String ||
        !ref.endsWith('/$rawId') ||
        raw['sha256'] != digest ||
        raw['size'] != size) {
      out.add(
        '$name.json ${d.id}: event ${data['event_id']} names $ref '
        '(${raw['sha256']}), not raw row $rawId ($digest)',
      );
    }
  }
  return out;
}

/// Every admitted request of every capture file decodes to the recorded event.
List<String> gateDecode(Capture c) {
  final out = <String>[];
  for (final name in c.names) {
    for (final d in c.of(name, 'admitted')) {
      try {
        final event = decodeBody(d.bodyText);
        if (d.status != 202 || d.raw['status'] != 'done') {
          out.add('$name.json ${d.id}: row is ${d.raw['status']}');
        }
        out.addAll(_rawLink(name, d));
        // One stored event per admitted delivery, or none when the committed
        // outcome accounts for it as a duplicate.
        final outcome = d.raw['outcome'] as Map<String, Object?>?;
        final duplicates =
            ((outcome?['duplicate_observation'] as int?) ?? 0) +
            ((outcome?['duplicate_quarantine'] as int?) ?? 0);
        if (d.events.isEmpty) {
          if (duplicates != 1) {
            out.add(
              '$name.json ${d.id}: no stored event and no duplicate outcome',
            );
          }
          continue;
        }
        if (d.events.length != 1 || duplicates != 0) {
          out.add(
            '$name.json ${d.id}: ${d.events.length} stored events with '
            '$duplicates duplicates',
          );
        }
        final data = d.data();
        final recorded = (
          data['fingerprint'],
          data['status'],
          data['kind'],
          data['severity'],
        );
        final decoded = (
          event.fingerprint,
          'EVENT_STATUS_${event.status.name.toUpperCase()}',
          'EVENT_KIND_${event.kind.name.toUpperCase()}',
          'EVENT_SEVERITY_${event.severity.name.toUpperCase()}',
        );
        if (recorded != decoded) {
          out.add('$name.json ${d.id}: decoded $decoded, recorded $recorded');
        }
        // The stored event is the observation this 202 delivered: the same
        // event id and source time as the request decodes to.
        final sourceTime = d.events.first['source_time'];
        if (data['event_id'] != event.eventId ||
            sourceTime is! String ||
            EventTimestamp.parse(sourceTime) != event.sourceTime) {
          out.add(
            '$name.json ${d.id}: stored event ${data['event_id']} at '
            '$sourceTime is not the decoded ${event.eventId} at '
            '${event.sourceTime}',
          );
        }
      } on Object catch (error) {
        out.add(
          '$name.json ${d.id}: does not decode: $error'
          '${_unknownFields(d)}',
        );
      }
    }
  }
  return out;
}

/// The fields whose removal makes [d]'s body decode, named for a failure.
String _unknownFields(Rec d) {
  final names = <String>[];
  final body = d.body;
  for (final key in body.keys) {
    try {
      decodeBody(jsonEncode({...body}..remove(key)));
      names.add(key);
    } on Object {
      // Removing this field does not help.
    }
  }
  return names.isEmpty ? '' : ' (field ${names.join(', ')})';
}

/// The capture manifest names this pair and records no failed scenario.
List<String> gateManifest(Capture c) {
  final m = c.manifest;
  final out = <String>[];
  if (m['release'] != c.pair.release ||
      m['architecture'] != c.pair.architecture) {
    out.add('manifest names ${m['release']}/${m['architecture']}');
  }
  final failed = m['failed_scenarios'];
  if (failed is! List || failed.isNotEmpty) {
    out.add('scenarios did not complete: $failed');
  }
  final digest = m['image_digest'];
  if (digest is! String ||
      !RegExp(r'^[^@\s]+@sha256:[0-9a-f]{64}$').hasMatch(digest)) {
    out.add('no image digest recorded: $digest');
  }
  // The release the daemon itself reported, not the label the driver was given.
  final version = m['icinga_version'];
  if (version is! String ||
      !version.endsWith('(version: v${c.pair.release})')) {
    out.add('the daemon reported $version');
  }
  if (!RegExp(r'^sha256:[0-9a-f]{64}$').hasMatch('${m['image_id']}')) {
    out.add('no image ID recorded: ${m['image_id']}');
  }
  // The pair's sender architecture is what Icinga 2 itself ran as: the
  // image's platform and the machine the kernel reported in the container.
  final (platform, machine) = switch (c.pair.architecture) {
    'linux-x64' => ('linux/amd64', 'x86_64'),
    'linux-arm64' => ('linux/arm64', 'aarch64'),
    final other => ('unknown architecture $other', ''),
  };
  if (m['image_platform'] != platform || m['container_machine'] != machine) {
    out.add(
      'Icinga 2 ran as ${m['image_platform']} (${m['container_machine']}), '
      'not $platform ($machine)',
    );
  }
  return out;
}

/// Evaluates every gate of [pair]; an empty list means it qualifies.
List<Failure> evaluatePair(Pair pair) {
  final c = Capture(pair);
  final failures = <Failure>[];
  void run(String gate, Check check) {
    for (final detail in guarded(check, c)) {
      failures.add(Failure(pair.name, gate, detail));
    }
  }

  if (!pair.directory.existsSync()) {
    return [Failure(pair.name, Gate.manifest, 'no committed capture')];
  }
  run(Gate.manifest, gateManifest);
  run(Gate.service, gateService);
  run(Gate.host, gateHost);
  run(Gate.notificationTime, gateNotificationTime);
  run(Gate.clock, gateClock);
  run(Gate.downtime, gateDowntime);
  run(Gate.firstProblem, gateFirstProblem);
  run(Gate.delivery, gateDelivery);
  run(Gate.decode, gateDecode);
  return failures;
}

/// Evaluates a statement: it must list at least one pair, and every listed
/// pair must pass.
List<Failure> evaluateStatement(List<Pair> pairs) {
  if (pairs.isEmpty) {
    return const [
      Failure(
        'statement',
        'no release passes',
        'the supported-release list is empty',
      ),
    ];
  }
  return [for (final p in pairs) ...evaluatePair(p)];
}

/// The architectures the sender is built for (`mise run build:icinga2-notify`).
const builtArchitectures = ['linux-x64', 'linux-arm64'];

/// The sender's file name inside each architecture's build directory.
const senderFileName = 'correlia-icinga2-notify';

/// The exact artifacts a capture ran: the sender's SHA-256 and the SHA-256 of
/// each `contrib/icinga2/` definition file, by file name.
final class Bundle {
  const Bundle(this.sender, this.definitions);

  /// The bundle a capture's manifest records, or null when it records none.
  static Bundle? of(Capture capture) {
    final manifest = capture.manifest;
    final sender = manifest['sender_sha256'];
    final definitions = manifest['contrib_sha256'];
    if (sender is! String || definitions is! Map<String, Object?>) return null;
    return Bundle(sender, {
      for (final MapEntry(:key, :value) in definitions.entries)
        if (value is String) key: value,
    });
  }

  /// The bundle of the built [sender] and the definition files in [contrib].
  static Bundle current(File sender, Directory contrib) => Bundle(
    sha256.convert(sender.readAsBytesSync()).toString(),
    definitionHashes(contrib),
  );

  final String sender;
  final Map<String, String> definitions;

  @override
  bool operator ==(Object other) =>
      other is Bundle &&
      other.sender == sender &&
      jsonEncode(_sorted(other.definitions)) ==
          jsonEncode(_sorted(definitions));

  @override
  int get hashCode => Object.hash(sender, jsonEncode(_sorted(definitions)));

  static Map<String, String> _sorted(Map<String, String> m) => {
    for (final k in m.keys.toList()..sort()) k: m[k]!,
  };

  @override
  String toString() =>
      'sender $sender, definitions ${jsonEncode(_sorted(definitions))}';
}

/// The SHA-256 of each file directly in [contrib], by file name.
Map<String, String> definitionHashes(Directory contrib) => {
  for (final file
      in contrib.listSync().whereType<File>().toList()
        ..sort((a, b) => a.path.compareTo(b.path)))
    file.uri.pathSegments.last: sha256
        .convert(file.readAsBytesSync())
        .toString(),
};

/// What [qualifiedBundles] found: the one bundle each qualified architecture
/// ran, and why each other listed architecture is refused.
typedef Qualification = ({
  Map<String, Bundle> qualified,
  Map<String, String> refused,
});

/// The qualified bundle of each architecture listed in [pairs].
///
/// An architecture qualifies only when every listed pair of it passes every
/// check and all of them ran one and the same bundle, so each advertised pair
/// vouches for exactly the artifacts that would ship. A failing pair, a
/// manifest without a bundle, or two pairs that ran different senders or
/// definitions refuse the architecture.
Qualification qualifiedBundles(List<Pair> pairs) {
  final byArchitecture = <String, List<Pair>>{};
  for (final pair in pairs) {
    (byArchitecture[pair.architecture] ??= []).add(pair);
  }
  final qualified = <String, Bundle>{};
  final refused = <String, String>{};
  for (final MapEntry(key: architecture, value: listed)
      in byArchitecture.entries) {
    String? reason;
    Bundle? bundle;
    for (final pair in listed) {
      if (evaluatePair(pair).isNotEmpty) {
        reason = '${pair.name} does not pass';
        break;
      }
      final ran = Bundle.of(Capture(pair));
      if (ran == null) {
        reason = '${pair.name} records no sender and definitions';
        break;
      }
      if (bundle != null && ran != bundle) {
        reason = '${pair.name} ran another bundle than ${listed.first.name}';
        break;
      }
      bundle = ran;
    }
    if (reason != null) {
      refused[architecture] = reason;
    } else if (bundle != null) {
      qualified[architecture] = bundle;
    }
  }
  return (qualified: qualified, refused: refused);
}

/// Publishes, for each architecture in [qualified], the built sender from
/// `<build>/<architecture>/` to `<release>/<architecture>/`, and the
/// definition files of [contrib] to `<release>/icinga2/`.
///
/// Publishing requires the built sender and the current definitions to be
/// exactly the bundle every listed pair of that architecture ran. [release]
/// is emptied first, so an architecture that no longer qualifies leaves no
/// artifact behind. With nothing qualified, or a built sender or a definition
/// that differs from the captured bundle, a [StateError] says so and nothing
/// is published: the webhook contract is not shipped without a qualified
/// pair. Returns the published architectures in build order.
List<String> publishSenders({
  required Directory build,
  required Directory contrib,
  required Directory release,
  required Map<String, Bundle> qualified,
}) {
  if (release.existsSync()) release.deleteSync(recursive: true);
  if (qualified.isEmpty) {
    throw StateError('no release and architecture pair qualifies');
  }
  final sources = <String, File>{};
  for (final architecture in builtArchitectures) {
    final captured = qualified[architecture];
    if (captured == null) continue;
    final source = File('${build.path}/$architecture/$senderFileName');
    if (!source.existsSync()) {
      throw StateError('no built sender for $architecture: ${source.path}');
    }
    final built = Bundle.current(source, contrib);
    if (built != captured) {
      throw StateError(
        'the built $architecture bundle ($built) is not the bundle its '
        'listed captures ran ($captured)',
      );
    }
    sources[architecture] = source;
  }
  for (final MapEntry(key: architecture, value: source) in sources.entries) {
    final target = Directory('${release.path}/$architecture')
      ..createSync(recursive: true);
    source.copySync('${target.path}/$senderFileName');
  }
  final definitions = Directory('${release.path}/icinga2')
    ..createSync(recursive: true);
  for (final file in contrib.listSync().whereType<File>()) {
    file.copySync('${definitions.path}/${file.uri.pathSegments.last}');
  }
  return sources.keys.toList();
}
