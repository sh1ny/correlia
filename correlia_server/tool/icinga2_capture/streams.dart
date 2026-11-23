import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

import 'lab.dart';
import 'staging.dart';

const _types = [
  'StateChange',
  'AcknowledgementSet',
  'AcknowledgementCleared',
  'DowntimeStarted',
  'DowntimeRemoved',
  'Flapping',
];
final _grants = [
  for (final type in _types) 'events/$type',
  'objects/query/Host',
  'objects/query/Service',
];
const _host = 'stream-host';
const _service = 'stream-service';
const _hostFilter = 'host.name == "$_host"';
const _serviceFilter = 'service.name == "$_service"';
const _wait = Duration(seconds: 15);

Future<void> main(List<String> arguments) async {
  final parser = ArgParser();
  for (final name in [
    'release',
    'image',
    'image-id',
    'image-platform',
    'container',
    'api-port',
    'out',
  ]) {
    parser.addOption(name, mandatory: true);
  }
  parser.addOption('digest', defaultsTo: '');
  final args = parser.parse(arguments);
  final release = args.option('release')!;
  final target = Directory('${args.option('out')}/$release/stream');
  final lock = lockPair(target);
  if (lock == null) throw StateError('Another capture holds ${target.path}');
  final lab = IcingaLab(
    image: args.option('image-id')!,
    name: args.option('container')!,
    apiPort: int.parse(args.option('api-port')!),
  );
  final staging = openStaging(target, keep: false);
  try {
    await lab.create();
    await _configure(lab);
    await lab.start();
    final version = await lab.version();
    final architecture = (await lab.exec(['uname', '-m'])).out.trim();
    final capture = await _capture(lab, staging);
    final manifest = {
      'capture_version': 1,
      'release': release,
      'image': args.option('image'),
      'image_digest': args.option('digest'),
      'image_id': args.option('image-id'),
      'image_platform': args.option('image-platform'),
      'container_machine': architecture,
      'icinga_version': version,
      'grants': _grants,
      ...capture,
    };
    File('${staging.path}/manifest.json').writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
    );
    publishStaging(staging, target);
    stdout.writeln('$release: captured Event Streams and permission matrix');
  } finally {
    await lab.remove();
    lock.closeSync();
    if (staging.existsSync()) staging.deleteSync(recursive: true);
  }
}

Future<void> _configure(IcingaLab lab) async {
  await lab.exec(['icinga2', 'api', 'setup'], user: 'icinga');
  await lab.exec([
    'sh',
    '-c',
    'cd $containerEtc/conf.d && rm -f hosts.conf services.conf '
        'notifications.conf users.conf downtimes.conf groups.conf',
  ]);
  Future<void> write(String path, String text) => lab.writeFile(
    '$containerEtc/$path',
    utf8.encode(text),
    owner: 'icinga:icinga',
  );
  await write('features-enabled/api.conf', '''
object ApiListener "api" {
  bind_host = "127.0.0.1"
  bind_port = ${lab.apiPort}
  ticket_salt = TicketSalt
}
''');
  await write('features-enabled/mainlog.conf', '''
object FileLogger "main-log" {
  severity = "notice"
  path = LogDir + "/icinga2.log"
}
''');
  String user(String name, List<String> grants) =>
      '''
object ApiUser "$name" {
  password = ${dslString(lab.apiPassword)}
  permissions = ${jsonEncode(grants)}
}
''';
  await write(
    'conf.d/api-users.conf',
    [
      user('capture', ['*']),
      user('stream', _grants),
      for (var i = 0; i < _grants.length; i++)
        user('omit-$i', [..._grants.take(i), ..._grants.skip(i + 1)]),
    ].join(),
  );
  await lab.writeCaptureConfig('''
object Host "$_host" {
  check_command = "dummy"
  enable_active_checks = false
  max_check_attempts = 2
}
object Service "$_service" {
  host_name = "$_host"
  check_command = "dummy"
  enable_active_checks = false
  enable_flapping = true
  max_check_attempts = 2
}
''');
}

// The disposable lab listens only on loopback; the production consumer's
// exclusive CA trust is exercised by the real-consumer capture, not this probe.
HttpClient _client() => HttpClient()
  ..connectionTimeout = _wait
  ..badCertificateCallback = (_, host, _) => host == '127.0.0.1';

