# Proposal

## Why

M2 (Icinga2, Thanos and the ingest track) brings the owner's real sources in, and every one of its later
changes registers a source: `icinga2-ingest`, `thanos-and-generic-webhook`, matcher rules and the dead-letter
work all hang off a source instance. M1 left that model minimal: one bearer token per source with no overlap
on rotation, no HMAC, no rate limit, a free-form namespace string that two sources can share by accident, and
signing and plugin secrets that exist only as plaintext in an operator file that every process must keep.
This change makes the source model and secret storage ready for those changes, first in M2's order.

It advances the M2 exit criterion "scenarios … ID-2, ID-3 … SEC-3 pass as named tests" (agent-verified).
ID-2 and ID-3 are proven end to end on the Alertmanager path here; `icinga2-ingest` re-runs ID-3 with Icinga2's
host and check output. It does not touch the user-verified criterion (a day of real feeds), which needs the
Icinga2 and Thanos changes and is judged at the milestone close.

## What Changes

- **Source instances, format version 2 of the bootstrap configuration.** Each source declares its `kind`
  (`alertmanager` now; later changes add theirs) and a list of credentials instead of one `token_ref`. A
  request to `/hooks/<kind>/<instance>` for a source of another kind is rejected like an unknown source.
  Format version 1 files are still read and map to one bearer credential.
- **Credentials with rotation overlap.** A source has 1 to 4 credentials, each a bearer token or an HMAC key
  under its own secret reference, optionally bounded by `not_before` and `not_after`. Any credential in its
  window authenticates, so a new one can be published beside the old one and the old one removed later.
  HMAC requests sign a timestamp and the exact body; the timestamp must be within the skew window.
- **Declared namespaces (D3, ID-2).** A source's namespace defaults to its own instance id. Sharing a namespace
  now requires a top-level `namespaces` declaration; a source naming an undeclared namespace, or a declared
  name shaped like a UUID, fails validation. Separate sources therefore never merge alerts by accident.
- **Per-source rate limits.** Each source has a request-rate budget (default 20 requests per second, burst 40)
  enforced after authentication; over budget returns 429 with `Retry-After` and no raw row. The existing body
  limit (default and maximum 1 MiB) stays per source.
- **Encrypted secret store (SEC-3, D31).** Source credentials, webhook signing keys and plugin secrets are
  imported from the operator's secret file into Postgres, encrypted with AES-256-GCM under a key-encryption
  key read from a file named by `CORRELIA_SECRET_KEY_FILE`, never stored in the database. Processes resolve
  secrets from the store; the secret file is needed only to publish references not yet stored. Secret bytes are
  never returned by an endpoint, logged, or written to snapshots, events, failures or diagnostics.
  The first upgraded publication also imports file material still pinned by live M1 deliveries, even when
  their references are no longer in the active configuration.
- **Named scenario tests.** ID-2 (two sources, same labels: two alerts; declared shared namespace: one),
  ID-3 (maximum-length identity label and 4097-character description through HTTP ingress: accepted, display
  truncated with a marker, identity unchanged, never a 500) and SEC-3.

## Capabilities

### New Capabilities

- `secret-store`: Encrypted at-rest storage of operator secrets under an external key-encryption key, import
  from the operator secret file, resolution by reference and commitment, and the rule that secret bytes never
  leave the process that uses them.

### Modified Capabilities

- `source-ingress`: source kinds, credential lists with validity windows, HMAC authentication, per-source rate
  limits, declared namespaces in the bootstrap format, and secrets resolved from the store instead of only from
  the secret file.
- `integration-alertmanager`: adds the end-to-end ID-3 scenario to the bounded display requirement;
  identity bytes and mapping do not change.
- `output-delivery`: historical signing references are verified from the encrypted store, including material
  imported for live M1 work; missing plugin material still blocks only its definition.

## Impact

