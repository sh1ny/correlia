-- Offline cutover. Stop every old process before running this step.
LOCK TABLE raw_inbox, events, outbox IN ACCESS EXCLUSIVE MODE;
SET LOCAL TIME ZONE 'UTC';

-- The parent's event type changes, and parent-targeted INSERT statements need
-- their own transition table trigger. Neither can stay bound to the old heap.
DROP FUNCTION events_effective_source_time(events);
DROP TRIGGER raw_admission_cutoff_fence ON raw_inbox;

ALTER TABLE raw_inbox RENAME TO legacy_raw_inbox;
ALTER TABLE events RENAME TO legacy_events;
ALTER TABLE outbox RENAME TO legacy_outbox;
ALTER INDEX raw_inbox_pkey RENAME TO legacy_raw_inbox_pkey;
ALTER INDEX raw_inbox_eligibility_idx RENAME TO legacy_raw_inbox_eligibility_idx;
ALTER INDEX raw_pending_receipt_idx RENAME TO legacy_raw_pending_receipt_idx;
ALTER INDEX raw_stream_retained_idx RENAME TO legacy_raw_stream_retained_idx;
ALTER INDEX events_pkey RENAME TO legacy_events_pkey;
ALTER INDEX events_subject_idx RENAME TO legacy_events_subject_idx;
ALTER INDEX outbox_pkey RENAME TO legacy_outbox_pkey;
ALTER INDEX outbox_eligibility_idx RENAME TO legacy_outbox_eligibility_idx;
ALTER INDEX outbox_definition_status_idx RENAME TO legacy_outbox_definition_status_idx;

ALTER TABLE legacy_raw_inbox
  ADD COLUMN queued_at timestamptz,
  ADD COLUMN processing_epoch bigint NOT NULL DEFAULT 0;
ALTER TABLE legacy_events
  ALTER COLUMN raw_observed_at DROP NOT NULL,
  ALTER COLUMN raw_id DROP NOT NULL,
  ADD COLUMN system_activity_id bigint,
  ADD CONSTRAINT events_origin_check CHECK (
    (raw_observed_at IS NOT NULL AND raw_id IS NOT NULL AND system_activity_id IS NULL)
    OR (raw_observed_at IS NULL AND raw_id IS NULL AND system_activity_id IS NOT NULL)
  );
ALTER TABLE legacy_outbox
  ADD COLUMN terminal_at timestamptz,
  ADD COLUMN retry_base integer NOT NULL DEFAULT 0;

-- Do not expire older failures based on when the intent was created. In the
-- absence of matching attempt evidence, give the row the full new window.
UPDATE legacy_outbox o SET terminal_at = COALESCE((
  SELECT a."finishedAt" AT TIME ZONE 'UTC' FROM delivery_attempts a
  WHERE a."outboxCreatedAt" = o.created_at AT TIME ZONE 'UTC'
    AND a."deliveryId" = o.delivery_id AND a."finishedAt" IS NOT NULL
    AND ((o.status = 'delivered' AND a.outcome = 'acknowledged')
      OR (o.status = 'dead' AND a.outcome IN ('permanent', 'retryable', 'interrupted')))
  ORDER BY a."attemptNumber" DESC LIMIT 1
), transaction_timestamp())
WHERE o.status IN ('dead', 'delivered');

CREATE TABLE pipeline_icinga2_replay_floor (
  singleton integer PRIMARY KEY CHECK (singleton = 1),
  receipt_floor timestamptz NOT NULL
);
INSERT INTO pipeline_icinga2_replay_floor (singleton, receipt_floor)
SELECT singleton, cutoff FROM raw_admission_cutoff;

