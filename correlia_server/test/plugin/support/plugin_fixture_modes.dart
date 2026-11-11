/// The acknowledgement behavior of a plugin fixture.
enum PluginFixtureAckMode {
  /// Acknowledge the exact epoch and sequence.
  normal('normal'),

  /// Journal the batch without acknowledging it.
  withhold('withhold'),

  /// Acknowledge with an invalid epoch.
  invalidEpoch('invalid-epoch'),

  /// Acknowledge with an invalid sequence.
  invalidSequence('invalid-sequence'),

  /// Acknowledge the same batch twice.
  duplicate('duplicate');

  const PluginFixtureAckMode(this.argument);

  /// The command-line argument value.
  final String argument;
}

/// The startup behavior of a plugin fixture.
enum PluginFixtureStartupMode {
  /// Start the stock go-plugin server.
  serve('serve'),

  /// Exit before writing a handshake.
  exit('exit'),

  /// Stay alive without writing a handshake.
  stall('stall'),

  /// Write one malformed handshake line.
  malformed('malformed'),

  /// Write a handshake larger than 16 KiB.
  oversized('oversized'),

  /// Write an incomplete handshake and stay alive.
  incomplete('incomplete'),

  /// Serve stock gRPC but withhold health check replies.
  stallHealth('stall-health'),

  /// Bind a real socket owned by namespace UID 1.
  foreignOwner('foreign-owner');

  const PluginFixtureStartupMode(this.argument);

  /// The command-line argument value.
  final String argument;
}

/// The transport-security behavior of a plugin fixture.
enum PluginFixtureTlsMode {
  /// Use stock go-plugin AutoMTLS when the client certificate is present.
  stock('stock'),

  /// Explicitly select stock plaintext serving.
  plaintext('plaintext'),

  /// Require a client certificate and fail otherwise.
  required('required');

  const PluginFixtureTlsMode(this.argument);

  /// The command-line argument value.
  final String argument;
}

/// The shutdown behavior of a plugin fixture.
enum PluginFixtureLifecycleMode {
  /// Exit after stock serving stops.
  cooperative('cooperative'),

  /// Remain alive after stock serving stops.
  uncooperative('uncooperative');

  const PluginFixtureLifecycleMode(this.argument);

  /// The command-line argument value.
  final String argument;
}

/// The standard fixture arguments used by plugin tests.
final class PluginFixtureArguments {
  /// Creates fixture arguments.
  PluginFixtureArguments({
    required this.journalPath,
    this.controlSocketPath,
    this.eofMarkerPath,
    this.ackMode = PluginFixtureAckMode.normal,
    this.startupMode = PluginFixtureStartupMode.serve,
    this.tlsMode = PluginFixtureTlsMode.stock,
    this.lifecycleMode = PluginFixtureLifecycleMode.cooperative,
    this.armBarrier = false,
  });

  /// The acceptance journal path.
  final String journalPath;

  /// The optional observer control-socket path.
  final String? controlSocketPath;

  /// The optional stdin-EOF cause marker path.
  final String? eofMarkerPath;

  /// The acknowledgement behavior.
  final PluginFixtureAckMode ackMode;

  /// The startup behavior.
  final PluginFixtureStartupMode startupMode;

  /// The transport-security behavior.
  final PluginFixtureTlsMode tlsMode;

  /// The shutdown behavior.
  final PluginFixtureLifecycleMode lifecycleMode;

  /// Whether the one-time pre-ack barrier is armed.
  final bool armBarrier;

  /// Serializes the arguments for the fixture executable.
  List<String> toArguments() => <String>[
    '--journal',
    journalPath,
    '--ack-mode',
    ackMode.argument,
    '--startup-mode',
    startupMode.argument,
    '--tls-mode',
    tlsMode.argument,
    '--lifecycle-mode',
    lifecycleMode.argument,
    if (controlSocketPath case final String path) ...[
      '--control-socket',
      path,
    ],
    if (eofMarkerPath case final String path) ...['--eof-marker', path],
    if (armBarrier) '--arm-barrier',
  ];
}
