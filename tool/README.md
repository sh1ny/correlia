# Correlia workspace tool

The tool package contains the repository task runner and generated-contract
checks. Run its commands through mise rather than invoking a bare Dart or Node
executable.

- `mise run proto` generates the canonical event contract outputs.
- `mise run proto:check` checks compatibility, generated drift and payload
  fixtures without changing the checkout.
- `mise run generated` remains the Serverpod generated-code check.
- `mise run check` runs the complete workspace gate.

See `docs/event-contract-tooling.md` for the canonical event generation,
compatibility policy and first-run dependency behavior.