Future<HttpClientResponse> _request(
  IcingaLab lab,
  HttpClient client,
  String user,
  String path,
  Map<String, Object?> body, {
  bool query = false,
}) async {
  final request = await client.postUrl(
    Uri(scheme: 'https', host: '127.0.0.1', port: lab.apiPort, path: path),
  );
  request.headers
    ..set('accept', 'application/json')
    ..set('content-type', 'application/json')
    ..set(
      'authorization',
      'Basic ${base64.encode(utf8.encode('$user:${lab.apiPassword}'))}',
    );
  if (query) request.headers.set('X-HTTP-Method-Override', 'GET');
  request.add(utf8.encode(jsonEncode(body)));
  return request.close().timeout(_wait);
}

const _subscription = {'queue': 'correlia-stream-capture', 'types': _types};
const _projections = {
  'hosts': ['name', 'last_check_result'],
  'services': ['name', 'host_name', 'last_check_result'],
};

Future<Map<String, Object?>> _capture(IcingaLab lab, Directory out) async {
  final client = _client();
  final streamClient = _client();
  try {
    final subscription = await _request(
      lab,
      streamClient,
      'stream',
      '/v1/events',
      _subscription,
    );
    if (subscription.statusCode != 200) {
      throw StateError('subscription HTTP ${subscription.statusCode}');
    }
    final events = _CapturedStream(subscription);
    final origin = DateTime.now().microsecondsSinceEpoch / 1000000 - 60;
    var count = 0;
    Future<int> check(
      String label,
      int state, {
      bool host = false,
      double? start,
      double? end,
      bool older = false,
    }) async {
      final t = start ?? origin + ++count / 1000;
      final response = await lab.api(
        'POST',
        '/v1/actions/process-check-result',
        body: {
          'type': host ? 'Host' : 'Service',
          'filter': host ? _hostFilter : _serviceFilter,
          'exit_status': state,
          'plugin_output': label,
          'execution_start': t,
          'execution_end': end ?? t,
        },
      );
      if (response.status != 200 && !(older && response.status == 409)) {
        throw StateError('$label: check result HTTP ${response.status}');
      }
      return response.status;
    }

    Future<void> action(String name, Map<String, Object?> body) async {
      final result = await lab.ok('POST', '/v1/actions/$name', body: body);
      if (result['code'] != 200) {
        throw StateError('$name did not apply: ${result['code']}');
      }
    }

    try {
      await check('initial host OK', 0, host: true);
      await check('host SOFT problem', 1, host: true);
      await check('host HARD problem', 1, host: true);
      await check('host recovery', 0, host: true);
      await check('initial service OK', 0);
      await check('service SOFT problem', 2, end: origin + 6);
      await check('service HARD problem', 2, end: origin + 4);
      final olderStatus = await check(
        'rejected older start',
        0,
        start: origin + .001,
        end: origin + 7,
        older: true,
      );

      final serviceResult = await events.waitFor((event) {
        final check = event['check_result'];
        return check is Map<String, Object?> &&
            check['output'] == 'service HARD problem';
      });
      final syncs = <String, Object?>{};
      for (final MapEntry(key: collection, value: attrs)
          in _projections.entries) {
        final response = await _request(
          lab,
          client,
          'stream',
          '/v1/objects/$collection',
          {'attrs': attrs},
          query: true,
        );
        final body = await utf8.decodeStream(response).timeout(_wait);
        if (response.statusCode != 200) {
          throw StateError('$collection sync HTTP ${response.statusCode}');
        }
        File('${out.path}/$collection.json').writeAsStringSync(body);
        syncs[collection] = jsonDecode(body);
      }
      final services = syncs['services']! as Map<String, Object?>;
      final objects = services['results']! as List<Object?>;
      final entry = objects.single! as Map<String, Object?>;
      final attrs = entry['attrs']! as Map<String, Object?>;
      final syncResult = attrs['last_check_result']! as Map<String, Object?>;
      if (attrs['name'] != _service ||
          attrs['host_name'] != _host ||
          syncResult['output'] != 'service HARD problem') {
        throw StateError(
          'service sync did not retain the short name and later execution start',
        );
      }

      await action('acknowledge-problem', {
        'type': 'Service',
        'filter': _serviceFilter,
        'author': 'operator',
        'comment': 'checking',
      });
      await events.waitFor((event) => event['type'] == 'AcknowledgementSet');
      await action('remove-acknowledgement', {
        'type': 'Service',
        'filter': _serviceFilter,
      });
      await events.waitFor(
        (event) => event['type'] == 'AcknowledgementCleared',
      );

      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await action('schedule-downtime', {
        'type': 'Service',
        'filter': _serviceFilter,
        'start_time': now - 1,
        'end_time': now + 3600,
        'fixed': true,
        'author': 'operator',
        'comment': 'planned window',
      });
      await check('activate scheduled downtime', 2);
      await events.waitFor((event) => event['type'] == 'DowntimeStarted');
      await action('remove-downtime', {
        'type': 'Downtime',
        'filter': 'downtime.service_name == "$_service"',
      });
      await events.waitFor((event) => event['type'] == 'DowntimeRemoved');

      for (var tick = 0; tick < 60 && !events.hasType('Flapping'); tick++) {
        await check('flapping $tick', tick.isEven ? 0 : 2);
      }
      await events.waitFor((event) => event['type'] == 'Flapping');
      await check('service recovery', 0);
      // An OK of an already healthy service need not emit another state change.
      final missing = _types.where((type) => !events.hasType(type)).toList();
      if (missing.isNotEmpty) {
        throw StateError('missing stream events: $missing');
      }

      final attrError = await _request(
        lab,
        client,
        'stream',
        '/v1/objects/hosts',
        {
          'attrs': ['correlia_unknown_capture_attribute'],
        },
        query: true,
      );
      final attrErrorBody = await utf8.decodeStream(attrError).timeout(_wait);
      File(
        '${out.path}/unknown-attribute.json',
      ).writeAsStringSync(attrErrorBody);
      File(
        '${out.path}/events.ndjson',
      ).writeAsStringSync('${events.lines.join('\n')}\n');
      return {
        'subscription_status': subscription.statusCode,
        'transfer_encoding': subscription.headers.value('transfer-encoding'),
        'content_length': subscription.contentLength,
        'unknown_attribute_status': attrError.statusCode,
        'older_result_status': olderStatus,
        'paired_service_output': 'service HARD problem',
        'paired_event_type': serviceResult['type'],
        'permission_denials': await _denials(lab, client),
      };
    } finally {
      await events.cancel();
    }
  } finally {
    streamClient.close(force: true);
    client.close(force: true);
  }
}

