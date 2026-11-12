# NATS JetStream output

The first-party `output-nats` plugin sends canonical structured CloudEvents to an **operator-owned** JetStream stream. It never creates or modifies streams. The development server embeds nats-server **2.15.3**; the plugin uses nats.go **1.55.0**. Use a private, durable production JetStream deployment and provision its stream before enabling the output.

## Local development stream

From the repository root, start the development server in one terminal:

```sh
mise run nats:dev
```

It prints `ready nats://127.0.0.1:<port>`; keep this terminal open and use that exact URL below. In another terminal, create the development stream:

```sh
mise run nats:stream -- --url nats://127.0.0.1:<port>
```

This creates `CORRELIA_EVENTS`, capturing `correlia.v1.ev.>`, with a ten-minute duplicate window. Subscribe before sending events:

```sh
mise run nats:sub -- --url nats://127.0.0.1:<port>
```

For production, provision a stream through the NATS operator's own tooling with the same subject capture and an appropriate duplicate window. Ten minutes exceeds the 30-second outbox lease and allows redelivery after an interrupted worker to be deduplicated; choose a window covering the actual recovery interval. Deduplication outside that window is not guaranteed. The plugin reports the capturing `stream` and `duplicate_window_ms` as configuration information; a missing capturing stream rejects configuration with `stream_missing`.

## Configure Correlia

Build with `mise run plugins:build`, place the executable in the owner-controlled `CORRELIA_PLUGIN_DIR`, and pin its SHA-256 in the output definition. See [bootstrap and rotation](../ingest-pipeline.md#bootstrap-and-rotation) for the complete source, output and secret-file configuration and filesystem permissions. The build task protects `build/plugins` and `output-nats` with owner-only permissions. `mise run run` defaults `CORRELIA_PLUGIN_DIR` to that directory; an explicitly supplied value takes precedence.

The output-specific fields are:

```json
{
  "kind": "plugin",
  "plugin": "output-nats",
  "config": {
    "server": "nats://127.0.0.1:4222",
    "stream": "CORRELIA_EVENTS"
  },
  "secret_refs": {}
}
```

Add the required output `id` and `sha256`, and route a source to it. `server` is a single NATS URL with no userinfo or credentials. `stream` must name the stream capturing `correlia.v1.ev.>`; publishes assert that stream so a changed mapping cannot silently redirect work. Use `tls://` and operator-managed TLS where appropriate.

Authentication is optional. For token authentication, set `secret_refs` to `{"token":"nats-token-v1"}`. For NATS credentials-file authentication, use `{"creds":"nats-creds-v1"}` and store the complete credentials file contents as that secret's bytes. These forms are mutually exclusive. Entries may use the bootstrap secret file's `{"bytes":"<unpadded base64url>"}` representation; see the bootstrap documentation for its bounds and rotation rules. Never put credentials in the server URL, plugin config, command line, environment, or logs. Configure sends resolved secret bytes separately to the plugin. Wrong credentials are reported as `nats_auth_failed` without the credential.

## Delivery and operations

Subjects are `correlia.v1.ev.<tenant>.<kind>.<source_kind>.<severity>`. Each token must be nonempty ASCII letters, digits, `_` or `-`. The body is the exact stored structured CloudEvents JSON; `Nats-Msg-Id` is the event id and CloudEvents attributes are copied into headers. An event is acknowledged only after JetStream confirms storage, including a duplicate acknowledgement. The plugin bounds a batch's publish acknowledgements to ten seconds.

`nats_unavailable`, `publish_timeout` and `stream_mismatch` are retryable. `payload_too_large` and `invalid_subject_token` reject only the affected event. Investigate stream ownership and capture on mismatch, server/network availability on retryable failures, and the source data or NATS payload limit for rejected events. Health is serving only while connected.

An intent whose stored payload alone exceeds the plugin's negotiated batch byte limit is retained
as dead with `payload_too_large` during acquisition, without starting a transport attempt. Later
fitting intents can proceed. Filling a batch's aggregate byte budget only defers another fitting
event; it does not reject that event.

Inspect the managed `plugin_instance_status` table through restricted SQL. Filter by `hostInstanceId`, `outputId` and `definitionDigest`: a replacement worker has a new host identity, while historical definitions remain pinned to their own work. Heartbeats refresh every 15 seconds; a row older than 60 seconds is stale regardless of its stored state. A killed worker's unchanged `ready` row is not evidence of a live instance.

- `waiting` with `lastErrorClass = instance_limit` means fair slot admission is pending. Limits are sixteen instances per worker and four per output; idle release and rotation prevent historical definitions from starving newer work.
- `backoff` means a launch or running instance failed. Restart delay doubles from one to sixty seconds and resets after ten minutes continuously ready.
- `degraded` means more than five failures in ten minutes opened the circuit. Probes run every five minutes; sixty seconds continuously ready closes the circuit. Inspect the bounded failure history and next start/probe times in `plugin_definition_health`.
- `lastErrorClass` is the host's classification. On configuration rejection it stays `plugin_config_rejected`; nullable `lastPluginErrorClass` holds a separately validated, secret-scrubbed reason such as `stream_missing` or `nats_auth_failed`. Configuration information and field-error messages are not automatically logged or persisted.
- `plugin_degraded` and `plugin_recovered` activity entries record circuit changes, not alerts. A graceful worker stop drains the relay before stopping plugins and records `stopped`; force termination is bounded by the five-second grace.

Missing or mismatched historical plugin secrets leave that definition unavailable and its intents queued without new attempts. Other outputs continue. Restore the matching secret reference or pinned executable; never redirect old rows to a new definition manually.

## Alertmanager-to-console demonstration

1. Complete the local stream setup above and keep the NATS server running.
2. Set the bootstrap configuration and secret-file environment variables described in the ingest guide. Route the Alertmanager source to this plugin output, using the printed NATS URL and `CORRELIA_EVENTS`.
3. With no other Correlia process occupying the configured ports, start the configured development instance:

   ```sh
   mise run run
   ```

4. Start the subscriber from the first section **before** sending an alert; it is live-only. Wait for its `ready` line.
5. Point Alertmanager at `/hooks/alertmanager/<source-id>` on the instance's web listener, using the source bearer token as described in the ingest guide. Open the development console and send a firing alert.
6. Verify the alert appears in the console feed and the subscriber prints its canonical event on the corresponding `correlia.v1.ev.…` subject. Resolving the alert updates the same console identity; downstream consumers deduplicate by event id, not arrival order.

The automated demo test exercises the same ingress → persisted alert/feed → real `natsdev sub` path. The owner's real-Alertmanager milestone-close check remains separate.