CREATE TABLE raw_inbox (
  LIKE legacy_raw_inbox INCLUDING ALL EXCLUDING INDEXES,
  PRIMARY KEY (observed_at, raw_id)
) PARTITION BY RANGE (observed_at);
CREATE TABLE events (
  LIKE legacy_events INCLUDING ALL EXCLUDING INDEXES,
  PRIMARY KEY (observed_at, event_id, disposition)
) PARTITION BY RANGE (observed_at);
CREATE TABLE outbox (
  LIKE legacy_outbox INCLUDING ALL EXCLUDING INDEXES,
  PRIMARY KEY (created_at, delivery_id)
) PARTITION BY RANGE (created_at);

CREATE INDEX raw_inbox_eligibility_idx ON raw_inbox (status, next_attempt_at);
CREATE INDEX raw_pending_receipt_idx ON raw_inbox (observed_at) WHERE status = 'pending';
CREATE INDEX raw_stream_retained_idx ON raw_inbox (source_id) WHERE status IN ('pending', 'failed');
CREATE INDEX events_subject_idx ON events (correlia_event_subject(payload));
CREATE INDEX outbox_eligibility_idx ON outbox (status, next_attempt_at, output_id);
CREATE INDEX outbox_definition_status_idx ON outbox (output_id, definition_digest, status);

DO $cutover$
DECLARE
  parent text;
  partition_key text;
  legacy text;
  historical_end date;
  day date;
BEGIN
  FOR parent, partition_key IN VALUES
    ('raw_inbox', 'observed_at'), ('events', 'observed_at'), ('outbox', 'created_at')
  LOOP
    legacy := 'legacy_' || parent;
    EXECUTE format('SELECT max(%I)::date + 1 FROM %I', partition_key, legacy)
      INTO historical_end;
    IF historical_end IS NULL THEN
      EXECUTE format('DROP TABLE %I', legacy);
    ELSE
      EXECUTE format('ALTER TABLE %I ATTACH PARTITION %I FOR VALUES FROM (MINVALUE) TO (%L)',
        parent, legacy, historical_end);
    END IF;

    FOR offset_days IN -1..1 LOOP
      day := current_date + offset_days;
      IF historical_end IS NULL OR day >= historical_end THEN
        EXECUTE format('CREATE TABLE %I PARTITION OF %I FOR VALUES FROM (%L) TO (%L)',
          parent || '_' || to_char(day, 'YYYYMMDD'), parent, day, day + 1);
      END IF;
    END LOOP;
    EXECUTE format('CREATE TABLE %I PARTITION OF %I DEFAULT', parent || '_default', parent);
  END LOOP;
END $cutover$;

CREATE FUNCTION events_effective_source_time(e events) RETURNS timestamptz
LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT COALESCE(e.effective_source_time, LEAST(e.source_time, e.observed_at + interval '5 minutes'))
$$;
CREATE TRIGGER raw_admission_cutoff_fence AFTER INSERT ON raw_inbox
  REFERENCING NEW TABLE AS incoming_raw FOR EACH STATEMENT
  EXECUTE FUNCTION correlia_enforce_raw_admission_cutoff();

CREATE TABLE pipeline_queue_policy (
  singleton integer PRIMARY KEY CHECK (singleton = 1),
  pending_max_rows integer NOT NULL DEFAULT 50000,
  pending_max_age_seconds integer NOT NULL DEFAULT 30,
  disk_budget_bytes bigint,
  disk_watermark_percent integer NOT NULL DEFAULT 85,
  raw_retention_days integer NOT NULL DEFAULT 30,
  event_retention_days integer NOT NULL DEFAULT 90,
  outbox_retention_days integer NOT NULL DEFAULT 7,
  dead_letter_retention_days integer NOT NULL DEFAULT 14
);
INSERT INTO pipeline_queue_policy (singleton) VALUES (1);

CREATE TABLE pipeline_pending (
  singleton integer PRIMARY KEY CHECK (singleton = 1),
  pending_rows bigint NOT NULL CHECK (pending_rows >= 0)
);
INSERT INTO pipeline_pending SELECT 1, count(*) FROM raw_inbox WHERE status = 'pending';
CREATE INDEX raw_pending_age_idx ON raw_inbox (coalesce(queued_at, observed_at))
  WHERE status = 'pending';

