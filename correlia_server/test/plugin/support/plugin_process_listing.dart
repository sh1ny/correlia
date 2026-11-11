import 'dart:io';

import 'plugin_process_identity.dart';

/// A snapshot of one Linux process used by exact-child assertions.
final class PluginProcessSnapshot {
  /// Creates a process snapshot.
  PluginProcessSnapshot({
    required this.identity,
    required this.parentPid,
    required this.state,
  });

  /// The exact process identity.
  final PluginProcessIdentity identity;

  /// The parent process id.
  final int parentPid;

  /// The single-character Linux process state.
  final String state;

  /// Whether this is the same live process captured by the observer.
  bool get isSameProcess => identity.matchesCurrentProcess();

  /// Whether the process is a zombie with the captured identity.
  bool get isZombie => state == 'Z';
}

/// Reads the exact process snapshot for [pid].
///
/// Returns `null` when the process is absent. A same-identity zombie is
/// returned so tests can distinguish a reaped child from a running orphan.
PluginProcessSnapshot? readPluginProcessSnapshot(int pid) {
  final stat = File('/proc/$pid/stat');
  try {
    final contents = stat.readAsStringSync();
    final closingParenthesis = contents.lastIndexOf(')');
    if (closingParenthesis < 0) return null;
    final fields = contents
        .substring(closingParenthesis + 2)
        .trim()
        .split(RegExp(r'\s+'));
    if (fields.length < 20) return null;
    final parentPid = int.tryParse(fields[1]);
    final startTime = int.tryParse(fields[19]);
    if (parentPid == null || startTime == null) return null;
    return PluginProcessSnapshot(
      identity: PluginProcessIdentity(pid: pid, startTime: startTime),
      parentPid: parentPid,
      state: fields[0],
    );
  } on FileSystemException {
    return null;
  }
}
