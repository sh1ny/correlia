import 'dart:convert';

import 'package:correlia_server/src/event/validation.dart';
import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:test/test.dart';

import '../../support/generic_webhook_fixture.dart';

EventPointerSegment _key(String token) => (token: token, arrayIndex: false);
String _stored(
  List<EventPointerSegment> segments,
  Map<String, Object?> document,
) => safeFailurePath(
  '',
  SourceKind.generic,
  mapping: GenericMapping.parse(document),
  senderPath: segments,
);

void main() {
  test('numeric_object_key', () {
    final mapping = {...checkMapping(), 'items': '/alerts'};
    expect(
      _stored([
        _key('alerts'),
        (token: '1', arrayIndex: true),
        _key('9'),
      ], mapping),
      '/alerts/1/*',
    );
    expect(
      _stored([_key('alerts'), _key('1'), _key('host')], mapping),
      '/alerts/*/*',
    );
    expect(
      _stored([
        _key('alerts'),
        (token: '1', arrayIndex: true),
        _key('host'),
      ], mapping),
      '/alerts/1/host',
    );
  });

  test('first_segment_longer_than_the_path_bound', () {
    final key = 'a' * 256;
    final mapping = {
      ...checkMapping(),
      'identity': {'host': '/$key'},
    };
    expect(_stored([_key(key)], mapping), '/*');
    expect(_stored([], mapping), '');
  });

  test('multibyte_segment_at_the_path_bound', () {
    final raw = '${'é' * 126}~/';
    final escaped = '${'é' * 126}~0~1';
    final mapping = {
      ...checkMapping(),
      'identity': {'host': '/$escaped/leaf'},
    };
    expect(_stored([_key(raw), _key('leaf')], mapping), '/*');
    final shorter = '${'é' * 125}~0~1';
    final path = _stored(
      [_key('${'é' * 125}~/'), _key('leaf')],
      {
        ...checkMapping(),
        'identity': {'host': '/$shorter/leaf'},
      },
    );
    expect(path, '/$shorter');
    expect(utf8.encode(path), hasLength(255));
  });
}
