import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../../support/icinga2_delivery.dart';
import '../../support/icinga2_matrix.dart';

/// The version matrix of the Icinga2 webhook (task 9.2).
///
/// The supported-release statement in `docs/ingest-pipeline.md` lists release
/// and architecture pairs. Each listed pair's committed captures (real Icinga 2
/// runs made by `tool/icinga2_capture.sh`) are evaluated here: the six gates,
/// the recorded 202 with its decoded event, and one named test per scenario
/// that only a real Icinga 2 can produce. The failure-naming tests break a
/// copy of a committed pair in a temporary directory.
void main() {
  final pairs = committedStatement();
  final temporary = <Directory>[];
  tearDownAll(() {
    for (final d in temporary) {
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
  });

  /// Runs [check] on every listed pair's capture and fails naming each pair
  /// with a problem.
  void eachPair(Check check) {
    expect(
      pairs,
      isNotEmpty,
      reason:
          'the supported-release statement in docs/ingest-pipeline.md lists '
          'no release and architecture pair',
    );
    final failures = [
      for (final p in pairs)
        for (final d in guarded(check, Capture(p))) '${p.name}: $d',
    ];
    expect(failures, isEmpty);
  }

  Pair baseline() {
    expect(
      pairs,
      isNotEmpty,
      reason: 'no listed pair to build synthetic evidence from',
    );
    return pairs.first;
  }

  /// A fresh temporary directory, removed after the test file.
  Directory temp() {
    final root = Directory.systemTemp.createTempSync('icinga2-publish-');
    temporary.add(root);
    return root;
  }

  /// A copy of [of] (default: the first listed pair) in a temporary
  /// directory.
  Pair copy([Pair? of]) {
    final source = of ?? baseline();
    final root = Directory.systemTemp.createTempSync('icinga2-matrix-');
    temporary.add(root);
    final target = Directory(
      '${root.path}/${source.release}/${source.architecture}',
    )..createSync(recursive: true);
    for (final f in source.directory.listSync().whereType<File>()) {
      f.copySync('${target.path}/${f.uri.pathSegments.last}');
    }
    return Pair(source.release, source.architecture, target);
  }

  void edit(
    Pair pair,
    String file,
    void Function(List<Map<String, Object?>> records) change,
  ) {
    final f = File('${pair.directory.path}/$file.json');
    final json = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
    change((json['records']! as List<Object?>).cast<Map<String, Object?>>());
    f.writeAsStringSync(jsonEncode(json));
  }

  void setBody(Map<String, Object?> record, String key, Object? value) {
    final request = record['request']! as Map<String, Object?>;
    final body = jsonDecode(request['body']! as String) as Map<String, Object?>;
    if (value == null) {
      body.remove(key);
    } else {
      body[key] = value;
    }
    request['body'] = jsonEncode(body);
    // The edited body stands for the bytes sent: its digest and size follow
    // it to the request, the raw row and the row's events.
    final bytes = utf8.encode(request['body']! as String);
    final digest = sha256.convert(bytes).toString();
    request['body_sha256'] = digest;
    request['body_size'] = bytes.length;
    if (record['raw'] case final Map<String, Object?> raw) {
      raw['body_sha256'] = digest;
    }
    for (final e in (record['events'] as List<Object?>?) ?? const []) {
      final data =
          ((e! as Map<String, Object?>)['cloud_event']!
                  as Map<String, Object?>)['data']!
              as Map<String, Object?>;
      (data['raw']! as Map<String, Object?>)
        ..['sha256'] = digest
        ..['size'] = bytes.length;
    }
  }

  var rawRows = 0;

  /// Gives a copied admitted [record] a raw row of its own, which its stored
  /// events name, as a separately admitted request would have.
  void newRawRow(Map<String, Object?> record) {
    final raw = record['raw']! as Map<String, Object?>;
    final old = raw['id']! as String;
    final id =
        '00000000-0000-4000-8000-${(++rawRows).toString().padLeft(12, '0')}';
    raw['id'] = id;
    for (final e in (record['events'] as List<Object?>?) ?? const []) {
      final data =
          ((e! as Map<String, Object?>)['cloud_event']!
                  as Map<String, Object?>)['data']!
              as Map<String, Object?>;
      final ref = data['raw']! as Map<String, Object?>;
      ref['ref'] = (ref['ref']! as String).replaceFirst(old, id);
    }
  }

  /// Makes [record]'s stored event the observation its (edited) body
  /// decodes to, so synthetic evidence stays coherent for the decode gate.
  void syncEvent(Map<String, Object?> record) {
    final decoded = decodeBody(Rec(record).bodyText);
    final event =
        (record['events']! as List<Object?>).single! as Map<String, Object?>;
    event['source_time'] = decoded.sourceTime?.toRfc3339();
    final cloud = event['cloud_event']! as Map<String, Object?>;
    (cloud['data']! as Map<String, Object?>)
      ..['event_id'] = decoded.eventId
      ..['fingerprint'] = decoded.fingerprint;
  }

  /// Fails unless [failures] names [pair] and [gate] (and only those gates in
  /// [only], when given).
  void expectNamed(
    List<Failure> failures,
    Pair pair,
    String gate, {
    String? mentions,
    bool only = false,
  }) {
    final named = failures.where((f) => f.pair == pair.name && f.gate == gate);
    expect(
      named,
      isNotEmpty,
      reason: 'no failure names ${pair.name} and "$gate": $failures',
    );
    if (mentions != null) {
      expect(named.join('\n'), contains(mentions));
    }
    if (only) {
      expect(
        failures.map((f) => f.gate).toSet(),
        {gate},
        reason: 'unexpected extra failures: $failures',
      );
    }
  }

  // --- Statement and gates --------------------------------------------------

  test('every_capture_decodes', () {
    expect(
      pairs,
      isNotEmpty,
      reason: 'the supported-release statement lists no pair',
    );
    final failures = [for (final p in pairs) ...evaluatePair(p)];
    expect(failures, isEmpty);
  });

  test('each_shipped_architecture_is_run', () {
    eachPair((c) => [...gateManifest(c), ...gateDelivery(c)]);
    expect({for (final p in pairs) p.architecture}, {'linux-x64'});
  });

  /// A build directory with a sender per built architecture whose content is
  /// its architecture name, and a contrib directory of three definitions.
  ({Directory build, Directory contrib, Directory release}) workspace() {
    final work = temp();
    final build = Directory('${work.path}/build');
    for (final architecture in builtArchitectures) {
      File('${build.path}/$architecture/$senderFileName')
        ..createSync(recursive: true)
        ..writeAsStringSync(architecture);
    }
    final contrib = Directory('${work.path}/contrib')..createSync();
    for (final name in ['correlia.conf', 'correlia-commands.conf']) {
      File('${contrib.path}/$name').writeAsStringSync(name);
    }
    return (
      build: build,
      contrib: contrib,
      release: Directory('${work.path}/release'),
    );
  }

  test('every_row_of_the_statement_is_read_or_refused', () {
    const header = '| Release | Architecture |\n|---|---|\n';
    // Markdown renders a row without its outer pipes as a row.
    expect(
      [
        for (final p in parseStatement(
          '$_begin\n$header| 2.16.6 | linux-x64 |\n'
          '| 2.16.6 | linux-arm64\n2.15.7 | linux-x64\n$_end\n',
        ))
          '${p.release}/${p.architecture}',
      ],
      ['2.16.6/linux-x64', '2.16.6/linux-arm64', '2.15.7/linux-x64'],
    );
    for (final bad in [
      '| 2.16 | linux-x64 |',
      '| 2.16.6 | linux-x64 | extra |',
      '| 2.16.6 |',
      'see below',
    ]) {
      expect(
        () => parseStatement('$_begin\n$header$bad\n$_end\n'),
        throwsFormatException,
        reason: bad,
      );
    }
    expect(
      () => parseStatement('$_begin\n| 2.16.6 | linux-x64 |\n$_end\n'),
      throwsFormatException,
    );
  });

  test('unreadable_statement_leaves_no_earlier_publication', () {
    final w = workspace();
    final stale = File('${w.release.path}/linux-x64/$senderFileName')
      ..createSync(recursive: true)
      ..writeAsStringSync('an earlier publication');
    expect(
      () => statementForPublishing(
        w.release,
        '$_begin\n| Release | Architecture |\n|---|---|\nsee below\n$_end\n',
      ),
      throwsFormatException,
    );
    expect(stale.existsSync(), isFalse);
    expect(w.release.existsSync(), isFalse);
  });

  test('current_definitions_are_the_qualified_bundle', () {
    // The release task publishes only the bundle the listed captures ran, so
    // a changed definition must fail here, in the gate, not only there.
    final qualified = qualifiedBundles(pairs).qualified;
    expect(qualified, isNotEmpty);
    final current = definitionHashes(Directory('../contrib/icinga2'));
    for (final MapEntry(key: architecture, value: bundle)
        in qualified.entries) {
      expect(current, bundle.definitions, reason: architecture);
    }
  });

  test('optional_arguments_are_decided_without_live_data', () {
    // Icinga 2 resolves an argument's set_if and value separately, so a
    // set_if that read live data (the check output, say) could pass the
    // argument with a value read after that data changed. Each set_if tests
    // a setting constant or the command's fixed notification type only.
    final commands = File(
      '../contrib/icinga2/correlia-commands.conf',
    ).readAsStringSync();
    final tests = [
      for (final m in RegExp(
        r'set_if = \{\{(.*?)\}\}',
        dotAll: true,
      ).allMatches(commands))
        m[1]!.trim(),
    ];
    expect(tests, isNotEmpty);
    final allowed = RegExp(
      r'^(Correlia[A-Za-z]+ != ""|'
      r'correlia_is_state_notification\(macro\("\$notification\.type\$"\)\))$',
    );
    for (final test in tests) {
      expect(test, matches(allowed));
    }
  });

  test('file_changed_during_publication_is_not_published', () {
    // The publisher checks the bytes it staged, not only the files it read
    // first: a sender or definition replaced in between is refused.
    for (final changed in [senderFileName, 'correlia-commands.conf']) {
      final w = workspace();
      final qualified = {
        'linux-x64': Bundle.current(
          File('${w.build.path}/linux-x64/$senderFileName'),
          w.contrib,
        ),
      };
      expect(
        () => publishSenders(
          build: w.build,
          contrib: w.contrib,
          release: w.release,
          qualified: qualified,
          copy: (from, to) {
            from.copySync(to);
            if (to.endsWith('/$changed')) {
              File(to).writeAsStringSync('replaced');
            }
          },
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('staged'),
          ),
        ),
        reason: changed,
      );
      expect(w.release.existsSync(), isFalse, reason: changed);
      expect(
        w.release.parent.listSync().map((e) => e.uri.pathSegments.last),
        isNot(contains(startsWith('release'))),
        reason: changed,
      );
    }
  });

  test('failed_copy_leaves_no_partial_bundle', () {
    // The bundle is assembled beside the release directory and moved into
    // place whole, so a copy that fails part way publishes nothing.
    final w = workspace();
    final qualified = {
      'linux-x64': Bundle.current(
        File('${w.build.path}/linux-x64/$senderFileName'),
        w.contrib,
      ),
    };
    var copies = 0;
    expect(
      () => publishSenders(
        build: w.build,
        contrib: w.contrib,
        release: w.release,
        qualified: qualified,
        copy: (from, to) {
          if (++copies == 2) throw const FileSystemException('disk full');
          from.copySync(to);
        },
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(copies, 2);
    expect(w.release.existsSync(), isFalse);
    expect(
      w.release.parent.listSync().map((e) => e.uri.pathSegments.last),
      isNot(contains(startsWith('release'))),
    );
  });

  test('only_one_architecture_qualifies', () {
    final statement = parseStatement(
      '$_begin\n| Release | Architecture |\n|---|---|\n'
      '| 2.16.6 | linux-x64 |\n| 2.15.7 | linux-x64 |\n$_end\n',
    );
    expect({for (final p in statement) p.architecture}, {'linux-x64'});
    expect({for (final p in pairs) p.architecture}, {'linux-x64'});
    expect(evaluateStatement(pairs), isEmpty);
    final committed = qualifiedBundles(pairs);
    expect(committed.qualified.keys, ['linux-x64']);
    expect(committed.refused, isEmpty);
    // Both architectures are built; only the qualified one is published,
    // and only as the exact bundle its listed captures ran.
    final w = workspace();
    final qualified = {
      'linux-x64': Bundle.current(
        File('${w.build.path}/linux-x64/$senderFileName'),
        w.contrib,
      ),
    };
    Directory('${w.release.path}/linux-arm64').createSync(recursive: true);
    List<String> publish() => publishSenders(
      build: w.build,
      contrib: w.contrib,
      release: w.release,
      qualified: qualified,
    );
    expect(publish(), ['linux-x64']);
    expect(
      File('${w.release.path}/linux-x64/$senderFileName').readAsStringSync(),
      'linux-x64',
    );
    expect(
      File('${w.release.path}/icinga2/correlia.conf').readAsStringSync(),
      'correlia.conf',
    );
    expect(Directory('${w.release.path}/linux-arm64').existsSync(), isFalse);
    // A changed definition, with the same sender, is not published.
    File('${w.contrib.path}/correlia-commands.conf').writeAsStringSync('new');
    expect(publish, throwsStateError);
    expect(w.release.existsSync(), isFalse);
    File(
      '${w.contrib.path}/correlia-commands.conf',
    ).writeAsStringSync('correlia-commands.conf');
    expect(publish(), ['linux-x64']);
    // A rebuilt sender that differs from the captured one is not published.
    File(
      '${w.build.path}/linux-x64/$senderFileName',
    ).writeAsStringSync('changed');
    expect(publish, throwsStateError);
    expect(w.release.existsSync(), isFalse);
  });

  test('capture_of_another_platform_or_release_fails_the_manifest_gate', () {
    for (final (field, value) in <(String, Object?)>[
      ('image_platform', 'linux/arm64'),
      ('container_machine', 'aarch64'),
      ('image_id', null),
      ('image_digest', null),
      ('image_digest', 'icinga/icinga2:2.14.10'),
      (
        'icinga_version',
        'icinga2 - The Icinga 2 network monitoring daemon (version: v2.99.0)',
      ),
      ('icinga_version', null),
    ]) {
      final pair = copy();
      final manifest = File('${pair.directory.path}/manifest.json');
      final json =
          jsonDecode(manifest.readAsStringSync()) as Map<String, Object?>;
      if (value == null) {
        json.remove(field);
      } else {
        json[field] = value;
      }
      manifest.writeAsStringSync(jsonEncode(json));
      expect(gateManifest(Capture(pair)), isNotEmpty, reason: '$field $value');
    }
  });

  test('capture_from_another_pair_or_scenario_fails', () {
    // Every capture file names the release, architecture and scenario it
    // was recorded for; a file put in another pair's place, or under another
    // scenario's name, is not that pair's evidence.
    final source = baseline();
    final other = pairs.firstWhere(
      (p) => p.release != source.release,
      orElse: () => fail('the statement lists one release only'),
    );
    final names = Capture(source).names;
    expect(evaluatePair(copy()), isEmpty);
    for (final name in names) {
      final broken = copy();
      File(
        '${other.directory.path}/$name.json',
      ).copySync('${broken.directory.path}/$name.json');
      expect(
        evaluatePair(broken).join('\n'),
        contains('$name.json declares ${other.release}/'),
        reason: '$name from ${other.release}',
      );
    }
    for (final (field, value) in [
      ('architecture', 'linux-arm64'),
      ('architecture', null),
      ('scenario', names.last),
      ('release', null),
    ]) {
      final broken = copy();
      final file = File('${broken.directory.path}/${names.first}.json');
      final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      if (value == null) {
        json.remove(field);
      } else {
        json[field] = value;
      }
      file.writeAsStringSync(jsonEncode(json));
      expect(
        gateManifest(Capture(broken)).join('\n'),
        contains('${names.first}.json declares'),
        reason: '$field $value',
      );
    }
  });

  test('listed_pairs_of_one_architecture_ran_one_bundle', () {
    // Recapturing one listed release with another sender, or with other
    // definitions, refuses the architecture until every row is recaptured.
    final other = pairs.length > 1 ? pairs[1] : baseline();
    for (final field in ['sender_sha256', 'contrib_sha256']) {
      final first = copy();
      final second = copy(other);
      final manifest = File('${second.directory.path}/manifest.json');
      final json =
          jsonDecode(manifest.readAsStringSync()) as Map<String, Object?>;
      json[field] = field == 'sender_sha256'
          ? '0' * 64
          : {
              ...(json[field]! as Map<String, Object?>),
              'correlia-commands.conf': '0' * 64,
            };
      manifest.writeAsStringSync(jsonEncode(json));
      final found = qualifiedBundles([first, second]);
      expect(found.qualified, isEmpty, reason: field);
      expect(
        found.refused['linux-x64'],
        contains('ran another bundle'),
        reason: field,
      );
    }
  });

  test('no_release_passes', () {
    final empty = evaluateStatement(const []);
    expect(empty.single.gate, 'no release passes');
    final broken = copy();
    File(
      '${broken.directory.path}/two_problems_within_one_second.json',
    ).deleteSync();
    final failures = evaluateStatement([broken]);
    expect(failures, isNotEmpty);
    expectNamed(failures, broken, Gate.service);
    // No qualified pair: no artifact is published.
    final found = qualifiedBundles([broken]);
    expect(found.qualified, isEmpty);
    expect(found.refused['linux-x64'], contains('does not pass'));
    final w = workspace();
    Directory('${w.release.path}/linux-x64').createSync(recursive: true);
    expect(
      () => publishSenders(
        build: w.build,
        contrib: w.contrib,
        release: w.release,
        qualified: const {},
      ),
      throwsStateError,
    );
    expect(w.release.existsSync(), isFalse);
  });

  test('listed_release_missing_a_capture', () {
    final missingGate = copy();
    File(
      '${missingGate.directory.path}/two_comments_from_one_author.json',
    ).deleteSync();
    expectNamed(
      evaluatePair(missingGate),
      missingGate,
      Gate.notificationTime,
      mentions: 'missing capture two_comments_from_one_author.json',
    );
    final missing202 = copy();
    File(
      '${missing202.directory.path}/'
      'notification_from_a_real_icinga_2_in_both_auth_modes.json',
    ).deleteSync();
    expectNamed(
      evaluatePair(missing202),
      missing202,
      Gate.delivery,
      mentions: 'missing capture',
    );
    // The stored event is another observation of the same object: same
    // fingerprint, status, kind and severity, another event id and time.
    final otherEvent = copy();
    edit(otherEvent, 'notification_from_a_real_icinga_2_in_both_auth_modes', (
      r,
    ) {
      final event =
          (r.firstWhere((x) => x['kind'] == 'admitted')['events']!
                      as List<Object?>)
                  .first!
              as Map<String, Object?>;
      event['source_time'] = '2026-01-01T00:00:00.000001Z';
      final cloud = event['cloud_event']! as Map<String, Object?>;
      (cloud['data']! as Map<String, Object?>)['event_id'] =
          '00000000-0000-5000-8000-000000000000';
    });
    expectNamed(
      evaluatePair(otherEvent),
      otherEvent,
      Gate.decode,
      mentions: 'is not the decoded',
      only: true,
    );
  });

  test('202_recorded_but_event_missing', () {
    final broken = copy();
    edit(broken, 'notification_from_a_real_icinga_2_in_both_auth_modes', (r) {
      r.firstWhere((x) => x['kind'] == 'admitted')['events'] = <Object?>[];
    });
    expectNamed(
      evaluatePair(broken),
      broken,
      Gate.delivery,
      mentions: 'no decoded event',
    );
  });

  test('known_timestamp_mismatch', () {
    final broken = copy();
    edit(broken, 'production_notification_clock_keeps_microseconds', (r) {
      final known = r.firstWhere(
        (x) => x['kind'] == 'known' && x['field'] == 'last_state_change',
      );
      final value = known['value']! as String;
      final parts = value.split('.');
      final micros = int.parse(parts[1]) + 1;
      known['value'] = '${parts[0]}.${micros.toString().padLeft(6, '0')}';
    });
    expectNamed(
      evaluatePair(broken),
      broken,
      Gate.clock,
      mentions: 'committed input',
      only: true,
    );
  });

  test('decoded_notification_time_must_be_the_known_input', () {
    final broken = copy();
    edit(broken, 'production_notification_clock_keeps_microseconds', (r) {
      // The wire text stays the known input; the committed event of that
      // CUSTOM notification is a microsecond later.
      final known = r.firstWhere(
        (x) =>
            x['kind'] == 'known' &&
            x['command'] == 'correlia-service' &&
            x['field'] == 'notification_time',
      );
      final delivery = r.firstWhere(
        (x) => x['kind'] == 'admitted' && x['id'] == known['delivery'],
      );
      final event =
          (delivery['events']! as List<Object?>).single!
              as Map<String, Object?>;
      final time = event['source_time']! as String;
      event['source_time'] = time.replaceFirstMapped(
        RegExp(r'\.(\d{6})Z$'),
        (m) => '.${(int.parse(m[1]!) + 1).toString().padLeft(6, '0')}Z',
      );
    });
    expectNamed(
      evaluatePair(broken),
      broken,
      Gate.clock,
      mentions: 'correlia-service notification_time: committed input',
    );
  });

  test('gate_evidence_present_but_failing', () {
    final broken = copy();
    edit(broken, 'two_problems_within_one_second', (r) {
      final admitted = r.where((x) => x['kind'] == 'admitted').toList();
      final first = Rec(admitted.first);
      setBody(
        admitted.last,
        'last_state_change',
        first.body['last_state_change'],
      );
      syncEvent(admitted.last);
      expect(Rec(admitted.last).eventId, first.eventId);
    });
    expectNamed(evaluatePair(broken), broken, Gate.service, only: true);
  });

  test('refire_that_does_not_win_fails_the_same_second_gate', () {
    final broken = copy();
    edit(broken, 'two_problems_within_one_second', (r) {
      final last = r.lastWhere((x) => x['kind'] == 'state');
      (last['alert']! as Map<String, Object?>)['status'] = 'resolved';
    });
    expectNamed(
      evaluatePair(broken),
      broken,
      Gate.service,
      mentions: 'the refire did not win',
      only: true,
    );
  });

  test('service_capture_in_the_host_gate_fails_it', () {
    // The service records under the host scenario's own declaration.
    final broken = copy();
    final service = Capture(broken).records('two_problems_within_one_second');
    edit(broken, 'host_command_keeps_sub_second_precision', (r) {
      r
        ..clear()
        ..addAll([for (final x in service) x.json]);
      for (final x in r) {
        if (x['kind'] == 'admitted') newRawRow(x);
      }
    });
    expectNamed(
      evaluatePair(broken),
      broken,
      Gate.host,
      mentions: 'object_type service, not host',
      only: true,
    );
  });

  test('auth_mode_delivery_must_be_the_service_problem', () {
    // A coherent capture of another notification (a CUSTOM, a host, another
    // service) in either mode's place is not the required state change.
    for (final (mode, key, value) in [
      ('hmac', 'notification_type', 'CUSTOM'),
      ('bearer', 'service', 'auth2'),
      ('hmac', 'state_type', 'SOFT'),
    ]) {
      final broken = copy();
      edit(broken, 'notification_from_a_real_icinga_2_in_both_auth_modes', (
        r,
      ) {
        final d = r.firstWhere(
          (x) => x['kind'] == 'admitted' && x['auth'] == mode,
        );
        setBody(d, key, value);
        syncEvent(d);
      });
      expectNamed(
        evaluatePair(broken),
        broken,
        Gate.delivery,
        mentions: '$mode delivery',
      );
    }
  });

  test('reminder_reusing_an_earlier_raw_row_fails_its_gate', () {
    // Each reminder's 202 admitted a raw row of its own, which committed the
    // duplicate observation; a reminder that names the first delivery's row
    // proves no reminder was newly admitted.
    final broken = copy();
    edit(broken, 'first_check_result_of_a_new_host_is_down', (r) {
      final admitted = r.where((x) => x['kind'] == 'admitted').toList();
      final first = admitted.first['raw']! as Map<String, Object?>;
      final reminder = admitted[1]['raw']! as Map<String, Object?>;
      reminder['id'] = first['id'];
    });
    expectNamed(
      evaluatePair(broken),
      broken,
      Gate.firstProblem,
      mentions: 'names an earlier raw row',
    );
    expectNamed(
      evaluatePair(broken),
      broken,
      Gate.decode,
      mentions: 'raw row',
    );
  });

  test('first_problem_without_the_second_result_fails_its_gate', () {
    final broken = copy();
    edit(broken, 'first_check_result_of_a_new_host_is_down', (r) {
      r.removeWhere(
        (x) => x['kind'] == 'result' && x['label'] == 'second_hard',
      );
    });
    expectNamed(
      evaluatePair(broken),
      broken,
      Gate.firstProblem,
      mentions: 'needs both HARD DOWN results',
      only: true,
    );
  });

  test('reminder_before_the_second_result_fails_the_first_problem_gate', () {
    final broken = copy();
    edit(broken, 'first_check_result_of_a_new_host_is_down', (r) {
      // The second check accepted after every reminder was sent.
      for (final x in r) {
        if (x['kind'] == 'result' && x['label'] == 'second_hard') {
          x['accepted_us'] = 4102444800000000;
        }
      }
    });
    expectNamed(
      evaluatePair(broken),
      broken,
      Gate.firstProblem,
      mentions: 'no reminder was sent after the second HARD DOWN result',
      only: true,
    );
  });

  test('volatile_deliveries_must_carry_the_recorded_check_times', () {
    final broken = copy();
    edit(broken, 'volatile_host_with_no_state_change_yet', (r) {
      // The second result as recorded is a microsecond after what both
      // deliveries carried, as if the commands had shifted the time.
      for (final x in r) {
        if (x['kind'] == 'result' &&
            x['cap_id'] == 'fp-volatile' &&
            x['label'] == 'second_hard') {
          final end = x['execution_end']! as String;
          final micros = microsOf(end) + 1;
          x['execution_end'] =
              '${micros ~/ 1000000}.${(micros % 1000000).toString().padLeft(6, '0')}';
        }
      }
    });
    expectNamed(
      evaluatePair(broken),
      broken,
      Gate.firstProblem,
      mentions: 'not the second_hard execution end',
      only: true,
    );
  });

  test('volatile_fence_must_belong_to_the_second_delivery', () {
    final broken = copy();
    edit(broken, 'volatile_host_with_no_state_change_yet', (r) {
      final states = [
        for (final x in r)
          if (x['kind'] == 'state' && jsonEncode(x).contains('fp-volatile')) x,
      ];
      (states[1]['alert']! as Map<String, Object?>)['fence_event_id'] =
          '00000000-0000-5000-8000-000000000000';
    });
    expectNamed(
      evaluatePair(broken),
      broken,
      Gate.firstProblem,
      mentions: 'the fence after the second delivery is',
      only: true,
    );
  });

  test('results_and_deliveries_must_name_one_object', () {
    final broken = copy();
    edit(broken, 'two_problems_within_one_second', (r) {
      r.firstWhere((x) => x['kind'] == 'result')['cap_id'] = 'other';
    });
    expectNamed(
      evaluatePair(broken),
      broken,
      Gate.service,
      mentions: 'result r1 is lab/other, delivery',
      only: true,
    );
  });

  test('comments_on_two_services_fail_the_notification_time_gate', () {
    final broken = copy();
    edit(broken, 'two_comments_from_one_author', (r) {
      final second = r.where((x) => x['kind'] == 'admitted').last;
      setBody(second, 'service', 'other');
      syncEvent(second);
    });
    expectNamed(
      evaluatePair(broken),
      broken,
      Gate.notificationTime,
      mentions: 'delivery 2 is lab/other',
      only: true,
    );
  });

  test('notification_times_out_of_order_fail_their_gate', () {
    final broken = copy();
    edit(broken, 'two_comments_from_one_author', (r) {
      final admitted = r.where((x) => x['kind'] == 'admitted').toList();
      final first = Rec(admitted.first).body['notification_time'];
      final second = Rec(admitted.last).body['notification_time'];
      setBody(admitted.first, 'notification_time', second);
      setBody(admitted.last, 'notification_time', first);
      admitted.forEach(syncEvent);
    });
    expectNamed(
      evaluatePair(broken),
      broken,
      Gate.notificationTime,
      mentions: 'do not increase',
      only: true,
    );
  });

  test('event_of_another_raw_row_fails_the_decode_gate', () {
    final broken = copy();
    edit(broken, 'two_comments_from_one_author', (r) {
      final admitted = r.where((x) => x['kind'] == 'admitted').toList();
      Map<String, Object?> rawOf(Map<String, Object?> d) =>
          ((((d['events']! as List<Object?>).single!
                          as Map<String, Object?>)['cloud_event']!
                      as Map<String, Object?>)['data']!
                  as Map<String, Object?>)['raw']!
              as Map<String, Object?>;
      final first = rawOf(admitted.first);
      rawOf(admitted.last)['ref'] = first['ref'];
    });
    expectNamed(
      evaluatePair(broken),
      broken,
      Gate.decode,
      mentions: 'not raw row',
      only: true,
    );
  });

  test('emitted_notification_time_rounded_to_10_us_fails_the_clock_gate', () {
    final broken = copy();
    edit(broken, 'production_notification_clock_keeps_microseconds', (r) {
      final emitted = {
        for (final e in r.where((x) => x['kind'] == 'emitted'))
          if (e['command'] == 'correlia-host') e['delivery'],
      };
      var step = 0;
      for (final d in r.where((x) => emitted.contains(x['id']))) {
        // Rounded to 10 us, yet distinct and increasing.
        final seconds = (Rec(d).body['notification_time']! as String)
            .split('.')
            .first;
        final rounded = (step++ * 10).toString().padLeft(6, '0');
        setBody(d, 'notification_time', '$seconds.$rounded');
        syncEvent(d);
      }
    });
    expectNamed(
      evaluatePair(broken),
      broken,
      Gate.clock,
      mentions: 'correlia-host: 20 emitted notification times do not show',
      only: true,
    );
  });

  test('notification_times_at_an_exact_millisecond_keep_their_order', () {
    // ISO text of .123000 is ".123Z" and of .123001 is ".123001Z", which
    // sorts first; the gate orders the instants themselves.
    for (final (earlier, later, passes) in [
      ('123000', '123001', true),
      ('123001', '123000', false),
    ]) {
      final pair = copy();
      edit(pair, 'two_comments_from_one_author', (r) {
        final admitted = r.where((x) => x['kind'] == 'admitted').toList();
        final second =
            (Rec(admitted.first).body['notification_time']! as String)
                .split('.')
                .first;
        setBody(admitted.first, 'notification_time', '$second.$earlier');
        setBody(admitted.last, 'notification_time', '$second.$later');
        admitted.forEach(syncEvent);
      });
      final failures = evaluatePair(
        pair,
      ).where((f) => f.gate == Gate.notificationTime).toList();
      expect(
        failures.isEmpty,
        passes,
        reason: '$earlier then $later: $failures',
      );
    }
  });

  test('clock_evidence_must_cover_both_commands_and_fields', () {
    final broken = copy();
    edit(broken, 'production_notification_clock_keeps_microseconds', (r) {
      // Two copies of the service record and no host one.
      final known = r.where((x) => x['kind'] == 'known').toList();
      final service = known.firstWhere(
        (k) =>
            k['command'] == 'correlia-service' &&
            k['field'] == 'last_state_change',
      );
      final host = known.firstWhere(
        (k) =>
            k['command'] == 'correlia-host' &&
            k['field'] == 'last_state_change',
      );
      host
        ..clear()
        ..addAll(service);
    });
    expectNamed(
      evaluatePair(broken),
      broken,
      Gate.clock,
      mentions: 'correlia-host last_state_change: 0 known inputs',
      only: true,
    );
  });

  test('admitted_delivery_without_an_event_or_a_duplicate_outcome', () {
    final broken = copy();
    edit(broken, 'captured_transition_sequence', (r) {
      final ack = r.firstWhere(
        (x) =>
            x['kind'] == 'admitted' &&
            Rec(x).notificationType == 'ACKNOWLEDGEMENT',
      );
      ack['events'] = <Object?>[];
    });
    expectNamed(
      evaluatePair(broken),
      broken,
      Gate.decode,
      mentions: 'no stored event and no duplicate outcome',
      only: true,
    );
  });

  test('a_capture_changes_shape', () {
    final broken = copy();
    edit(broken, 'two_problems_within_one_second', (r) {
      setBody(
        r.firstWhere((x) => x['kind'] == 'admitted'),
        'surprise_field',
        'new',
      );
    });
    final failures = evaluatePair(broken);
    expectNamed(
      failures,
      broken,
      Gate.decode,
      mentions: 'two_problems_within_one_second.json',
    );
    expect(
      failures.where((f) => f.gate == Gate.decode).join('\n'),
      contains('surprise_field'),
    );
  });

  // --- First-problem failure naming --------------------------------------------

  List<Map<String, Object?>> hostRecords(
    List<Map<String, Object?>> records,
    String host,
  ) => [
    for (final r in records)
      if (r['kind'] == 'admitted' && Rec(r).body['host'] == host) r,
  ];

  test('five_gates_pass_but_the_first_problem_is_lost', () {
    final broken = copy();
    edit(broken, 'first_check_result_of_a_new_host_is_down', (r) {
      // The runtime host's first delivery carries the daemon start time.
      final start =
          r.firstWhere(
                (x) =>
                    x['kind'] == 'info' && x['name'] == 'daemon_program_start',
              )['value']!
              as num;
      final first = hostRecords(r, 'fp-runtime').first;
      setBody(first, 'last_state_change', start.toStringAsFixed(6));
      (first['raw']! as Map<String, Object?>)['outcome'] = {
        ...Rec(first).outcome,
        'late': 1,
        'applied': 0,
      };
      // A late observation is still stored, as a `late` event.
      final event =
          (first['events']! as List<Object?>).single! as Map<String, Object?>;
      event['disposition'] = 'late';
      syncEvent(first);
    });
    expectNamed(
      evaluatePair(broken),
      broken,
      Gate.firstProblem,
      mentions: 'daemon start time',
      only: true,
    );
  });

  test('reminder_of_a_first_problem_is_a_new_observation', () {
    final broken = copy();
    edit(broken, 'first_check_result_of_a_new_host_is_down', (r) {
      final reminder = hostRecords(r, 'fp-startup').last;
      setBody(reminder, 'last_state_change', '1700000001.000001');
    });
    expectNamed(
      evaluatePair(broken),
      broken,
      Gate.firstProblem,
      mentions: 'different event id',
      only: true,
    );
  });

  test('reminder_accepted_without_a_committed_duplicate_outcome', () {
    final broken = copy();
    edit(broken, 'first_check_result_of_a_new_host_is_down', (r) {
      final reminder = hostRecords(r, 'fp-startup').last;
      final raw = reminder['raw']! as Map<String, Object?>;
      raw['outcome'] = {
        ...Rec(reminder).outcome,
        'duplicate_observation': 0,
      };
    });
    final failures = evaluatePair(broken);
    expectNamed(
      failures,
      broken,
      Gate.firstProblem,
      mentions: 'duplicate_observation',
    );
    // With no stored event, the outcome must account for the delivery.
    expectNamed(
      failures,
      broken,
      Gate.decode,
      mentions: 'no duplicate outcome',
    );
    expect(failures.map((f) => f.gate).toSet(), {
      Gate.firstProblem,
      Gate.decode,
    });
  });

  test('second_hard_check_emits_a_second_event', () {
    final broken = copy();
    edit(broken, 'first_check_result_of_a_new_host_is_down', (r) {
      final startup = hostRecords(r, 'fp-startup');
      final reminder = startup.last;
      final second =
          jsonDecode(jsonEncode(startup.first)) as Map<String, Object?>;
      final secondEnd = r.firstWhere(
        (x) =>
            x['kind'] == 'result' &&
            x['label'] == 'second_hard' &&
            x['cap_id'] == 'fp-startup',
      )['execution_end'];
      setBody(second, 'last_state_change', secondEnd);
      syncEvent(second);
      newRawRow(second);
      r.insert(r.indexOf(reminder), second);
      setBody(reminder, 'last_state_change', secondEnd);
      final states = r.where(
        (x) =>
            x['kind'] == 'state' &&
            (x['object']! as Map<String, Object?>)['host'] == 'fp-startup',
      );
      final counts = states.last['events']! as Map<String, Object?>;
      counts['total'] = 2;
      counts['by_status'] = {'firing': 2};
    });
    expectNamed(evaluatePair(broken), broken, Gate.firstProblem, only: true);
  });

  test('transport_duplicate_counted_as_a_reminder_outcome', () {
    final broken = copy();
    edit(broken, 'first_check_result_of_a_new_host_is_down', (r) {
      final reminder = hostRecords(r, 'fp-startup').last;
      reminder['kind'] = 'transport_duplicate';
      reminder.remove('raw');
      reminder.remove('events');
    });
    expectNamed(
      evaluatePair(broken),
      broken,
      Gate.firstProblem,
      mentions: 'transport_duplicate',
      only: true,
    );
  });

  // --- Gate scenarios ------------------------------------------------------------

  test('two_problems_within_one_second', () => eachPair(gateService));
  test('host_command_keeps_sub_second_precision', () => eachPair(gateHost));
  test('two_comments_from_one_author', () {
    eachPair((c) {
      final out = gateNotificationTime(c);
      final authors = {
        for (final d in c.admitted('two_comments_from_one_author'))
          d.body['notification_author'],
      };
      if (authors.length != 1) out.add('the two comments differ in author');
      return out;
    });
  });
  test('production_notification_clock_keeps_microseconds', () {
    eachPair(gateClock);
  });
  test('microsecond_values_survive_the_command', () {
    eachPair((c) {
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
    });
  });
  test('captured_downtime_removal', () => eachPair(gateDowntime));

  test('downtime_removal_without_a_route_or_an_expiry', () {
    const file = 'captured_downtime_removal';
    Map<String, Object?> removal(
      List<Map<String, Object?>> records,
      String comment,
    ) => records.firstWhere(
      (r) =>
          r['kind'] == 'admitted' &&
          removalTypes.contains(Rec(r).notificationType) &&
          Rec(r).body['notification_comment'] == comment,
    );

    // An event committed with no output intent is not routed.
    final unrouted = copy();
    edit(unrouted, file, (r) {
      final events = removal(r, downtimeExpires)['events']! as List<Object?>;
      (events.single! as Map<String, Object?>)['outbox'] = <Object?>[];
    });
    expectNamed(
      evaluatePair(unrouted),
      unrouted,
      Gate.downtime,
      mentions: 'no output intent',
      only: true,
    );

    // Two removals of the manual downtime and none of the expiry.
    final noExpiry = copy();
    edit(noExpiry, file, (r) {
      final expiry = removal(r, downtimeExpires);
      setBody(expiry, 'notification_comment', downtimeRemoved);
      syncEvent(expiry);
    });
    expectNamed(
      evaluatePair(noExpiry),
      noExpiry,
      Gate.downtime,
      mentions: 'one removal of the "expires" downtime, found 0',
      only: true,
    );

    // The expiry's removal only arrived with the manual removal.
    final late = copy();
    edit(late, file, (r) {
      final expiry = Rec(removal(r, downtimeExpires));
      final time = double.parse(expiry.body['notification_time']! as String);
      r.firstWhere(
        (x) => x['name'] == 'manual_removal_requested',
      )['value'] = time - 1;
    });
    expectNamed(
      evaluatePair(late),
      late,
      Gate.downtime,
      mentions: 'is not before the manual removal',
      only: true,
    );
  });
  test('same_named_custom_variables_are_ignored', () {
    eachPair((c) {
      final out = <String>[];
      final ds = c.admitted('same_named_custom_variables_are_ignored');
      final results = c.of('same_named_custom_variables_are_ignored', 'result');
      if (ds.length != 3 || results.length != 3) {
        return ['expected three results and three deliveries'];
      }
      for (var i = 0; i < 3; i++) {
        if (ds[i].body['last_state_change'] !=
            results[i].json['execution_end']) {
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
    });
  });
  test('captured_host_transitions', () {
    eachPair((c) {
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
    });
  });
  test('captured_transition_sequence', () {
    eachPair((c) {
      final out = <String>[];
      final ds = c.admitted('captured_transition_sequence');
      final types = [for (final d in ds) d.notificationType];
      for (final t in [
        'PROBLEM',
        'ACKNOWLEDGEMENT',
        'FLAPPINGSTART',
        'FLAPPINGEND',
        'DOWNTIMESTART',
        'DOWNTIMEEND',
        'RECOVERY',
      ]) {
        if (!types.contains(t)) out.add('no $t observation');
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
      final alert = states.isEmpty ? null : _alert(states.last);
      if (alert == null || alert['status'] != 'resolved') {
        out.add('the alert does not end resolved');
      }
      return out;
    });
  });

  // --- First problem -------------------------------------------------------------

  test('first_check_result_of_a_new_host_is_down', () {
    eachPair(firstProblemHosts);
  });
  test('volatile_host_with_no_state_change_yet', () {
    eachPair(firstProblemVolatile);
  });
  test('retained_state_across_a_restart', () {
    eachPair((c) {
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
    });
  });
  test('earlier_result_with_a_negative_execution_end', () {
    eachPair((c) {
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
    });
  });
  test('initialized_state_change_time_of_a_runtime_created_host', () {
    eachPair((c) {
      const file = 'initialized_state_change_time_of_a_runtime_created_host';
      final console = c.of(file, 'console').single;
      final now =
          (console.json['input']! as Map<String, Object?>)['now']! as int;
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
    });
  });
  test('time_outside_the_formatter_s_domain', () {
    eachPair((c) {
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
    });
  });

  // --- Shipped command ----------------------------------------------------------

  test('notification_from_a_real_icinga_2_in_both_auth_modes', () {
    eachPair(gateDelivery);
  });
  test('long_check_output', () {
    eachPair((c) {
      final d = c.admitted('long_check_output').first;
      final out = <String>[];
      if (!(d.body['output']! as String).endsWith(truncationMarker)) {
        out.add('delivered output lacks the marker');
      }
      // The stored description is cut again to the event's own bound, which
      // is shorter than the delivered text, and ends with Correlia's display
      // marker (an ellipsis).
      final stored = d.data()['description']! as String;
      if (!stored.endsWith('\u2026') || stored.runes.length > 8192) {
        out.add('stored description does not end with the display marker');
      }
      return out;
    });
  });
  test('recovery_output_with_dollar_signs', () {
    eachPair((c) {
      final d = c
          .admitted('recovery_output_with_dollar_signs')
          .firstWhere((x) => x.notificationType == 'RECOVERY');
      final text = d.body['output']! as String;
      return [
        if (!text.startsWith('OK: cost below \$5, see \$host.name\$'))
          'cut text',
        if (!text.endsWith(truncationMarker)) 'no marker',
        if (d.data()['status'] != 'EVENT_STATUS_RESOLVED') 'not resolved',
        ...recoveryApplied(c, 'recovery_output_with_dollar_signs', d),
      ];
    });
  });
  test('multibyte_character_across_the_cut', () {
    eachPair((c) {
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
    });
  });
  test('invalid_utf_8_in_check_output', () {
    eachPair((c) {
      final d = c.admitted('invalid_utf_8_in_check_output').single;
      final text = d.body['output']! as String;
      return [
        if (!text.contains('�')) 'no U+FFFD',
        if (!text.contains('still text') || !text.startsWith('bad '))
          'surrounding text changed',
        if (d.status != 202) 'not accepted',
      ];
    });
  });
  test('oversized_custom_notification', () {
    eachPair((c) {
      final ds = c.admitted('oversized_custom_notification');
      final custom = ds.singleWhere((d) => d.notificationType == 'CUSTOM');
      final states = c.of('oversized_custom_notification', 'state');
      return [
        if (custom.data()['kind'] != 'EVENT_KIND_COMMENT')
          'not a comment event',
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
    });
  });
  test('burst_of_verbose_notifications', () {
    eachPair((c) {
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
                        i.json['name'] ==
                        'seconds_from_last_result_to_last_body',
                  )
                  .json['value']!
              as num;
      if (seconds > 60) out.add('the last body took $seconds s');
      return out;
    });
  });
  test('runtime_options_in_icinga_s_environment', () {
    eachPair((c) {
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
    });
  });
  test('inherited_correlia_settings_are_ignored', () {
    eachPair((c) {
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
    });
  });
  test('name_with_an_embedded_nul_is_not_delivered', () {
    eachPair((c) {
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
        if (states.isEmpty || _alert(states.last)?['status'] != 'firing')
          'the db1 alert is not firing',
      ];
    });
  });
  test('oversized_or_invalid_name_is_not_delivered', () {
    eachPair((c) {
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
    });
  });

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
      if (failures[i].json['exit_code'] != 2 ||
          !detail.contains(arguments[i])) {
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

  test('a_refusal_scenario_without_its_scan_fails', () {
    final broken = copy();
    for (final (file, name) in [
      ('base_url_carrying_a_credential', 'secret'),
      ('multiline_settings', 'SECRET-MARKER'),
      ('source_that_is_not_a_uuid', 'token'),
    ]) {
      edit(
        broken,
        file,
        (r) => r.removeWhere((x) => x['kind'] == 'secret_scan'),
      );
      expect(
        refusals(Capture(broken), file, const [], scanned: [name]),
        contains('expected one secret scan, found 0'),
        reason: file,
      );
    }
  });

  test('setting_not_deliverable_exactly', () {
    eachPair((c) {
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
    });
  });
  test('nul_in_a_file_path', () {
    eachPair((c) {
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
    });
  });
  test('base_url_carrying_a_credential', () {
    eachPair(
      (c) => refusals(
        c,
        'base_url_carrying_a_credential',
        [
          '--base-url',
          '--base-url',
          '--base-url',
        ],
        scanned: ['secret'],
      ),
    );
  });
  test('multiline_settings', () {
    eachPair(
      (c) => refusals(
        c,
        'multiline_settings',
        [
          '--base-url',
          '--source',
        ],
        scanned: ['SECRET-MARKER'],
      ),
    );
  });
  test('source_that_is_not_a_uuid', () {
    eachPair(
      (c) => refusals(
        c,
        'source_that_is_not_a_uuid',
        ['--source'],
        scanned: ['token'],
      ),
    );
  });
  test('macro_text_in_a_setting_is_literal', () {
    eachPair((c) {
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
        if (ds.length == 2 &&
            ds.last.body['output'] != 'CRITICAL: dollar sender')
          'the dollar sender path delivered ${ds.last.body['output']}',
      ];
    });
  });
  test('nul_in_display_text', () {
    eachPair((c) {
      final d = c.admitted('nul_in_display_text').single;
      return [
        if (d.body['notification_comment'] != 'before�after')
          'comment ${d.body['notification_comment']}',
        if (d.body['notification_author'] != 'ali�ce')
          'author ${d.body['notification_author']}',
        if (d.status != 202) 'not accepted',
      ];
    });
  });
  test('rejected_delivery_leaves_no_secret_in_icinga_2_logs', () {
    eachPair((c) {
      const file = 'rejected_delivery_leaves_no_secret_in_icinga_2_logs';
      final rejected = c.of(file, 'rejected');
      final scans = c.of(file, 'secret_scan');
      return [
        if (rejected.length != 2 || rejected.any((r) => r.status != 401))
          'expected two 401 rejections',
        if (c.of(file, 'command_failure').length != 2) 'expected two failures',
        // Icinga 2's line holds the status, the texts and the file paths.
        for (final f in c.of(file, 'command_failure'))
          if (f.json['log'] case final String log
              when !log.contains('status 401') ||
                  !log.contains('"probe"') ||
                  !log.contains('/etc/icinga2/correlia/wrong-'))
            'the failure log lacks the status, a text or the file path',
        if (scans.length != 1) 'no secret scan',
        for (final s in scans) ...[
          if ((s.json['found']! as List<Object?>).isNotEmpty)
            'secrets in the log: ${s.json['found']}',
          // The rejected senders' own credentials, and each rejected
          // header both whole and as its bare token or digest.
          for (final name in [
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
    });
  });
  test('concurrent_signed_notifications_beyond_the_cap', () {
    // The deterministic overlap is proved by the e2e test of the same name;
    // this capture shows the shipped command under a real Icinga 2: three
    // signed notifications overlap, Correlia refuses one with 503 and admits
    // two, and Icinga 2 logs the refused command with its status.
    eachPair((c) {
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
    });
  });

  test('hostile_inherited_environment', () {
    eachPair((c) {
      const file = 'hostile_inherited_environment';
      Object? info(String name) => c
          .of(file, 'info')
          .firstWhere((i) => i.json['name'] == name)
          .json['value'];
      final failures = c.of(file, 'command_failure');
      return [
        if (c.admitted(file).length != 1)
          'the loopback delivery did not arrive',
        if (info('recording_listener_connections') != 0)
          'the recording listener received a connection',
        if (info('https_endpoint_requests') != 0)
          'the https endpoint received request bytes',
        if (failures.length != 1 || failures.single.json['exit_code'] == 0)
          'the https endpoint was not refused',
        if (info('key_log_file_exists') != false) 'a key log file exists',
      ];
    });
  });
  test(
    'non_state_notification_for_an_object_with_an_unusable_state_change_time',
    () {
      eachPair((c) {
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
          if (states.isEmpty || _alert(states.last) != null) 'an alert exists',
        ];
      });
    },
  );
  test('multiline_recovery_and_custom_notification_without_output', () {
    eachPair((c) {
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
        if (_alert(states[1])?['status'] != 'resolved') 'not resolved',
        ...firstProblemCustom(c),
      ];
    });
  });
  test('delayed_recovery_publishes_the_live_check_output', () {
    eachPair((c) {
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
    });
  });
}

const _begin = '<!-- icinga2-supported-releases:begin -->';
const _end = '<!-- icinga2-supported-releases:end -->';

Map<String, Object?>? _alert(Rec state) =>
    state.json['alert'] as Map<String, Object?>?;

/// The fingerprint of a host-only object of the capture's source.
String fingerprintOfHost(String host) => decodeOne(
  hostDelivery(set: {'host': host}),
  sourceInstance: matrixSource,
).fingerprint;