CREATE TABLE pipeline_disk_sample (
  singleton integer PRIMARY KEY CHECK (singleton = 1),
  sampled_at timestamptz NOT NULL DEFAULT '-infinity',
  database_bytes bigint NOT NULL DEFAULT 0
);
INSERT INTO pipeline_disk_sample (singleton) VALUES (1);

CREATE TABLE pipeline_output_capacity (
  output_id uuid PRIMARY KEY,
  active boolean NOT NULL DEFAULT false,
  max_rows integer NOT NULL DEFAULT 500000,
  max_payload_bytes bigint NOT NULL DEFAULT 1073741824,
  overflow_policy text NOT NULL DEFAULT 'discard_new',
  used_rows bigint NOT NULL DEFAULT 0 CHECK (used_rows >= 0),
  used_bytes bigint NOT NULL DEFAULT 0 CHECK (used_bytes >= 0),
  live_rows bigint NOT NULL DEFAULT 0 CHECK (live_rows >= 0),
  pinned_rows bigint NOT NULL DEFAULT 0 CHECK (pinned_rows >= 0),
  demand_rows integer NOT NULL DEFAULT 0,
  demand_bytes bigint NOT NULL DEFAULT 0
);
CREATE INDEX pipeline_output_live_idx ON pipeline_output_capacity (output_id)
  WHERE live_rows > 0 OR pinned_rows > 0;
CREATE INDEX pipeline_output_blocking_idx ON pipeline_output_capacity (output_id)
  WHERE overflow_policy = 'block_ingest' AND (
    used_rows >= max_rows OR used_bytes >= max_payload_bytes
    OR demand_rows > max_rows - used_rows OR demand_bytes > max_payload_bytes - used_bytes
  );

CREATE TABLE pipeline_event_reference (
  observed_at timestamptz NOT NULL,
  event_id uuid NOT NULL,
  disposition text NOT NULL,
  protected_count bigint NOT NULL CHECK (protected_count >= 0),
  PRIMARY KEY (observed_at, event_id, disposition)
);

CREATE TABLE pipeline_output_commitment (
  reference text NOT NULL,
  commitment text NOT NULL,
  kind text NOT NULL,
  pinned_count bigint NOT NULL DEFAULT 0 CHECK (pinned_count >= 0),
  live_count bigint NOT NULL DEFAULT 0 CHECK (live_count >= 0),
  PRIMARY KEY (reference, commitment, kind)
);
CREATE INDEX pipeline_live_webhook_commitment_idx ON pipeline_output_commitment
  (reference, commitment) WHERE kind = 'webhook' AND live_count > 0;

-- Base routes plus any matcher route that could apply to this pinned source.
CREATE FUNCTION correlia_raw_pin_routes(p_snapshot text, p_source uuid)
RETURNS TABLE (output_id uuid)
LANGUAGE sql STABLE AS $$
  WITH enabled AS MATERIALIZED (
    SELECT doc, source
    FROM ingest_config_snapshot s
    CROSS JOIN LATERAL (SELECT s."publicJson"::jsonb AS doc) d
    CROSS JOIN LATERAL jsonb_array_elements(doc->'sources') source
    WHERE s."snapshotId"=p_snapshot AND source->>'id'=p_source::text
      AND source->'enabled'='true'::jsonb
  )
  SELECT route::uuid FROM enabled
  CROSS JOIN LATERAL jsonb_array_elements_text(source->'output_ids') route
  UNION
  SELECT (action->>'output_id')::uuid FROM enabled
  CROSS JOIN LATERAL jsonb_array_elements(doc->'matcher'->'rules') rule
  CROSS JOIN LATERAL jsonb_array_elements(rule->'actions') action
  WHERE action->>'type'='route'
$$;

