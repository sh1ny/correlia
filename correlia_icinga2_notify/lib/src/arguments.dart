import 'dart:convert';

import 'failure.dart';

/// Every argument the sender accepts, each followed by one JSON string literal.
const _names = {
  '--base-url',
  '--source',
  '--token-file',
  '--hmac-key-file',
  '--ca-file',
  '--object-type',
  '--host',
  '--service',
  '--state',
  '--state-type',
  '--last-state-change',
  '--output',
  '--notification-type',
  '--notification-author',
  '--notification-comment',
  '--notification-time',
};

const _required = [
  '--base-url',
  '--source',
  '--object-type',
  '--host',
  '--state',
  '--state-type',
  '--notification-type',
  '--notification-time',
];

/// Notification types whose document must carry the state change time
/// (design D13); every other type may omit it.
const _stateNotificationTypes = {'PROBLEM', 'RECOVERY'};

final _baseUrl = RegExp(r'^https?://[A-Za-z0-9.:\[\]-]+$');
final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);
final _time = RegExp(r'^[1-9][0-9]{0,11}\.[0-9]{6}$');

/// First whole second past the v1 time range (year 10000, UTC); the server
/// refuses a time at or after it as out of range.
const _secondsLimit = 253402300800;

/// Whether [baseUrl]'s authority has no port, or one port in 1-65535 written
/// without leading zeros. An explicit port 0 would otherwise reach the
/// scheme's default port.
bool _portInRange(String baseUrl) {
  final authority = baseUrl.substring(baseUrl.indexOf('//') + 2);
  final hostEnd = authority.startsWith('[')
      ? authority.indexOf(']') + 1
      : (authority.contains(':') ? authority.indexOf(':') : authority.length);
  if (hostEnd <= 0) return false;
  final rest = authority.substring(hostEnd);
  if (rest.isEmpty) return true;
  if (!RegExp(r'^:[1-9][0-9]{0,4}$').hasMatch(rest)) return false;
  return int.parse(rest.substring(1)) <= 65535;
}

const _hostStates = {'UP', 'DOWN', 'UNREACHABLE'};
const _serviceStates = {'OK', 'WARNING', 'CRITICAL', 'UNKNOWN'};
const _notificationTypes = {
  'PROBLEM',
  'RECOVERY',
  'ACKNOWLEDGEMENT',
  'DOWNTIMESTART',
  'DOWNTIMEEND',
  'DOWNTIMECANCELLED',
  'FLAPPINGSTART',
  'FLAPPINGEND',
  'CUSTOM',
};

/// Largest accepted host or service name, in UTF-8 bytes.
const maxNameBytes = 1024;

/// Largest accepted base URL or file path, in UTF-8 bytes.
const maxSettingBytes = 4096;

/// Which credential file the delivery uses.
enum CredentialKind {
  /// The file holds a bearer token.
  token('--token-file'),

  /// The file holds an HMAC key in Correlia's canonical form.
  hmacKey('--hmac-key-file');

  const CredentialKind(this.argument);

  /// The argument that names the file.
  final String argument;
}

/// The validated command line.
final class SenderArguments {
  SenderArguments._({
    required this.baseUrl,
    required this.source,
    required this.credentialKind,
    required this.credentialPath,
    required this.caPath,
    required this.document,
  });

