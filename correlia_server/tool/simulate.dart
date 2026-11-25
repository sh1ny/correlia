/// Simulates the matcher rules against one event through a running server.
///
/// Run from `correlia_server`:
///
/// ```sh
/// mise exec -- dart run tool/simulate.dart --event-id <id> --observed-at <time>
/// mise exec -- dart run tool/simulate.dart --event event.json --draft draft.json
/// ```
///
/// Options and output are in `simulate_cli.dart` and `docs/ingest-pipeline.md`.
library;

import 'dart:io';

import 'package:correlia_client/correlia_client.dart';

import 'simulate_cli.dart';

Future<void> main(List<String> args) async {
  final client = Client(serverOption(args));
  try {
    exitCode = await runSimulate(
      args,
      client.ruleSimulator.simulate,
      stdout,
      stderr,
    );
  } finally {
    client.close();
  }
}
