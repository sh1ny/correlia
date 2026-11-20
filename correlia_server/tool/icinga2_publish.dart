/// Publishes the Icinga 2 sender only for architectures with a qualified pair
/// (task 9.5).
///
/// Run from `correlia_server` (the `release:icinga2-notify` mise task does
/// this) after `mise run build:icinga2-notify`. It evaluates every pair the
/// supported-release statement in `docs/ingest-pipeline.md` lists on the
/// committed captures, and copies the sender of each architecture with at
/// least one passing pair, when it is the exact artifact a passing capture ran, from `../build/icinga2-notify/<architecture>/` to
/// `../build/icinga2-notify/release/<architecture>/`. With no qualified pair it
/// publishes nothing and exits 1.
library;

import 'dart:io';

import '../test/support/icinga2_matrix.dart';

void main() {
  final statement = committedStatement();
  final failures = evaluateStatement(statement);
  for (final failure in failures) {
    stderr.writeln('not qualified: $failure');
  }
  final qualified = qualifiedSenders(statement);
  try {
    final published = publishSenders(
      build: Directory('../build/icinga2-notify'),
      release: Directory('../build/icinga2-notify/release'),
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
