import 'dart:typed_data';

import 'package:correlia_server/event.dart';
import 'package:correlia_server/src/pipeline/pipeline.dart'
    show safeFailurePath;
import 'package:test/test.dart';

import '../../support/icinga2_delivery.dart';

/// Runs [document] through the decoder and returns the validation error.
EventFieldError rejected(Object? document) {
  try {
    decodeDelivery(document);
  } on EventFieldError catch (error) {
    return error;
  }
  fail('the delivery decoded');
}

void main() {
  test('unknown_field_name_is_not_reflected', () {
    final error = rejected(delivery(set: {'secret_token_abc': 'x'}));
    expect(error.code, 'unknown_field');
    expect(error.path, '*');
    expect(safeFailurePath(error.path), '*');
    expect(error.toString(), isNot(contains('secret_token_abc')));
  });

  test('dotted_unknown_field_name', () {
    final error = rejected(delivery(set: {'state.state_type': 'x'}));
    expect(error.code, 'unknown_field');
    expect(error.path, '*');
    final persisted = safeFailurePath(error.path);
    expect(persisted, '*');
    expect(persisted, isNot(contains('state')));
  });

  test('unsupported_format_version', () {
    final error = rejected(delivery(set: {'format': 'correlia.icinga2.v2'}));
    expect(error.code, 'unsupported_version');
    expect(error.path, 'format');
  });

  test('state_notification_without_a_state_change_time', () {
    for (final type in ['PROBLEM', 'RECOVERY']) {
      final error = rejected(
        delivery(set: {'notification_type': type, 'last_state_change': null}),
      );
      expect(
        (error.code, error.path),
        (
          'missing_field',
          'last_state_change',
        ),
        reason: type,
      );
    }
  });

  test('invalid_state_change_time_on_a_non_state_delivery', () {
    final error = rejected(
      delivery(
        set: {'notification_type': 'CUSTOM', 'last_state_change': '0.000000'},
      ),
    );
    expect((error.code, error.path), ('invalid_time', 'last_state_change'));
  });

  test('time_not_in_the_fixed_form', () {
    for (final text in [
      '1.5',
      '1e9',
      '0.000000',
      '01.000000',
      '+1.000000',
      '1763571234.123456\n',
    ]) {
      final error = rejected(delivery(set: {'notification_time': text}));
      expect((error.code, error.path), ('invalid_time', 'notification_time'));
    }
    final number = rejected(
      delivery(set: {'notification_time': 1763571234.123456}),
    );
    expect((number.code, number.path), ('invalid_type', 'notification_time'));
  });

  test('exact_microseconds_at_the_top_of_the_range', () {
    final first = decodeOne(
      delivery(set: {'last_state_change': '8589934592.000001'}),
    );
    final second = decodeOne(
      delivery(set: {'last_state_change': '8589934592.000002'}),
    );
    expect(first.eventId, isNot(second.eventId));
    final one = first.sourceTime!, two = second.sourceTime!;
    expect(one.seconds, two.seconds);
    expect((one.nanos, two.nanos), (1000, 2000));
    final top = decodeOne(
      delivery(set: {'last_state_change': '253402300799.999999'}),
    );
    expect(top.sourceTime!.seconds, 253402300799);
    expect(top.sourceTime!.nanos, 999999000);
    expect(top.reportedSourceTime, '9999-12-31T23:59:59.999999Z');
  });

  test('zero_state_change_time', () {
    final error = rejected(delivery(set: {'last_state_change': '0.000000'}));
    expect((error.code, error.path), ('invalid_time', 'last_state_change'));
  });

  test('missing_notification_time', () {
    final error = rejected(delivery(set: {'notification_time': null}));
    expect((error.code, error.path), ('missing_field', 'notification_time'));
  });

  test('unknown_state_name', () {
    final error = rejected(delivery(set: {'state': 'DEGRADED'}));
    expect((error.code, error.path), ('invalid_state', 'state'));
  });

  group('beyond the named scenarios', () {
    test('out_of_range_time', () {
      final error = rejected(
        delivery(set: {'last_state_change': '253402300800.000000'}),
      );
      expect((error.code, error.path), ('out_of_range', 'last_state_change'));
    });

    test('wrong_type_on_a_known_field', () {
      final error = rejected(delivery(set: {'state': 2}));
      expect((error.code, error.path), ('invalid_type', 'state'));
      expect(safeFailurePath(error.path), 'state');
    });

    test('nul_in_a_host_name', () {
      final error = rejected(delivery(set: {'host': 'db1\u0000x'}));
      expect((error.code, error.path), ('invalid_text', 'host'));
    });

    test('nul_in_the_output_and_a_control_character_in_a_name', () {
      final output = rejected(delivery(set: {'output': 'a\u0000b'}));
      expect((output.code, output.path), ('invalid_text', 'output'));
      final name = rejected(delivery(set: {'service': 'di\nsk'}));
      expect((name.code, name.path), ('invalid_text', 'service'));
    });

    test('deeply_nested_body', () {
      final error = rejected(body0(10000));
      expect((error.code, error.path), ('depth_bound', 'body'));
    });

    test('unsupported_type', () {
      final error = rejected(
        delivery(set: {'notification_type': 'ESCALATION'}),
      );
      expect(
        (error.code, error.path),
        ('unsupported_type', 'notification_type'),
      );
    });

    test('a_service_object_needs_its_service', () {
      final error = rejected(delivery(set: {'service': null}));
      expect((error.code, error.path), ('missing_field', 'service'));
    });

    test('failure_paths_render_the_icinga2_field_names', () {
      for (final name in [
        'format',
        'object_type',
        'host',
        'service',
        'state',
        'state_type',
        'last_state_change',
        'output',
        'notification_type',
        'notification_author',
        'notification_comment',
        'notification_time',
      ]) {
        expect(safeFailurePath(name), name);
      }
    });
  });
}

/// An array nested [depth] levels deep, as body bytes.
Uint8List body0(int depth) =>
    Uint8List.fromList('${'[' * depth}${']' * depth}'.codeUnits);
