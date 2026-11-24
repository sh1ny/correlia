import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:test/test.dart';

import '../../support/icinga2_stream_fixture.dart';
import 'source_config_test.dart' show field, now, source;

void main() {
  test('valid_stream_source_config', () {
    final parsed = _parse();
    final json = parsed.sources.single.toJson();
    expect(json['mode'], 'event_streams');
    expect(json['api'], containsPair('url', 'https://icinga.example:5665'));
    expect(json['api'], containsPair('password_ref', 'icinga-password'));
    expect(json['api'], containsPair('ca_ref', 'icinga-ca'));
    expect(json['state_type_policy'], 'soft_and_hard');
    expect(json['max_pending_rows'], 100);
    expect(parsed.sources.single.credentials, isEmpty);
  });

  test('webhook_only_field_on_a_stream_source', () {
    for (final MapEntry(:key, :value) in {
      'credentials': <Object?>[],
      'body_limit_bytes': 1024,
      'rate_limit': {'per_second': 1, 'burst': 1},
    }.entries) {
      expect(
        () => _parse(fields: {key: value}),
        throwsA(
          isA<BootstrapError>()
              .having((error) => error.field, 'field', 'sources[0].$key')
              .having((error) => error.code, 'code', 'webhook_only'),
        ),
      );
    }
  });

  test('url_with_a_path_or_plain_http', () {
    for (final url in [
      'http://icinga.example:5665',
      'https://icinga.example:5665/v1',
      'https://user@icinga.example:5665',
      'https://icinga.example:5665?x=y',
    ]) {
      expect(() => _parse(api: {'url': url}), field('sources[0].api.url'));
    }
  });

  test('sync_interval_out_of_range', () {
    expect(
      () => _parse(api: {'sync_interval_seconds': 60}),
      field('sources[0].api.sync_interval_seconds'),
    );
  });
}

IngestBootstrap _parse({
  Map<String, Object?> fields = const {},
  Map<String, Object?> api = const {},
}) {
  final config = streamSource(source);
  final defaults = config['api']! as Map<String, Object?>;
  return IngestBootstrap.parse(
    streamBootstrap(1, [
      {
        ...config,
        'api': {...defaults, ...api},
        ...fields,
      },
    ]),
    streamMaterial(),
    runMode: 'test',
    clock: () => now,
  );
}
