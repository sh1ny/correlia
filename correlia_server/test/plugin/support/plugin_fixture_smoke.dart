import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'plugin_fixture_suite.dart';

/// A bounded diagnostic sink for a launched fixture.
///
/// Standard output and standard error are drained continuously so a noisy
/// child cannot block. Only the configured tail is retained.
final class PluginFixtureDiagnostics {
  PluginFixtureDiagnostics._(this._tail);

  /// The maximum retained bytes.
  static const int defaultMaximumBytes = 64 * 1024;

  /// Starts consuming a fixture's standard streams.
  static PluginFixtureDiagnostics consume(Process process) {
    final diagnostics = PluginFixtureDiagnostics._(
      _BoundedTail(defaultMaximumBytes),
    );
    unawaited(diagnostics._tail.consume(process.stdout));
    unawaited(diagnostics._tail.consume(process.stderr));
    return diagnostics;
  }

  final _BoundedTail _tail;

  /// The retained diagnostic text.
  String get text => _tail.text;
}

final class _BoundedTail {
  _BoundedTail(this.maximumBytes);

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

/// Builds the fixture suite and creates a throwaway credential identity.
///
/// This helper exists for the fixture foundation check. It uses the same
/// suite-owned build and cleanup APIs as later plugin tests.
Future<void> verifyPluginFixtureSuite({
  PluginFixtureSuite? suite,
  Duration timeout = const Duration(seconds: 120),
}) async {
  final ownedSuite = suite ?? PluginFixtureSuite.create();
  try {
    final build = await ownedSuite.build(timeout: timeout);
    final credentials = await ownedSuite.createCredentials(
      timeout: timeout,
    );
    if (!credentials.certificate.existsSync() ||
        !credentials.privateKey.existsSync()) {
      throw StateError('credential helper did not create its identity');
    }
    if (build.binaries.length != PluginFixtureBinary.values.length) {
      throw StateError('the suite did not build every fixture binary');
    }
  } finally {
    if (suite == null) await ownedSuite.dispose();
  }
}
