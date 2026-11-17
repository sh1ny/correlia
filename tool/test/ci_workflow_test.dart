import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const _checkoutSha = '3d3c42e5aac5ba805825da76410c181273ba90b1';
const _miseSha = 'd5574b52816a478f9d4e6529a3f6ff17a8a36785';

File get _workflowFile =>
    File('${Directory.current.parent.path}/.github/workflows/ci.yml');

/// Reads the workflow as plain Dart maps and lists.
Map<String, Object?> _workflow() {
  final parsed = _plain(loadYaml(_workflowFile.readAsStringSync()));
  if (parsed is! Map<String, Object?>) {
    fail('ci.yml is not a mapping');
  }
  return parsed;
}

Object? _plain(Object? node) => switch (node) {
  YamlMap() => {
    for (final MapEntry(:key, :value) in node.entries)
      // YAML 1.1 parsers may read the key `on` as `true`.
      (key == true ? 'on' : '$key'): _plain(value),
  },
  YamlList() => [for (final item in node) _plain(item)],
  _ => node,
};

Map<String, Object?> _map(Object? value) {
  if (value is! Map<String, Object?>) fail('expected a mapping, got $value');
  return value;
}

Map<String, Object?> _job() {
  final jobs = _map(_workflow()['jobs']);
  expect(jobs, hasLength(1), reason: 'exactly one job');
  return _map(jobs.values.single);
}

List<Map<String, Object?>> _steps() {
  final steps = _job()['steps'];
  if (steps is! List<Object?>) fail('steps is not a list');
  return [for (final step in steps) _map(step)];
}

String? _run(Map<String, Object?> step) {
  final run = step['run'];
  return run is String ? run.trim() : null;
}

int _indexOfRun(List<Map<String, Object?>> steps, String command) {
  final matches = [
    for (var i = 0; i < steps.length; i++)
      if (_run(steps[i]) == command) i,
  ];
  expect(matches, hasLength(1), reason: 'one step runs exactly `$command`');
  return matches.single;
}

