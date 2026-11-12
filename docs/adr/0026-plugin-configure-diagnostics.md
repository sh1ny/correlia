# 0026. Typed plugin Configure diagnostics

- Status: accepted (2026-11-12)
- Date: 2026-11-12
- Supersedes: [0025](0025-plugin-protocol-v1-output-contract-and-supervision.md) D1 Configure response only (partial)
- Chosen by: user (diagnostic amendment approved 2026-11-12); validation and status details chosen by agent and independently reviewed

## Context

The NATS output must report its capturing stream and duplicate window and distinguish missing streams from rejected credentials. A Configure response carrying only acceptance, limits and field errors cannot expose those results safely through a host that intentionally discards arbitrary diagnostic text. The host's classification and the plugin's reason are separate facts.

Accepted ADRs are immutable (ADR 0023). This partial supersession leaves ADR 0025 unchanged and keeps its other protocol, queue, readiness, supervision, module-layout and compatibility decisions in force.

## Decision

`correlia.plugin.v1.ConfigureResponse` adds an optional `error_class` and a `configuration_info` string map. The class is empty or matches `^[a-z][a-z0-9_]{0,63}$`. Information contains at most eight entries; keys match that pattern (at most 64 ASCII bytes) and values contain at most 256 UTF-8 bytes each. Information is non-secret and exposed to the caller as an immutable map, never automatically logged or persisted. Field-error messages are likewise not automatically logged or persisted.

Validation order is explicit:

1. The complete GetMetadata or Configure response and its frame must fit 64 KiB. A response/frame-bound failure is `plugin_metadata_invalid`.
2. Within those bounds, validate diagnostic class, information entry/key/value bounds and response exclusivity. Accepted responses carry no error class or field errors. Rejected responses carry no configuration information. Any violation is `plugin_protocol_error`, without reflecting diagnostic content.
3. Only then classify acceptance or rejection. Rejection retains host class `plugin_config_rejected` and exposes the validated plugin class separately as `pluginErrorClass`.

Before exposing the plugin class, compare its ASCII bytes with every non-empty resolved secret's exact bytes. Silently discard the class if it contains any such secret, without logging it. This rule also protects short secret values; regular-expression validity alone is not sanitization.

The status mirror keeps host classification in `lastErrorClass` and the nullable validated, scrubbed plugin reason in `lastPluginErrorClass`. Durable health/admission policy uses only the host classification; plugin diagnostics do not change restart or circuit policy.

A configured NATS output reports `stream` and `duplicate_window_ms` (decimal milliseconds). Its rejected Configure reports plugin class `stream_missing` or `nats_auth_failed` as appropriate. These never replace the host's rejection classification.

## Alternatives and reversal cost

Rejected: encoding classes in free-text field messages or health reasons, which conflates diagnostics with protocol state; discarding the required NATS information; persisting a syntactically valid class without comparing secret bytes; or replacing the host classification with a plugin-controlled string.

Reversal cost is medium because plugin authors may consume these fields. They are additive before ADR 0025's 1.0 compatibility freeze; the canonical event baseline is untouched.

## Consequences

Operators can distinguish a missing stream from an authentication failure without exposing credential material in status. The response and per-entry bounds remain fixed regardless of backlog or number of definitions. Configuration information remains ephemeral; only the separately scrubbed class enters status. Malformed plugin diagnostics fail closed before the host starts delivery.
