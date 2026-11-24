CREATE TABLE icinga2_sync_progress (
  sync_id uuid PRIMARY KEY,
  source_id uuid NOT NULL,
  phase text NOT NULL CHECK (phase IN ('reading','applying','complete','failed','stalled')),
  rows_admitted bigint NOT NULL DEFAULT 0,
  rows_done bigint NOT NULL DEFAULT 0,
  rows_failed bigint NOT NULL DEFAULT 0,
  counts jsonb NOT NULL DEFAULT '{}'::jsonb,
  started_at timestamptz NOT NULL,
  read_end_at timestamptz,
  read_problem text,
  ended_at timestamptz,
  reason text
);
CREATE INDEX icinga2_sync_progress_source_idx ON icinga2_sync_progress (source_id, started_at DESC);

ALTER TABLE alerts ADD COLUMN silent_tombstone boolean NOT NULL DEFAULT false;
CREATE INDEX alerts_silent_tombstone_idx ON alerts ("fenceEffectiveSeconds", "fenceEffectiveNanos", id)
  WHERE silent_tombstone;
CREATE INDEX raw_pending_receipt_idx ON raw_inbox (observed_at) WHERE status='pending';
CREATE INDEX activity_entity_idx ON activity (entity_kind, entity_id);
CREATE INDEX observation_keys_fingerprint_idx ON observation_keys (fingerprint);

CREATE FUNCTION correlia_event_subject(value bytea) RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
RETURN convert_from(value, 'UTF8')::jsonb->>'subject';
CREATE INDEX events_subject_idx ON events (correlia_event_subject(payload));

CREATE TABLE raw_admission_cutoff (
  singleton integer PRIMARY KEY CHECK (singleton=1),
  cutoff timestamptz NOT NULL DEFAULT '-infinity',
  cursor_seconds bigint NOT NULL DEFAULT 0,
  cursor_nanos bigint NOT NULL DEFAULT 0,
  cursor_id bigint NOT NULL DEFAULT 0
);
INSERT INTO raw_admission_cutoff (singleton) VALUES (1);

CREATE FUNCTION correlia_enforce_raw_admission_cutoff() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  minimum timestamptz;
  threshold timestamptz;
BEGIN
  SELECT min(observed_at) INTO minimum FROM incoming_raw;
  IF minimum IS NULL THEN RETURN NULL; END IF;
  SELECT cutoff INTO threshold FROM raw_admission_cutoff WHERE singleton=1 FOR SHARE;
  IF minimum < threshold THEN
    RAISE EXCEPTION USING ERRCODE='CR001', MESSAGE='raw admission receipt is before the cutoff';
  END IF;
  RETURN NULL;
END;
$$;
CREATE TRIGGER raw_admission_cutoff_fence AFTER INSERT ON raw_inbox
  REFERENCING NEW TABLE AS incoming_raw FOR EACH STATEMENT
  EXECUTE FUNCTION correlia_enforce_raw_admission_cutoff();
