import 'lab.dart';

/// The objects the capture defines in Icinga 2, as one `conf.d` file.
///
/// Every object carries `vars.cap_id`, which the driver's REST filters use, so
/// that no filter has to spell a name holding a NUL or an invalid byte.
/// The notification objects use the shipped commands unchanged, except two
/// capture-only commands that import a shipped command and replace one
/// argument each: the notification clock source (the known value, with the
/// shipped conversion unchanged) and a gate that holds a command until the
/// driver releases it (so that a RECOVERY can run after a refire).
final class CaptureConfig {
  CaptureConfig({
    required this.serviceClock,
    required this.hostClock,
    required this.longName,
  });

  /// Known notification clock values, in the shipped fixed form.
  final String serviceClock;
  final String hostClock;

  /// The 1025-byte service name.
  final String longName;

  static const lab = 'lab';

  /// The burst services, one per notification.
  static const burstCount = 50;

  static List<String> get burstIds => [
    for (var i = 1; i <= burstCount; i++)
      'burst-${i.toString().padLeft(2, '0')}',
  ];

  /// Plain services on host `lab`: id and command.
  static const services = <(String id, String command)>[
    ('ss', 'correlia-service'),
    ('cv', 'correlia-service'),
    ('two', 'correlia-service'),
    ('ts', 'correlia-service'),
    ('tsclk', 'correlia-service-clock'),
    ('dt', 'correlia-service'),
    ('tx', 'correlia-service'),
    ('long', 'correlia-service'),
    ('custom', 'correlia-service'),
    ('unchecked', 'correlia-service'),
    ('recov1', 'correlia-service'),
    ('recov2', 'correlia-service'),
    ('recov3', 'correlia-service'),
    ('gated', 'correlia-service-delayed'),
    ('nultext', 'correlia-service'),
    ('auth1', 'correlia-service'),
    ('auth2', 'correlia-service'),
    ('env1', 'correlia-service'),
    ('env2', 'correlia-service'),
    ('hostile1', 'correlia-service'),
    ('hostile2', 'correlia-service'),
    ('rej1', 'correlia-service'),
    ('rej2', 'correlia-service'),
    ('inactive', 'correlia-service'),
    ('cap1', 'correlia-service'),
    ('cap2', 'correlia-service'),
    ('cap3', 'correlia-service'),
  ];