void main() {
  test('job_runs_check_then_test_all_on_pr_and_main', () {
    final workflow = _workflow();
    final on = _map(workflow['on']);
    expect(
      on.keys,
      unorderedEquals(['pull_request', 'push', 'workflow_dispatch']),
    );
    expect(_map(on['pull_request'])['branches'], ['main']);
    expect(_map(on['push'])['branches'], ['main']);
    expect(on, isNot(contains('pull_request_target')));

    final job = _job();
    expect(job['name'], 'Linux verification');
    expect(job['runs-on'], 'ubuntu-24.04');
    expect(job['timeout-minutes'], 60);

    final steps = _steps();
    final checkout = steps.indexWhere(
      (s) => '${s['uses']}'.startsWith('actions/checkout@'),
    );
    final mise = steps.indexWhere(
      (s) => '${s['uses']}'.startsWith('jdx/mise-action@'),
    );
    // A fresh Flutter SDK has no flutter.version.json until the `flutter`
    // command first runs; the first bare `dart` call cannot resolve the
    // workspace's Flutter package without it.
    final flutter = _indexOfRun(steps, 'mise exec -- flutter --version');
    final check = _indexOfRun(steps, 'mise run check');
    final testAll = _indexOfRun(steps, 'mise run test:all');
    expect(checkout, greaterThanOrEqualTo(0));
    expect(checkout, lessThan(mise));
    expect(mise, lessThan(flutter));
    expect(flutter, lessThan(check));
    expect(check, lessThan(testAll));
    for (final step in steps) {
      expect(step['name'], isA<String>(), reason: 'every step is named');
    }
  });

  test('gate_failure_fails_job_before_test_all', () {
    final steps = _steps();
    final check = steps[_indexOfRun(steps, 'mise run check')];
    final testAll = steps[_indexOfRun(steps, 'mise run test:all')];
    expect(check, isNot(contains('continue-on-error')));
    expect(check, isNot(contains('if')));
    // Without an `if`, a failed gate skips every later step.
    expect(testAll, isNot(contains('if')));
    expect(
      _indexOfRun(steps, 'mise run check'),
      lessThan(steps.indexOf(testAll)),
    );
  });

  test('test_all_failure_fails_job_and_load_never_runs', () {
    expect(_job(), isNot(contains('continue-on-error')));
    final steps = _steps();
    for (final step in steps) {
      expect(step, isNot(contains('continue-on-error')));
      final run = _run(step);
      if (run == null) continue;
      expect(run, isNot(contains('|| true')));
      expect(run, isNot(contains('load')));
    }
    final testAll = steps[_indexOfRun(steps, 'mise run test:all')];
    expect('${testAll['if']}', isNot(matches(RegExp('always|failure'))));
    expect(testAll, isNot(contains('if')));
    expect(_workflowFile.readAsStringSync(), isNot(contains('--tags')));
  });

  test('toolchain_comes_from_mise_with_pinned_actions', () {
    final steps = _steps();
    final sha = RegExp(r'^[\w.-]+/[\w.-]+@[0-9a-f]{40}$');
    final uses = [
      for (final step in steps)
        if (step['uses'] case final String value) value,
    ];
    expect(uses, hasLength(2), reason: 'only checkout and mise-action');
    for (final value in uses) {
      expect(value, matches(sha));
    }

    final checkout = steps.singleWhere(
      (s) => '${s['uses']}'.startsWith('actions/checkout@'),
    );
    expect(checkout['uses'], 'actions/checkout@$_checkoutSha');
    expect(_map(checkout['with'])['persist-credentials'], false);

    final mise = steps.singleWhere(
      (s) => '${s['uses']}'.startsWith('jdx/mise-action@'),
    );
    expect(mise['uses'], 'jdx/mise-action@$_miseSha');
    final with_ = _map(mise['with']);
    expect(with_['version'].toString(), '2026.11.8');
    expect(with_['install'], true);
    expect(with_['cache'], true);

    final trusted =
        [
          _workflow()['env'],
          _job()['env'],
        ].whereType<Map<String, Object?>>().map(
          (e) => e['MISE_TRUSTED_CONFIG_PATHS'],
        );
    expect(trusted, contains(r'${{ github.workspace }}'));
  });

  test('pr_runs_share_a_cancelling_group', () {
    final concurrency = _map(_workflow()['concurrency']);
    expect(
      concurrency['group'],
      r'ci-${{ github.event_name }}-${{ github.event.pull_request.number || github.run_id }}',
    );
    expect(concurrency['group'], contains('github.event.pull_request.number'));
    expect(
      concurrency['cancel-in-progress'],
      r"${{ github.event_name == 'pull_request' }}",
    );
  });

  test('main_pushes_get_unique_uncancelled_groups', () {
    final concurrency = _map(_workflow()['concurrency']);
    // Outside pull requests the PR number is empty, so the group falls back
    // to the run id, which is unique per run.
    expect(
      concurrency['group'],
      contains('github.event.pull_request.number || github.run_id'),
    );
    // Cancellation is only true when the event is a pull request.
    expect(
      concurrency['cancel-in-progress'],
      r"${{ github.event_name == 'pull_request' }}",
    );
  });

  test('token_is_read_only_without_secrets', () {
    expect(_workflow()['permissions'], {'contents': 'read'});
    expect(_job(), isNot(contains('permissions')));
    expect(_workflowFile.readAsStringSync(), isNot(contains('secrets.')));
  });

  test('user_namespaces_are_enabled_and_checked_before_test_tiers', () {
    // The plugin host's foreign-owner socket test starts its fixture under
    // `unshare --user --map-root-user --map-auto`; Ubuntu 24.04 runners
    // restrict unprivileged user namespaces through AppArmor by default.
    final steps = _steps();
    final userns = steps.indexWhere((step) {
      final run = _run(step);
      return run != null &&
          run.contains(
            'sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0',
          ) &&
          run.contains('unshare --user --map-root-user --map-auto -- true');
    });
    expect(userns, greaterThanOrEqualTo(0));
    expect(userns, lessThan(_indexOfRun(steps, 'mise run test:all')));
  });
}
