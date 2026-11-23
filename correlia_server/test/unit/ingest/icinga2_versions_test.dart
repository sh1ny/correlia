import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../../support/icinga2_matrix.dart';
import '../../support/icinga2_scenarios.dart';

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

  /// Fails unless [failures] names [pair] and [gate], and, with [only], no
  /// gate other than [gate] and [Gate.scenario].
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
      // A synthetic edit may also break the scenario checks that read the
      // edited file; no other gate may fail.
      expect(
        {
          for (final f in failures)
            if (f.gate != Gate.scenario) f.gate,
        },
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
    // The foreign file is made from this pair's own, so a statement listing
    // one release proves it too.
    const foreign = '2.0.0';
    final names = Capture(baseline()).names;
    expect(evaluatePair(copy()), isEmpty);
    for (final name in names) {
      final broken = copy();
      final file = File('${broken.directory.path}/$name.json');
      final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      file.writeAsStringSync(jsonEncode({...json, 'release': foreign}));
      expect(
        evaluatePair(broken).join('\n'),
        contains('$name.json declares $foreign/'),
        reason: '$name from $foreign',
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

  test('publication_runs_every_scenario_check', () {
    // The publisher qualifies a pair only on everything this test file checks
    // of its captures: each scenario's file and each scenario's check.
    expect([
      for (final name in captureScenarios)
        if (!scenarioChecks.containsKey(name)) name,
    ], isEmpty);
    expect(qualifiedBundles([copy()]).qualified.keys, contains('linux-x64'));
    final missing = copy();
    File(
      '${missing.directory.path}/captured_host_transitions.json',
    ).deleteSync();
    final noFile = qualifiedBundles([missing]);
    expect(noFile.qualified, isEmpty);
    expect(
      evaluatePair(missing).join('\n'),
      contains('no captured_host_transitions.json capture'),
    );
    final keyLog = copy();
    edit(keyLog, 'hostile_inherited_environment', (r) {
      r.firstWhere(
        (x) => x['kind'] == 'info' && x['name'] == 'key_log_file_exists',
      )['value'] = true;
    });
    final failures = evaluatePair(keyLog);
    expect(failures.map((f) => f.gate).toSet(), {Gate.scenario});
    expect(
      failures.join('\n'),
      contains('hostile_inherited_environment: a key log file exists'),
    );
    expect(qualifiedBundles([keyLog]).qualified, isEmpty);
  });

  test('long_description_above_the_display_bound_fails', () {
    // A stored description longer than the display bound, even one ending in
    // the display marker, is not the scenario's second cut.
    final broken = copy();
    edit(broken, 'long_check_output', (r) {
      final d = r.firstWhere((x) => x['kind'] == 'admitted');
      final cloud =
          ((d['events']! as List<Object?>).first!
                  as Map<String, Object?>)['cloud_event']!
              as Map<String, Object?>;
      (cloud['data']! as Map<String, Object?>)['description'] =
          '${'x' * 5999}\u2026';
    });
    expect(
      scenarioChecks['long_check_output']!(Capture(broken)),
      [contains('stored description is 6000 scalars')],
    );
    expect(
      qualifiedBundles([broken]).qualified,
      isEmpty,
    );
  });

  test('oversized_custom_event_without_its_texts_fails', () {
    // The delivered texts are cut and marked, but the stored comment event
    // publishes neither the comment nor the author.
    final broken = copy();
    edit(broken, 'oversized_custom_notification', (r) {
      final custom = r.singleWhere(
        (x) => x['kind'] == 'admitted' && Rec(x).notificationType == 'CUSTOM',
      );
      final data = Rec(custom).data();
      data.remove('description');
      (data['annotations']! as Map<String, Object?>).remove(
        'icinga2.notification_author',
      );
    });
    expect(scenarioChecks['oversized_custom_notification']!(Capture(broken)), [
      contains('stored description'),
      contains('stored author annotation'),
    ]);
    expect(qualifiedBundles([broken]).qualified, isEmpty);
  });

  test('capture_file_of_another_bundle_fails', () {
    // An earlier capture of the same pair and scenario, made with another
    // sender or other definitions, restored beside the new manifest.
    for (final field in ['sender_sha256', 'contrib_sha256']) {
      final broken = copy();
      final f = File('${broken.directory.path}/long_check_output.json');
      final json = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
      json[field] = field == 'sender_sha256'
          ? '0' * 64
          : {
              ...(json[field]! as Map<String, Object?>),
              'correlia-commands.conf': '0' * 64,
            };
      f.writeAsStringSync(jsonEncode(json));
      expectNamed(
        evaluatePair(broken),
        broken,
        Gate.manifest,
        mentions: 'long_check_output.json was made with sender',
        only: true,
      );
      expect(qualifiedBundles([broken]).qualified, isEmpty);
    }
  });

  test('burst_body_that_is_no_hard_critical_problem_fails', () {
    // The recording endpoint answers 202 without decoding: a burst body of
    // another type, or one that does not decode, still has a burst service
    // name and an exactly cut output.
    final broken = copy();
    edit(broken, 'burst_of_verbose_notifications', (r) {
      final bodies = r.where((x) => x['kind'] == 'recorder_only').toList();
      setBody(bodies[0], 'notification_type', 'RECOVERY');
      setBody(bodies[1], 'format', 'correlia.icinga2.v0');
    });
    final failures = scenarioChecks['burst_of_verbose_notifications']!(
      Capture(broken),
    );
    expect(failures, [
      contains('not a HARD CRITICAL PROBLEM'),
      contains('does not decode'),
    ]);
    expect(qualifiedBundles([broken]).qualified, isEmpty);
  });

  test('delayed_recovery_deduplicated_against_the_initial_problem_fails', () {
    // The recovery carries the initial problem's state change time and is
    // its duplicate, while the refire publishes an event of its own: still
    // one event and one duplicate, both CRITICAL text.
    final broken = copy();
    edit(broken, 'delayed_recovery_publishes_the_live_check_output', (r) {
      final admitted = r.where((x) => x['kind'] == 'admitted').toList();
      final initial = admitted.first;
      final recovery = admitted.singleWhere(
        (x) => Rec(x).notificationType == 'RECOVERY',
      );
      final refire = admitted.lastWhere(
        (x) => Rec(x).notificationType == 'PROBLEM',
      );
      final published = [recovery, refire].firstWhere(
        (x) => Rec(x).events.isNotEmpty,
      );
      if (!identical(published, refire)) {
        refire['events'] = published['events'];
        refire['raw'] = {
          ...Rec(refire).raw,
          'outcome': {...Rec(published).outcome},
        };
      }
      setBody(
        recovery,
        'last_state_change',
        Rec(initial).body['last_state_change'],
      );
      recovery['events'] = <Object?>[];
      recovery['raw'] = {
        ...Rec(recovery).raw,
        'outcome': {...Rec(recovery).outcome, 'duplicate_observation': 1},
      };
      syncEvent(refire);
    });
    final failures =
        scenarioChecks['delayed_recovery_publishes_the_live_check_output']!(
          Capture(broken),
        );
    expect(
      failures,
      contains(contains('the recovery and the refire decode to different')),
    );
    expect(qualifiedBundles([broken]).qualified, isEmpty);
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
      // The whole pair was recaptured with that bundle: its evidence files
      // name it too.
      for (final f in second.directory.listSync().whereType<File>()) {
        if (f.path.endsWith('manifest.json')) continue;
        final evidence =
            jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
        evidence[field] = json[field];
        f.writeAsStringSync(jsonEncode(evidence));
      }
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
      // Its reminders repeat that observation, so they still decode as its
      // duplicates.
      for (final reminder in hostRecords(r, 'fp-runtime').skip(1)) {
        setBody(reminder, 'last_state_change', start.toStringAsFixed(6));
      }
    });
    expectNamed(
      evaluatePair(broken),
      broken,
      Gate.firstProblem,
      mentions: 'daemon start time',
      only: true,
    );
  });

  test('new_service_sending_its_initial_state_change_time_fails', () {
    // A service helper that always took last_state_change would send the
    // service's initializer instead of its first UNKNOWN result's execution
    // end; its reminders repeat that value, so they still decode as its
    // duplicates.
    final broken = copy();
    edit(broken, firstServiceFile, (r) {
      const initial = '1700000000.000000';
      final deliveries = [
        for (final x in r)
          if (x['kind'] == 'admitted' && Rec(x).body['service'] == 'fp-service')
            x,
      ];
      for (final d in deliveries) {
        setBody(d, 'last_state_change', initial);
      }
      syncEvent(deliveries.first);
    });
    expectNamed(
      evaluatePair(broken),
      broken,
      Gate.firstProblem,
      mentions: 'the driver recorded',
      only: true,
    );
  });

  test('reminder_of_a_first_problem_is_a_new_observation', () {
    final broken = copy();
    edit(broken, 'first_check_result_of_a_new_host_is_down', (r) {
      final reminder = hostRecords(r, 'fp-startup').last;
      setBody(reminder, 'last_state_change', '1700000001.000001');
    });
    final failures = evaluatePair(broken);
    expectNamed(
      failures,
      broken,
      Gate.firstProblem,
      mentions: 'different event id',
    );
    // Counted as a duplicate, it repeats no stored observation either.
    expectNamed(
      failures,
      broken,
      Gate.decode,
      mentions: 'a duplicate of no earlier stored observation',
    );
    expect(failures.map((f) => f.gate).toSet(), {
      Gate.firstProblem,
      Gate.decode,
      Gate.scenario,
    });
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
      Gate.scenario,
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

  // Each captured scenario's own check, which publication runs too.
  for (final MapEntry(key: name, value: check) in scenarioChecks.entries) {
    test(name, () => eachPair(check));
  }

  test('downtime_removal_of_another_object_fails_its_gate', () {
    // Each removal must be of the service whose alert snapshots are compared:
    // a routed downtime event for another service proves nothing of it.
    for (final field in ['service', 'host']) {
      final broken = copy();
      edit(broken, 'captured_downtime_removal', (r) {
        final removal = r.firstWhere(
          (x) =>
              x['kind'] == 'admitted' &&
              removalTypes.contains(Rec(x).notificationType) &&
              Rec(x).body['notification_comment'] == downtimeRemoved,
        );
        setBody(removal, field, 'elsewhere');
        syncEvent(removal);
      });
      expectNamed(
        evaluatePair(broken),
        broken,
        Gate.downtime,
        mentions: 'not the compared',
        only: true,
      );
    }
  });

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
  test('acknowledgement_counted_as_a_duplicate_fails_the_sequence', () {
    // Each named type needs an observation that was stored: an
    // acknowledgement counted as a duplicate of nothing is no acknowledgement.
    final broken = copy();
    edit(broken, 'captured_transition_sequence', (r) {
      final ack = r.firstWhere(
        (x) =>
            x['kind'] == 'admitted' &&
            Rec(x).notificationType == 'ACKNOWLEDGEMENT',
      );
      ack['events'] = <Object?>[];
      ((ack['raw']! as Map<String, Object?>)['outcome']!
            as Map<String, Object?>)
        ..['committed'] = 0
        ..['duplicate_observation'] = 1;
    });
    expect(
      transitionSequence(Capture(broken)),
      contains('no stored ACKNOWLEDGEMENT observation'),
    );
    expectNamed(
      evaluatePair(broken),
      broken,
      Gate.decode,
      mentions: 'a duplicate of no earlier stored observation',
      only: true,
    );
  });

  // --- First problem -------------------------------------------------------------

  // --- Shipped command ----------------------------------------------------------

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

  test('rejected_delivery_without_its_log_or_marker_fails', () {
    // The scenario holds only when both of Icinga 2's failure lines were read
    // and the scan looked for the rejection body's marker.
    const file = 'rejected_delivery_leaves_no_secret_in_icinga_2_logs';
    final noLog = copy();
    edit(noLog, file, (r) {
      r.firstWhere((x) => x['kind'] == 'command_failure').remove('log');
    });
    expect(
      rejectedDelivery(Capture(noLog)),
      contains('a failure without its Icinga 2 log line'),
    );
    final noMarker = copy();
    edit(noMarker, file, (r) {
      (r.firstWhere((x) => x['kind'] == 'secret_scan')['checked']!
              as List<Object?>)
          .remove('marker');
    });
    expect(
      rejectedDelivery(Capture(noMarker)),
      contains('the scan did not check marker'),
    );
  });
}

const _begin = '<!-- icinga2-supported-releases:begin -->';
const _end = '<!-- icinga2-supported-releases:end -->';