  String render() {
    final out = StringBuffer()
      ..writeln(
        r'''
object CheckCommand "capture-passive" { command = [ "/bin/true" ] }

/* An active check whose plugin prints bytes that are not valid UTF-8. */
object CheckCommand "capture-invalid-utf8" {
  command = [ "/bin/sh", "-c", "printf 'bad \\377\\376 bytes, still text\\n'; exit 2" ]
}

template Host "cap-host" {
  check_command = "capture-passive"
  enable_active_checks = false
  max_check_attempts = 1
  address = "127.0.0.1"
  vars.cap_cmd = "correlia-host"
  vars.cap_remind = false
}

template Service "cap-service" {
  check_command = "capture-passive"
  enable_active_checks = false
  max_check_attempts = 1
}

object User "correlia" {
  email = "correlia@localhost"
  states = [ OK, Warning, Critical, Unknown, Up, Down ]
  types = [ Problem, Recovery, Acknowledgement, DowntimeStart, DowntimeEnd, DowntimeRemoved,
            FlappingStart, FlappingEnd, Custom ]
}

/* The capture's control object: the gate and nothing else reads it. */
object Host "capture-control" {
  import "cap-host"
  vars.cap_id = "control"
  vars.capture_hold = false
}

/*
 * Capture-only wrappers around the shipped commands. Each imports a shipped
 * command and replaces exactly one argument.
 */
const CaptureServiceClock = $serviceClock
const CaptureHostClock = $hostClock

object NotificationCommand "correlia-service-clock" {
  import "correlia-service"
  arguments += {
    "--notification-time" = {
      value = {{ correlia_time_literal(CaptureServiceClock) }}
    }
  }
}

object NotificationCommand "correlia-host-clock" {
  import "correlia-host"
  arguments += {
    "--notification-time" = {
      value = {{ correlia_time_literal(CaptureHostClock) }}
    }
  }
}

/* Holds the command (macro resolution runs when the command does) until the driver clears capture_hold. */
globals.capture_gate = function() {
  for (i in range(2400)) {
    if (Icinga.get_host("capture-control").vars.capture_hold != true) {
      return null
    }
    sleep(0.05)
  }
  return null
}

object NotificationCommand "correlia-service-delayed" {
  import "correlia-service"
  arguments += {
    "--base-url" = {
      order = -100
      value = {{
        capture_gate()
        correlia_base_url(CorreliaBaseUrl)
      }}
    }
  }
}

apply Notification "correlia-service" to Service {
  command = "correlia-service"
  users = [ "correlia" ]
  interval = 0
  assign where service.vars.cap_cmd == "correlia-service"
}

apply Notification "correlia-service-clock" to Service {
  command = "correlia-service-clock"
  users = [ "correlia" ]
  interval = 0
  assign where service.vars.cap_cmd == "correlia-service-clock"
}

apply Notification "correlia-service-delayed" to Service {
  command = "correlia-service-delayed"
  users = [ "correlia" ]
  interval = 0
  assign where service.vars.cap_cmd == "correlia-service-delayed"
}

apply Notification "correlia-host" to Host {
  command = "correlia-host"
  users = [ "correlia" ]
  interval = 0
  assign where host.vars.cap_cmd == "correlia-host" && host.vars.cap_remind != true
}

apply Notification "correlia-host-remind" to Host {
  command = "correlia-host"
  users = [ "correlia" ]
  interval = 2s
  assign where host.vars.cap_cmd == "correlia-host" && host.vars.cap_remind == true
}

apply Notification "correlia-host-clock" to Host {
  command = "correlia-host-clock"
  users = [ "correlia" ]
  interval = 0
  assign where host.vars.cap_cmd == "correlia-host-clock"
}

object Host "lab" {
  import "cap-host"
  vars.cap_id = "lab"
}
'''
            .replaceAll(r'$serviceClock', serviceClock)
            .replaceAll(r'$hostClock', hostClock),
      );

    void host(String id, String name, {String extra = '', String? literal}) {
      out.writeln('''
object Host ${literal ?? dslString(name)} {
  import "cap-host"
  vars.cap_id = ${dslString(id)}
$extra}
''');
    }

    host('host-ss', 'host-ss');
    host('host-tr', 'host-tr');
    host('host-ts', 'host-ts');
    host(
      'host-tsclk',
      'host-tsclk',
      extra: '  vars.cap_cmd = "correlia-host-clock"\n',
    );
    host('host-neg', 'host-neg', extra: '  max_check_attempts = 2\n');
    host('host-neg2', 'host-neg2');
    host('host-neg3', 'host-neg3');
    host('fp-startup', 'fp-startup', extra: '  vars.cap_remind = true\n');
    host(
      'fp-volatile',
      'fp-volatile',
      extra: '  vars.cap_remind = true\n  volatile = true\n',
    );
    host('db1', 'db1');
    // A host whose name holds an embedded NUL, written as an octal escape.
    host('db1nul', '', literal: r'"db1\000x"');

    for (final (id, command) in services) {
      out.writeln('''
object Service ${dslString(id)} {
  import "cap-service"
  host_name = "lab"
  vars.cap_id = ${dslString(id)}
  vars.cap_cmd = ${dslString(command)}
${_extra(id)}}
''');
    }
    for (final id in burstIds) {
      out.writeln('''
object Service ${dslString(id)} {
  import "cap-service"
  host_name = "lab"
  vars.cap_id = ${dslString(id)}
  vars.cap_cmd = "correlia-service"
}
''');
    }
    out.writeln('''
object Service ${dslString(longName)} {
  import "cap-service"
  host_name = "lab"
  vars.cap_id = "name1025"
  vars.cap_cmd = "correlia-service"
}

/* A name holding a byte that is not valid UTF-8, written as an octal escape. */
object Service "bad\\377name" {
  import "cap-service"
  host_name = "lab"
  vars.cap_id = "badutf8"
  vars.cap_cmd = "correlia-service"
}

object Service "invalid-output" {
  import "cap-service"
  host_name = "lab"
  check_command = "capture-invalid-utf8"
  enable_active_checks = false
  check_interval = 1h
  vars.cap_id = "invalid"
  vars.cap_cmd = "correlia-service"
}
''');
    return out.toString();
  }

  String _extra(String id) => switch (id) {
    'cv' =>
      '  vars.correlia_last_state_change = "1234567890.000001"\n'
          '  vars.correlia_base_url = "http://127.0.0.1:9"\n',
    'tx' => '  enable_flapping = true\n',
    _ => '',
  };
}

/// The operator-edited `correlia.conf`: the shipped file with its constants set.
///
/// Each argument is the DSL literal of the constant, or null to keep the
/// shipped value.
String settingsText(
  String shipped, {
  String? baseUrl,
  String? source,
  String? tokenFile,
  String? hmacKeyFile,
  String? caFile,
  String? senderPath,
}) {
  var text = shipped;
  String set(String text, String name, String? literal) {
    if (literal == null) return text;
    final pattern = RegExp('^const $name = .*\$', multiLine: true);
    if (!pattern.hasMatch(text)) throw StateError('no constant $name');
    return text.replaceFirst(pattern, 'const $name = $literal');
  }

  text = set(text, 'CorreliaBaseUrl', baseUrl);
  text = set(text, 'CorreliaSource', source);
  text = set(text, 'CorreliaTokenFile', tokenFile);
  text = set(text, 'CorreliaHmacKeyFile', hmacKeyFile);
  text = set(text, 'CorreliaCaFile', caFile);
  text = set(text, 'CorreliaSenderPath', senderPath);
  return text;
}
