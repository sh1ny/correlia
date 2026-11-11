# Plugin fixture support

This directory contains suite-owned helpers for the plugin host spike. It is
test support only; none of it is a production plugin host.

## API overview

- `PluginFixtureSuite` owns one temporary scratch directory, builds the Go
  fixtures once per suite, generates owner-only ephemeral credentials, tracks
  launched children, and removes only its own scratch tree;
- `PluginFixtureArguments`, `PluginFixtureAckMode`,
  `PluginFixtureStartupMode`, `PluginFixtureTlsMode`, and
  `PluginFixtureLifecycleMode` describe the explicit fixture argv contract;
- `PluginFixtureEnvironment` describes the minimal environment passed to a
  fixture process, including the cookie, protocol versions, optional client
  certificate, and optional stock Unix-socket directory;
- `createPluginFixtureIdentity` exposes the suite-owned P-521 client
  certificate and private key without moving either file out of scratch;
- `PluginFixtureProcess` starts a fixture, keeps stdin open, captures its
  exact Linux PID and start time, and stops only that exact identity;
- `readPluginProcessSnapshot` reads the parent, state, and start identity of
  an exact Linux process, distinguishing a zombie from a running process;
- `PluginControlSocket` observes the one-shot pre-ack barrier and releases
  the paused receiver through one bounded frame in each direction;
- `readPluginJournal` parses the receiver journal and rejects torn records;
- `PluginFixtureDiagnostics` drains process output into a bounded retained
  tail.

`plugin_fixture_support.dart` exports the complete support surface.

## Bounds

The suite retains at most 64 KiB of diagnostic output, accepts at most 8 KiB
per control frame in either direction, and accepts at most 32 MiB of journal
data. The Go receiver enforces the journal bound independently before every
acknowledgement.

## Ownership and cleanup

The scratch directory is created atomically with Linux `mktemp -d` (mode
0700), independent of the caller's umask. Credentials are generated into an owner-only subdirectory with
owner-only files. Cleanup reverses the suite's child list and signals only a
captured PID/start-time identity, then deletes the exact suite-owned scratch
directory. It never matches a process by name and never signals an unrelated
process.

Stock socket permissions still follow the inherited umask: the foundation
smoke observed mode 0775 with the current development umask. The support
does not chmod stock sockets or approve that mode. Startup security checks
must reject group/other-writable sockets; explicitly selected restrictive
launch umasks must be recorded with runtime gate evidence.