CREATE FUNCTION correlia_snapshot_output_commitments(p_snapshot text, p_output uuid)
RETURNS TABLE (reference text, commitment text, kind text)
LANGUAGE sql STABLE AS $$
  WITH selected AS MATERIALIZED (
    SELECT output FROM ingest_config_snapshot s
    CROSS JOIN LATERAL jsonb_array_elements(s."publicJson"::jsonb->'outputs') output
    WHERE s."snapshotId"=p_snapshot AND output->>'id'=p_output::text
  )
  SELECT output->>'signing_key_ref', output->>'signing_key_commitment', 'webhook'
  FROM selected WHERE output->>'kind'='webhook'
  UNION
  SELECT value->>'reference', value->>'commitment', 'plugin' FROM selected
  CROSS JOIN LATERAL jsonb_each(output->'secret_refs')
  WHERE output->>'kind'='plugin'
$$;

CREATE FUNCTION correlia_pin_commitments(p_snapshot text, p_source uuid)
RETURNS TABLE (reference text, commitment text, kind text)
LANGUAGE sql STABLE AS $$
  SELECT DISTINCT c.* FROM correlia_raw_pin_routes(p_snapshot,p_source) r
  CROSS JOIN LATERAL correlia_snapshot_output_commitments(p_snapshot,r.output_id) c
$$;

CREATE FUNCTION correlia_intent_commitments(
  p_snapshot text, p_output uuid, p_kind text, p_ref text, p_commitment text
) RETURNS TABLE (reference text, commitment text, kind text)
LANGUAGE sql STABLE AS $$
  SELECT p_ref, p_commitment, p_kind WHERE p_kind='webhook'
  UNION ALL
  SELECT c.* FROM correlia_snapshot_output_commitments(p_snapshot,p_output) c
  WHERE p_kind='plugin' AND c.kind='plugin'
$$;

CREATE FUNCTION correlia_publish_queue_policy(doc jsonb) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  policy jsonb := doc->'pipeline_operations';
  lane record;
  budget jsonb;
BEGIN
  UPDATE pipeline_queue_policy SET
    pending_max_rows=coalesce((policy->>'pending_max_rows')::int,50000),
    pending_max_age_seconds=coalesce((policy->>'pending_max_age_seconds')::int,30),
    disk_budget_bytes=(policy->>'disk_budget_bytes')::bigint,
    disk_watermark_percent=coalesce((policy->>'disk_watermark_percent')::int,85),
    raw_retention_days=coalesce((policy->>'raw_retention_days')::int,30),
    event_retention_days=coalesce((policy->>'event_retention_days')::int,90),
    outbox_retention_days=coalesce((policy->>'outbox_retention_days')::int,7),
    dead_letter_retention_days=coalesce((policy->>'dead_letter_retention_days')::int,14)
  WHERE singleton=1;
  FOR lane IN
    SELECT id, bool_or(will_be_active) AS enabled FROM (
      SELECT (value->>'id')::uuid AS id, true AS will_be_active
      FROM jsonb_array_elements(doc->'outputs')
      UNION ALL SELECT output_id,false FROM pipeline_output_capacity WHERE active
    ) ids GROUP BY id ORDER BY id
  LOOP
    IF lane.enabled THEN
      budget := policy->'output_budgets'->(lane.id::text);
      INSERT INTO pipeline_output_capacity
        (output_id,active,max_rows,max_payload_bytes,overflow_policy)
      VALUES (lane.id,true,coalesce((budget->>'max_rows')::int,500000),
        coalesce((budget->>'max_payload_bytes')::bigint,1073741824),
        coalesce(budget->>'overflow_policy','discard_new'))
      ON CONFLICT (output_id) DO UPDATE SET active=true,
        max_rows=excluded.max_rows,max_payload_bytes=excluded.max_payload_bytes,
        overflow_policy=excluded.overflow_policy;
    ELSE
      UPDATE pipeline_output_capacity SET active=false WHERE output_id=lane.id;
    END IF;
  END LOOP;
