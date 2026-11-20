import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../test/support/icinga2_delivery.dart';
import 'lab.dart';
import 'rig.dart';

/// The fixed-form time text of whole [seconds] plus [micros] microseconds.
String timeText(int seconds, int micros) =>
    '$seconds.${micros.toString().padLeft(6, '0')}';

/// The capture's shared handles and the output directory.
final class Capture {
  Capture({
    required this.rig,
    required this.lab,
    required this.out,
    required this.shipped,
  });

  final CorreliaRig rig;
  final IcingaLab lab;
  final Directory out;

  /// The shipped `correlia.conf`, before the capture sets its constants.
  final String shipped;

  int _proxyCursor = 0;
  int _receiverCursor = 0;
  final List<String> failed = [];

  /// The current wall clock in whole Unix seconds.
  int nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  Evidence begin(String name) => Evidence._(this, name);

  /// Waits until [count] more requests reached the proxy, and takes them.
  Future<List<SeenRequest>> takeProxied(
    int count, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (rig.proxied.length < _proxyCursor + count) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError(
          'expected $count request(s) through the proxy, saw '
          '${rig.proxied.length - _proxyCursor}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    final taken = rig.proxied.sublist(_proxyCursor, _proxyCursor + count);
    _proxyCursor += count;
    return taken;
  }

  Future<List<SeenRequest>> takeReceived(
    int count, {
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (rig.received.length < _receiverCursor + count) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError(
          'expected $count request(s) at the receiver, saw '
          '${rig.received.length - _receiverCursor}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    final taken = rig.received.sublist(
      _receiverCursor,
      _receiverCursor + count,
    );
    _receiverCursor += count;
    return taken;
  }

  /// How many proxied requests nobody has taken yet.
  int get untakenProxied => rig.proxied.length - _proxyCursor;

  /// Skips every request seen so far (for steps whose requests are not
  /// evidence).
  void drain() {
    _proxyCursor = rig.proxied.length;
    _receiverCursor = rig.received.length;
  }
}

/// One evidence file: an ordered list of records.
final class Evidence {
  Evidence._(this.cap, this.name);

  final Capture cap;
  final String name;
  final List<Map<String, Object?>> records = [];
  int _ids = 0;
  late int _logMark;
  int _failuresConsumed = 0;

  /// The log offset [markLog] took.
  int get logMark => _logMark;

  String nextId(String prefix) => '$prefix${++_ids}';

  /// Marks the Icinga 2 log; later log reads start here.
  Future<void> markLog() async => _logMark = await cap.lab.logSize();

  void add(Map<String, Object?> record) => records.add(record);

  void info(String name, Object? value) =>
      add({'kind': 'info', 'name': name, 'value': value});

  /// Submits a passive result and records its execution end.
  Future<String> result({
    required String objectType,
    required String id,
    required int exit,
    required String output,
    required String end,
    String? label,
  }) async {
    final type = objectType == 'host' ? 'Host' : 'Service';
    final field = objectType == 'host' ? 'host' : 'service';
    await cap.lab.processCheckResult(
      type: type,
      filter: '$field.vars.cap_id == ${dslString(id)}',
      exitStatus: exit,
      output: output,
      end: end,
    );
    final recordId = nextId('r');
    add({
      'kind': 'result',
      'id': recordId,
      'object_type': objectType,
      'cap_id': id,
      'exit_status': exit,
      'output_bytes': utf8.encode(output).length,
      if (output.length <= 200) 'output': output,
      'execution_end': end,
      'label': ?label,
    });
    return recordId;
  }

  /// Waits for [count] requests through the proxy, correlates each with its
  /// raw row and records it as admitted, transport-deduplicated or rejected.
  Future<List<Map<String, Object?>>> deliveries(int count) async {
    final taken = await cap.takeProxied(count);
    final recorded = <Map<String, Object?>>[];
    for (final request in taken) {
      final record = await _classify(request);
      add(record);
      recorded.add(record);
    }
    return recorded;
  }

  Future<Map<String, Object?>> _classify(SeenRequest request) async {
    final base = <String, Object?>{
      'id': nextId('d'),
      'auth': request.auth,
      'request': {
        'path': request.path,
        'body': utf8.decode(request.body, allowMalformed: true),
      },
      'response_status': request.status,
    };
    if (request.status != 202) {
      return {'kind': 'rejected', ...base};
    }
    if (request.newRawIds.isEmpty) {
      return {'kind': 'transport_duplicate', ...base};
    }
    final raw = await cap.rig.rawResult(request.newRawIds.single);
    return {
      'kind': 'admitted',
      ...base,
      'raw': {
        'status': raw.status,
        'outcome': raw.outcome,
        'failure': raw.failure,
      },
      'events': raw.events,
    };
  }

  /// Waits for [count] requests at the recording receiver.
  Future<List<Map<String, Object?>>> recorded(
    int count, {
    bool bodies = true,
  }) async {
    final taken = await cap.takeReceived(count);
    final recorded = <Map<String, Object?>>[];
    for (final request in taken) {
      final record = <String, Object?>{
        'kind': 'recorder_only',
        'id': nextId('d'),
        'auth': request.auth,
        'request': {
          'path': request.path,
          'body': utf8.decode(request.body, allowMalformed: true),
        },
        'response_status': request.status,
      };
      add(record);
      recorded.add(record);
    }
    return recorded;
  }

  /// Records the committed alert and event counts for an object.
  Future<void> snapshot(
    String after, {
    required String host,
    String? service,
  }) async {
    final fingerprint = fingerprintOf(host, service);
    add({
      'kind': 'state',
      'after': after,
      'object': {'host': host, 'service': ?service},
      'alert': await cap.rig.alert(fingerprint),
      'events': await cap.rig.eventCounts(fingerprint),
    });
  }

  /// The fingerprint Correlia derives for an object of this capture's source.
  static String fingerprintOf(String host, String? service) {
    final document = service == null
        ? hostDelivery(set: {'host': host})
        : delivery(set: {'host': host, 'service': service});
    return decodeOne(document, sourceInstance: captureSource).fingerprint;
  }

  /// Waits for [count] failed commands in the Icinga 2 log since [markLog]
  /// and records each with its exit code and the sender's one-line detail.
  Future<List<Map<String, Object?>>> failures(
    int count, {
    String? mustContain,
  }) async {
    final pattern = RegExp(
      r"terminated with exit code (\d+), output: '?(.*?)'?$",
    );
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (true) {
      final all = const LineSplitter()
          .convert(await cap.lab.logFrom(_logMark))
          .where(
            (l) => l.contains('PluginNotificationTask') && pattern.hasMatch(l),
          )
          .toList();
      final lines = all
          .skip(_failuresConsumed)
          .where((l) => mustContain == null || l.contains(mustContain))
          .toList();
      if (lines.length >= count) {
        final recorded = <Map<String, Object?>>[];
        _failuresConsumed = all.indexOf(lines[count - 1]) + 1;
        for (final line in lines.take(count)) {
          final match = pattern.firstMatch(line)!;
          final record = <String, Object?>{
            'kind': 'command_failure',
            'id': nextId('f'),
            'exit_code': int.parse(match.group(1)!),
            'detail': match.group(2),
            'log': IcingaLab.cutLines(line, 3000).single,
          };
          add(record);
          recorded.add(record);
        }
        return recorded;
      }
      if (DateTime.now().isAfter(deadline)) {
        throw StateError(
          'expected $count failed command(s), found ${lines.length}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  /// Records the notification-related log lines written since [markLog].
  Future<void> logExcerpt({String? label}) async {
    final text = await cap.lab.logFrom(_logMark);
    final lines = [
      for (final line in IcingaLab.cutLines(text, 3000))
        if (line.contains('correlia-icinga2-notify') ||
            line.contains('PluginNotificationTask') ||
            line.contains('Notification'))
          line,
    ];
    add({'kind': 'log', 'label': ?label, 'lines': lines});
  }

  /// Evaluates [expression] in Icinga 2's console and records the value.
  Future<Object?> console(String expression, {Object? input}) async {
    final value = await cap.lab.console(expression);
    add({
      'kind': 'console',
      'id': nextId('c'),
      'expression': expression,
      'input': ?input,
      'result': value,
    });
    return value;
  }

  /// Writes the file, one JSON document.
  void save(String release) {
    final file = File('${cap.out.path}/$name.json');
    file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({'scenario': name, 'release': release, 'records': records})}\n',
    );
  }
}
