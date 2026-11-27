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
  // The client is built only when the call is made, after runSimulate has
  // checked the arguments, since its constructor asserts on a bad URL.
  Client? client;
  try {
    exitCode = await runSimulate(
      args,
      ({eventJson, eventId, observedAt, disposition, draftMatcher}) =>
          (client ??= Client(serverOption(args))).ruleSimulator.simulate(
            eventJson: eventJson,
            eventId: eventId,
            observedAt: observedAt,
            disposition: disposition,
            draftMatcher: draftMatcher,
          ),
      stdout,
      stderr,
    );
  } finally {
    client?.close();
  }
}
