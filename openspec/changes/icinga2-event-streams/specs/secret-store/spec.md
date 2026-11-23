# Spec Delta

## MODIFIED Requirements

### Requirement: Secret bytes never leave their consumer

Secret bytes SHALL pass only to their consumer: verification, signing, TLS or basic authentication, plugin
Configure, or the reuse check. Responses, snapshots, events, raw rows, diagnostics, attempt and status rows,
activity, logs and process output SHALL NOT expose secret values or copy credential echoes. A coincidental
match in fixed metadata or serialization syntax is not an echo.

#### Scenario: SEC-3 plugin config secret
- **WHEN** a plugin output with a secret reference is published, configured, fails a Configure call with an error echoing the secret, and is read back through every existing endpoint and the public snapshot, with console and persistent logging enabled
- **THEN** the plugin receives the bytes at Configure, the stored record is ciphertext only, and the secret bytes and their base64url form appear in no response, snapshot, status row, failure row, log or captured process output

#### Scenario: Decryption failure stays sanitized
- **WHEN** resolution fails for integrity, key mismatch or a database error while console and persistent logging are enabled
- **THEN** the logged diagnostic contains the reference name and a fixed code only, never ciphertext, nonce, plaintext or key material

#### Scenario: Stream password and CA
- **WHEN** a stream source connects, fails authentication with an error echoing the password, and is read back through every endpoint and the status method with console and persistent logging enabled
- **THEN** only the consumer's TLS context and authorization header received the bytes, and the password and CA bytes appear in no response, snapshot, status row, failure row or log

## ADDED Requirements

### Requirement: Icinga 2 API passwords and CA bundles

A stream source's `password_ref` (1 to 1024 bytes) and `ca_ref` (a PEM bundle of at most 16 KiB) SHALL be
stored as encrypted records with keyed commitments, never a bare SHA-256. Their bytes SHALL be resolved only by
the consumer that uses them and by publication's reuse check.

#### Scenario: Password imported
- **WHEN** a stream source is published with a password in the operator secret file
- **THEN** its record is ciphertext with an `hmac-sha256:` commitment, and the snapshot, status and logs hold no password bytes and no bare digest of them

#### Scenario: CA bundle too large
- **WHEN** the `ca_ref` value in the operator secret file is larger than 16 KiB
- **THEN** activation fails with a field error at `secrets.value` for that reference, and the prior snapshot stays active

### Requirement: Passwords never share bytes with a bare commitment

A publication SHALL fail with `password_reuse` when the bytes of a stream password equal the bytes of any secret
whose commitment is a bare SHA-256 (source credentials, webhook signing keys, historical M1 pins), under any
reference, whichever was published first, also when the earlier one was since removed or rotated, and also
within one publication.

#### Scenario: Password equals a signing key
- **WHEN** a stream password reference holds the same 32 bytes as an existing webhook signing key reference
- **THEN** activation fails with `password_reuse` naming only the password field path, and the prior snapshot stays active

#### Scenario: Credential added after the password
- **WHEN** a stream password is published, and a later revision adds a source credential whose bytes equal it
- **THEN** that revision fails with `password_reuse`, and no bare digest of the password is stored

#### Scenario: Credential added after the password was rotated away
- **WHEN** password P is published, a later revision rotates it to Q, and a third revision adds a source credential whose bytes equal P
- **THEN** the third revision fails with `password_reuse`

#### Scenario: Same bytes in one publication
- **WHEN** one publication adds a stream password and a source credential with equal bytes
- **THEN** it fails with `password_reuse`

#### Scenario: Different bytes
- **WHEN** a stream password differs from every bare-commitment secret
- **THEN** activation succeeds

### Requirement: Reuse digests are kept for every published secret

Every bare commitment and, for every password, a reuse digest (HMAC-SHA256 under the commitment key over a fixed
domain and the bytes, with no reference) SHALL be kept for as long as the store exists. A new password's SHA-256
SHALL be checked against every bare commitment, and a new bare-commitment secret's reuse digest against every
password reuse digest.

