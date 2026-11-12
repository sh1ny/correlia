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
