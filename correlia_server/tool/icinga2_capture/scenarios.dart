import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../test/support/icinga2_matrix.dart'
    show downtimeExpires, downtimeRemoved;
import 'config.dart';
import 'evidence.dart';
import 'lab.dart';
import 'rig.dart';

const _token = '$containerCorrelia/token';
const _hmacKey = '$containerCorrelia/hmac-key';
const _wrongToken = '$containerCorrelia/wrong-token';
const _wrongKey = '$containerCorrelia/wrong-hmac-key';
const _dollarToken = '$containerCorrelia/tok\$en';

/// Which credential the sender settings name.
enum Credential { token, hmac, wrongToken, wrongKey, dollarToken, none }

/// The capture scenarios of one release. Each writes one evidence file.
final class Scenarios {
  Scenarios(this.c, {required this.release, required this.config, this.only});

  final Capture c;
  final String release;
  final CaptureConfig config;
  final Set<String>? only;

  IcingaLab get lab => c.lab;
  CorreliaRig get rig => c.rig;

  String get proxyUrl => 'http://127.0.0.1:${rig.proxyPort}';
  String get receiverUrl => 'http://127.0.0.1:${rig.receiverPort}';

  // --- Setup ------------------------------------------------------------

  /// Credential files: readable only by the Icinga 2 user, in a directory
  /// only root and that user can write.
  Future<void> installCredentials() async {
    Future<void> file(String path, String content) => lab.writeFile(
      path,
      utf8.encode(content),
      owner: 'icinga:icinga',
      mode: '600',
    );
    await file(_token, rig.token);
    await file(_hmacKey, rig.hmacKey);
    // Same shape, different value: Correlia refuses both with 401.
    await file(_wrongToken, 'W' * 43);
    final random = Random.secure();
    await file(
      _wrongKey,
      base64Url
          .encode(List<int>.generate(32, (_) => random.nextInt(256)))
          .replaceAll('=', ''),
    );
    await file(_dollarToken, rig.token);
  }

  /// Writes the operator's `correlia.conf`; the daemon reads it on start.
  Future<void> useSettings({
    String? baseUrl,
    String? source,
    Credential credential = Credential.token,
    String? caFile,
    String? tokenLiteral,
  }) async {
    final (token, key) = switch (credential) {
      Credential.token => (dslString(_token), '""'),
      Credential.hmac => ('""', dslString(_hmacKey)),
      Credential.wrongToken => (dslString(_wrongToken), '""'),
      Credential.wrongKey => ('""', dslString(_wrongKey)),
      Credential.dollarToken => (dslString(_dollarToken), '""'),
      Credential.none => ('""', '""'),
    };
    await lab.writeSettings(
      settingsText(
        c.shipped,
        baseUrl: baseUrl ?? dslString(proxyUrl),
        source: source ?? dslString(captureSource),
        tokenFile: tokenLiteral ?? token,
        hmacKeyFile: key,
        caFile: caFile,
      ),
    );
  }

  // --- Plumbing ---------------------------------------------------------

  bool _wants(String name) => only == null || only!.contains(name);

  /// Runs one scenario, always saving what it recorded, and notes a failure
  /// without stopping the capture.
  Future<void> scenario(
    String name,
    Future<void> Function(Evidence ev) body,
  ) async {
    if (!_wants(name)) return;
    final ev = c.begin(name);
    stdout.writeln('scenario $name');
    try {
      // Let what the previous scenario left in flight finish, and keep it
      // out of this scenario's evidence.
      await ev.markLog();
      await waitQuiet(ev);
      if (c.untakenProxied != 0) {
        stdout.writeln('  note: ${c.untakenProxied} stray request(s)');
      }
      c.drain();
      await ev.markLog();
      await body(ev);
    } on Object catch (error, stack) {
      stderr.writeln('scenario $name failed: $error\n$stack');
      ev.add({'kind': 'scenario_error', 'error': error.toString()});
      c.failed.add(name);
      try {
        await ev.logExcerpt(label: 'error');
      } on Object {
        // The excerpt is best effort.
      }
    }
    ev.save(release);
  }

  Future<Map<String, Object?>> _action(String path, Object body) =>
      lab.ok('POST', '/v1/actions/$path', body: body);

  Future<void> custom(
    String type,
    String id, {
    String author = 'operator',
    String comment = 'a note',
  }) async {
    final field = type == 'Host' ? 'host' : 'service';
    await _action('send-custom-notification', {
      'type': type,
      'filter': '$field.vars.cap_id == ${dslString(id)}',
      'author': author,
      'comment': comment,
    });
  }

  Future<void> setAttr(String host, Map<String, Object?> attrs) => lab.ok(
    'POST',
    '/v1/objects/hosts/${Uri.encodeComponent(host)}',
    body: {'attrs': attrs},
  );

