import 'dart:io';

import 'plugin_fixture_suite.dart';

/// The client identity passed to a stock go-plugin AutoMTLS launch.
///
/// The certificate is self-signed, P-521, and valid for client
/// authentication. The private key never leaves the owner-only scratch
/// directory.
final class PluginFixtureIdentity {
  /// Creates an identity from suite-owned files.
  PluginFixtureIdentity({
    required this.certificate,
    required this.privateKey,
  });

  /// The PEM certificate file.
  final File certificate;

  /// The PEM private-key file.
  final File privateKey;

  /// Reads the PEM certificate for `PLUGIN_CLIENT_CERT`.
  Future<String> certificatePem() => certificate.readAsString();
}

/// Creates a P-521 client identity in the suite's owner-only storage.
///
/// This convenience keeps test callers from having to know the helper's
/// output filenames.
Future<PluginFixtureIdentity> createPluginFixtureIdentity(
  PluginFixtureSuite suite,
) async {
  final credentials = await suite.createCredentials();
  return PluginFixtureIdentity(
    certificate: credentials.certificate,
    privateKey: credentials.privateKey,
  );
}
