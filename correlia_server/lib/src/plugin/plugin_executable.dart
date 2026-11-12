import 'dart:io';

import 'package:crypto/crypto.dart';

/// A configured plugin executable failed an ownership, path or integrity check.
final class PluginExecutableRejected implements Exception {
  const PluginExecutableRejected();
}

/// Verifies the resolved executable immediately before each plugin launch.
Future<String> verifyPluginExecutable(
  String directory,
  String name,
  String digest,
) async {
  try {
    if (!RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$').hasMatch(name)) {
      throw const PluginExecutableRejected();
    }
    final root = await Directory(directory).resolveSymbolicLinks();
    final executable = await File('$root/$name').resolveSymbolicLinks();
    if (!executable.startsWith('$root/')) {
      throw const PluginExecutableRejected();
    }
    final file = File(executable);
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file || stat.mode & 0x12 != 0) {
      throw const PluginExecutableRejected();
    }
    final owner = await Process.run('/usr/bin/stat', [
      '-c',
      '%u',
      '--',
      executable,
    ]);
    final user = await Process.run('/usr/bin/id', ['-u']);
    if (owner.exitCode != 0 ||
        user.exitCode != 0 ||
        owner.stdout.toString().trim() != user.stdout.toString().trim()) {
      throw const PluginExecutableRejected();
    }
    if ((await sha256.bind(file.openRead()).first).toString() != digest) {
      throw const PluginExecutableRejected();
    }
    return executable;
  } on Object {
    throw const PluginExecutableRejected();
  }
}
