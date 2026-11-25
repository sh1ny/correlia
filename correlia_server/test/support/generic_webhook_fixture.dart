/// A generic webhook mapping for one check, with optional batching by callers.
Map<String, Object?> checkMapping({String name = 'checks'}) => {
  'name': name,
  'mapping_format': 1,
  'identity': {'host': '/host'},
  'source_time': {'pointer': '/time', 'format': 'rfc3339'},
  'status': {
    'pointer': '/state',
    'values': {'PROBLEM': 'firing', 'OK': 'resolved'},
  },
  'severity': {'constant': 'critical'},
  'summary': {'copy': '/summary'},
};

/// A generic webhook source using the named mapping and bearer reference.
Map<String, Object?> genericSource(
  String id,
  String reference, {
  String mapping = 'checks',
}) => {
  'id': id,
  'kind': 'generic',
  'enabled': true,
  'mapping': mapping,
  'credentials': [
    {'type': 'bearer', 'ref': reference},
  ],
  'output_ids': <Object?>[],
};
