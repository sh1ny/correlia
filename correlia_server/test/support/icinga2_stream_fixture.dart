import 'dart:convert';
import 'dart:io';

/// A stream source with its own credentials and no webhook-only fields.
Map<String, Object?> streamSource(String id, {bool enabled = true}) => {
  'id': id,
  'kind': 'icinga2',
  'enabled': enabled,
  'mode': 'event_streams',
  'api': {
    'url': 'https://icinga.example:5665',
    'username': 'correlia',
    'password_ref': 'icinga-password',
    'ca_ref': 'icinga-ca',
    'sync_interval_seconds': 300,
  },
  'state_type_policy': 'soft_and_hard',
  'max_pending_rows': 100,
  'output_ids': <String>[],
};

/// A complete bootstrap document for the given [sources].
Map<String, Object?> streamBootstrap(int revision, List<Object?> sources) => {
  'format_version': 2,
  'revision': revision,
  'outputs': <Object?>[],
  'sources': sources,
};

/// Operator import values for [streamSource].
Map<String, Object?> streamMaterial() => {
  'icinga-password': _bytes(utf8.encode('fixture password')),
  'icinga-ca': _bytes(
    File(
      '../correlia_icinga2_notify/test/fixtures/ca_one.pem',
    ).readAsBytesSync(),
  ),
};

Map<String, Object?> _bytes(List<int> value) => {
  'bytes': base64Url.encode(value).replaceAll('=', ''),
};
