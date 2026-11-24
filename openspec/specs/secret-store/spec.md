# secret-store Specification

## Purpose
Keeps operator secrets (source credentials, webhook signing keys, plugin secrets) encrypted at rest in
PostgreSQL under a key that never enters the database, and keeps secret bytes out of every API response, log,
snapshot, event and diagnostic.

## Requirements

### Requirement: External key-encryption key

Every process with ingest configured SHALL read a 32-byte key-encryption key from the regular file named by `CORRELIA_SECRET_KEY_FILE`, owned by the process user with mode 0600 or stricter, symlinks rejected. The key SHALL never be written to PostgreSQL, logs or diagnostics. A missing, malformed, wrongly owned or wrongly permissioned key file SHALL fail startup with only file kind, field and code.

#### Scenario: Key file accepted
- **WHEN** a process starts with ingest configured and a valid 0600 key file owned by its user
- **THEN** it starts, and no database table or log line contains the key bytes or their base64url text

#### Scenario: Key file rejected
- **WHEN** the key file is absent, group-readable, a symlink, owned by another user, or does not decode to exactly 32 bytes
- **THEN** startup fails with a bounded `secret_key` file-kind error naming the code, and the key file content never appears in output

### Requirement: Encrypted secret records

Each stored secret SHALL be one record per reference holding only AES-256-GCM ciphertext, a unique random nonce, the commitment of the plaintext (SHA-256 for 32-byte credentials and signing keys, keyed by the key-encryption key for plugin secrets) and the commitment of the key-encryption key that sealed it. The reference name and both commitments SHALL be authenticated with the ciphertext. A reference SHALL never be rebound to different bytes.

#### Scenario: Import seals secrets
- **WHEN** a publication names references present in the operator secret file and absent from the store
- **THEN** one record per reference is committed with the publication, its ciphertext differs from the plaintext, and decrypting it with the key yields bytes whose commitment equals the snapshot's commitment

#### Scenario: Rebinding refused
- **WHEN** a publication supplies different bytes for a reference that is already stored
- **THEN** activation fails with a bounded `reference_rebound` error, the stored record and the active snapshot are unchanged

#### Scenario: Tampered or moved record
- **WHEN** a stored record's ciphertext, nonce or commitment is altered, or its sealed bytes are copied to another reference name
- **THEN** resolving that reference fails authentication, the dependent source or output is unavailable with a bounded `secret_integrity` reason, and other references still resolve

### Requirement: Resolution from the store

Processes SHALL resolve secret bytes from the store by reference, verifying the plaintext against the commitment in the active snapshot. The operator secret file SHALL be required only when the configuration names a reference not yet stored. A record sealed under a different key SHALL fail resolution with `key_mismatch` before any decryption attempt.

#### Scenario: Secret file not needed after import
- **WHEN** a revision has been published with its secrets imported and a process later starts with the same configuration file and key file but no secret file
- **THEN** the process starts, admits requests with the stored source credentials and signs deliveries with the stored signing keys

#### Scenario: New reference without secret file
- **WHEN** a process starts with a configuration naming a reference absent from the store and no secret file
- **THEN** startup fails with a bounded `missing_secret` field error and the prior active snapshot remains active

#### Scenario: M1 plugin work drains after upgrade
- **GIVEN** a database holding queued plugin deliveries pinned to an M1 definition whose secret commitment is a plain SHA-256
- **WHEN** the process is upgraded, started once with the M1 secret file and a key file, then restarted without the secret file under a new revision
- **THEN** the queued deliveries are configured with the same secret bytes and delivered, their pinned definition digest is unchanged, and new snapshots carry only keyed plugin-secret commitments

#### Scenario: Historical outputs drain after a revision change
- **WHEN** webhook and plugin deliveries are queued under revision A, revision B removes both outputs' secret references from the active configuration, and the process keeps running
- **THEN** both deliveries are attempted with their original keys without a restart, and no delivery waits on the active configuration containing its reference

#### Scenario: Plugin and webhook share a stored reference
- **WHEN** a plugin and a webhook use the same reference and bytes with different commitment schemes
- **THEN** both resolve their pinned commitments from the same record, and neither starts an attempt with a mismatched commitment

#### Scenario: More stored references than a process caches
- **WHEN** successive publications have stored more secret references than one process keeps decrypted in memory, and requests and deliveries use references across all of them
- **THEN** every valid credential authenticates and every delivery resolves its key; none is rejected or delayed past one store read because of the number of stored references

#### Scenario: Wrong key after restore
- **WHEN** a database restored from backup is started with a key file different from the one that sealed its records
- **THEN** startup fails with `key_mismatch` naming no secret reference value, and no record is altered or re-sealed

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

A publication SHALL fail with `password_reuse` when a stream password equals any secret with a bare SHA-256
commitment, including source credentials, webhook signing keys, and historical M1 pins. The check applies
under any reference, whichever value was published first, and within one publication. Removing or rotating
either secret SHALL NOT permit reuse of its prior bytes.

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

The reuse inventory SHALL read all historical snapshot digest fields and all commitment and credential
rows up to cutover boundaries, in bounded passes outside the publication lock with separate resume
marks. At cutover a trigger SHALL retain old pre-cutover credential digests transactionally in a separate
append-only set included in reuse checks. Passwords SHALL fail `reuse_inventory_pending` until all passes finish.

#### Scenario: Password published during the backfill
- **WHEN** a stream password is published while the backfill has not finished
- **THEN** activation fails with `reuse_inventory_pending`, and the prior snapshot stays active

#### Scenario: Backfill interrupted
- **WHEN** the process stops halfway through the backfill and starts again
- **THEN** the backfill resumes from its mark, inserts no digest twice, and the first password can be published once every pass has completed

#### Scenario: Interrupted between passes
- **WHEN** the process stops after the snapshot pass completed and before the credential-row pass started, and starts again
- **THEN** the snapshot pass is not repeated, the credential-row pass runs, and passwords stay refused with `reuse_inventory_pending` until it completes

#### Scenario: A credential row disappears before its backfill batch
- **WHEN** a digest exists only in a pre-cutover credential row and a webhook publication replaces that row before the credential pass reads it
- **THEN** the digest is in the inventory after backfill and a stream password with those bytes fails with `password_reuse`

#### Scenario: Outbox pins are covered by snapshots
- **WHEN** the backfill has completed on a database with webhook and plugin outbox rows
- **THEN** every distinct outbox signing commitment equals one in its pinned snapshot and is in the inventory

#### Scenario: Publication overlaps a backfill write
- **WHEN** a webhook publication replaces pre-cutover credentials while a backfill batch writes overlapping digests
- **THEN** both transactions complete without a lock cycle and the batch mark advances

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

After this release's schema step, the database SHALL refuse publication by an older release of any role.
A publisher must declare this release's publisher version or newer. The schema step SHALL record the
backfill boundaries and install the publisher-version trigger in one transaction holding the publication
lock.

#### Scenario: Publication in flight at the cutover
- **WHEN** an older process holds the publication lock with its snapshot inserted but not committed as this release's schema step starts
- **THEN** the step waits for it, the older snapshot is within the recorded boundary and its digests are backfilled, and no later publication by the older process commits

#### Scenario: Older process publishes after the upgrade
- **WHEN** after the schema step an older-release `api` process tries to activate a revision adding a source credential
- **THEN** the database refuses it, no snapshot or commitment is written, and the active revision is unchanged

#### Scenario: Rollback after a password was published
- **WHEN** a stream password is published and a process of the previous release then starts with a new configuration revision
- **THEN** its publication is refused, and the password's bytes never appear under a bare commitment
