/// The check of each captured Icinga 2 scenario, by scenario name.
///
/// The version matrix test runs each as a test of that name, and
/// [evaluatePair] runs all of them, so the release publisher qualifies a pair
/// only when every check the matrix test makes passes.
library;

import 'dart:convert';

import 'package:correlia_server/event.dart';
import 'package:correlia_server/src/event_generated/correlia/event/v1/event_bounds.dart';

import 'icinga2_delivery.dart';
import 'icinga2_matrix.dart';

/// Every scenario check, by the name of the scenario it reads.
final Map<String, Check> scenarioChecks = {
  'two_problems_within_one_second': gateService,
  'host_command_keeps_sub_second_precision': gateHost,
  'two_comments_from_one_author': (c) {
    final out = gateNotificationTime(c);
    final authors = {
      for (final d in c.admitted('two_comments_from_one_author'))
        d.body['notification_author'],
    };
    if (authors.length != 1) out.add('the two comments differ in author');
    return out;
  },
  'production_notification_clock_keeps_microseconds': gateClock,
  'microsecond_values_survive_the_command': (c) {
    final out = <String>[];
    for (final k in c.of(
      'production_notification_clock_keeps_microseconds',
      'known',
    )) {
      if (k.json['field'] == 'last_state_change') {
        final micros = int.parse((k.json['value']! as String).split('.')[1]);
        if (micros % 10 == 0) out.add('known value has no fine digit');
      }
    }
    return [...out, ...gateClock(c)];
  },
  'captured_downtime_removal': gateDowntime,
  'same_named_custom_variables_are_ignored': (c) {
    final out = <String>[];
    final ds = c.admitted('same_named_custom_variables_are_ignored');
    final results = c.of('same_named_custom_variables_are_ignored', 'result');
    if (ds.length != 3 || results.length != 3) {
      return ['expected three results and three deliveries'];
    }
    for (var i = 0; i < 3; i++) {
      if (ds[i].body['last_state_change'] != results[i].json['execution_end']) {
        out.add('delivery ${i + 1} does not carry the real state change');
      }
      if (ds[i].body['last_state_change'] == '1234567890.000001') {
        out.add('the custom variable reached the delivery');
      }
    }
    if ({for (final d in ds) d.eventId}.length != 3) {
      out.add('the three observations share event ids');
    }
    return out;
  },
  'captured_host_transitions': (c) {
    final out = <String>[];
    final ds = c.admitted('captured_host_transitions');
    if (ds.length != 2) {
      return ['expected exactly a DOWN and an UP delivery, got ${ds.length}'];
    }
    if ({for (final d in ds) d.data()['fingerprint']}.length != 1) {
      out.add('the host observations have different fingerprints');
    }
    final fingerprint = ds.first.data()['fingerprint']! as String;
    if (fingerprint != fingerprintOfHost('host-tr')) {
      out.add('the fingerprint is not the host-only fingerprint');
    }
    if (ds[0].data()['status'] != 'EVENT_STATUS_FIRING' ||
        ds[0].data()['severity'] != 'EVENT_SEVERITY_CRITICAL') {
      out.add('the DOWN is not firing critical');
    }
    if (ds[1].data()['status'] != 'EVENT_STATUS_RESOLVED') {
      out.add('the UP is not resolved');
    }
    for (final d in ds) {
      if (d.events.single['source_time'] !=
          isoOf(d.body['last_state_change']! as String)) {
        out.add('${d.notificationType} source time is not its state change');
      }
    }
    final states = c.of('captured_host_transitions', 'state');
    final last = states.isEmpty
        ? null
        : states.last.json['alert'] as Map<String, Object?>?;
    if (last?['status'] != 'resolved' ||
        last?['fence_event_id'] != ds[1].eventId) {
      out.add(
        'the final state is ${last?['status']} at '
        '${last?['fence_event_id']}, not resolved at the UP '
        '${ds[1].eventId}',
      );
    }
    return out;
  },
  'captured_transition_sequence': transitionSequence,
  'first_check_result_of_a_new_host_is_down': firstProblemHosts,
  'volatile_host_with_no_state_change_yet': firstProblemVolatile,
  'retained_state_across_a_restart': (c) {
    final first = c
        .admitted('first_check_result_of_a_new_host_is_down')
        .firstWhere((d) => d.body['host'] == 'fp-startup');
    final reminders = c.admitted('retained_state_across_a_restart');
    if (reminders.isEmpty) return ['no reminder after the restart'];
    final out = <String>[];
    for (final r in reminders) {
      if (r.body['last_state_change'] != first.body['last_state_change']) {
        out.add('the reminder carries a different state change time');
      }
      if (r.outcome['duplicate_observation'] != 1) {
        out.add('the reminder committed no duplicate_observation outcome');
      }
    }
    return out;
  },
  'earlier_result_with_a_negative_execution_end': (c) {
    const file = 'earlier_result_with_a_negative_execution_end';
    final soft = c
        .of(file, 'result')
        .firstWhere((r) => r.json['label'] == 'soft_down');
    final d = c.admitted(file).single;
    return d.body['last_state_change'] == soft.json['execution_end']
        ? <String>[]
        : [
            'delivered ${d.body['last_state_change']}, the SOFT DOWN '
                'ended ${soft.json['execution_end']}',
          ];
  },
  'initialized_state_change_time_of_a_runtime_created_host': (c) {
    const file = 'initialized_state_change_time_of_a_runtime_created_host';
    final console = c.of(file, 'console').single;
    final now = (console.json['input']! as Map<String, Object?>)['now']! as int;
    final result = console.json['result'];
    if (result is! num || result.toInt() != now - 1) {
      return ['the helper yielded $result, not one second before now'];
    }
    final event = decodeOne(
      delivery(
        set: {'last_state_change': '${result.toInt()}.000000'},
      ),
    );
    return event.status.name == 'firing'
        ? <String>[]
        : ['a delivery built from the helper does not fire'];
  },
  'time_outside_the_formatter_s_domain': (c) {
    final results = [
      for (final r in c.of('time_outside_the_formatter_s_domain', 'console'))
        r.json['result'],
    ];
    return results.length == 3 &&
            results[0] == '' &&
            results[1] == '' &&
            results[2] == '4294967295.999999'
        ? <String>[]
        : ['formatter results were $results'];
  },
  'notification_from_a_real_icinga_2_in_both_auth_modes': gateDelivery,
  'long_check_output': (c) {
    final d = c.admitted('long_check_output').first;
    final out = <String>[];
    if (!(d.body['output']! as String).endsWith(truncationMarker)) {
      out.add('delivered output lacks the marker');
    }
    // The stored description is the delivered text cut again at the
    // event's display bound, which is shorter, ending with Correlia's display
    // marker (an ellipsis).
    const bound = 4096;
    if (CanonicalEventBounds.CanonicalEventDescriptionLength.max != bound) {
      out.add('the display bound is not $bound scalars');
    }
    final stored = d.data()['description'] as String?;
    final expected = normalizeDisplayText(
      d.body['output']! as String,
      maxScalars: bound,
    );
    if (stored != expected ||
        stored!.runes.length != bound ||
        !stored.endsWith('\u2026')) {
      out.add(
        'stored description is ${stored?.runes.length} scalars, not the '
        'delivered output cut at $bound with the display marker',
      );
    }
    return out;
  },
  'recovery_output_with_dollar_signs': (c) {
    final d = c
        .admitted('recovery_output_with_dollar_signs')
        .firstWhere((x) => x.notificationType == 'RECOVERY');
    final text = d.body['output']! as String;
    return [
      if (!text.startsWith('OK: cost below \$5, see \$host.name\$')) 'cut text',
      if (!text.endsWith(truncationMarker)) 'no marker',
      if (d.data()['status'] != 'EVENT_STATUS_RESOLVED') 'not resolved',
      ...recoveryApplied(c, 'recovery_output_with_dollar_signs', d),
    ];
  },
  'multibyte_character_across_the_cut': (c) {
    final d = c
        .admitted('multibyte_character_across_the_cut')
        .firstWhere((x) => x.notificationType == 'RECOVERY');
    final text = d.body['output']! as String;
    final body = text.substring(0, text.length - truncationMarker.length);
    return [
      if (!text.startsWith('\$\$\$')) 'dollar signs lost',
      if (!text.endsWith(truncationMarker)) 'no marker',
      if ('�'.allMatches(text).length > 1) 'more than one U+FFFD',
      if (body.contains('�') && !body.endsWith('�')) 'U+FFFD inside',
      if (d.data()['status'] != 'EVENT_STATUS_RESOLVED') 'not resolved',
      ...recoveryApplied(c, 'multibyte_character_across_the_cut', d),
    ];
  },
  'invalid_utf_8_in_check_output': (c) {
    final d = c.admitted('invalid_utf_8_in_check_output').single;
    final text = d.body['output']! as String;
    return [
      if (!text.contains('�')) 'no U+FFFD',
      if (!text.contains('still text') || !text.startsWith('bad '))
        'surrounding text changed',
      if (d.status != 202) 'not accepted',
    ];
  },
  'oversized_custom_notification': (c) {
    final ds = c.admitted('oversized_custom_notification');
    final custom = ds.singleWhere((d) => d.notificationType == 'CUSTOM');
    final states = c.of('oversized_custom_notification', 'state');
    return [
      if (custom.data()['kind'] != 'EVENT_KIND_COMMENT') 'not a comment event',
      if (!(custom.body['notification_comment']! as String).endsWith(
        truncationMarker,
      ))
        'comment not cut and marked',
      if (!(custom.body['notification_author']! as String).endsWith(
        truncationMarker,
      ))
        'author not cut and marked',
      if (jsonEncode(states.first.json['alert']) !=
          jsonEncode(states.last.json['alert']))
        'the alert changed',
    ];
  },
  'burst_of_verbose_notifications': (c) {
    const file = 'burst_of_verbose_notifications';
    final bodies = [for (final r in c.of(file, 'recorder_only')) r.body];
    final out = <String>[];
    if (bodies.length != 50) out.add('${bodies.length} bodies, not 50');
    if ({for (final b in bodies) b['service']}.length != 50) {
      out.add('not 50 services');
    }
    // Each of the two inputs keeps exactly its first 8192 bytes, then the
    // marker; dollar signs come through unchanged.
    final dollar = '${'\$' * 8192}$truncationMarker';
    final verbose = 'CRITICAL: ${'v' * (8192 - 10)}$truncationMarker';
    var dollars = 0;
    var verboses = 0;
    for (final b in bodies) {
      final text = b['output']! as String;
      if (text == dollar) {
        dollars++;
      } else if (text == verbose) {
        verboses++;
      } else {
        out.add(
          'an output is not an exact 8192-byte prefix and the marker '
          '(${utf8.encode(text).length} bytes)',
        );
      }
    }
    if (dollars != 25) out.add('$dollars dollar outputs, not 25');
    if (verboses != 25) out.add('$verboses verbose outputs, not 25');
    final seconds =
        c
                .of(file, 'info')
                .firstWhere(
                  (i) =>
                      i.json['name'] == 'seconds_from_last_result_to_last_body',
                )
                .json['value']!
            as num;
    if (seconds > 60) out.add('the last body took $seconds s');
    return out;
  },
  'runtime_options_in_icinga_s_environment': (c) {
    const file = 'runtime_options_in_icinga_s_environment';
    final log = c
        .of(file, 'log')
        .expand((r) => r.json['lines']! as List<Object?>);
    final text = log.join('\n');
    return [
      if (c.admitted(file).isEmpty) 'no 202 delivery',
      if (!text.contains('terminated with exit code 0')) 'no exit 0',
      if (RegExp(r'exit code [1-9]').hasMatch(text)) 'a non-zero exit',
    ];
  },
  'inherited_correlia_settings_are_ignored': (c) {
    const file = 'inherited_correlia_settings_are_ignored';
    final ds = c.admitted(file);
    final infos = {
      for (final r in c.of(file, 'info')) r.json['name']: r.json['value'],
    };
    final cases = [for (final r in c.of(file, 'case')) r.json['label']];
    return [
      // The inherited URL, CA and key settings change nothing: one
      // delivery over loopback HTTP, then one accepted over HTTPS with no
      // --ca-file, trusting the distribution's bundle although Icinga 2's
      // environment names another CA file.
      if (ds.length != 2)
        'expected two deliveries to the configured endpoint, got ${ds.length}',
      for (final d in ds)
        if (d.auth != 'bearer' || d.status != 202)
          '${d.id} was ${d.auth} ${d.status}',
      if (ds.length == 2 && ds[1].body['service'] != 'env3')
        'the HTTPS delivery is ${ds[1].body['service']}, not env3',
      if (jsonEncode(cases) != jsonEncode(['distribution_trust_over_https']))
        'cases were $cases',
      if (infos['tls_forwarder_connections'] case final int n when n >= 1)
        ...[]
      else
        'no TLS connection: ${infos['tls_forwarder_connections']}',
      if (c.of(file, 'command_failure').isNotEmpty) 'a command failed',
    ];
  },
  'name_with_an_embedded_nul_is_not_delivered': (c) {
    const file = 'name_with_an_embedded_nul_is_not_delivered';
    final failures = c.of(file, 'command_failure');
    final states = c.of(file, 'state');
    return [
      if (failures.length != 2) 'expected two failed commands',
      for (final f in failures)
        if (f.json['exit_code'] != 2 ||
            !(f.json['detail']! as String).contains('invalid_name'))
          'a command did not exit 2 with invalid_name',
      if (c.admitted(file).length != 1) 'a request was made for the NUL name',
      if (states.isEmpty || alertOf(states.last)?['status'] != 'firing')
        'the db1 alert is not firing',
    ];
  },
  'oversized_or_invalid_name_is_not_delivered': (c) {
    const file = 'oversized_or_invalid_name_is_not_delivered';
    final failures = c.of(file, 'command_failure');
    return [
      if (failures.length != 2) 'expected two failed commands',
      for (final f in failures)
        if (f.json['exit_code'] != 2 ||
            !(f.json['detail']! as String).contains('invalid_name'))
          'a command did not exit 2 with invalid_name',
      if (c.requests(file).isNotEmpty) 'a request reached Correlia',
    ];
  },
  'setting_not_deliverable_exactly': (c) {
    const file = 'setting_not_deliverable_exactly';
    final failures = c.of(file, 'command_failure');
    final out = <String>[];
    // The sender refuses the long base URL, the invalid and the relative
    // token paths, and a token or key pasted as its file path (which the
    // definitions turn into ""). A relative sender path runs nothing (env
    // exits 127), not the sender on env's search path; nor does one holding
    // "=", which the definitions turn into "".
    const refused = [
      '--base-url',
      '--token-file',
      '--token-file',
      '--token-file',
      '--hmac-key-file',
    ];
    final cases = [for (final r in c.of(file, 'case')) r.json['label']];
    if (jsonEncode(cases) !=
        jsonEncode([
          'long_base_url',
          'invalid_utf8_token_path',
          'relative_token_path',
          'token_as_token_path',
          'key_as_key_path',
          'relative_sender_path',
          'equals_in_sender_path',
        ])) {
      out.add('cases were $cases');
    }
    final consoles = c.of(file, 'console');
    if (consoles.length != 1 || consoles.single.json['result'] != '') {
      out.add(
        'a sender path holding "=" was passed: '
        '${[for (final r in consoles) r.json['result']]}',
      );
    }
    if (failures.length != refused.length + 2) {
      out.add(
        'expected ${refused.length + 2} failed commands, '
        'found ${failures.length}',
      );
    } else {
      for (var i = 0; i < refused.length; i++) {
        final detail = failures[i].json['detail']! as String;
        if (failures[i].json['exit_code'] != 2 ||
            !detail.contains(refused[i])) {
          out.add(
            'refusal ${i + 1} was ${failures[i].json['exit_code']} '
            '$detail',
          );
        }
      }
      for (final (i, what) in [
        (refused.length, 'the relative sender path'),
        (refused.length + 1, 'the sender path holding "="'),
      ]) {
        if (failures[i].json['exit_code'] != 127) {
          out.add(
            '$what ran something: exit ${failures[i].json['exit_code']}',
          );
        }
      }
    }
    final scans = c.of(file, 'secret_scan');
    if (scans.isEmpty) out.add('no secret scan recorded');
    for (final scan in scans) {
      if ((scan.json['found']! as List<Object?>).isNotEmpty) {
        out.add('a credential reached the log: ${scan.json['found']}');
      }
    }
    if (c.requests(file).isNotEmpty) out.add('a request was made');
    return out;
  },
  'nul_in_a_file_path': (c) {
    const file = 'nul_in_a_file_path';
    final failures = c.of(file, 'command_failure');
    final cases = [for (final r in c.of(file, 'case')) r.json['label']];
    return [
      if (jsonEncode(cases) !=
          jsonEncode(['nul_in_ca_path', 'nul_in_sender_path']))
        'cases were $cases',
      if (failures.length != 2)
        'expected 2 failed commands, found ${failures.length}'
      else ...[
        if (failures[0].json['exit_code'] != 2 ||
            !(failures[0].json['detail']! as String).contains('--ca-file'))
          'the CA path was not refused naming --ca-file',
        // No file is called "": env fails before any sender runs, the one
        // at the path's prefix included.
        if (failures[1].json['exit_code'] != 127)
          'the sender path with a NUL ran something: exit '
              '${failures[1].json['exit_code']}',
      ],
      if (c.requests(file).isNotEmpty) 'a request was made',
    ];
  },
  'base_url_carrying_a_credential': (c) => refusals(
    c,
    'base_url_carrying_a_credential',
    [
      '--base-url',
      '--base-url',
      '--base-url',
    ],
    scanned: ['secret'],
  ),
  'multiline_settings': (c) => refusals(
    c,
    'multiline_settings',
    [
      '--base-url',
      '--source',
    ],
    scanned: ['SECRET-MARKER'],
  ),
  'source_that_is_not_a_uuid': (c) => refusals(
    c,
    'source_that_is_not_a_uuid',
    ['--source'],
    scanned: ['token'],
  ),
  'macro_text_in_a_setting_is_literal': (c) {
    const file = 'macro_text_in_a_setting_is_literal';
    final failures = c.of(file, 'command_failure');
    final ds = c.admitted(file);
    return [
      if (failures.length != 1 ||
          failures.single.json['exit_code'] != 2 ||
          !(failures.single.json['detail']! as String).contains('--base-url'))
        'the macro base URL was not refused naming --base-url',
      // The token path, then the sender path, with a dollar sign: both
      // reach Correlia exactly as configured.
      if (ds.length != 2 || ds.any((d) => d.status != 202))
        'the dollar sign paths were not both accepted: '
            '${[for (final d in ds) d.status]}',
      if (ds.length == 2 && ds.last.body['output'] != 'CRITICAL: dollar sender')
        'the dollar sender path delivered ${ds.last.body['output']}',
    ];
  },
  'nul_in_display_text': (c) {
    final d = c.admitted('nul_in_display_text').single;
    return [
      if (d.body['notification_comment'] != 'before�after')
        'comment ${d.body['notification_comment']}',
      if (d.body['notification_author'] != 'ali�ce')
        'author ${d.body['notification_author']}',
      if (d.status != 202) 'not accepted',
    ];
  },
  'rejected_delivery_leaves_no_secret_in_icinga_2_logs': rejectedDelivery,
  // The deterministic overlap is proved by the e2e test of the same name;
  // this capture shows the shipped command under a real Icinga 2: three
  // signed notifications overlap, Correlia refuses one with 503 and admits
  // two, and Icinga 2 logs the refused command with its status.
  'concurrent_signed_notifications_beyond_the_cap': (c) {
    const file = 'concurrent_signed_notifications_beyond_the_cap';
    final infos = {
      for (final r in c.of(file, 'info')) r.json['name']: r.json['value'],
    };
    final failures = c.of(file, 'command_failure');
    return [
      if (infos['correlia_refusals'] != 1)
        'Correlia logged ${infos['correlia_refusals']} refusals, not one',
      if (infos['raw_rows_added'] != 2)
        '${infos['raw_rows_added']} requests admitted, not two',
      if (failures.length != 1)
        '${failures.length} failed commands recorded, not one'
      else ...[
        if (failures.single.json['exit_code'] != 1)
          'the refused command exited ${failures.single.json['exit_code']}',
        if (!'${failures.single.json['detail']}'.contains('status 503'))
          'Icinga 2 logged ${failures.single.json['detail']}, not the 503',
      ],
    ];
  },
  'hostile_inherited_environment': (c) {
    const file = 'hostile_inherited_environment';
    Object? info(String name) => c
        .of(file, 'info')
        .firstWhere((i) => i.json['name'] == name)
        .json['value'];
    final failures = c.of(file, 'command_failure');
    return [
      if (c.admitted(file).length != 1) 'the loopback delivery did not arrive',
      if (info('recording_listener_connections') != 0)
        'the recording listener received a connection',
      if (info('https_endpoint_requests') != 0)
        'the https endpoint received request bytes',
      if (failures.length != 1 || failures.single.json['exit_code'] == 0)
        'the https endpoint was not refused',
      if (info('key_log_file_exists') != false) 'a key log file exists',
    ];
  },
  'non_state_notification_for_an_object_with_an_unusable_state_change_time': (c) {
    const file =
        'non_state_notification_for_an_object_with_an_unusable_state_change_time';
    final d = c.admitted(file).single;
    final states = c.of(file, 'state');
    return [
      if (d.notificationType != 'ACKNOWLEDGEMENT') 'not an acknowledgement',
      if (d.body.containsKey('last_state_change'))
        'the delivery carries last_state_change',
      if (d.status != 202) 'not accepted',
      if (d.events.length != 1 || d.data()['kind'] != 'EVENT_KIND_ACK')
        'no single ack event',
      if (states.isEmpty || alertOf(states.last) != null) 'an alert exists',
    ];
  },
  'multiline_recovery_and_custom_notification_without_output': (c) {
    const file = 'multiline_recovery_and_custom_notification_without_output';
    final recovery = c
        .admitted(file)
        .singleWhere((d) => d.notificationType == 'RECOVERY');
    final description = recovery.data()['description']! as String;
    final states = c.of(file, 'state');
    return [
      if (recovery.status != 202) 'recovery not accepted',
      for (final line in ['first', 'second line', 'third line'])
        if (!description.contains(line)) 'description lacks "$line"',
      if (alertOf(states[1])?['status'] != 'resolved') 'not resolved',
      ...firstProblemCustom(c),
    ];
  },
  'delayed_recovery_publishes_the_live_check_output': (c) {
    const file = 'delayed_recovery_publishes_the_live_check_output';
    final ds = c.admitted(file);
    final recovery = ds.singleWhere((d) => d.notificationType == 'RECOVERY');
    final refire = ds.lastWhere((d) => d.notificationType == 'PROBLEM');
    final published = [
      for (final d in [recovery, refire])
        if (d.events.isNotEmpty) d,
    ];
    final deduplicated = [
      for (final d in [recovery, refire])
        if (d.events.isEmpty && d.outcome['duplicate_observation'] == 1) d,
    ];
    return [
      if (recovery.body['output'] != 'CRITICAL: disk full')
        'the recovery delivered ${recovery.body['output']}',
      if (published.length != 1 || deduplicated.length != 1)
        'the refire and the recovery are not one event and one duplicate',
      for (final d in published)
        if (d.data()['status'] != 'EVENT_STATUS_FIRING' ||
            d.data()['description'] != 'CRITICAL: disk full')
          'the published event is ${d.data()['status']} '
              '${d.data()['description']}',
      if (jsonEncode([for (final d in ds) ...d.events]).contains(
        'disk recovered',
      ))
        'an event carries the OK text',
    ];
  },
};

