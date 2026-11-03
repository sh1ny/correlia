import 'dart:io';

/// The tool versions the repository pins.
///
/// Versions for Flutter, Go, buf and OpenSpec come from `mise.toml`, the
/// Serverpod CLI version from the `correlia_server` pubspec. Dart is not a mise
/// tool: it is the SDK bundled with the pinned Flutter, so its version is the
/// constant [bundledDartVersion], which must change together with the Flutter
/// pin in `mise.toml`.
class Pins {
  /// Creates pins from an explicit table (tests, or [load]).
  const Pins(this.versions);

  /// Dart bundled with the pinned Flutter 3.47.9.
  static const bundledDartVersion = '3.13.7';

  /// Tool name to pinned version.
  final Map<String, String> versions;

  /// Reads the pins from the repository at [repoRoot].
  factory Pins.load(Directory repoRoot) {
    final mise = File('${repoRoot.path}/mise.toml').readAsStringSync();
    final pubspec = File(
      '${repoRoot.path}/correlia_server/pubspec.yaml',
    ).readAsStringSync();
    final versions = <String, String>{'dart': bundledDartVersion};
    for (final tool in ['flutter', 'go', 'buf']) {
      versions[tool] = _match(
        mise,
        RegExp('^$tool\\s*=\\s*"([^"]+)"', multiLine: true),
        tool,
      );
    }
    versions['openspec'] = _match(
      mise,
      RegExp(r'^"npm:@fission-ai/openspec"\s*=\s*"([^"]+)"', multiLine: true),
      'openspec',
    );
    versions['serverpod_cli'] = _match(
      pubspec,
      RegExp(r'^\s*serverpod_cli:\s*([\d.]+)\s*$', multiLine: true),
      'serverpod_cli',
    );
    return Pins(versions);
  }

  /// The pinned version of [tool].
  String versionOf(String tool) =>
      versions[tool] ?? (throw ArgumentError('No pin for $tool'));

  static String _match(String text, RegExp pattern, String tool) {
    final version = pattern.firstMatch(text)?.group(1);
    if (version == null) {
      throw StateError(
        'Cannot read the pinned version of $tool from the repository',
      );
    }
    return version;
  }
}
