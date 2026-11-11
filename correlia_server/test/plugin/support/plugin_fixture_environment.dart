import 'dart:io';

import 'plugin_fixture_suite.dart';

/// The explicit environment for a stock plugin fixture launch.
///
/// The fixture inherits only the host contract values selected by the test.
/// The go-plugin transport-specific variables are supplied separately by the
/// caller when required.
final class PluginFixtureEnvironment {
  /// Creates a fixture environment.
  PluginFixtureEnvironment({
    required this.cookieKey,
    required this.cookieValue,
    required this.protocolVersions,
    this.clientCertificatePem,
    this.unixSocketDirectory,
  });

  /// The magic-cookie environment variable name.
  final String cookieKey;

  /// The magic-cookie environment variable value.
  final String cookieValue;

  /// The comma-separated application protocol versions.
  final String protocolVersions;

  /// The optional PEM client certificate used by stock AutoMTLS.
  final String? clientCertificatePem;

  /// The optional owner-only directory for the stock Unix socket.
  final String? unixSocketDirectory;

  /// Serializes the environment for [Process.start].
  Map<String, String> toEnvironment() => <String, String>{
    cookieKey: cookieValue,
    'PLUGIN_PROTOCOL_VERSIONS': protocolVersions,
    if (clientCertificatePem case final String certificate)
      'PLUGIN_CLIENT_CERT': certificate,
    if (unixSocketDirectory case final String directory)
      'PLUGIN_UNIX_SOCKET_DIR': directory,
  };

  /// Creates the standard environment for this spike.
  static PluginFixtureEnvironment standard({
    required PluginFixtureSuite suite,
    String? clientCertificatePem,
  }) => PluginFixtureEnvironment(
    cookieKey: 'CORRELIA_PLUGIN_COOKIE',
    cookieValue: 'correlia-plugin-host-spike',
    protocolVersions: '1',
    clientCertificatePem: clientCertificatePem,
    unixSocketDirectory: suite.scratchDirectory.path,
  );
}