- Server: `correlia_server/lib/src/ingest/` (bootstrap parser, config repository, ingress authentication and
  rate limiting), a new `lib/src/secrets/` (key loading, AEAD, store), the plugin and webhook output paths that
  read secret bytes, model YAML, generated code and one managed migration (credential and secret tables).
- Runtime dependency: `libcrypto.so.3` is opened by every process with ingest configured, not only by plugin
  hosts.
- Operator interface: new `CORRELIA_SECRET_KEY_FILE`; configuration format version 2; `docs/ingest-pipeline.md`
  and the example files are updated. M1 configuration files remain supported with a key file and a one-time
  revision bump for an existing installation. Rotate source tokens under new references; changing the bytes
  under an existing `token_ref` is no longer allowed.
- No new endpoint, no Flutter change. No change to the canonical event format or identity bytes.

## Decision Making

DECISION_MAKING: autonomous
- **Source:** setting

### S1: Bootstrap files stay the only configuration input

- **Choice:** Extend the bootstrap configuration (format version 2) and secret file. Add no source or secret
  administration endpoint; the write-only secret API comes with the authenticated admin surface (ADR 0009,
  M4). YAML provisioning of rules belongs to `matcher-rules-and-versions`.
- **Rejected:** An admin endpoint now: people authentication does not exist before M4, so it would be an open
  hole or a throwaway. A YAML loader for sources now: a second format before the rule provisioning format is
  designed.
- **Reversal cost:** low.
- **Important:** yes — binds future changes (configuration format and its version).
- **Chosen by:** agent

### S2: Secrets encrypted in Postgres under an external key (D31 default)

- **Choice:** Take open decision D31's assumed default: a key-encryption key outside the database, in a file
  named by server configuration; Postgres and its backups hold only ciphertext; a restore needs the same key.
  Key rotation (re-encryption in batches) and the UPG-2 restore drill stay in M10; each ciphertext records the
  key's commitment so rotation can be added without a format change.
- **Rejected:** Keep secrets only in the plaintext operator file (SEC-3 asks for encryption at rest and HMAC
  verification needs key bytes on every api process); a key stored in the database (protects nothing); an
  external KMS (out of scope for a self-hosted 1.0).
- **Reversal cost:** medium (stored data format).
- **Important:** yes — high reversal cost, binds future changes, and an open owner question answered with its
  default.
- **Chosen by:** agent (D31 stays open for the owner; the change follows its assumed default)

### S3: ID-2 and ID-3 proven on the Alertmanager path in this change

- **Choice:** Prove both scenarios end to end through HTTP ingress, the pipeline and the stored event for
  Alertmanager sources. Host name and check output are Icinga2 fields, so `icinga2-ingest` repeats ID-3 for
  them through the same bounds contract.
- **Rejected:** Wait for Icinga2 to prove ID-3 at all (leaves the roadmap item of this change unproven).
- **Reversal cost:** low.
- **Important:** no.
- **Chosen by:** agent

### S4: Rate limits are per process, after authentication

- **Choice:** A token bucket per source in each api process, consulted only after the credential is verified,
  so unauthenticated traffic cannot spend a source's budget. With several api processes the effective limit
  is the per-process limit times the process count; this is documented.
- **Rejected:** A Postgres-coordinated budget (a write per request on the admission path); rate limiting before
  authentication (lets a stranger lock a source out).
- **Reversal cost:** low.
- **Important:** yes — changes behaviour users see (429 responses).
- **Chosen by:** agent

### S5: HMAC as an alternative, not a replacement

- **Choice:** Bearer stays the default and the only form Alertmanager can send; HMAC is available to senders
  that can sign (Icinga2 notification scripts, generic webhooks). Path tokens stay bearer-only.
- **Rejected:** HMAC only (Alertmanager cannot sign); mutual TLS (operators terminate TLS at a proxy).
- **Reversal cost:** low.
- **Important:** yes — binds a sender-facing contract.
- **Chosen by:** agent
