@Tags(['db'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/decoy.dart';

/// [path] made absolute against [base], with symbolic links resolved.
String _canonical(String path, {String? base}) => Directory(
  base == null ? path : p.normalize(p.join(base, path)),
).resolveSymbolicLinksSync();

void main() {
  final clusterRoot = Directory(
    p.join(Directory.current.path, '.serverpod', 'test'),
  );
  late Directory decoyDir;
  late Decoy decoy;

  setUpAll(() async {
    decoyDir = await Directory.systemTemp.createTemp('correlia-decoy-');
    decoy = await Decoy.start(decoyDir);
  });
  tearDownAll(() async {
    await decoy.stop();
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