/// The transition sequence scenario: every named notification type stored
/// one event of its kind, with the source time the evidence names, and the
/// alert ends resolved.
List<String> transitionSequence(Capture c) {
  const kinds = {
    'PROBLEM': 'EVENT_KIND_ALERT',
    'ACKNOWLEDGEMENT': 'EVENT_KIND_ACK',
    'FLAPPINGSTART': 'EVENT_KIND_STATE',
    'FLAPPINGEND': 'EVENT_KIND_STATE',
    'DOWNTIMESTART': 'EVENT_KIND_DOWNTIME',
    'DOWNTIMEEND': 'EVENT_KIND_DOWNTIME',
    'RECOVERY': 'EVENT_KIND_ALERT',
  };
  final out = <String>[];
  final ds = c.admitted('captured_transition_sequence');
  for (final MapEntry(key: type, value: kind) in kinds.entries) {
    final stored = ds.where(
      (d) =>
          d.notificationType == type &&
          d.outcome['committed'] == 1 &&
          d.events.length == 1 &&
          d.data()['kind'] == kind,
    );
    if (stored.isEmpty) out.add('no stored $type observation');
  }
  for (final d in ds.where((d) => d.events.isNotEmpty)) {
    final type = d.notificationType;
    if (type == 'PROBLEM' || type == 'RECOVERY') {
      if (d.events.single['source_time'] !=
          isoOf(d.body['last_state_change']! as String)) {
        out.add('$type source time is not its state change');
      }
    } else if (d.data()['status'] != 'EVENT_STATUS_INFO') {
      out.add('$type is not an informational event');
    }
  }
  final states = c.of('captured_transition_sequence', 'state');
  final alert = states.isEmpty ? null : alertOf(states.last);
  if (alert == null || alert['status'] != 'resolved') {
    out.add('the alert does not end resolved');
  }
  return out;
}

