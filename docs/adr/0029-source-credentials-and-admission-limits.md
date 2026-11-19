# 0029. Source credentials, HMAC signing and admission limits

- Status: accepted (2026-11-18)
- Date: 2026-11-18
- Supersedes: none (extends [0024](0024-identities-and-upstream-evidence.md))
- Chosen by: agent (source and admission contract); user (one migration with the bearer cutover)

## Context

M1 stores one bearer digest per source and allows free-form namespaces. Rotation needs overlap, some senders can authenticate the exact payload, and sources need independent request budgets and explicit opt-in to shared identity.

## Decision

Format v2 declares `kind`, `credentials`, optional `namespace`, `body_limit_bytes` and `rate_limit`; the root can declare `namespaces`. Only `alertmanager` is supported initially. Read format v1 as one bearer credential from `token_ref`, with the default budget and its existing namespace. New snapshots use v2. An existing M1 installation must bump the revision once; rotating a source token requires a new reference. Namespace defaults to the source UUID; v2 shared names must be explicitly declared, unique, 1–128 UTF-8 bytes, not UUID-shaped, with at most 64 declarations.

Store one to four bearer or HMAC credentials per source in `ingest_source_credential`, unique by `(sourceId, reference)`, with digest and optional validity bounds. Add `ingest_source.kind` with a persisted `alertmanager` default and drop the old digest column in the same migration as the bearer cutover. Kind mismatches are indistinguishable from unknown sources. Evaluate validity at receipt, compare every eligible credential without secret-dependent early exits, and recheck the credential, source kind, enabled state, and path-token policy under a source `FOR SHARE` lock before inserting raw or transport-key rows.

Bearer authentication precedes body buffering. HMAC uses `X-Correlia-Timestamp` (Unix seconds, decimal digits as sent, at most ten digits, within ±300 seconds) and `X-Correlia-Signature: sha256=<64 lowercase hex digits>`. The HMAC-SHA256 input is exactly `ASCII(timestamp) || 0x2e || ASCII(K) || 0x2e || body`, where `K` is `-` if `Idempotency-Key` is absent and otherwise the 64 lowercase hex characters of SHA-256 over its UTF-8 value. Verify after the bounded read using the exact body bytes. HMAC keys are not bearer or path tokens.

Use an authenticated per-source token bucket per API process: default 20 requests/second, burst 40; allowed values 1–1000 and 1–10000. Spend after credential verification (before the read for bearer, after signature verification for HMAC). Rekey on revision changes. Exhaustion returns 429 and a whole-second `Retry-After` of at least one without inserting a raw row.

## Alternatives and reversal cost

Rejected: credential lists only in snapshot JSON, signing without binding timestamp and idempotency key, rate limiting before authentication, and implicit namespace sharing. Reversal cost is medium for the sender signing contract once deployed; changing the local budget algorithm or parser is low cost.

## Consequences

Old and new credentials can overlap without letting a revoked credential commit after publication. Sender-specific abuse cannot spend another source's budget without authenticating, and replica count multiplies the effective budget. Namespace sharing changes identity only when explicitly configured.
