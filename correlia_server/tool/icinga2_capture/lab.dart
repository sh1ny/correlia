import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// The command-line paths inside the Icinga 2 container.
const containerEtc = '/etc/icinga2';
const containerSender = '/usr/local/bin/correlia-icinga2-notify';
const containerCorrelia = '$containerEtc/correlia';
const containerLog = '/var/log/icinga2/icinga2.log';

/// A DSL string literal for [value], escaping what the DSL treats specially.
String dslString(String value) {
  final out = StringBuffer('"');
  for (final unit in value.runes) {
    switch (unit) {
      case 0x22:
        out.write(r'\"');
      case 0x5c:
        out.write(r'\\');
      case 0x0a:
        out.write(r'\n');
      default:
        out.writeCharCode(unit);
    }
  }
  return (out..write('"')).toString();
}

/// A result of one command run inside the container.
typedef Executed = ({int code, String out, String err});

/// One official Icinga 2 image run as an idle container, with its daemon
/// started and stopped through `docker exec` so that each start can carry its
/// own environment. Everything runs in the container's own file system; the
/// host's Icinga 2 and every other service are never touched.
final class IcingaLab {
  IcingaLab({required this.image, required this.name, required this.apiPort});

  final String image;
  final String name;
  final int apiPort;

  /// The API user's password, generated for this run and never recorded.
  final String apiPassword = _secret(18);

  int _logOffset = 0;

