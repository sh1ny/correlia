@Tags(['db'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';

/// The decoy listener process and what it reports.
final class _Decoy {
  _Decoy(this.process, this.tcpPort, this.socketPath, this._lines);

  final Process process;
  final int tcpPort;
  final String socketPath;
  final StreamIterator<String> _lines;
  bool exited = false;

  /// Asks the decoy how many connections it has accepted; proves it runs.
  Future<int> ping() async {
    process.stdin.writeln('ping');
    while (await _lines.moveNext()) {
      if (_lines.current.startsWith('PONG ')) {
        return int.parse(_lines.current.substring(5));
      }
    }
    throw StateError('the decoy closed its output');
  }
}

Future<_Decoy> _startDecoy(Directory dir) async {
  final process = await Process.start(Platform.resolvedExecutable, [
    p.join(Directory.current.path, 'test', 'support', 'decoy_listener.dart'),
    dir.path,
  ]);
  final lines = StreamIterator(
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
  );
  unawaited(process.stderr.drain<void>());
  while (await lines.moveNext().timeout(const Duration(seconds: 60))) {
    if (lines.current.startsWith('READY ')) {
      final port = int.parse(lines.current.substring(6));
      final decoy = _Decoy(
        process,
        port,
        p.join(dir.path, '.s.PGSQL.$port'),
        lines,
      );
      unawaited(process.exitCode.then((_) => decoy.exited = true));
      return decoy;
    }
  }
  throw StateError('the decoy never became ready');
}

/// [path] made absolute against [base], with symbolic links resolved.
String _canonical(String path, {String? base}) => Directory(
  base == null ? path : p.normalize(p.join(base, path)),
).resolveSymbolicLinksSync();

void main() {
  final clusterRoot = Directory(
    p.join(Directory.current.path, '.serverpod', 'test'),
  );
  late Directory decoyDir;
  late _Decoy decoy;

  setUpAll(() async {
    decoyDir = await Directory.systemTemp.createTemp('correlia-decoy-');
    decoy = await _startDecoy(decoyDir);
  });
  tearDownAll(() async {
    decoy.process.kill(ProcessSignal.sigterm);
    await decoy.process.exitCode;
    await decoyDir.delete(recursive: true);
  });

  withServerpod('Given a PostgreSQL-like decoy outside the cluster root', (
    sessionBuilder,
    _,
  ) {
    test(
      'a decoy listener and socket get no connection and keep running',
      () async {
        expect(
          p.isWithin(clusterRoot.path, decoyDir.path),
          isFalse,
          reason: 'the decoy lives outside the root',
        );
        expect(File(decoy.socketPath).existsSync(), isTrue);
        final session = sessionBuilder.build();

        final rows = await session.db.unsafeQuery('SELECT 1 AS one');

        expect(rows.single.toColumnMap()['one'], 1);
        expect(await decoy.ping(), 0, reason: 'accepted connections');
        expect(decoy.exited, isFalse);
      },
    );

    test(
      'data_directory and unix_socket_directories lie inside the cluster root',
      () async {
        final session = sessionBuilder.build();
        final root = _canonical(clusterRoot.path);

        final dataDirectory =
            (await session.db.unsafeQuery(
                  'SHOW data_directory',
                )).single.first!
                as String;
        final socketDirectories =
            (await session.db.unsafeQuery(
                  'SHOW unix_socket_directories',
                )).single.first!
                as String;

        expect(p.isWithin(root, _canonical(dataDirectory)), isTrue);
        final directories = socketDirectories.split(',').map((d) => d.trim());
        expect(directories, isNotEmpty);
        for (final directory in directories) {
          expect(
            p.isWithin(root, _canonical(directory, base: dataDirectory)),
            isTrue,
            reason: directory,
          );
        }
      },
    );
  }, testGroupTagsOverride: ['db']);
}
