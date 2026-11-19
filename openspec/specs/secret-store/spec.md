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

Secret bytes SHALL be passed only to the component that uses them: credential verification, webhook signing, or a plugin's Configure call. They SHALL never appear in endpoint responses, public snapshots, events, raw rows, pipeline failures, delivery attempts, plugin status, activity entries, session logs or process output.

#### Scenario: SEC-3 plugin config secret
- **WHEN** a plugin output with a secret reference is published, configured, fails a Configure call with an error echoing the secret, and is read back through every existing endpoint and the public snapshot, with console and persistent logging enabled
- **THEN** the plugin receives the bytes at Configure, the stored record is ciphertext only, and the secret bytes and their base64url form appear in no response, snapshot, status row, failure row, log or captured process output

#### Scenario: Decryption failure stays sanitized
- **WHEN** resolution fails for integrity, key mismatch or a database error while console and persistent logging are enabled
- **THEN** the logged diagnostic contains the reference name and a fixed code only, never ciphertext, nonce, plaintext or key material