  Map<String, Object?> _body(Map<String, Object?> record) =>
      jsonDecode(
            ((record['request']! as Map<String, Object?>)['body']! as String),
          )
          as Map<String, Object?>;

  /// Takes deliveries one at a time until one satisfies [match].
  Future<List<Map<String, Object?>>> until(
    Evidence ev,
    bool Function(Map<String, Object?> body) match, {
    int limit = 80,
  }) async {
    final taken = <Map<String, Object?>>[];
    for (var i = 0; i < limit; i++) {
      final record = (await ev.deliveries(1)).single;
      taken.add(record);
      final body = _body(record);
      if (match(body)) return taken;
    }
    throw StateError('no matching delivery in $limit requests');
  }

  /// Waits until Icinga 2 has no notification in flight and nothing new
  /// reaches the proxy.
  Future<void> waitQuiet(Evidence ev) async {
    var stable = 0;
    var last = -1;
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (stable < 12) {
      final log = await lab.logFrom(ev.logMark);
      final activity = RegExp(
        r"(Sending '|Completed sending)",
      ).allMatches(log).length;
      final seen = rig.proxied.length + activity;
      if (seen == last) {
        stable++;
      } else {
        stable = 0;
      }
      last = seen;
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('notifications did not settle');
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  /// [waitQuiet], then takes what arrived.
  Future<List<Map<String, Object?>>> settle(Evidence ev) async {
    await waitQuiet(ev);
    final n = c.untakenProxied;
    return n == 0 ? [] : ev.deliveries(n);
  }

  // --- Scenarios --------------------------------------------------------

  Future<void> all() async {
    await _core();
  }

  /// Submits a passive result, takes the one delivery it causes and records
  /// the committed state after it.
  Future<Map<String, Object?>> _step(
    Evidence ev, {
    required String objectType,
    required String id,
    required int exit,
    required String output,
    required String end,
    String host = 'lab',
  }) async {
    await ev.result(
      objectType: objectType,
      id: id,
      exit: exit,
      output: output,
      end: end,
    );
    final d = (await ev.deliveries(1)).single;
    if (objectType == 'host') {
      await ev.snapshot(d['id']! as String, host: id);
    } else {
      await ev.snapshot(d['id']! as String, host: host, service: id);
    }
    return d;
  }

  Future<void> _sameSecond(
    Evidence ev,
    String objectType,
    String id,
    List<(int, String)> steps,
  ) async {
    final s = c.nowSeconds();
    var micros = 210001;
    for (final (exit, output) in steps) {
      await _step(
        ev,
        objectType: objectType,
        id: id,
        exit: exit,
        output: output,
        end: timeText(s, micros),
      );
      micros += 270001;
    }
  }

  Future<void> _core() async {
    await scenario('two_problems_within_one_second', (ev) async {
      await _sameSecond(ev, 'service', 'ss', [
        (2, 'CRITICAL: one'),
        (0, 'OK: two'),
        (2, 'CRITICAL: three'),
      ]);
    });
    await scenario('same_named_custom_variables_are_ignored', (ev) async {
      await _sameSecond(ev, 'service', 'cv', [
        (2, 'CRITICAL: one'),
        (0, 'OK: two'),
        (2, 'CRITICAL: three'),
      ]);
    });
    await scenario('host_command_keeps_sub_second_precision', (ev) async {
      await _sameSecond(ev, 'host', 'host-ss', [
        (1, 'DOWN: one'),
        (0, 'UP: two'),
        (1, 'DOWN: three'),
      ]);
    });
    await scenario('captured_host_transitions', (ev) async {
      final s = c.nowSeconds();
      await _step(
        ev,
        objectType: 'host',
        id: 'host-tr',
        exit: 1,
        output: 'DOWN: first',
        end: timeText(s, 100001),
      );
      await _step(
        ev,
        objectType: 'host',
        id: 'host-tr',
        exit: 0,
        output: 'UP: back',
        end: timeText(s, 600002),
      );
      await _step(
        ev,
        objectType: 'host',
        id: 'host-tr',
        exit: 1,
        output: 'DOWN: again',
        end: timeText(s + 1, 100003),
      );
    });
    await scenario('two_comments_from_one_author', (ev) async {
      for (var attempt = 0; attempt < 12; attempt++) {
        final mark = ev.records.length;
        await custom('Service', 'two', author: 'alice', comment: 'first');
        await custom('Service', 'two', author: 'alice', comment: 'second');
        final both = await ev.deliveries(2);
        final seconds = {
          for (final d in both)
            (_body(d)['notification_time']! as String).split('.').first,
        };
        if (seconds.length == 1) {
          await ev.snapshot('both', host: 'lab', service: 'two');
          return;
        }
        ev.records.removeRange(mark, ev.records.length);
      }
      throw StateError('two notifications never shared one second');
    });
    await _clock();
    await _downtime();
    await _firstProblem();
    await _outputs();
    await _timeEdges();
    await _transitionSequence();
    await _delayedRecovery();
    await _names();
    await _retained();
    await _authAndEnvironment();
    await _burst();
    await _settingsFailures();
    await _hostileAndRejected();
    await _reconfigure();
  }

  Future<void> _clock() =>
      scenario('production_notification_clock_keeps_microseconds', (ev) async {
        final s = c.nowSeconds();
        for (var digit = 0; digit < 10; digit++) {
          final input = '$s.12345$digit';
          await ev.console('correlia_time_literal($input)', input: input);
        }
        await ev.console('range(20).map(i => correlia_time_text(get_time()))');
        final serviceEnd = timeText(s, 123457);
        await ev.result(
          objectType: 'service',
          id: 'ts',
          exit: 2,
          output: 'CRITICAL: known time',
          end: serviceEnd,
        );
        var d = (await ev.deliveries(1)).single;
        ev.add({
          'kind': 'known',
          'command': 'correlia-service',
          'field': 'last_state_change',
          'value': serviceEnd,
          'delivery': d['id'],
        });
        final hostEnd = timeText(s, 654321);
        await ev.result(
          objectType: 'host',
          id: 'host-ts',
          exit: 1,
          output: 'DOWN: known time',
          end: hostEnd,
        );
        d = (await ev.deliveries(1)).single;
        ev.add({
          'kind': 'known',
          'command': 'correlia-host',
          'field': 'last_state_change',
          'value': hostEnd,
          'delivery': d['id'],
        });
        await custom('Service', 'tsclk', comment: 'clock');
        d = (await ev.deliveries(1)).single;
        ev.add({
          'kind': 'known',
          'command': 'correlia-service',
          'field': 'notification_time',
          'value': config.serviceClock,
          'delivery': d['id'],
        });
        await custom('Host', 'host-tsclk', comment: 'clock');
        d = (await ev.deliveries(1)).single;
        ev.add({
          'kind': 'known',
          'command': 'correlia-host',
          'field': 'notification_time',
          'value': config.hostClock,
          'delivery': d['id'],
        });
      });

  Future<void> _downtime() => scenario('captured_downtime_removal', (ev) async {
    final s = c.nowSeconds();
    await _step(
      ev,
      objectType: 'service',
      id: 'dt',
      exit: 2,
      output: 'CRITICAL: before downtime',
      end: timeText(s, 100001),
    );
    Future<String> schedule(int seconds, String comment) async {
      final now = c.nowSeconds();
      final result = await _action('schedule-downtime', {
        'type': 'Service',
        'filter': 'service.vars.cap_id == "dt"',
        'start_time': now - 2,
        'end_time': now + seconds,
        'fixed': true,
        'author': 'operator',
        'comment': comment,
      });
      return jsonEncode(result);
    }

    // Takes deliveries until the removal of the downtime with [comment]
    // arrives. Icinga 2.13 ends an expired downtime on its expiry timer,
    // up to a minute after the end time; the take waits up to 90 s.
    Future<void> untilRemoval(String comment) async {
      while (true) {
        final d = (await ev.deliveries(1)).single;
        final request = d['request']! as Map<String, Object?>;
        final body = jsonDecode(request['body']! as String);
        if (body case {
          'notification_type': 'DOWNTIMEEND' || 'DOWNTIMECANCELLED',
          'notification_comment': final String c,
        } when c == comment) {
          return;
        }
      }
    }

    // Every event is routed to this output; the gate checks its intents.
    ev.info('output_id', captureOutput);
    // One downtime that expires; its removal comes from Icinga 2 alone.
    await schedule(4, downtimeExpires);
    await untilRemoval(downtimeExpires);
    await settle(ev);
    // One downtime removed by hand, after the expiry's removal arrived.
    await schedule(3600, downtimeRemoved);
    await settle(ev);
    final micros = DateTime.now().microsecondsSinceEpoch;
    ev.info('manual_removal_requested', micros / 1000000);
    await lab.ok(
      'POST',
      '/v1/actions/remove-downtime',
      body: {
        'type': 'Downtime',
        'filter':
            'downtime.service_name == "dt" && '
            'downtime.comment == ${dslString(downtimeRemoved)}',
      },
    );
    await untilRemoval(downtimeRemoved);
    await settle(ev);
    await ev.snapshot('removal', host: 'lab', service: 'dt');
    await ev.logExcerpt(label: 'downtime');
  });
}

extension Batch on Scenarios {
  /// The wall clock now, in the result time form.
  String _nowText() {
    final micros = DateTime.now().microsecondsSinceEpoch;
    return timeText(micros ~/ 1000000, micros % 1000000);
  }

  Future<void> _remindOnce(Evidence ev, String host) async {
    // The next delivery is the reminder (interval 2s); then stop reminders.
    await ev.deliveries(1);
    await setAttr(host, {'enable_notifications': false});
    await settle(ev);
    await ev.snapshot('reminder', host: host);
  }

  Future<void> _firstProblem() async {
    await scenario('first_check_result_of_a_new_host_is_down', (ev) async {
      // The daemon's start time, the initial state change time Icinga 2
      // gives an object created at runtime (D13). The gate checks that the
      // runtime host's first delivery does not carry it.
      final status = await lab.ok('GET', '/v1/status/IcingaApplication');
      if (status case {
        'status': {'icingaapplication': {'app': {'program_start': num start}}},
      }) {
        ev.info('daemon_program_start', start);
      } else {
        throw StateError('no program_start in $status');
      }
      await lab.ok(
        'PUT',
        '/v1/objects/hosts/fp-runtime',
        body: {
          'templates': ['cap-host'],
          'attrs': {
            'vars': {
              'cap_id': 'fp-runtime',
              'cap_cmd': 'correlia-host',
              'cap_remind': true,
            },
          },
        },
      );
      for (final host in ['fp-startup', 'fp-runtime']) {
        final s = c.nowSeconds();
        await ev.result(
          objectType: 'host',
          id: host,
          exit: 1,
          output: 'DOWN: first $host',
          end: timeText(s, 300001),
          label: 'first_hard',
        );
        final first = (await ev.deliveries(1)).single;
        await ev.snapshot(first['id']! as String, host: host);
        await ev.result(
          objectType: 'host',
          id: host,
          exit: 1,
          output: 'DOWN: second $host',
          end: timeText(s + 1, 400002),
          label: 'second_hard',
        );
        await _remindOnce(ev, host);
      }
    });
    await scenario('volatile_host_with_no_state_change_yet', (ev) async {
      final s = c.nowSeconds();
      await ev.result(
        objectType: 'host',
        id: 'fp-volatile',
        exit: 1,
        output: 'DOWN: first',
        end: timeText(s, 300001),
        label: 'first_hard',
      );
      final first = (await ev.deliveries(1)).single;
      await ev.snapshot(first['id']! as String, host: 'fp-volatile');
      await ev.result(
        objectType: 'host',
        id: 'fp-volatile',
        exit: 1,
        output: 'DOWN: second',
        end: timeText(s + 2, 400002),
        label: 'second_hard',
      );
      final second = (await ev.deliveries(1)).single;
      await ev.snapshot(second['id']! as String, host: 'fp-volatile');
      await _remindOnce(ev, 'fp-volatile');
    });
    await scenario(
      'multiline_recovery_and_custom_notification_without_output',
      (ev) async {
        final s = c.nowSeconds();
        await _step(
          ev,
          objectType: 'service',
          id: 'recov1',
          exit: 2,
          output: 'CRITICAL: first\nsecond line\nthird line',
          end: timeText(s, 100001),
        );
        await _step(
          ev,
          objectType: 'service',
          id: 'recov1',
          exit: 0,
          output: 'OK: first\nsecond line\nthird line',
          end: timeText(s, 600002),
        );
        await custom('Service', 'unchecked', comment: 'no result yet');
        final d = (await ev.deliveries(1)).single;
        await ev.snapshot(
          d['id']! as String,
          host: 'lab',
          service: 'unchecked',
        );
      },
    );
  }

  Future<void> _outputs() async {
    await scenario('long_check_output', (ev) async {
      final s = c.nowSeconds();
      await _step(
        ev,
        objectType: 'service',
        id: 'long',
        exit: 2,
        output: 'CRITICAL: ${'l' * (200 * 1024)}',
        end: timeText(s, 100001),
      );
    });
    await scenario('recovery_output_with_dollar_signs', (ev) async {
      final s = c.nowSeconds();
      await _step(
        ev,
        objectType: 'service',
        id: 'recov2',
        exit: 2,
        output: 'CRITICAL: down',
        end: timeText(s, 100001),
      );
      await _step(
        ev,
        objectType: 'service',
        id: 'recov2',
        exit: 0,
        output: 'OK: cost below \$5, see \$host.name\$ ${'x' * 9000}',
        end: timeText(s, 600002),
      );
    });
    await scenario('multibyte_character_across_the_cut', (ev) async {
      final s = c.nowSeconds();
      await _step(
        ev,
        objectType: 'service',
        id: 'recov3',
        exit: 2,
        output: 'CRITICAL: down',
        end: timeText(s, 100001),
      );
      await _step(
        ev,
        objectType: 'service',
        id: 'recov3',
        exit: 0,
        output: '\$\$\$${'a' * 8187}€${'b' * 100}',
        end: timeText(s, 600002),
      );
    });
    await scenario('oversized_custom_notification', (ev) async {
      await _step(
        ev,
        objectType: 'service',
        id: 'custom',
        exit: 2,
        output: 'CRITICAL: for custom',
        end: timeText(c.nowSeconds(), 100001),
      );
      await custom(
        'Service',
        'custom',
        author: 'a' * 4096,
        comment: 'c' * (200 * 1024),
      );
      final d = (await ev.deliveries(1)).single;
      await ev.snapshot(d['id']! as String, host: 'lab', service: 'custom');
    });
    await scenario('nul_in_display_text', (ev) async {
      await custom(
        'Service',
        'nultext',
        author: 'ali\u0000ce',
        comment: 'before\u0000after',
      );
      await ev.deliveries(1);
    });
    await scenario('invalid_utf_8_in_check_output', (ev) async {
      await lab.ok(
        'POST',
        '/v1/objects/services/lab!invalid-output',
        body: {
          'attrs': {'enable_active_checks': true},
        },
      );
      await _action('reschedule-check', {
        'type': 'Service',
        'filter': 'service.vars.cap_id == "invalid"',
        'force_check': true,
      });
      await ev.deliveries(1);
    });
  }

  Future<void> _timeEdges() async {
    await scenario('time_outside_the_formatter_s_domain', (ev) async {
      for (final v in ['0.5', '4294967296', '4294967295.999999']) {
        await ev.console('correlia_time_text($v)', input: v);
      }
    });
    await scenario('initialized_state_change_time_of_a_runtime_created_host', (
      ev,
    ) async {
      final now = c.nowSeconds();
      await ev.console(
        'correlia_host_state_change({ state_type = 1, last_state_up = 0, '
        'last_state_change = ${now - 8 * 86400}, '
        'last_hard_state_change = ${now - 1} })',
        input: {'now': now},
      );
    });
    await scenario('earlier_result_with_a_negative_execution_end', (ev) async {
      final s = c.nowSeconds();
      await ev.result(
        objectType: 'host',
        id: 'host-neg',
        exit: 0,
        output: 'UP: before',
        end: '-1.000000',
        label: 'negative_end',
      );
      await ev.result(
        objectType: 'host',
        id: 'host-neg',
        exit: 1,
        output: 'DOWN: soft',
        end: timeText(s, 200001),
        label: 'soft_down',
      );
      await ev.result(
        objectType: 'host',
        id: 'host-neg',
        exit: 1,
        output: 'DOWN: hard',
        end: timeText(s, 700002),
        label: 'hard_down',
      );
      final d = (await ev.deliveries(1)).single;
      await ev.snapshot(d['id']! as String, host: 'host-neg');
    });
    await scenario(
      'non_state_notification_for_an_object_with_an_unusable_state_change_time',
      (ev) async {
        await ev.result(
          objectType: 'host',
          id: 'host-neg3',
          exit: 1,
          output: 'DOWN: negative',
          end: '-3.000000',
          label: 'negative_end',
        );
        await ev.failures(1, mustContain: 'host-neg3');
        await _action('acknowledge-problem', {
          'type': 'Host',
          'filter': 'host.vars.cap_id == "host-neg3"',
          'author': 'operator',
          'comment': 'looking',
          'notify': true,
        });
        final d = (await ev.deliveries(1)).single;
        await ev.snapshot(d['id']! as String, host: 'host-neg3');
      },
    );
  }

  Future<void> _transitionSequence() =>
      scenario('captured_transition_sequence', (ev) async {
        final s = c.nowSeconds();
        const filter = 'service.vars.cap_id == "tx"';
        Future<bool> logged(String text) async =>
            (await lab.logFrom(ev.logMark)).contains(text);
        await _step(
          ev,
          objectType: 'service',
          id: 'tx',
          exit: 2,
          output: 'CRITICAL: tx',
          end: timeText(s, 100001),
        );
        await _action('acknowledge-problem', {
          'type': 'Service',
          'filter': filter,
          'author': 'operator',
          'comment': 'ack',
          'notify': true,
        });
        await ev.deliveries(1);
        // Flapping: alternate results until Icinga 2 reports it started, then
        // steady CRITICAL results until it ends.
        var tick = 0;
        while (!await logged("'FlappingStart'")) {
          if (++tick > 60) throw StateError('flapping never started');
          await ev.result(
            objectType: 'service',
            id: 'tx',
            exit: tick.isEven ? 2 : 0,
            output: 'flap $tick',
            end: _nowText(),
          );
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
        while (!await logged("'FlappingEnd'")) {
          if (++tick > 200) throw StateError('flapping never ended');
          await ev.result(
            objectType: 'service',
            id: 'tx',
            exit: 2,
            output: 'steady $tick',
            end: _nowText(),
          );
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
        await settle(ev);
        await _action('schedule-downtime', {
          'type': 'Service',
          'filter': filter,
          'start_time': c.nowSeconds() - 1,
          'end_time': c.nowSeconds() + 3600,
          'fixed': true,
          'author': 'operator',
          'comment': 'window',
        });
        await settle(ev);
        await lab.ok(
          'POST',
          '/v1/actions/remove-downtime',
          body: {
            'type': 'Downtime',
            'filter': 'downtime.service_name == "tx"',
          },
        );
        await settle(ev);
        await ev.result(
          objectType: 'service',
          id: 'tx',
          exit: 0,
          output: 'OK: tx back',
          end: _nowText(),
        );
        await settle(ev);
        await ev.snapshot('end', host: 'lab', service: 'tx');
        await ev.logExcerpt(label: 'transitions');
      });

  Future<void> _delayedRecovery() =>
      scenario('delayed_recovery_publishes_the_live_check_output', (ev) async {
        final s = c.nowSeconds();
        await _step(
          ev,
          objectType: 'service',
          id: 'gated',
          exit: 2,
          output: 'CRITICAL: disk full',
          end: timeText(s, 100001),
        );
        await setAttr('capture-control', {'vars.capture_hold': true});
        await ev.result(
          objectType: 'service',
          id: 'gated',
          exit: 0,
          output: 'OK: disk recovered',
          end: timeText(s, 300002),
        );
        await ev.result(
          objectType: 'service',
          id: 'gated',
          exit: 2,
          output: 'CRITICAL: disk full',
          end: timeText(s, 500003),
          label: 'refire',
        );
        await setAttr('capture-control', {'vars.capture_hold': false});
        await settle(ev);
        await ev.snapshot('end', host: 'lab', service: 'gated');
      });

  Future<void> _names() async {
    await scenario('name_with_an_embedded_nul_is_not_delivered', (ev) async {
      final s = c.nowSeconds();
      await _step(
        ev,
        objectType: 'host',
        id: 'db1',
        exit: 1,
        output: 'DOWN: db1',
        end: timeText(s, 100001),
      );
      await ev.result(
        objectType: 'host',
        id: 'db1nul',
        exit: 1,
        output: 'DOWN: nul',
        end: timeText(s, 300002),
      );
      await ev.result(
        objectType: 'host',
        id: 'db1nul',
        exit: 0,
        output: 'UP: nul',
        end: timeText(s, 600003),
      );
      await ev.failures(2, mustContain: 'db1');
      if (c.untakenProxied != 0) {
        throw StateError('request for an invalid name');
      }
      await ev.snapshot('end', host: 'db1');
    });
    await scenario('oversized_or_invalid_name_is_not_delivered', (ev) async {
      final s = c.nowSeconds();
      for (final id in ['name1025', 'badutf8']) {
        await ev.result(
          objectType: 'service',
          id: id,
          exit: 2,
          output: 'CRITICAL: $id',
          end: timeText(s, 100001),
        );
      }
      await ev.failures(2);
      if (c.untakenProxied != 0) {
        throw StateError('request for an invalid name');
      }
    });
  }
}

extension Batch2 on Scenarios {
  /// Writes the operator settings and restarts the daemon, with [env] in its
  /// environment.
  Future<void> _reconfigure({
    String? baseUrl,
    String? source,
    Credential credential = Credential.token,
    String? caFile,
    String? tokenLiteral,
    Map<String, String> env = const {},
  }) async {
    await useSettings(
      baseUrl: baseUrl,
      source: source,
      credential: credential,
      caFile: caFile,
      tokenLiteral: tokenLiteral,
    );
    await lab.restart(env: env);
  }

  /// One CUSTOM notification for [id], through whatever the settings now are.
  Future<void> _trigger(String id) => custom('Service', id, comment: 'probe');

  Future<void> _retained() =>
      scenario('retained_state_across_a_restart', (ev) async {
        await lab.restart();
        await setAttr('fp-startup', {'enable_notifications': true});
        await ev.deliveries(1);
        await setAttr('fp-startup', {'enable_notifications': false});
        await settle(ev);
        await ev.snapshot('reminder', host: 'fp-startup');
      });

  Future<void> _authAndEnvironment() async {
    await scenario('notification_from_a_real_icinga_2_in_both_auth_modes', (
      ev,
    ) async {
      final s = c.nowSeconds();
      await _step(
        ev,
        objectType: 'service',
        id: 'auth1',
        exit: 2,
        output: 'CRITICAL: bearer',
        end: timeText(s, 100001),
      );
      await _reconfigure(credential: Credential.hmac);
      await _step(
        ev,
        objectType: 'service',
        id: 'auth2',
        exit: 2,
        output: 'CRITICAL: hmac',
        end: timeText(s, 300002),
      );
    });
    await scenario('runtime_options_in_icinga_s_environment', (ev) async {
      await _reconfigure(
        env: {
          'DART_VM_OPTIONS': '--help',
          'CORRELIA_URL': 'http://127.0.0.1:9',
        },
      );
      await _step(
        ev,
        objectType: 'service',
        id: 'env1',
        exit: 2,
        output: 'CRITICAL: env',
        end: timeText(c.nowSeconds(), 100001),
      );
      await settle(ev);
      await ev.logExcerpt(label: 'env');
    });
    await scenario('inherited_correlia_settings_are_ignored', (ev) async {
      await _reconfigure(
        env: {
          'CORRELIA_URL': 'http://127.0.0.1:9',
          'CORRELIA_CA_FILE': '/nonexistent/ca.pem',
          'CORRELIA_HMAC_KEY_FILE': '/nonexistent/key',
        },
      );
      await _step(
        ev,
        objectType: 'service',
        id: 'env2',
        exit: 2,
        output: 'CRITICAL: inherited',
        end: timeText(c.nowSeconds(), 100001),
      );
    });
    await _reconfigure();
  }

  Future<void> _burst() =>
      scenario('burst_of_verbose_notifications', (ev) async {
        await _reconfigure(baseUrl: dslString(receiverUrl));
        c.drain();
        DateTime? last;
        var i = 0;
        for (final id in CaptureConfig.burstIds) {
          final output = i.isEven
              ? 'CRITICAL: ${'v' * (512 * 1024 - 10)}'
              : '\$' * (512 * 1024);
          i++;
          await ev.result(
            objectType: 'service',
            id: id,
            exit: 2,
            output: output,
            end: _nowText(),
          );
          last = DateTime.now();
        }
        final bodies = await ev.recorded(CaptureConfig.burstCount);
        ev.info(
          'seconds_from_last_result_to_last_body',
          DateTime.now().difference(last!).inMilliseconds / 1000,
        );
        ev.info('bodies', bodies.length);
        await _reconfigure();
      });

  Future<void> _failureCase(
    Evidence ev,
    String label, {
    String? baseUrl,
    String? source,
    String? caFile,
    String? tokenLiteral,
    Map<String, String> env = const {},
    String trigger = 'rej2',
  }) async {
    await _reconfigure(
      baseUrl: baseUrl,
      source: source,
      caFile: caFile,
      tokenLiteral: tokenLiteral,
      env: env,
    );
    ev.add({'kind': 'case', 'label': label});
    await _trigger(trigger);
    await ev.failures(1, mustContain: trigger);
    if (c.untakenProxied != 0) {
      throw StateError('$label: a request was made');
    }
  }

  /// Records that none of [secrets] (name to value) appears in the log since
  /// the evidence mark; the values themselves are never written.
  Future<void> _scan(Evidence ev, Map<String, String> secrets) async {
    final log = await lab.logFrom(ev.logMark);
    ev.add({
      'kind': 'secret_scan',
      'checked': secrets.keys.toList(),
      'found': [
        for (final e in secrets.entries)
          if (e.value.isNotEmpty && log.contains(e.value)) e.key,
      ],
    });
  }

  Future<void> _settingsFailures() async {
    await scenario('setting_not_deliverable_exactly', (ev) async {
      await _failureCase(
        ev,
        'long_base_url',
        baseUrl: dslString('https://${'a' * 4100}.example'),
      );
      await _failureCase(
        ev,
        'invalid_utf8_token_path',
        tokenLiteral: r'"/etc/icinga2/correlia/\377token"',
      );
    });
    await scenario('nul_in_a_file_path', (ev) async {
      await lab.writeFile(
        '$containerCorrelia/ca.pem',
        utf8.encode(await _ca()),
        owner: 'icinga:icinga',
        mode: '600',
      );
      await _failureCase(
        ev,
        'nul_in_ca_path',
        caFile: r'"/etc/icinga2/correlia/ca.pem\000-next"',
      );
    });
    await scenario('base_url_carrying_a_credential', (ev) async {
      for (final (label, url) in [
        ('userinfo', 'https://user:secret@correlia.example'),
        ('query_token', 'https://correlia.example?token=secret'),
        (
          'path_token',
          'https://correlia.example/hooks/icinga2/$captureSource/secret',
        ),
      ]) {
        await _failureCase(ev, label, baseUrl: dslString(url));
      }
      await _scan(ev, {'secret': 'secret'});
    });
    await scenario('multiline_settings', (ev) async {
      await _failureCase(
        ev,
        'multiline_base_url',
        baseUrl: dslString(
          'https://correlia.example\n'
          'https://correlia.example/hooks/icinga2/$captureSource/SECRET-MARKER',
        ),
      );
      await _failureCase(
        ev,
        'multiline_source',
        source: dslString('$captureSource\nSECRET-MARKER'),
      );
      await _scan(ev, {'SECRET-MARKER': 'SECRET-MARKER'});
    });
    await scenario('source_that_is_not_a_uuid', (ev) async {
      await _failureCase(
        ev,
        'credential_as_source',
        source: dslString(rig.token),
      );
      await _scan(ev, {'token': rig.token});
    });
    await scenario('macro_text_in_a_setting_is_literal', (ev) async {
      await _failureCase(
        ev,
        'macro_base_url',
        baseUrl: r'"https://$host.name$"',
      );
      await _reconfigure(credential: Credential.dollarToken);
      ev.add({'kind': 'case', 'label': 'dollar_token_path'});
      await _step(
        ev,
        objectType: 'service',
        id: 'env1',
        exit: 0,
        output: 'OK: dollar path',
        end: _nowText(),
      );
    });
    await _reconfigure();
  }

  /// A fresh self-signed certificate for 127.0.0.1; writes the key next to
  /// the run's files and returns the certificate PEM.
  Future<String> _ca() async {
    final dir = rig.files.path;
    final result = await Process.run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-keyout',
      '$dir/hostile.key',
      '-out',
      '$dir/hostile.pem',
      '-days',
      '2',
      '-subj',
      '/CN=127.0.0.1',
      '-addext',
      'subjectAltName=IP:127.0.0.1',
    ]);
    if (result.exitCode != 0) throw StateError('openssl: ${result.stderr}');
    return File('$dir/hostile.pem').readAsStringSync();
  }

  Future<void> _hostileAndRejected() async {
    await scenario('hostile_inherited_environment', (ev) async {
      final pem = await _ca();
      await lab.writeFile(
        '$containerCorrelia/hostile-ca.pem',
        utf8.encode(pem),
        owner: 'icinga:icinga',
        mode: '644',
      );
      var proxyHits = 0;
      final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      proxy.listen((socket) {
        proxyHits++;
        socket.destroy();
      });
      var tlsRequests = 0;
      final context = SecurityContext()
        ..useCertificateChain('${rig.files.path}/hostile.pem')
        ..usePrivateKey('${rig.files.path}/hostile.key');
      final tls = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        context,
      );
      tls.listen((request) async {
        tlsRequests++;
        request.response.statusCode = 202;
        await request.response.close();
      });
      try {
        final env = {
          'http_proxy': 'http://127.0.0.1:${proxy.port}',
          'ALL_PROXY': 'http://127.0.0.1:${proxy.port}',
          'OPENSSL_CONF': '/nonexistent/openssl.cnf',
          'SSL_CERT_FILE': '$containerCorrelia/hostile-ca.pem',
          'SSL_CERT_DIR': '/nonexistent',
          'CURL_CA_BUNDLE': '$containerCorrelia/hostile-ca.pem',
          'SSLKEYLOGFILE': '/tmp/keylog-capture.txt',
        };
        await _reconfigure(env: env);
        ev.add({'kind': 'case', 'label': 'loopback_http'});
        await _step(
          ev,
          objectType: 'service',
          id: 'hostile1',
          exit: 2,
          output: 'CRITICAL: hostile',
          end: _nowText(),
        );
        await _failureCase(
          ev,
          'https_endpoint',
          baseUrl: dslString('https://127.0.0.1:${tls.port}'),
          env: env,
          trigger: 'hostile2',
        );
        final keylog = await lab.exec(
          ['test', '-e', '/tmp/keylog-capture.txt'],
          check: false,
        );
        ev.info('recording_listener_connections', proxyHits);
        ev.info('https_endpoint_requests', tlsRequests);
        ev.info('key_log_file_exists', keylog.code == 0);
      } finally {
        await proxy.close();
        await tls.close(force: true);
      }
      await _reconfigure();
    });
    await scenario('rejected_delivery_leaves_no_secret_in_icinga_2_logs', (
      ev,
    ) async {
      rig.injectedBodyOnRejection = 'MARKER-REJECTED-BODY-7f3a';
      final credentials = <String>[];
      try {
        for (final (label, credential) in [
          ('wrong_token', Credential.wrongToken),
          ('wrong_hmac_key', Credential.wrongKey),
        ]) {
          await _reconfigure(credential: credential);
          ev.add({'kind': 'case', 'label': label});
          await _trigger('rej1');
          await ev.deliveries(1);
          await ev.failures(1, mustContain: 'rej1');
        }
        for (final seen in rig.proxied.where((r) => r.status == 401)) {
          credentials.addAll(seen.credentials);
        }
      } finally {
        rig.injectedBodyOnRejection = null;
      }
      await _scan(ev, {
        'marker': 'MARKER-REJECTED-BODY-7f3a',
        'token': rig.token,
        'hmac_key': rig.hmacKey,
        for (var i = 0; i < credentials.length; i++)
          'credential_header_$i': credentials[i],
      });
      await _reconfigure();
    });
  }
}
