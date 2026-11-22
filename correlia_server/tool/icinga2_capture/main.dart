/// Captures real Icinga 2 notifications for one release (task 9.1).
///
/// Run through `tool/icinga2_capture.sh`, which checks for the built sender, picks the
/// image and cleans up. This driver starts a real Correlia child on the shared
/// embedded cluster, installs the built sender and the shipped definitions into
/// the official image the way an operator would, drives each capture scenario
/// through Icinga 2's REST API, and writes evidence under
/// `<out>/<release>/linux-x64/`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import '../../test/support/icinga2_matrix.dart' show captureScenarios;
import 'bundle.dart';
import 'config.dart';
import 'evidence.dart';
import 'lab.dart';
import 'rig.dart';
import 'scenarios.dart';
import 'staging.dart';

/// Bumped when the evidence format or the scenario set changes.
const scriptVersion = '14';

/// Scenarios that rely on objects another scenario prepared, with that
/// scenario: a partial run must select both.
const prerequisites = {
  'retained_state_across_a_restart': 'first_check_result_of_a_new_host_is_down',
  'macro_text_in_a_setting_is_literal':
      'runtime_options_in_icinga_s_environment',
};

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('release', mandatory: true)
    ..addOption('image', mandatory: true)
    ..addOption(
      'image-id',
      mandatory: true,
      help: 'the inspected image ID, which the container runs',
    )
    ..addOption('image-platform', mandatory: true)
    ..addOption('digest', defaultsTo: '')
    ..addOption('container', mandatory: true)
    ..addOption('api-port', mandatory: true)
    ..addOption('out', mandatory: true)
    ..addOption('sender', mandatory: true)
    ..addOption('contrib', mandatory: true)
    ..addOption('only', help: 'comma separated scenario names');
  final args = parser.parse(arguments);
  final release = args.option('release')!;
  final target = Directory('${args.option('out')}/$release/linux-x64');
  // One capture of a pair at a time, written apart and put in place whole:
  // the pair directory then holds one run's records with that run's manifest.
  if (lockPair(target) == null) {
    stderr.writeln('another capture of $release/linux-x64 is running');
    exit(2);
  }
  final out = openStaging(target, keep: args.option('only') != null);
  // Read once: the hashes, the installed files and the settings are these
  // bytes.
  final bundle = CaptureBundle.read(
    File(args.option('sender')!),
    Directory(args.option('contrib')!),
  );
  // The inputs every capture file of a manifest was made with.
  final inputs = <String, Object?>{
    'script_version': scriptVersion,
    'image_digest': args.option('digest'),
    'image_id': args.option('image-id'),
    'image_platform': args.option('image-platform'),
    'sender_sha256': bundle.senderSha256,
    'contrib_sha256': bundle.contribSha256,
  };
  final only = args.option('only')?.split(',').toSet();
  // A partial recapture keeps the other captures, so it must run with exactly
  // the inputs that made them: otherwise the manifest would vouch for an
  // artifact that never ran the kept scenarios.
  var previouslyFailed = <String>[];
  if (only != null) {
    // A scenario that relies on objects an earlier scenario prepared needs
    // that scenario in the same run: alone it would wait for state that a
    // fresh lab never reaches and overwrite good evidence with a failure.
    final missing = [
      for (final MapEntry(key: scenario, value: needs) in prerequisites.entries)
        if (only.contains(scenario) && !only.contains(needs))
          '$scenario needs $needs',
    ];
    if (missing.isNotEmpty) {
      stderr.writeln('incomplete selection: ${missing.join('; ')}');
      exit(2);
    }
    // A partial run only refreshes scenarios of the complete run it extends,
    // each of which left its evidence file; a misspelled name would match no
    // scenario and leave the run looking successful.
    final unknown = [
      for (final name in only)
        if (name == 'manifest' || !File('${out.path}/$name.json').existsSync())
          name,
    ]..sort();
    if (unknown.isNotEmpty) {
      stderr.writeln('unknown scenarios: ${unknown.join(', ')}');
      exit(2);
    }
    final file = File('${out.path}/manifest.json');
    final previous = file.existsSync()
        ? jsonDecode(file.readAsStringSync()) as Map<String, Object?>
        : null;
    final changed = [
      if (previous == null)
        'no manifest of a complete run'
      else
        for (final MapEntry(:key, :value) in inputs.entries)
          if (jsonEncode(previous[key]) != jsonEncode(value)) key,
    ];
    if (changed.isNotEmpty) {
      stderr.writeln(
        'a partial recapture needs the inputs of the complete run; '
        'changed: ${changed.join(', ')}. Run every scenario instead.',
      );
      exit(2);
    }
    previouslyFailed = [
      for (final name in previous!['failed_scenarios']! as List<Object?>)
        if (!only.contains(name)) name! as String,
    ];
  }
  final lab = IcingaLab(
    image: args.option('image-id')!,
    name: args.option('container')!,
    apiPort: int.parse(args.option('api-port')!),
  );
  CorreliaRig? rig;
  var failed = <String>[];
  // What the kernel reports inside the container: x86_64 unless emulated.
  String? machine;
  try {
    rig = await CorreliaRig.start();
    await rig.startListeners();
    await lab.create();
    await lab.install(bundle);

    final s = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final config = CaptureConfig(
      serviceClock: timeText(s, 234561),
      hostClock: timeText(s, 345672),
      longName: 'n' * 1025,
    );
    await lab.writeCaptureConfig(config.render());
    final shipped = bundle.shippedSettings;
    final capture = Capture(rig: rig, lab: lab, out: out, shipped: shipped);

    final run = Scenarios(
      capture,
      release: release,
      config: config,
      only: only,
    );
    await run.installCredentials();
    await run.useSettings();
    await lab.start();
    stdout.writeln('icinga2 ${await lab.version()} running as ${lab.name}');
    machine = (await lab.exec(['uname', '-m'])).out.trim();
    await run.all();
    failed = [...previouslyFailed, ...capture.failed];
    // The run's files are the scenario set the matrix requires: a scenario
    // that wrote no file, or a file of no listed scenario, fails the run.
    final written = {
      for (final f in out.listSync().whereType<File>())
        if (f.path.endsWith('.json') && !f.path.endsWith('/manifest.json'))
          f.uri.pathSegments.last.replaceAll('.json', ''),
    };
    final required = captureScenarios.toSet();
    failed.addAll([
      for (final name in required.difference(written)) 'no file: $name',
      for (final name in written.difference(required)) 'not listed: $name',
    ]);

    final manifest = {
      'script_version': inputs['script_version'],
      'release': release,
      'architecture': captureArchitecture,
      'image': args.option('image'),
      'image_digest': inputs['image_digest'],
      'image_id': inputs['image_id'],
      'image_platform': inputs['image_platform'],
      'container_machine': machine,
      'icinga_version': await lab.version(),
      'sender_sha256': inputs['sender_sha256'],
      'contrib_sha256': inputs['contrib_sha256'],
      'source': captureSource,
      'namespace': captureSource,
      'failed_scenarios': failed,
    };
    File('${out.path}/manifest.json').writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
    );
    publishStaging(out, target);
  } finally {
    try {
      await lab.stop();
    } on Object {
      // The container is removed next whatever the daemon did.
    }
    await lab.remove();
    try {
      await rig?.dispose().timeout(const Duration(seconds: 60));
    } on TimeoutException {
      stderr.writeln('the database teardown did not finish; exiting anyway');
    }
  }
  if (failed.isNotEmpty) {
    stderr.writeln('scenarios that did not complete: ${failed.join(', ')}');
    exitCode = 1;
  }
  // Nothing else of this run is wanted; do not wait for lingering handles.
  exit(exitCode);
}
