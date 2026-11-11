import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'plugin_fixture_process.dart';

/// Maximum retained plugin diagnostic bytes.
///
/// The plugin process drains both standard streams continuously. Only this
/// bounded tail is retained for failure messages.
const int pluginDiagnosticTailBytes = 64 * 1024;

/// Maximum size of one control frame in either direction.
const int pluginControlFrameBytes = 8 * 1024;

/// Maximum size of the acceptance journal.
const int pluginJournalMaxBytes = 32 * 1024 * 1024;

/// A suite-owned set of built plugin fixtures and their scratch files.
///
/// One instance represents one test suite. [build] serializes fixture builds
/// and can safely be called from concurrent test groups; the binaries are
/// built once and reused by every launch in the suite.
final class PluginFixtureSuite {
  PluginFixtureSuite._(this._root, this._binaries, this._build, this._children);

  /// Creates a suite with an owner-only scratch directory.
  ///
  /// The directory is created beneath the system temporary directory because
  /// it contains ephemeral private keys and process-owned sockets.
  factory PluginFixtureSuite.create() {
    // mktemp creates mode 0700 atomically, independent of the caller's umask.
    final created = Process.runSync('mktemp', [
      '-d',
      '${Directory.systemTemp.path}/correlia-plugin-fixture-XXXXXXXX',
    ]);
    if (created.exitCode != 0) {
      throw StateError(
        'private fixture directory creation failed: ${created.stderr}',
      );
    }
    final root = Directory((created.stdout as String).trim());
    _requireOwnerOnlyDirectory(root);
    final binaries = <PluginFixtureBinary, File>{};
    return PluginFixtureSuite._(
      root,
      binaries,
      _BuildState(),
      <PluginFixtureProcess>[],
    );
  }

  final Directory _root;
  final Map<PluginFixtureBinary, File> _binaries;
  final _BuildState _build;
  final List<PluginFixtureProcess> _children;

  /// The suite-owned scratch directory.
  Directory get scratchDirectory => _root;

  /// The owner-only directory containing generated client credentials.
  Directory get credentialsDirectory =>
      Directory(p.join(_root.path, 'credentials'));

  /// The journal shared by all receiver processes in this suite.
  File get journalFile => File(p.join(_root.path, 'accepted-events.jsonl'));

  /// The Unix control socket used by the pre-ack barrier.
  File get controlSocketFile => File(p.join(_root.path, 'barrier.sock'));

  /// The distinct stdin-EOF cause marker.
  File get eofMarkerFile => File(p.join(_root.path, 'stdin-eof.marker'));

  /// Builds all fixture binaries once for this suite.
  ///
  /// Go commands run through the pinned mise toolchain. Build output and
  /// errors are bounded and retained in the returned diagnostic tail.
  Future<PluginFixtureBuild> build({
    Duration timeout = const Duration(seconds: 120),
  }) async {
    if (_build.completer case final Completer<PluginFixtureBuild> completer) {
      return completer.future;
    }

    final completer = Completer<PluginFixtureBuild>();
    _build.completer = completer;
    try {
      final result = await _buildAll(timeout);
      completer.complete(result);
    } on Object catch (error, stackTrace) {
      _build.completer = null;
      completer.completeError(error, stackTrace);
    }
    return completer.future;
  }

  Future<PluginFixtureBuild> _buildAll(Duration timeout) async {
    final moduleDirectory = p.join(
      Directory.current.path,
      'test',
      'plugin',
      'fixtures',
      'go',
    );
    final outputDirectory = Directory(p.join(_root.path, 'bin'))
      ..createSync(recursive: true);

    final result = await runBoundedProcess(
      'mise',
      [
        'exec',
        '--',
        'go',
        'build',
        '-trimpath',
        '-o',
        '${outputDirectory.path}${p.separator}',
        './cmd/...',
      ],
      workingDirectory: moduleDirectory,
      timeout: timeout,
    );
    _requireSuccess(result, 'plugin fixtures');
    _binaries[PluginFixtureBinary.plainStock] = File(
      p.join(outputDirectory.path, 'plain-stock'),
    );
    _binaries[PluginFixtureBinary.stdinWatched] = File(
      p.join(outputDirectory.path, 'stdin-watched'),
    );
    _binaries[PluginFixtureBinary.credentialHelper] = File(
      p.join(outputDirectory.path, 'credential-helper'),
    );

    return PluginFixtureBuild(
      binaries: Map.unmodifiable(_binaries),
      diagnostics: result.diagnostics,
    );
  }

