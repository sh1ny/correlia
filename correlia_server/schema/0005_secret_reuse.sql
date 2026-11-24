SELECT pg_advisory_xact_lock(1129271884);

CREATE TABLE secret_reuse_digest (
  kind text NOT NULL CHECK (kind IN ('bare', 'password')),
  digest text NOT NULL CHECK (digest ~ '^[0-9a-f]{64}$'),
  PRIMARY KEY (kind, digest)
);

CREATE TABLE secret_reuse_retired_credential (
  digest text PRIMARY KEY CHECK (digest ~ '^[0-9a-f]{64}$')
);

CREATE TABLE secret_reuse_backfill (
  singleton integer PRIMARY KEY CHECK (singleton = 1),
  snapshot_boundary bigint NOT NULL,
  commitment_boundary bigint NOT NULL,
  credential_boundary bigint NOT NULL,
  snapshot_mark bigint NOT NULL DEFAULT 0,
  commitment_mark bigint NOT NULL DEFAULT 0,
  credential_mark bigint NOT NULL DEFAULT 0,
  complete boolean NOT NULL DEFAULT false
);

INSERT INTO secret_reuse_backfill
  (singleton, snapshot_boundary, commitment_boundary, credential_boundary)
SELECT 1,
  COALESCE((SELECT s.revision FROM ingest_active_config a
    JOIN ingest_config_snapshot s ON s."snapshotId" = a."snapshotId"
    WHERE a.singleton = 1), 0),
  COALESCE((SELECT max(id) FROM ingest_secret_commitment), 0),
  COALESCE((SELECT max(id) FROM ingest_source_credential), 0);

CREATE FUNCTION correlia_require_publisher_version() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF COALESCE(NULLIF(current_setting('correlia.publisher_version', true), ''), '0')::integer < 1 THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'outdated configuration publisher';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER correlia_publisher_version
  BEFORE INSERT ON ingest_config_snapshot
  FOR EACH ROW EXECUTE FUNCTION correlia_require_publisher_version();
CREATE TRIGGER correlia_publisher_version
  BEFORE INSERT ON ingest_secret_commitment
  FOR EACH ROW EXECUTE FUNCTION correlia_require_publisher_version();

CREATE FUNCTION correlia_keep_retired_credential_digest() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.id <= (SELECT credential_boundary FROM secret_reuse_backfill WHERE singleton = 1)
      AND OLD.digest ~ '^[0-9a-f]{64}$' THEN
    INSERT INTO secret_reuse_retired_credential (digest) VALUES (OLD.digest)
      ON CONFLICT DO NOTHING;
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER correlia_keep_retired_credential_digest
  BEFORE UPDATE OR DELETE ON ingest_source_credential
  FOR EACH ROW EXECUTE FUNCTION correlia_keep_retired_credential_digest();