Future<Map<String, Object?>> _denials(IcingaLab lab, HttpClient client) async {
  final results = <String, Object?>{};
  for (var i = 0; i < _grants.length; i++) {
    final isolated = _client();
    final user = 'omit-$i';
    var phase = 'subscription';
    final int status;
    try {
      final response = await _request(
        lab,
        isolated,
        user,
        '/v1/events',
        _subscription,
      );
      if (response.statusCode != 200) {
        status = response.statusCode;
      } else {
        var syncStatus = 200;
        for (final MapEntry(key: collection, value: attrs)
            in _projections.entries) {
          final response = await _request(
            lab,
            client,
            user,
            '/v1/objects/$collection',
            {'attrs': attrs},
            query: true,
          );
          syncStatus = response.statusCode;
          await response.drain<void>().timeout(_wait);
          phase = collection;
          if (syncStatus != 200) break;
        }
        status = syncStatus;
      }
    } finally {
      isolated.close(force: true);
    }
    final expectedPhase = switch (_grants[i]) {
      'objects/query/Host' => 'hosts',
      'objects/query/Service' => 'services',
      _ => 'subscription',
    };
    if (phase != expectedPhase || (status != 403 && status != 404)) {
      throw StateError(
        'omitting ${_grants[i]} gave $phase HTTP $status; expected a $expectedPhase denial',
      );
    }
    results[_grants[i]] = {'phase': phase, 'status': status};
  }
  return results;
}

final class _CapturedStream {
  _CapturedStream(HttpClientResponse response) {
    _subscription = response
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            lines.add(line);
            _events.add(jsonDecode(line) as Map<String, Object?>);
            _notify();
          },
          onError: (Object error) {
            _failure = error;
            _notify();
          },
          onDone: () {
            _failure ??= StateError('subscription closed');
            _notify();
          },
        );
  }

  final lines = <String>[];
  final _events = <Map<String, Object?>>[];
  late final StreamSubscription<String> _subscription;
  var _changed = Completer<void>();
  Object? _failure;

  void _notify() {
    final change = _changed;
    _changed = Completer<void>();
    change.complete();
  }

  bool hasType(String type) => _events.any((event) => event['type'] == type);

  Future<Map<String, Object?>> waitFor(
    bool Function(Map<String, Object?>) match,
  ) async {
    final clock = Stopwatch()..start();
    var seen = 0;
    while (true) {
      for (; seen < _events.length; seen++) {
        if (match(_events[seen])) return _events[seen];
      }
      if (_failure case final error?) throw error;
      await _changed.future.timeout(_wait - clock.elapsed);
    }
  }

  Future<void> cancel() => _subscription.cancel();
}