  /// Generates an ephemeral P-521 client identity in owner-only storage.
  ///
  /// The helper is original test-only code and does not provide production
  /// certificate issuance.
  Future<PluginFixtureCredentials> createCredentials({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    await build();
    final helper = _binaries[PluginFixtureBinary.credentialHelper];
    if (helper == null) {
      throw StateError('the credential helper was not built');
    }

    final outputDirectory = credentialsDirectory;
    final result = await runBoundedProcess(
      helper.path,
      ['--output-dir', outputDirectory.path],
      workingDirectory: _root.path,
      timeout: timeout,
    );
    if (result.exitCode != 0) {
      throw StateError(
        'credential helper failed with ${result.exitCode}: '
        '${result.diagnostics}',
      );
    }

    _requireOwnerOnlyDirectory(outputDirectory);
    final manifestFile = File(p.join(outputDirectory.path, 'credentials.json'));
    final manifest = jsonDecode(await manifestFile.readAsString());
    if (manifest is! Map<String, Object?>) {
      throw const FormatException('credential manifest is not an object');
    }
    final certificatePath = manifest['certificate'];
    final privateKeyPath = manifest['private_key'];
    if (certificatePath is! String || privateKeyPath is! String) {
      throw const FormatException('credential manifest is incomplete');
    }
    final certificate = File(certificatePath);
    final privateKey = File(privateKeyPath);
    _requireOwnerOnlyFile(certificate);
    _requireOwnerOnlyFile(privateKey);
    _requireOwnerOnlyFile(manifestFile);
    return PluginFixtureCredentials(
      certificate: certificate,
      privateKey: privateKey,
    );
  }

  /// Registers a child process for suite-owned cleanup.
  void registerChild(PluginFixtureProcess child) {
    _children.add(child);
  }

  /// Removes all files and child processes owned by this suite.
  ///
  /// Cleanup signals only captured PID and start-time identities. The
  /// deletion is restricted to the exact suite-owned scratch directory.
  Future<void> dispose() async {
    for (final child in _children.reversed) {
      await child.stop();
    }
    _children.clear();
    if (_root.existsSync()) {
      await _root.delete(recursive: true);
    }
  }

  static void _requireSuccess(
    BoundedProcessResult result,
    String fixtureName,
  ) {
    if (result.exitCode != 0) {
      throw StateError(
        '$fixtureName build failed with ${result.exitCode}: '
        '${result.diagnostics}',
      );
    }
  }
}

/// The fixture executables owned by a plugin suite.
enum PluginFixtureBinary {
  /// The plain stock go-plugin executable.
  plainStock,

  /// The stdin-watched go-plugin executable.
  stdinWatched,

  /// The ephemeral credential helper.
  credentialHelper,
}

/// The result of building the fixture binaries once per suite.
final class PluginFixtureBuild {
  /// Creates a build result.
  PluginFixtureBuild({
    required Map<PluginFixtureBinary, File> binaries,
    required this.diagnostics,
  }) : binaries = Map.unmodifiable(binaries);

  /// The built binaries.
  final Map<PluginFixtureBinary, File> binaries;

  /// The bounded build diagnostic tail.
  final String diagnostics;
}

/// An ephemeral client identity used by a plugin test.
final class PluginFixtureCredentials {
  /// Creates a credential pair.
  PluginFixtureCredentials({
    required this.certificate,
    required this.privateKey,
  });

  /// The PEM-encoded client certificate.
  final File certificate;

  /// The PEM-encoded private key.
  final File privateKey;
}

/// A bounded subprocess result.
final class BoundedProcessResult {
  /// Creates a bounded process result.
  BoundedProcessResult({
    required this.exitCode,
    required this.diagnostics,
  });

  /// The process exit code.
  final int exitCode;

  /// The retained diagnostic tail.
  final String diagnostics;
}

final class _BuildState {
  Completer<PluginFixtureBuild>? completer;
}

/// Runs a process while draining and bounding its diagnostic output.
///
/// Standard output and standard error are combined into a bounded tail. The
/// process cannot block on a full pipe, and only the last
/// [pluginDiagnosticTailBytes] are retained.
Future<BoundedProcessResult> runBoundedProcess(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Duration timeout = const Duration(seconds: 30),
  Map<String, String>? environment,
}) async {
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
  );
  final diagnostics = _BoundedDiagnostics(pluginDiagnosticTailBytes);
  final outputDone = diagnostics.consume(process.stdout);
  final errorDone = diagnostics.consume(process.stderr);

  try {
    final exitCode = await process.exitCode.timeout(timeout);
    await Future.wait([outputDone, errorDone]);
    return BoundedProcessResult(
      exitCode: exitCode,
      diagnostics: diagnostics.text,
    );
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
    await Future.wait([outputDone, errorDone]);
    throw TimeoutException(
      '$executable exceeded $timeout',
      timeout,
    );
  }
}

final class _BoundedDiagnostics {
  _BoundedDiagnostics(this.maximumBytes);

  final int maximumBytes;
  final List<int> _bytes = <int>[];
  int _totalBytes = 0;

  Future<void> consume(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      _totalBytes += chunk.length;
      _bytes.addAll(chunk);
      final excess = _bytes.length - maximumBytes;
      if (excess > 0) _bytes.removeRange(0, excess);
    }
  }

  String get text {
    final suffix = _totalBytes > _bytes.length
        ? '\n[diagnostics truncated]\n'
        : '';
    return '${utf8.decode(_bytes, allowMalformed: true)}$suffix';
  }
}

void _requireOwnerOnlyDirectory(Directory directory) {
  final stat = directory.statSync();
  if ((stat.mode & 0x03f) != 0) {
    throw StateError(
      '${directory.path} is accessible by group or other; mode ${stat.mode.toRadixString(8)}',
    );
  }
}

void _requireOwnerOnlyFile(File file) {
  final stat = file.statSync();
  if ((stat.mode & 0x03f) != 0) {
    throw StateError(
      '${file.path} is accessible by group or other; mode ${stat.mode.toRadixString(8)}',
    );
  }
}
