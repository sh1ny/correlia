import 'dart:io';

/// A Linux process identity that survives PID reuse checks.
///
/// The start time is Linux's `/proc/<pid>/stat` field 22. A PID alone is not
/// sufficient for exact-process cleanup because the kernel may reuse it.
final class PluginProcessIdentity {
  /// Creates a process identity.
  PluginProcessIdentity({required this.pid, required this.startTime});

  /// The process id.
  final int pid;

  /// The kernel start-time tick value.
  final int startTime;

  /// Reads the current identity of [pid].
  ///
  /// Returns `null` when the process is absent or cannot be inspected.
  static PluginProcessIdentity? read(int pid) {
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
      final startTime = int.tryParse(fields[19]);
      if (startTime == null) return null;
      return PluginProcessIdentity(pid: pid, startTime: startTime);
    } on FileSystemException {
      return null;
    }
  }

  /// Whether this identity still names the same live process.
  bool get isLive => read(pid)?.startTime == startTime;

  /// Whether the process is a zombie with this exact identity.
  bool get isZombie {
    final stat = File('/proc/$pid/stat');
    try {
      final contents = stat.readAsStringSync();
      final closingParenthesis = contents.lastIndexOf(')');
      if (closingParenthesis < 0) return false;
      final fields = contents
          .substring(closingParenthesis + 2)
          .trim()
          .split(RegExp(r'\s+'));
      return fields.isNotEmpty && fields[0] == 'Z';
    } on FileSystemException {
      return false;
    }
  }

  /// Sends [signal] only when [pid] still has this exact start identity.
  ///
  /// Returns whether the signal was sent. A false result means the process is
  /// absent or a different process now owns the PID.
  bool signalIfExact(ProcessSignal signal) {
    final current = read(pid);
    if (current == null || current.startTime != startTime) return false;
    return Process.killPid(pid, signal);
  }

  /// Whether this identity still names the same process, including a zombie.
  bool matchesCurrentProcess() => read(pid)?.startTime == startTime;

  @override
  bool operator ==(Object other) =>
      other is PluginProcessIdentity &&
      other.pid == pid &&
      other.startTime == startTime;

  @override
  int get hashCode => Object.hash(pid, startTime);

  @override
  String toString() =>
      'PluginProcessIdentity(pid: $pid, startTime: $startTime)';
}
