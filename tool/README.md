# Correlia workspace tool

The tool package contains the repository task runner and generated-contract
checks. Run its commands through mise rather than invoking a bare Dart or Node
executable.

- `mise run proto` generates the canonical event and plugin protocol outputs.
- `mise run proto:check` checks event compatibility, Dart and Go generated
  drift, and payload fixtures without changing the checkout. The event v1.0
  baseline remains frozen; the production plugin protocol has no baseline yet.
- `mise run plugins:build` builds the pinned first-party Go plugin and
  `natsdev` into `build/plugins`. Plugin and e2e test tiers build both first.
- `mise run nats:dev` starts loopback JetStream and prints its URL. Pass that
  URL to `mise run nats:stream -- --url <url>` to create the event stream and
  to `mise run nats:sub -- --url <url>` to receive its live messages.
- `mise run generated` remains the Serverpod generated-code check.
- `mise run check` runs the complete workspace gate.

See `docs/event-contract-tooling.md` for the canonical event generation,
compatibility policy and first-run dependency behavior.

## Icinga 2 Event Streams captures

Run the upstream-only scenario against the official Linux x64 images:

```sh
mise exec -- tool/icinga2_capture.sh --stream 2.13.14 2.14.10 2.15.7 2.16.6
```

This mode needs Docker but does not build the webhook sender or start
Correlia. It drives passive results and operator actions, writes the six
subscribed event types and both object projections to
`correlia_server/test/unit/ingest/fixtures/icinga2/<release>/stream/`,
and records the image and the result of omitting each required grant.
Treat these as wire captures, not proof that the Correlia consumer works.
The separate real-consumer run record is checked by the version matrix
alongside the captures.