/// The rejected delivery scenario: both wrong credentials are refused with
/// 401, Icinga 2 logs each failure with its status, a text and the file
/// path, and the log scan finds neither the marker Correlia put in its
/// rejection body nor any of the credentials.
List<String> rejectedDelivery(Capture c) {
  const file = 'rejected_delivery_leaves_no_secret_in_icinga_2_logs';
  final rejected = c.of(file, 'rejected');
  final failures = c.of(file, 'command_failure');
  final scans = c.of(file, 'secret_scan');
  final logs = [
    for (final f in failures)
      if (f.json['log'] case final String log) log,
  ];
  return [
    if (rejected.length != 2 || rejected.any((r) => r.status != 401))
      'expected two 401 rejections',
    if (failures.length != 2) 'expected two failures',
    if (logs.length != failures.length)
      'a failure without its Icinga 2 log line',
    // Icinga 2's line holds the status, the texts and the file paths.
    for (final log in logs)
      if (!log.contains('status 401') || !log.contains('"probe"'))
        'the failure log lacks the status or a text',
    for (final path in ['wrong-token', 'wrong-hmac-key'])
      if (logs.where((l) => l.contains('/etc/icinga2/correlia/$path')).length !=
          1)
        'no single failure log names the $path file',
    if (scans.length != 1) 'no secret scan',
    for (final s in scans) ...[
      if ((s.json['found']! as List<Object?>).isNotEmpty)
        'secrets in the log: ${s.json['found']}',
      // The rejection body's marker, the rejected senders' credentials, and
      // each rejected header both whole and as its bare token or digest.
      for (final name in [
        'marker',
        'token',
        'hmac_key',
        'wrong_token',
        'wrong_hmac_key',
        'credential_header_0',
        'credential_value_0',
        'credential_header_1',
        'credential_value_1',
      ])
        if (!(s.json['checked']! as List<Object?>).contains(name))
          'the scan did not check $name',
    ],
  ];
}

