import 'dart:ffi';
import 'dart:io';

/// Observed authentication and native configuration facts for a connection.
final class PluginTlsEvidence {
  /// Snapshots the observed values without retaining any private key material.
  PluginTlsEvidence({
    required this.backendVersion,
    required this.protocol,
    required this.serverCertificateCurve,
    required this.clientCertificateCurve,
    required this.configurationPolicy,
    required this.configurationSource,
    required Map<String, String?> configurationEnvironment,
  }) : configurationEnvironment = Map.unmodifiable(configurationEnvironment);

  /// The loaded native library version.
  final String backendVersion;

  /// The negotiated TLS protocol name.
  final String protocol;

  /// The server certificate's observed elliptic-curve group, when applicable.
  final String? serverCertificateCurve;

  /// The client certificate's observed elliptic-curve group, when applicable.
  final String? clientCertificateCurve;

  /// The native configuration policy used for this connection.
  final String configurationPolicy;

  /// The selected configuration path or compiled default directory description.
  final String configurationSource;

  /// The selected OpenSSL configuration environment, not its file contents.
  final Map<String, String?> configurationEnvironment;
}

/// An internal, failure-only native dependency probe.
///
/// This type is deliberately excluded from the public plugin entry point.
/// Neither case can supply an alternative library or verification result.
enum PluginNativeTlsFault {
  /// Attempts an actual load at a fixed non-loadable path.
  unavailableLibrary,

  /// Looks up a deliberately absent symbol in the genuine system library.
  missingAbiSymbol,
}

/// An internal acquisition port for real-socket lifetime tests.
typedef PluginRawSocketConnector =
    Future<RawSocket> Function(InternetAddress address, int port);

/// Internal test-harness controls that cannot select a replacement verifier.
///
/// This type is not exported through `plugin.dart` and never belongs to the
/// public host configuration. Production callers use the fixed native policy.
final class PluginTlsTestControls {
  /// Selects explicit failure, ownership or capability checks for a test.
  const PluginTlsTestControls({
    this.nativeFault,
    this.socketConnector,
    this.allocator,
    this.withoutP521Signatures = false,
  });

  /// The failure-only native dependency selection.
  final PluginNativeTlsFault? nativeFault;

  /// The real-socket acquisition port used to control late receipts.
  final PluginRawSocketConnector? socketConnector;

  /// The allocator used to account for real native staging allocations.
  final Allocator? allocator;

  /// Whether the actual TLS offer excludes P-521 signature support.
  final bool withoutP521Signatures;
}
