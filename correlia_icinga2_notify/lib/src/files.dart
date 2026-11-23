import 'dart:io';

/// What the sender needs to know about a path before it opens it.
final class FileInfo {
  /// Creates the description of one path.
  const FileInfo({required this.type, required this.mode, required this.size});

  /// The entry type after following symbolic links.
  final FileSystemEntityType type;

  /// The POSIX permission bits (the file-type bits may be present).
  final int mode;

  /// The size in bytes reported by `stat`.
  final int size;
}

/// The only way the sender touches the file system, asynchronous by design.
///
/// A blocked [open] must never stop the sender's deadline timer, so nothing
/// here may be a synchronous file call.
abstract interface class SenderFiles {
  /// Describes [path] without opening it; a missing path has type
  /// [FileSystemEntityType.notFound].
  Future<FileInfo> stat(String path);

  /// Opens [path] and yields at most [maxBytes] bytes of it.
  Stream<List<int>> open(String path, int maxBytes);
}

/// The real file system through Dart's asynchronous file API.
final class DiskFiles implements SenderFiles {
  /// Creates the disk-backed hooks.
  const DiskFiles();

  @override
  Future<FileInfo> stat(String path) async {
    final stat = await FileStat.stat(path);
    return FileInfo(type: stat.type, mode: stat.mode, size: stat.size);
  }

  @override
  Stream<List<int>> open(String path, int maxBytes) =>
      File(path).openRead(0, maxBytes);
}
