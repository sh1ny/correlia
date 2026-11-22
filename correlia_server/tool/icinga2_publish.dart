/// Publishes the Icinga 2 sender only for architectures with a qualified pair
/// (task 9.5).
///
/// Run from `correlia_server` after the sender build;
/// `tool/release_icinga2_notify.sh` (the `release:icinga2-notify` mise task)
/// removes the earlier publication, builds, then runs this. It evaluates every pair the
/// supported-release statement in `docs/ingest-pipeline.md` lists on the
/// committed captures. An architecture qualifies when every listed pair of it
/// passes and all of them ran one bundle (sender and definitions). For each,
/// it copies the sender from `../build/icinga2-notify/<architecture>/` to
/// `../build/icinga2-notify/release/<architecture>/`, and `../contrib/icinga2/`
/// to `../build/icinga2-notify/release/icinga2/`, only when the build and the
/// definitions are exactly that bundle. With no qualified pair, or a build or
/// definition that differs, or a statement it cannot read, it publishes
/// nothing, leaves no earlier publication in place and exits 1.
library;

import 'dart:io';

import '../test/support/icinga2_matrix.dart';

void main() {
  final release = Directory('../build/icinga2-notify/release');
  final List<Pair> statement;
  try {
    final file = File(matrixStatementFile);
    statement = statementForPublishing(
      release,
      file.existsSync() ? file.readAsStringSync() : '',
    );
  } on FormatException catch (e) {
    stderr.writeln('not published: ${e.message}');
    exitCode = 1;
    return;
  }
  final failures = evaluateStatement(statement);
  for (final failure in failures) {
    stderr.writeln('not qualified: $failure');
  }
  final (:qualified, :refused) = qualifiedBundles(statement);
  for (final MapEntry(key: architecture, value: reason) in refused.entries) {
    stderr.writeln('not qualified $architecture: $reason');
  }
  try {
    final published = publishSenders(
      build: Directory('../build/icinga2-notify'),
      contrib: Directory('../contrib/icinga2'),
      release: release,
      qualified: qualified,
    );
    for (final architecture in builtArchitectures) {
      stdout.writeln(
        published.contains(architecture)
            ? 'published $architecture'
            : 'not published $architecture: no qualified pair',
      );
    }
  } on StateError catch (e) {
    stderr.writeln(e.message);
    exitCode = 1;
  }
}
