import 'dart:io';

/// Takes the capture lock of the pair directory [target] for this process.
///
/// Two captures of one release and architecture would otherwise write into
/// one directory, and the last manifest could vouch for records another
/// bundle made. Returns null when another process holds the lock. The lock
/// is released when the returned file is closed or the process exits.
RandomAccessFile? lockPair(Directory target) {
  target.parent.createSync(recursive: true);
  final file = File('${target.path}.lock').openSync(mode: FileMode.write);
  try {
    file.lockSync(FileLock.exclusive);
    return file;
  } on FileSystemException {
    file.closeSync();
    return null;
  }
}

/// A fresh staging directory for a capture of [target].
///
/// With [keep], it starts as a copy of [target]'s files, which a partial run
/// keeps; otherwise it starts empty.
///
/// A publication interrupted between its two renames leaves the last
/// complete run in `.old` and no [target]; that run is moved back first.
Directory openStaging(Directory target, {required bool keep}) {
  final old = Directory('${target.path}.old');
  if (old.existsSync()) {
    if (target.existsSync()) {
      old.deleteSync(recursive: true);
    } else {
      old.renameSync(target.path);
    }
  }
  final staging = Directory('${target.path}.staging');
  if (staging.existsSync()) staging.deleteSync(recursive: true);
  staging.createSync(recursive: true);
  if (keep && target.existsSync()) {
    for (final f in target.listSync().whereType<File>()) {
      f.copySync('${staging.path}/${f.uri.pathSegments.last}');
    }
  }
  return staging;
}

/// Replaces [target] with [staging], so the pair directory holds the
/// records of one run and the manifest written with them, and nothing else.
void publishStaging(Directory staging, Directory target) {
  final old = Directory('${target.path}.old');
  if (old.existsSync()) old.deleteSync(recursive: true);
  if (target.existsSync()) target.renameSync(old.path);
  staging.renameSync(target.path);
  if (old.existsSync()) old.deleteSync(recursive: true);
}
