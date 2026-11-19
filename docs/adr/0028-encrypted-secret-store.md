# 0028. Encrypted secret store under an external key

- Status: accepted (2026-11-18)
- Date: 2026-11-18
- Supersedes: none
- Chosen by: agent (D31 assumed default; D31 remains open for the owner). Historical M1 import and shared references were chosen by the owner.

## Context

Operator files supply source credentials, webhook signing keys and plugin secrets. Runtime processes need those bytes without keeping the import file, and a PostgreSQL backup alone must not expose them. Existing M1 pinned commitments and definition digests cannot change.

## Decision

With ingest configured, read the key from `CORRELIA_SECRET_KEY_FILE`: a regular, non-symlink file owned by the process user, mode 0600 or stricter, containing exactly 43 canonical unpadded base64url characters (32 decoded bytes), optionally followed by one newline. No key is needed without ingest configuration. Fail closed with bounded diagnostics.

Store one immutable `secret_record` per reference: algorithm `aes-256-gcm-v1`, 12-byte nonce from OpenSSL `RAND_bytes`, ciphertext followed by the 16-byte tag, plaintext commitment, key commitment and creation time. Use AES-256-GCM through OpenSSL 3 EVP FFI and clear native buffers before freeing them. Authenticate the tuple `(correlia-secret-v1, reference, commitment, keyCommitment)` as length-prefixed UTF-8. The key commitment is SHA-256 over UTF-8 `correlia-kek-commitment-v1` followed by the raw key.

Bare lowercase 64-hex commitments mean SHA-256 of the secret bytes. Keep that scheme for 32-byte source credentials and webhook signing keys and for immutable M1 pins. New plugin commitments are `hmac-sha256:<hex>`: HMAC-SHA256 over UTF-8 `correlia-plugin-secret-v1`, the UTF-8 reference, then the bytes, keyed with a 32-byte HKDF-SHA256 output derived from the encryption key with info `correlia-commitment-key-v1`. A consumer verifies its pinned scheme independently of the record's scheme. Do not rewrite M1 pins; rotate low-entropy M1 plugin secrets to new references because historical bare hashes remain in the database.

The locked publication transaction imports new references from the operator file, including material matching commitments pinned by live M1 work. It refuses rebinding and key mismatch. Runtime consumers use the store and a process-local LRU (1024 entries, 16 MiB plaintext); a cache miss loads and decrypts the record and verifies the caller's commitment. Webhook discovery matches references; an attempt requires successful resolution of its pinned commitment. Webhooks and plugins can share identical material under one reference.

## Alternatives and reversal cost

Rejected: runtime plaintext files, keys stored in the database or environment, a single ciphertext blob, and new bare SHA-256 hashes of variable-length plugin secrets. Reversal cost is medium: a new algorithm or key needs an explicit re-seal, and new keyed commitments change plugin definition digests.

## Consequences

The database and its backups contain ciphertext, not the external key. Restore requires that key; rotation and the restore drill are separate work. Secret bytes and cryptographic diagnostics never appear in public snapshots, logs or API responses.