List<String> refusals(
  Capture c,
  String file,
  List<String> arguments, {
  List<String> scanned = const [],
}) {
  final failures = c.of(file, 'command_failure');
  final out = <String>[];
  if (failures.length != arguments.length) {
    out.add(
      'expected ${arguments.length} refusals, found ${failures.length}',
    );
  }
  for (var i = 0; i < failures.length && i < arguments.length; i++) {
    final detail = failures[i].json['detail']! as String;
    if (failures[i].json['exit_code'] != 2 || !detail.contains(arguments[i])) {
      out.add(
        'refusal ${i + 1} was ${failures[i].json['exit_code']} $detail',
      );
    }
  }
  if (c.requests(file).isNotEmpty) out.add('a request was made');
  // A scenario that keeps a credential out of argv and the log proves it
  // with one scan that names each of [scanned] and found none of them.
  if (scanned.isNotEmpty) {
    final scans = c.of(file, 'secret_scan');
    if (scans.length != 1) {
      out.add('expected one secret scan, found ${scans.length}');
    }
    for (final s in scans) {
      final checked = s.json['checked']! as List<Object?>;
      for (final name in scanned) {
        if (!checked.contains(name)) out.add('the scan did not check $name');
      }
      if ((s.json['found']! as List<Object?>).isNotEmpty) {
        out.add('a secret reached the log: ${s.json['found']}');
      }
    }
  }
  return out;
}

/// The alert snapshot of a recorded `state` item, if one exists.
Map<String, Object?>? alertOf(Rec state) =>
    state.json['alert'] as Map<String, Object?>?;

/// The fingerprint of a host-only object of the capture's source.
String fingerprintOfHost(String host) => decodeOne(
  hostDelivery(set: {'host': host}),
  sourceInstance: matrixSource,
).fingerprint;