#### Scenario: Reuse digest holds no bare digest
- **WHEN** a password is published
- **THEN** its reuse digest row differs from the SHA-256 of its bytes, and recomputing it needs the commitment key

#### Scenario: Removed password still checked
- **WHEN** a password is removed from the configuration, and a later revision adds a signing key with its bytes
- **THEN** that revision fails with `password_reuse`

#### Scenario: Upgrade with removed secrets
- **WHEN** a database holds a historical snapshot with a credential since removed and a webhook signing key whose reference now has a keyed record, and the first stream password with the same bytes as either is published
- **THEN** the publication fails with `password_reuse`, because the reuse inventory was filled from every stored snapshot, commitment row and source credential row before the first password publication

### Requirement: The reuse inventory is complete before the first password

Up to boundaries recorded by this release's schema step, the reuse inventory SHALL be filled from every digest
field of every historical snapshot format (credential, `token_digest`, signing-key and bare plugin `secret_refs`
commitments) and every commitment and credential row, in bounded passes outside the publication lock, each
resuming from its own mark. A password publication SHALL fail `reuse_inventory_pending` until every
pass has completed.

#### Scenario: Password published during the backfill
- **WHEN** a stream password is published while the backfill has not finished
- **THEN** activation fails with `reuse_inventory_pending`, and the prior snapshot stays active

#### Scenario: Backfill interrupted
- **WHEN** the process stops halfway through the backfill and starts again
- **THEN** the backfill resumes from its mark, inserts no digest twice, and the first password can be published once every pass has completed

#### Scenario: Interrupted between passes
- **WHEN** the process stops after the snapshot pass completed and before the credential-row pass started, and starts again
- **THEN** the snapshot pass is not repeated, the credential-row pass runs, and passwords stay refused with `reuse_inventory_pending` until it completes

#### Scenario: Outbox pins are covered by snapshots
- **WHEN** the backfill has completed on a database with webhook and plugin outbox rows
- **THEN** every distinct outbox signing commitment equals one in its pinned snapshot and is in the inventory

#### Scenario: Large history
- **WHEN** the database holds 10,000 historical snapshots and 100,000 commitment and credential rows
- **THEN** every pass reads batches of at most 500 rows, and publications of other sources are not blocked by it

#### Scenario: Format version 1 token digest
- **WHEN** the only copy of a removed source's bare digest is the `token_digest` of a format version 1 snapshot, and a stream password with its bytes is published after the backfill
- **THEN** the publication fails with `password_reuse`

#### Scenario: Bare plugin commitment only in a pinned snapshot
- **WHEN** a plugin output's bare commitment survives only in the `secret_refs` of the snapshot an outbox row is pinned to, with no commitment row and no signing commitment, and a stream password with its bytes is published after the backfill
- **THEN** the publication fails with `password_reuse`

### Requirement: Only this release or newer publishes after the upgrade

Once this release's schema step has run, the database SHALL refuse a configuration publication from a process
that does not declare this release's publisher version or newer, so no process of an older release, of any role,
can publish a bare commitment after a password is accepted. The schema step SHALL record the backfill boundaries
and install this refusal in one transaction holding the publication lock.

#### Scenario: Publication in flight at the cutover
- **WHEN** an older process holds the publication lock with its snapshot inserted but not committed as this release's schema step starts
- **THEN** the step waits for it, the older snapshot is within the recorded boundary and its digests are backfilled, and no later publication by the older process commits

#### Scenario: Older process publishes after the upgrade
- **WHEN** after the schema step an older-release `api` process tries to activate a revision adding a source credential
- **THEN** the database refuses it, no snapshot or commitment is written, and the active revision is unchanged

#### Scenario: Rollback after a password was published
- **WHEN** a stream password is published and a process of the previous release then starts with a new configuration revision
- **THEN** its publication is refused, and the password's bytes never appear under a bare commitment