END;
$$;

-- Count the legacy payload rows once. Everything after cutover reads counts
-- and adjusts them in the same transaction as the relevant state transition.
CREATE TEMP TABLE pipeline_cutover_pins ON COMMIT DROP AS
SELECT config_snapshot_id,source_id,count(*) AS row_count
FROM raw_inbox WHERE status='pending' AND config_snapshot_id IS NOT NULL
GROUP BY config_snapshot_id,source_id;

INSERT INTO pipeline_output_capacity (output_id,used_rows,used_bytes,live_rows)
SELECT output_id,count(*),sum(octet_length(payload)),
  count(*) FILTER (WHERE status IN ('queued','delivering'))
FROM outbox WHERE status IN ('queued','delivering','dead') GROUP BY output_id;

INSERT INTO pipeline_output_capacity (output_id,pinned_rows)
SELECT r.output_id,sum(p.row_count) FROM pipeline_cutover_pins p
CROSS JOIN LATERAL correlia_raw_pin_routes(p.config_snapshot_id,p.source_id) r
GROUP BY r.output_id
ON CONFLICT (output_id) DO UPDATE SET pinned_rows=excluded.pinned_rows;

INSERT INTO pipeline_event_reference
SELECT event_observed_at,event_id,event_disposition,count(*)
FROM outbox WHERE status IN ('queued','delivering','dead')
GROUP BY event_observed_at,event_id,event_disposition;

INSERT INTO pipeline_output_commitment (reference,commitment,kind,pinned_count)
SELECT c.reference,c.commitment,c.kind,sum(p.row_count)
FROM pipeline_cutover_pins p
CROSS JOIN LATERAL correlia_pin_commitments(p.config_snapshot_id,p.source_id) c
GROUP BY c.reference,c.commitment,c.kind;

INSERT INTO pipeline_output_commitment (reference,commitment,kind,live_count)
SELECT c.reference,c.commitment,c.kind,sum(i.row_count)
FROM (
  SELECT config_snapshot_id,output_id,output_kind,signing_key_ref,signing_key_commitment,
    count(*) AS row_count
  FROM outbox WHERE status IN ('queued','delivering')
  GROUP BY config_snapshot_id,output_id,output_kind,signing_key_ref,signing_key_commitment
) i
CROSS JOIN LATERAL correlia_intent_commitments(
  i.config_snapshot_id,i.output_id,i.output_kind,i.signing_key_ref,i.signing_key_commitment
) c
GROUP BY c.reference,c.commitment,c.kind
ON CONFLICT (reference,commitment,kind) DO UPDATE SET live_count=excluded.live_count;

SELECT correlia_publish_queue_policy(s."publicJson"::jsonb)
FROM ingest_active_config a JOIN ingest_config_snapshot s USING ("snapshotId")
WHERE a.singleton=1;

CREATE OR REPLACE FUNCTION correlia_retained_output_ids() RETURNS TABLE (output_id text)
LANGUAGE sql STABLE AS $$
  SELECT c.output_id::text FROM pipeline_output_capacity c
  WHERE live_rows > 0 OR pinned_rows > 0 ORDER BY c.output_id LIMIT 65
$$;
DROP FUNCTION correlia_pinned_output_routes();

