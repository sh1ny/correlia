# Spec Delta

## MODIFIED Requirements

### Requirement: Signing key availability before acquisition

A relay SHALL acquire a webhook intent only if its stored signing key matches the pinned commitment. An unavailable key leaves work queued with no attempt and a fixed, sanitized diagnostic. Dead intents retain their commitments and need keys only for future explicit replay. Plugin intents have no signing reference; plugin supervision governs their availability.

#### Scenario: Loaded historical signing reference
- **WHEN** an intent retains an older output definition whose committed signing key is in the store
- **THEN** it is delivered under that original key even though the active configuration uses a newer reference

#### Scenario: Unloaded live signing reference
- **WHEN** a running relay encounters queued work whose pinned signing reference cannot be resolved from the store
- **THEN** its intents remain queued, no attempt is started, the sanitized availability diagnostic appears and unrelated outputs continue delivering

#### Scenario: Plugin intents need no signing reference
- **WHEN** a relay discovers queued plugin intents, which have no signing reference
- **THEN** signing-key availability neither blocks nor admits them, and their acquisition follows plugin readiness

### Requirement: Kind-aware startup validation

Startup SHALL require matching stored signing material only for live webhook intents; publication may import it in the same transaction. Publication SHALL import supplied historical plugin secrets that match live pins without changing those pins. Missing historical plugin secrets SHALL NOT block startup; they are checked at plugin launch. Publication SHALL record webhook and plugin secret commitments and reject reference rebinding.

#### Scenario: Restart with pending unauthenticated plugin work
- **WHEN** a worker restarts while queued and delivering intents exist for a NATS output that uses no secrets
- **THEN** startup succeeds, expired claims are recovered and the intents are delivered

#### Scenario: Mixed live work with a missing plugin secret
- **WHEN** live webhook intents have matching signing keys in the store, and live intents of an older plugin definition reference a secret absent from both the store and the import file
- **THEN** the worker starts, the webhook intents are delivered, and the plugin intents stay queued with zero new attempts and status `plugin_secret_unavailable`

#### Scenario: Missing webhook key still fails startup
- **WHEN** a live webhook intent's signing reference is absent from the store and the import file
- **THEN** startup fails with `historical_key_unavailable`

#### Scenario: Plugin secret reference rebound
- **WHEN** a new snapshot binds an existing plugin secret reference to different bytes
- **THEN** activation fails with `reference_rebound` and the active snapshot stays unchanged

#### Scenario: M1 work with historical secret references drains after upgrade
- **GIVEN** live M1 webhook and plugin intents whose pinned secret references are absent from the upgraded configuration but present in the M1 secret file
- **WHEN** the upgraded process publishes with that file and a valid key, then restarts at a higher revision without the file
- **THEN** the historical references are imported and both intents deliver using the original bytes and unchanged pinned commitments

### Requirement: Validated plugin output definitions

Bootstrap SHALL accept outputs of kind `webhook` or `plugin`. A plugin output SHALL name:
- an executable in the plugin directory and its SHA-256;
- a bounded JSON config object;
- secret references resolvable from the secret store or the import file, stored in the public definition only as commitments.

An invalid definition SHALL fail activation with a field error and leave the active snapshot unchanged.

#### Scenario: Plugin output activates
- **WHEN** bootstrap defines a plugin output with a valid name, digest, config and resolvable secret reference, and a source routes to it
- **THEN** the snapshot activates, its stored definition holds the secret commitment but no secret value, and new intents for that output pin the definition

#### Scenario: Invalid plugin output
- **WHEN** a plugin output has an unknown kind, a path outside the plugin directory, a malformed digest, a config above its size bound or an unresolvable secret reference
- **THEN** activation fails with a field error naming that output field, and the previously active snapshot and routes stay unchanged