  /// Parses and validates [args]; throws [SenderExit] on the first problem.
  ///
  /// Nothing here touches the file system or the network.
  factory SenderArguments.parse(List<String> args) {
    final raw = <String, String>{};
    if (args.length.isOdd) {
      final last = args.last;
      throw SenderExit.config(
        _names.contains(last) ? 'missing_value $last' : 'unknown_argument',
      );
    }
    for (var i = 0; i < args.length; i += 2) {
      final name = args[i];
      if (!_names.contains(name)) {
        throw const SenderExit.config('unknown_argument');
      }
      if (raw.containsKey(name)) {
        throw SenderExit.config('repeated_argument $name');
      }
      raw[name] = args[i + 1];
    }
    for (final name in _required) {
      if (!raw.containsKey(name)) {
        throw SenderExit.config('missing_argument $name');
      }
    }
    final hasToken = raw.containsKey('--token-file');
    final hasKey = raw.containsKey('--hmac-key-file');
    if (hasToken == hasKey) {
      throw const SenderExit.config('credential_arguments');
    }

    final values = {
      for (final MapEntry(:key, :value) in raw.entries)
        key: _decode(key, value),
    };

    for (final name in ['--host', '--service']) {
      if (values[name] case final value?) _checkName(value);
    }
    for (final name in [
      '--base-url',
      '--source',
      '--token-file',
      '--hmac-key-file',
      '--ca-file',
    ]) {
      if (values[name] case final value?) _checkSetting(name, value);
    }
    // A relative file path would resolve against whatever directory Icinga 2
    // runs in and could name another file.
    for (final name in ['--token-file', '--hmac-key-file', '--ca-file']) {
      if (values[name] case final value? when !value.startsWith('/')) {
        throw SenderExit.config('invalid_argument $name');
      }
    }

    final baseUrl = values['--base-url']!;
    if (!_baseUrl.hasMatch(baseUrl) || !_portInRange(baseUrl)) {
      throw const SenderExit.config('invalid_argument --base-url');
    }
    final source = values['--source']!;
    if (!_uuid.hasMatch(source)) {
      throw const SenderExit.config('invalid_argument --source');
    }

    final objectType = values['--object-type']!;
    final isService = switch (objectType) {
      'host' => false,
      'service' => true,
      _ => throw const SenderExit.config('invalid_argument --object-type'),
    };
    if (isService != values.containsKey('--service')) {
      throw const SenderExit.config('invalid_argument --service');
    }
    final state = values['--state']!;
    if (!(isService ? _serviceStates : _hostStates).contains(state)) {
      throw const SenderExit.config('invalid_argument --state');
    }
    if (!const {'SOFT', 'HARD'}.contains(values['--state-type'])) {
      throw const SenderExit.config('invalid_argument --state-type');
    }
    if (!_notificationTypes.contains(values['--notification-type'])) {
      throw const SenderExit.config('invalid_argument --notification-type');
    }
    final notificationType = values['--notification-type']!;
    if (_stateNotificationTypes.contains(notificationType) &&
        !values.containsKey('--last-state-change')) {
      throw const SenderExit.config('missing_argument --last-state-change');
    }
    for (final name in ['--last-state-change', '--notification-time']) {
      if (values[name] case final value?
          when !_time.hasMatch(value) ||
              int.parse(value.substring(0, value.indexOf('.'))) >=
                  _secondsLimit) {
        throw SenderExit.config('invalid_argument $name');
      }
    }

    // An empty optional text is absent: the shipped commands always pass the
    // texts, each read once, and give the empty literal when there is none.
    String? text(String name) => switch (values[name]) {
      null || '' => null,
      final value => _replaceInvalid(value),
    };

    final output = text('--output');
    final author = text('--notification-author');
    final comment = text('--notification-comment');
    final document = <String, String>{
      'format': 'correlia.icinga2.v1',
      'object_type': objectType,
      'host': values['--host']!,
      'service': ?values['--service'],
      'state': state,
      'state_type': values['--state-type']!,
      'last_state_change': ?values['--last-state-change'],
      'output': ?output,
      'notification_type': notificationType,
      'notification_author': ?author,
      'notification_comment': ?comment,
      'notification_time': values['--notification-time']!,
    };
    return SenderArguments._(
      baseUrl: baseUrl,
      source: source,
      credentialKind: hasToken ? CredentialKind.token : CredentialKind.hmacKey,
      credentialPath: values[hasToken ? '--token-file' : '--hmac-key-file']!,
      caPath: values['--ca-file'],
      document: document,
    );
  }

  /// The base URL, already matched against its fixed form.
  final String baseUrl;

  /// The source UUID.
  final String source;

  /// Whether the credential file is a bearer token or an HMAC key.
  final CredentialKind credentialKind;

  /// The credential file path.
  final String credentialPath;

  /// The `--ca-file` path, or null for the distribution bundle.
  final String? caPath;

  /// The webhook document v1, in field order, ready for `jsonEncode`.
  final Map<String, String> document;
}

/// Decodes one argument that must be a single JSON string literal.
String _decode(String name, String raw) {
  if (raw.length < 2 || !raw.startsWith('"') || !raw.endsWith('"')) {
    throw SenderExit.config('invalid_argument $name');
  }
  try {
    return switch (jsonDecode(raw)) {
      final String value => value,
      _ => throw SenderExit.config('invalid_argument $name'),
    };
  } on FormatException {
    throw SenderExit.config('invalid_argument $name');
  }
}

bool _isControl(int unit) => unit < 0x20 || unit == 0x7f;

/// Whether [value] holds a surrogate that is not half of a valid pair.
bool _hasLoneSurrogate(String value) {
  final units = value.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (i + 1 < units.length &&
          units[i + 1] >= 0xdc00 &&
          units[i + 1] <= 0xdfff) {
        i++;
        continue;
      }
      return true;
    }
    if (unit >= 0xdc00 && unit <= 0xdfff) return true;
  }
  return false;
}

void _checkName(String value) {
  if (value.isEmpty ||
      value.codeUnits.any(_isControl) ||
      _hasLoneSurrogate(value) ||
      utf8.encode(value).length > maxNameBytes) {
    throw const SenderExit.config('invalid_name');
  }
}

void _checkSetting(String name, String value) {
  if (value.isEmpty ||
      value.codeUnits.any(_isControl) ||
      _hasLoneSurrogate(value) ||
      utf8.encode(value).length > maxSettingBytes) {
    throw SenderExit.config('invalid_argument $name');
  }
}

/// Replaces U+0000 and lone surrogates with U+FFFD, so the decoder's
/// `invalid_text` rule never rejects a shipped delivery.
String _replaceInvalid(String value) {
  final units = value.codeUnits;
  final out = <int>[];
  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    final pair =
        unit >= 0xd800 &&
        unit <= 0xdbff &&
        i + 1 < units.length &&
        units[i + 1] >= 0xdc00 &&
        units[i + 1] <= 0xdfff;
    if (pair) {
      out
        ..add(unit)
        ..add(units[++i]);
    } else if (unit == 0 || (unit >= 0xd800 && unit <= 0xdfff)) {
      out.add(0xfffd);
    } else {
      out.add(unit);
    }
  }
  return String.fromCharCodes(out);
}