  static String _secret(int bytes) {
    final random = Random.secure();
    return base64Url
        .encode(List<int>.generate(bytes, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }

  /// Runs `docker` with [args]; throws when it exits non-zero unless [check]
  /// is false.
  static Future<Executed> docker(
    List<String> args, {
    bool check = true,
    List<int>? stdin,
  }) async {
    final process = await Process.start('docker', args);
    final out = process.stdout.fold<List<int>>([], (a, b) => a..addAll(b));
    final err = process.stderr.fold<List<int>>([], (a, b) => a..addAll(b));
    if (stdin != null) {
      process.stdin.add(stdin);
    }
    await process.stdin.close();
    final code = await process.exitCode;
    final result = (
      code: code,
      out: utf8.decode(await out, allowMalformed: true),
      err: utf8.decode(await err, allowMalformed: true),
    );
    if (check && code != 0) {
      throw StateError(
        'docker ${args.take(3).join(' ')} failed: $code\n'
        '${result.err}',
      );
    }
    return result;
  }

  /// Starts the idle container.
  Future<void> create() async {
    await docker([
      'run',
      '-d',
      '--name',
      name,
      '--network',
      'host',
      '--label',
      'correlia.capture=1',
      image,
      'sleep',
      '36000',
    ]);
    // The image's own entrypoint initialises /data before it runs the command.
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (true) {
      final ready = await exec([
        'test',
        '-d',
        '$containerEtc/conf.d',
      ], check: false);
      if (ready.code == 0) return;
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('container $name never initialised its /data');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  /// Removes the container and its anonymous volume.
  Future<void> remove() async {
    await docker(['rm', '-fv', name], check: false);
  }

  Future<Executed> exec(
    List<String> command, {
    String user = '0',
    Map<String, String> env = const {},
    bool check = true,
    List<int>? stdin,
  }) => docker(
    [
      'exec',
      if (stdin != null) '-i',
      '-u',
      user,
      for (final e in env.entries) ...['-e', '${e.key}=${e.value}'],
      name,
      ...command,
    ],
    check: check,
    stdin: stdin,
  );

  /// Writes [bytes] to [path] in the container, owned by [owner] with [mode].
  Future<void> writeFile(
    String path,
    List<int> bytes, {
    String owner = 'root:root',
    String mode = '644',
  }) async {
    await exec(['sh', '-c', 'cat > "\$1"', 'sh', path], stdin: bytes);
    await exec(['chown', owner, path]);
    await exec(['chmod', mode, path]);
  }

  Future<String> readFile(String path) async => (await exec(['cat', path])).out;

  /// Installs the sender and the shipped definitions the way an operator
  /// does: the binary owned by root, mode 0755, and the three definition
  /// files together in `/etc/icinga2/correlia/`, included by one line.
  Future<void> install({
    required File sender,
    required Directory contrib,
  }) async {
    await writeFile(containerSender, sender.readAsBytesSync(), mode: '755');
    await exec(['mkdir', '-p', containerCorrelia]);
    for (final file in contrib.listSync().whereType<File>().where(
      (f) => f.path.endsWith('.conf'),
    )) {
      final base = file.uri.pathSegments.last;
      await writeFile('$containerCorrelia/$base', file.readAsBytesSync());
    }
    await exec(['icinga2', 'api', 'setup'], user: 'icinga');
    // The API user: a password made for this run.
    await writeFile(
      '$containerEtc/conf.d/api-users.conf',
      utf8.encode('''
object ApiUser "capture" {
  password = ${dslString(apiPassword)}
  permissions = [ "*" ]
}
'''),
      owner: 'icinga:icinga',
    );
    await writeFile(
      '$containerEtc/features-enabled/api.conf',
      utf8.encode('''
object ApiListener "api" {
  bind_host = "127.0.0.1"
  bind_port = $apiPort
  ticket_salt = TicketSalt
}
'''),
      owner: 'icinga:icinga',
    );
    await writeFile(
      '$containerEtc/features-enabled/mainlog.conf',
      utf8.encode('''
object FileLogger "main-log" {
  severity = "notice"
  path = LogDir + "/icinga2.log"
}
'''),
      owner: 'icinga:icinga',
    );
    // The stock example objects are replaced by the capture's own.
    await exec([
      'sh',
      '-c',
      'cd $containerEtc/conf.d && '
          'rm -f hosts.conf services.conf notifications.conf users.conf '
          'downtimes.conf groups.conf',
    ]);
    final main = await readFile('$containerEtc/icinga2.conf');
    await writeFile(
      '$containerEtc/icinga2.conf',
      utf8.encode('$main\ninclude "correlia/correlia.conf"\n'),
      owner: 'icinga:icinga',
    );
  }

  /// Replaces the capture's own object definitions.
  Future<void> writeCaptureConfig(String text) => writeFile(
    '$containerEtc/conf.d/capture.conf',
    utf8.encode(text),
    owner: 'icinga:icinga',
  );

  /// Writes the operator-edited `correlia.conf`.
  Future<void> writeSettings(String text) =>
      writeFile('$containerCorrelia/correlia.conf', utf8.encode(text));

  /// Validates the configuration; throws with Icinga 2's own words.
  Future<void> validate() async {
    final result = await exec(
      [
        'icinga2',
        'daemon',
        '-C',
      ],
      user: 'icinga',
      check: false,
    );
    if (result.code != 0) {
      throw StateError('icinga2 daemon -C failed:\n${result.out}${result.err}');
    }
  }

  /// The Icinga 2 version line.
  Future<String> version() async =>
      (await exec(['icinga2', '--version'])).out.split('\n').first;

  /// Starts the daemon with [env] and waits until it has activated its objects.
  Future<void> start({Map<String, String> env = const {}}) async {
    await validate();
    final mark = await logSize();
    await docker([
      'exec',
      '-d',
      '-u',
      'icinga',
      for (final e in env.entries) ...['-e', '${e.key}=${e.value}'],
      name,
      'icinga2',
      'daemon',
    ]);
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (true) {
      final text = await logFrom(mark);
      if (text.contains('Activated all objects.') && await _apiAnswers()) {
        return;
      }
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('daemon did not start:\n$text');
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  Future<bool> _apiAnswers() async {
    try {
      final response = await api('GET', '/v1/status/IcingaApplication');
      return response.status == 200;
    } on Object {
      return false;
    }
  }

  /// Stops the daemon with SIGTERM, so that it writes its retained state.
  Future<void> stop() async {
    await exec([
      'sh',
      '-c',
      'test -e /run/icinga2/icinga2.pid && kill -TERM \$(cat /run/icinga2/icinga2.pid) || true',
    ]);
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (true) {
      final gone = await exec([
        'sh',
        '-c',
        'test ! -e /run/icinga2/icinga2.pid',
      ], check: false);
      if (gone.code == 0 && !await _apiAnswers()) return;
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('daemon did not stop');
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  Future<void> restart({Map<String, String> env = const {}}) async {
    await stop();
    await start(env: env);
  }

  // --- REST API ---------------------------------------------------------

  /// One REST call; [body] is JSON-encoded. Query parameters go in [path].
  Future<({int status, Map<String, Object?> json})> api(
    String method,
    String path, {
    Object? body,
  }) async {
    final client = HttpClient()
      ..badCertificateCallback = ((_, _, _) => true)
      ..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.openUrl(
        method,
        Uri.parse('https://127.0.0.1:$apiPort$path'),
      );
      request.headers
        ..set('accept', 'application/json')
        ..set(
          'authorization',
          'Basic ${base64.encode(utf8.encode('capture:$apiPassword'))}',
        );
      if (body != null) {
        request.headers.set('content-type', 'application/json');
        request.add(utf8.encode(jsonEncode(body)));
      }
      final response = await request.close();
      final text = await utf8.decodeStream(response);
      final json = text.isEmpty
          ? <String, Object?>{}
          : jsonDecode(text) as Map<String, Object?>;
      return (status: response.statusCode, json: json);
    } finally {
      client.close(force: true);
    }
  }

  /// Like [api] but requires status 200 and returns the first result.
  Future<Map<String, Object?>> ok(
    String method,
    String path, {
    Object? body,
  }) async {
    final response = await api(method, path, body: body);
    if (response.status != 200) {
      throw StateError('$method $path -> ${response.status} ${response.json}');
    }
    final results = response.json['results'];
    if (results is List && results.isNotEmpty) {
      return results.first! as Map<String, Object?>;
    }
    return response.json;
  }

  /// Submits a passive check result with an explicit execution start and end.
  ///
  /// [filter] is a DSL filter such as `service.vars.cap_id == "x"`. The start
  /// equals the end, so Icinga 2 never rejects a later result as older.
  Future<void> processCheckResult({
    required String type,
    required String filter,
    required int exitStatus,
    required String output,
    required String end,
  }) async {
    final response = await api(
      'POST',
      '/v1/actions/process-check-result',
      body: {
        'type': type,
        'filter': filter,
        'exit_status': exitStatus,
        'plugin_output': output,
        'execution_start': num.parse(end),
        'execution_end': num.parse(end),
      },
    );
    if (response.status != 200) {
      throw StateError(
        'process-check-result -> ${response.status} '
        '${response.json}',
      );
    }
  }

  /// Evaluates one DSL expression in Icinga 2's console and returns its value.
  Future<Object?> console(String expression) async {
    final response = await api(
      'POST',
      '/v1/console/execute-script?session=capture',
      body: {'command': expression},
    );
    final results = response.json['results']! as List<Object?>;
    final result = results.first! as Map<String, Object?>;
    if (result['code'] != 200) {
      throw StateError('console $expression -> ${result['status']}');
    }
    return result['result'];
  }

  /// The attributes of one object, or null when it does not exist.
  Future<Map<String, Object?>?> attrs(String collection, String name) async {
    final response = await api(
      'GET',
      '/v1/objects/$collection/${Uri.encodeComponent(name)}',
    );
    if (response.status == 404) return null;
    final results = response.json['results']! as List<Object?>;
    return (results.first! as Map<String, Object?>)['attrs']!
        as Map<String, Object?>;
  }

  // --- Log --------------------------------------------------------------

  Future<int> logSize() async {
    final result = await exec([
      'sh',
      '-c',
      'stat -c %s $containerLog 2>/dev/null || echo 0',
    ]);
    return int.parse(result.out.trim());
  }

  /// The log text written after byte [offset].
  Future<String> logFrom(int offset) async {
    final result = await exec([
      'sh',
      '-c',
      'tail -c +${offset + 1} $containerLog 2>/dev/null || true',
    ]);
    return result.out;
  }

  /// The current end of the log; later [logFrom] calls start here.
  Future<int> markLog() async => _logOffset = await logSize();

  /// The log written since the last [markLog], cut per line.
  Future<List<String>> logSinceMark({int lineLimit = 3000}) async =>
      cutLines(await logFrom(_logOffset), lineLimit);

  /// Cuts every line to [limit] characters, noting the cut.
  static List<String> cutLines(String text, int limit) => [
    for (final line in const LineSplitter().convert(text))
      if (line.length <= limit)
        line
      else
        '${line.substring(0, limit)}…[line cut by the capture: ${line.length} characters]',
  ];
}
