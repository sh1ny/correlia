# 0009. Identity and access: Serverpod auth for people, scoped tokens for machines

- Status: accepted (2026-11-03)
- Date: 2026-11-03
- Supersedes: none

## Context

The legacy service used shared bearer tokens and took the operator's name from a request field (legacy 7.4,
lesson P0.5). A Flutter web bundle cannot hold a shared secret. Serverpod 4.1 auth supports email OTP,
Google, Apple, GitHub, Microsoft and passkeys. It has no generic OIDC provider, and its scopes are flat.

## Decision

- **People** sign in through Serverpod auth, email OTP first.
  - Roles: viewer, operator, admin.
  - Per-team permissions are implemented in Correlia on top of Serverpod scopes.
  - Generic OIDC (Keycloak, Authentik, Entra) is a custom identity provider, delivered before 1.0.
- **Machines** use scoped tokens:
  - one ingest credential per source instance: a bearer token or HMAC signature, rotatable, never shared
    across sources;
  - API keys with scopes, for automation.
- **Admission:** sign-up is invite-only by default. An admin invites an email address with a role; email
  OTP only signs in invited addresses. Optional: an allowed email domain auto-joins as viewer. The first
  admin is created by a one-time bootstrap token printed to the server log on first start (and by a CLI
  command), which expires once used.
- **Permissions on data:** raw payloads and source configuration are readable only with the `raw:read`
  permission (admin by default); operators see canonical events. Plugin secrets are write-only through the
  API.
- **Redaction:** URL-path tokens, `Authorization` headers, HMAC signatures and query-string secrets are
  redacted before anything is logged (Serverpod session logs, request logs, error reports). The raw inbox
  stores the body and a per-source header allowlist only.
- Every write records the authenticated actor in the activity ledger (ADR 0007).
- Single tenant in 1.0. The `tenant` field exists in the event format and the keys, fixed to `default`.

Rejected: shared operator tokens (legacy). Reversal cost: medium.

## Consequences

- Some webhook senders cannot send headers. Those need a token in the URL path, scoped to ingest only.
- Multi-tenancy can be added later without changing the event format.
