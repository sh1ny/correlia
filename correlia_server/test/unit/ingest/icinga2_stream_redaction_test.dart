import 'dart:convert';
import 'dart:typed_data';

import 'package:correlia_server/src/ingest/icinga2/stream/redaction.dart';
import 'package:test/test.dart';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

Map<String, Object?> _object(Uint8List bytes) =>
    (jsonDecode(utf8.decode(bytes)) as Map<String, Object?>);

void main() {
  group('PasswordRedactor', () {
    test('short_password_is_not_recreated', () {
      const password = 'red';
      // A marker beginning with d or ending with r recreates the password.
      const input = '{"comment":"before-rereded-after","other":"intact"}';
      final result = PasswordRedactor(_bytes(password)).sanitize(_bytes(input));

      expect(result.invalidJson, isFalse);
      expect(result.redacted, isTrue);
      final text = utf8.decode(result.bytes);
      final object = _object(result.bytes);
      final comment = object['comment']! as String;
      expect(text, isNot(contains(password)));
      expect(comment, isNot(contains(password)));
      expect(comment, startsWith('before-re'));
      expect(comment, endsWith('ed-after'));
      expect(object['other'], 'intact');
    });

    test('unrelated_escape_preserves_event', () {
      const input = r'{"comment":"\u0041","other":17}';
      final result = PasswordRedactor(_bytes('u0041')).sanitize(_bytes(input));

      expect(result.invalidJson, isFalse);
      expect(result.redacted, isFalse);
      expect(result.bytes, orderedEquals(_bytes(input)));
      expect(_object(result.bytes), {'comment': 'A', 'other': 17});
    });

    test('escaped_echoes_in_keys_and_values_are_redacted', () {
      const password = 'a"\\é';
      const input =
          r'{"key-a\"\\\u00e9-end":"value-a\"\\\u00e9-end","untouched":"safe"}';
      final result = PasswordRedactor(_bytes(password)).sanitize(_bytes(input));

      expect(result.invalidJson, isFalse);
      expect(result.redacted, isTrue);
      final object = _object(result.bytes);
      expect(object['untouched'], 'safe');
      final key = object.keys.singleWhere((key) => key.startsWith('key-'));
      final value = object[key]! as String;
      expect(key, endsWith('-end'));
      expect(key, isNot(contains(password)));
      expect(value, startsWith('value-'));
      expect(value, endsWith('-end'));
      expect(value, isNot(contains(password)));
      expect(utf8.decode(result.bytes), isNot(contains(r'a\"\\\u00e9')));
    });

    test('overlapping_literal_and_escaped_echoes_are_redacted', () {
      const input = r'{"comment":"left-ab\u0061ba-right","keep":"safe"}';
      final result = PasswordRedactor(_bytes('aba')).sanitize(_bytes(input));

      expect(result.invalidJson, isFalse);
      expect(result.redacted, isTrue);
      final object = _object(result.bytes);
      final comment = object['comment']! as String;
      expect(comment, startsWith('left-'));
      expect(comment, endsWith('-right'));
      expect(comment, isNot(contains('aba')));
      expect(object['keep'], 'safe');
    });

    test('standard_and_url_base64_padded_and_unpadded_are_redacted', () {
      const password = '࿿x';
      final passwordBytes = _bytes(password);
      final standard = base64.encode(passwordBytes);
      final url = base64Url.encode(passwordBytes);
      final forms = [
        standard,
        standard.replaceAll('=', ''),
        url,
        url.replaceAll('=', ''),
      ];
      expect(forms.toSet(), hasLength(4));
      for (final form in forms) {
        final input = jsonEncode({'comment': 'left-$form-right', 'keep': 42});
        final result = PasswordRedactor(passwordBytes).sanitize(_bytes(input));
        expect(result.invalidJson, isFalse, reason: form);
        expect(result.redacted, isTrue, reason: form);
        final object = _object(result.bytes);
        final comment = object['comment']! as String;
        expect(comment, startsWith('left-'), reason: form);
        expect(comment, endsWith('-right'), reason: form);
        expect(comment, isNot(contains(form)), reason: form);
        expect(utf8.decode(result.bytes), isNot(contains(form)), reason: form);
        expect(object['keep'], 42, reason: form);
      }
    });

    test('basic_token_does_not_expand_the_password_marker', () {
      final password = _bytes('!#');
      final token = base64.encode(_bytes('${'u' * 256}:!#'));
      final input = _bytes('{"comment":"left !# right"}');
      final result = PasswordRedactor(
        password,
        basicToken: token,
      ).sanitize(input);
      final comment = _object(result.bytes)['comment']! as String;
      expect(comment, startsWith('left '));
      expect(comment, endsWith(' right'));
      expect(comment.contains('!#'), isFalse);
      expect(
        comment.length,
        'left  right'.length + base64.encode(password).length,
      );
    });

    test('malformed_basic_token_echo_keeps_its_lexical_failure', () {
      final password = _bytes('fixture-secret');
      final token = base64.encode(_bytes('u:fixture-secret'));
      final input = _bytes('{"comment":"left Basic $token right');
      final result = PasswordRedactor(
        password,
        basicToken: token,
      ).sanitize(input);
      final text = utf8.decode(result.bytes);
      expect(result.invalidJson, isTrue);
      expect(result.redacted, isTrue);
      expect(text.contains(token), isFalse);
      expect(text, startsWith('{"comment":"left Basic '));
      expect(text, endsWith(' right'));
    });

    test('original_lexical_failure_survives_tab_redaction', () {
      const input = '{"comment":"before\tafter","keep":7}';
      final result = PasswordRedactor(_bytes('\t')).sanitize(_bytes(input));

      expect(result.invalidJson, isTrue);
      expect(result.redacted, isTrue);
      expect(result.bytes, isNot(contains(9)));
      final object = _object(result.bytes);
      final comment = object['comment']! as String;
      expect(comment, startsWith('before'));
      expect(comment, endsWith('after'));
      expect(object['keep'], 7);
    });

    test('invalid_utf8_redacts_literal_and_recoverable_escaped_echoes', () {
      final input = Uint8List.fromList([
        ..._bytes(r'{"comment":"left-s\u0065cret-right","other":"secret"}'),
        0xff,
      ]);
      final result = PasswordRedactor(_bytes('secret')).sanitize(input);

      expect(result.invalidJson, isTrue);
      expect(result.redacted, isTrue);
      expect(result.bytes.last, 0xff);
      final text = utf8.decode(result.bytes, allowMalformed: true);
      expect(text, isNot(contains('secret')));
      expect(text, isNot(contains(r's\u0065cret')));
      expect(text, contains('left-'));
      expect(text, contains('-right'));
      final jsonBytes = result.bytes.sublist(0, result.bytes.length - 1);
      final object = _object(jsonBytes);
      expect(object['comment'], isNot(contains('secret')));
      expect(object['other'], isNot(contains('secret')));
    });

    test(
      'unicode_escape_matches_scalars_without_rewriting_an_isolated_surrogate',
      () {
        final redactor = PasswordRedactor(_bytes('🛰'));
        final paired = redactor.sanitize(_bytes(r'{"echo":"\ud83d\udef0"}'));
        expect(paired.invalidJson, isFalse);
        expect(paired.redacted, isTrue);
        expect(_object(paired.bytes)['echo'], isNot(contains('🛰')));
        final isolated = _bytes(r'{"keep":"\ud800"}');
        final untouched = PasswordRedactor(_bytes('�')).sanitize(isolated);
        expect(untouched.bytes, orderedEquals(isolated));
        expect(untouched.redacted, isFalse);
      },
    );

    test('invalid_utf8_sequences_preserve_the_original_verdict', () {
      final redactor = PasswordRedactor(_bytes('not the fixture'));
      for (final bytes in [
        [0xc0, 0xaf],
        [0xe0, 0x80, 0x80],
        [0xed, 0xa0, 0x80],
        [0xf0, 0x80, 0x80, 0x80],
        [0xf4, 0x90, 0x80, 0x80],
        [0xc2, 0x41],
      ]) {
        final line = Uint8List.fromList([34, ...bytes, 34]);
        final result = redactor.sanitize(line);
        expect(result.invalidJson, isTrue, reason: '$bytes');
        expect(result.bytes, orderedEquals(line));
      }
    });

    test('duplicate_members_are_valid_json_syntax', () {
      const input = '{"outer":{"state":1,"state":2},"keep":"safe"}';
      final result = PasswordRedactor(_bytes('secret')).sanitize(_bytes(input));

      expect(result.invalidJson, isFalse);
      expect(result.redacted, isFalse);
      expect(result.bytes, orderedEquals(_bytes(input)));
    });
  });
}