CREATE FUNCTION correlia_adjust_commitment(
  p_reference text, p_commitment text, p_kind text, pin_delta int, live_delta int
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF pin_delta > 0 OR live_delta > 0 THEN
    INSERT INTO pipeline_output_commitment (reference,commitment,kind,pinned_count,live_count)
    VALUES (p_reference,p_commitment,p_kind,pin_delta,live_delta)
    ON CONFLICT (reference,commitment,kind) DO UPDATE
    SET pinned_count=pipeline_output_commitment.pinned_count+excluded.pinned_count,
        live_count=pipeline_output_commitment.live_count+excluded.live_count;
  ELSE
    UPDATE pipeline_output_commitment
    SET pinned_count=pinned_count+pin_delta,live_count=live_count+live_delta
    WHERE reference=p_reference AND commitment=p_commitment AND kind=p_kind;
    DELETE FROM pipeline_output_commitment
    WHERE reference=p_reference AND commitment=p_commitment AND kind=p_kind
      AND pinned_count=0 AND live_count=0;
  END IF;
END;
$$;

CREATE FUNCTION correlia_adjust_raw_pin(p_snapshot text, p_source uuid, delta int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  lane uuid;
  c record;
BEGIN
  FOR lane IN SELECT output_id FROM correlia_raw_pin_routes(p_snapshot,p_source) ORDER BY output_id
  LOOP
    INSERT INTO pipeline_output_capacity (output_id) VALUES (lane) ON CONFLICT DO NOTHING;
    UPDATE pipeline_output_capacity SET pinned_rows=pinned_rows+delta WHERE output_id=lane;
  END LOOP;
  FOR c IN SELECT * FROM correlia_pin_commitments(p_snapshot,p_source) ORDER BY reference,commitment,kind
  LOOP
    PERFORM correlia_adjust_commitment(c.reference,c.commitment,c.kind,delta,0);
  END LOOP;
END;
$$;

CREATE FUNCTION correlia_lock_raw_pin(p_snapshot text, p_source uuid)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM c.output_id FROM pipeline_output_capacity c
  JOIN correlia_raw_pin_routes(p_snapshot,p_source) r USING (output_id)
  ORDER BY c.output_id FOR UPDATE OF c;
  PERFORM c.reference FROM pipeline_output_commitment c
  JOIN correlia_pin_commitments(p_snapshot,p_source) r USING (reference,commitment,kind)
  ORDER BY c.reference,c.commitment,c.kind FOR UPDATE OF c;
END;
$$;

CREATE FUNCTION correlia_account_raw() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  old_pending boolean := TG_OP <> 'INSERT' AND OLD.status='pending';
  new_pending boolean := TG_OP <> 'DELETE' AND NEW.status='pending';
BEGIN
  IF old_pending AND (NOT new_pending OR OLD.config_snapshot_id IS DISTINCT FROM NEW.config_snapshot_id)
      AND OLD.config_snapshot_id IS NOT NULL THEN
    PERFORM correlia_adjust_raw_pin(OLD.config_snapshot_id,OLD.source_id,-1);
  END IF;
  IF new_pending AND (NOT old_pending OR OLD.config_snapshot_id IS DISTINCT FROM NEW.config_snapshot_id)
      AND NEW.config_snapshot_id IS NOT NULL THEN
    PERFORM correlia_adjust_raw_pin(NEW.config_snapshot_id,NEW.source_id,1);
  END IF;
  RETURN NULL;
END;
$$;
CREATE TRIGGER raw_pin_insert AFTER INSERT ON raw_inbox
  FOR EACH ROW WHEN (NEW.status='pending' AND NEW.config_snapshot_id IS NOT NULL)
  EXECUTE FUNCTION correlia_account_raw();
CREATE TRIGGER raw_pin_update AFTER UPDATE ON raw_inbox
  FOR EACH ROW WHEN ((OLD.status IS DISTINCT FROM NEW.status
    OR OLD.config_snapshot_id IS DISTINCT FROM NEW.config_snapshot_id)
    AND (OLD.config_snapshot_id IS NOT NULL OR NEW.config_snapshot_id IS NOT NULL))
  EXECUTE FUNCTION correlia_account_raw();
CREATE TRIGGER raw_pin_delete AFTER DELETE ON raw_inbox
  FOR EACH ROW WHEN (OLD.status='pending' AND OLD.config_snapshot_id IS NOT NULL)
  EXECUTE FUNCTION correlia_account_raw();

CREATE FUNCTION correlia_account_pending() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  delta bigint := 0;
BEGIN
  IF TG_OP <> 'INSERT' THEN
    SELECT -count(*) INTO delta FROM prior_raw WHERE status='pending';
  END IF;
  IF TG_OP <> 'DELETE' THEN
    SELECT delta+count(*) INTO delta FROM next_raw WHERE status='pending';
  END IF;
  IF delta <> 0 THEN
    UPDATE pipeline_pending SET pending_rows=pending_rows+delta WHERE singleton=1;
  END IF;
  RETURN NULL;
END;
$$;
CREATE TRIGGER raw_pending_insert AFTER INSERT ON raw_inbox
  REFERENCING NEW TABLE AS next_raw FOR EACH STATEMENT
  EXECUTE FUNCTION correlia_account_pending();
CREATE TRIGGER raw_pending_update AFTER UPDATE ON raw_inbox
  REFERENCING OLD TABLE AS prior_raw NEW TABLE AS next_raw FOR EACH STATEMENT
  EXECUTE FUNCTION correlia_account_pending();
CREATE TRIGGER raw_pending_delete AFTER DELETE ON raw_inbox
  REFERENCING OLD TABLE AS prior_raw FOR EACH STATEMENT
  EXECUTE FUNCTION correlia_account_pending();

CREATE FUNCTION correlia_account_outbox() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  old_used boolean := TG_OP <> 'INSERT' AND OLD.status IN ('queued','delivering','dead');
  new_used boolean := TG_OP <> 'DELETE' AND NEW.status IN ('queued','delivering','dead');
  old_live boolean := TG_OP <> 'INSERT' AND OLD.status IN ('queued','delivering');
  new_live boolean := TG_OP <> 'DELETE' AND NEW.status IN ('queued','delivering');
  used_delta integer := new_used::int-old_used::int;
  live_delta integer := new_live::int-old_live::int;
  byte_delta bigint;
  intent outbox;
  c record;
BEGIN
  IF used_delta=0 AND live_delta=0 THEN RETURN NULL; END IF;
  intent := CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
  byte_delta := used_delta::bigint*octet_length(intent.payload);
  IF TG_OP='INSERT' THEN
    INSERT INTO pipeline_output_capacity (output_id) VALUES (intent.output_id) ON CONFLICT DO NOTHING;
  END IF;
  UPDATE pipeline_output_capacity
  SET used_rows=used_rows+used_delta,used_bytes=used_bytes+byte_delta,live_rows=live_rows+live_delta
  WHERE output_id=intent.output_id;
  IF used_delta > 0 THEN
    INSERT INTO pipeline_event_reference VALUES
      (intent.event_observed_at,intent.event_id,intent.event_disposition,1)
    ON CONFLICT (observed_at,event_id,disposition) DO UPDATE
      SET protected_count=pipeline_event_reference.protected_count+1;
  ELSIF used_delta < 0 THEN
    UPDATE pipeline_event_reference SET protected_count=protected_count-1
    WHERE observed_at=intent.event_observed_at AND event_id=intent.event_id
      AND disposition=intent.event_disposition;
    DELETE FROM pipeline_event_reference
    WHERE observed_at=intent.event_observed_at AND event_id=intent.event_id
      AND disposition=intent.event_disposition AND protected_count=0;
  END IF;
  IF live_delta <> 0 THEN
    FOR c IN SELECT * FROM correlia_intent_commitments(intent.config_snapshot_id,
      intent.output_id,intent.output_kind,intent.signing_key_ref,intent.signing_key_commitment)
      ORDER BY reference,commitment,kind
    LOOP
      PERFORM correlia_adjust_commitment(c.reference,c.commitment,c.kind,0,live_delta);
    END LOOP;
  END IF;
  RETURN NULL;
END;
$$;
CREATE TRIGGER outbox_queue_accounting AFTER INSERT OR UPDATE OR DELETE ON outbox
  FOR EACH ROW EXECUTE FUNCTION correlia_account_outbox();

-- Truncation is for controlled repair and fixtures, not queue reclamation.
CREATE FUNCTION correlia_reset_queue_accounting() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_TABLE_NAME='raw_inbox' THEN
    UPDATE pipeline_output_capacity SET pinned_rows=0 WHERE pinned_rows<>0;
    UPDATE pipeline_output_commitment SET pinned_count=0 WHERE pinned_count<>0;
    UPDATE pipeline_pending SET pending_rows=0 WHERE singleton=1;
  ELSE
    UPDATE pipeline_output_capacity SET used_rows=0,used_bytes=0,live_rows=0
    WHERE used_rows<>0 OR live_rows<>0;
    UPDATE pipeline_output_commitment SET live_count=0 WHERE live_count<>0;
    TRUNCATE pipeline_event_reference;
  END IF;
  DELETE FROM pipeline_output_commitment WHERE pinned_count=0 AND live_count=0;
  RETURN NULL;
END;
$$;
CREATE TRIGGER raw_truncate_accounting AFTER TRUNCATE ON raw_inbox
  FOR EACH STATEMENT EXECUTE FUNCTION correlia_reset_queue_accounting();
CREATE TRIGGER outbox_truncate_accounting AFTER TRUNCATE ON outbox
  FOR EACH STATEMENT EXECUTE FUNCTION correlia_reset_queue_accounting();

CREATE FUNCTION correlia_disk_pressure() RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE
  budget bigint;
  watermark integer;
  sample pipeline_disk_sample;
BEGIN
  SELECT disk_budget_bytes,disk_watermark_percent INTO budget,watermark
  FROM pipeline_queue_policy WHERE singleton=1;
  IF budget IS NULL THEN RETURN false; END IF;
  SELECT * INTO sample FROM pipeline_disk_sample WHERE singleton=1;
  IF sample.sampled_at <= clock_timestamp()-interval '1 second' THEN
    SELECT * INTO sample FROM pipeline_disk_sample WHERE singleton=1 FOR UPDATE;
    IF sample.sampled_at <= clock_timestamp()-interval '1 second' THEN
      UPDATE pipeline_disk_sample SET database_bytes=pg_database_size(current_database()),
        sampled_at=clock_timestamp() WHERE singleton=1 RETURNING * INTO sample;
    END IF;
  END IF;
  RETURN sample.database_bytes::numeric*100 >= budget::numeric*watermark;
END;
$$;

-- Hold this lock until the actual INSERT; row triggers account only committed
-- work. Replay skips age, disk and output pressure but shares the row cap.
CREATE FUNCTION correlia_reserve_raw(incoming integer, replay boolean DEFAULT false)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  pending bigint;
  policy pipeline_queue_policy;
BEGIN
  SELECT pending_rows INTO pending FROM pipeline_pending WHERE singleton=1 FOR UPDATE;
  SELECT * INTO policy FROM pipeline_queue_policy WHERE singleton=1;
  IF NOT replay THEN
    IF correlia_disk_pressure() THEN RETURN 'storage'; END IF;
    IF EXISTS (SELECT 1 FROM pipeline_output_capacity WHERE overflow_policy='block_ingest' AND (
        used_rows >= max_rows OR used_bytes >= max_payload_bytes
        OR demand_rows > max_rows - used_rows OR demand_bytes > max_payload_bytes - used_bytes
    )) THEN RETURN 'output'; END IF;
    IF EXISTS (SELECT 1 FROM raw_inbox WHERE status='pending'
      AND coalesce(queued_at,observed_at) <= statement_timestamp()
        - make_interval(secs=>policy.pending_max_age_seconds)
    ) THEN RETURN 'inbox'; END IF;
  END IF;
  IF pending > policy.pending_max_rows - incoming THEN RETURN 'inbox'; END IF;
  RETURN NULL;
END;
$$;
