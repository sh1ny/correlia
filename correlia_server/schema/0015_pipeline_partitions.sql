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
  effective_floor timestamptz NOT NULL
);
INSERT INTO pipeline_icinga2_replay_floor (singleton, effective_floor)
SELECT singleton, cutoff - interval '7 days' FROM raw_admission_cutoff;

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
CREATE INDEX raw_pending_schedule_idx ON raw_inbox (coalesce(next_attempt_at,observed_at),observed_at,raw_id)
  WHERE status = 'pending' AND config_snapshot_id IS NOT NULL;
CREATE INDEX raw_stream_retained_idx ON raw_inbox (source_id) WHERE status IN ('pending', 'failed');
CREATE INDEX events_subject_idx ON events (correlia_event_subject(payload));
CREATE INDEX outbox_eligibility_idx ON outbox (status, next_attempt_at, output_id);
CREATE INDEX outbox_definition_status_idx ON outbox (output_id, definition_digest, status);

CREATE TABLE pipeline_partition_range (
  parent_name text NOT NULL,
  child_name text PRIMARY KEY,
  first_day date NOT NULL,
  end_day date NOT NULL,
  checked_at timestamptz,
  UNIQUE (parent_name,end_day)
);

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
      INSERT INTO pipeline_partition_range (parent_name,child_name,first_day,end_day)
      VALUES (parent,legacy,'-infinity',historical_end);
    END IF;

    FOR offset_days IN -1..1 LOOP
      day := current_date + offset_days;
      IF historical_end IS NULL OR day >= historical_end THEN
        EXECUTE format('CREATE TABLE %I PARTITION OF %I FOR VALUES FROM (%L) TO (%L)',
          parent || '_' || to_char(day, 'YYYYMMDD'), parent, day, day + 1);
        INSERT INTO pipeline_partition_range (parent_name,child_name,first_day,end_day)
        VALUES (parent,parent || '_' || to_char(day,'YYYYMMDD'),day,day+1);
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
  capacity pipeline_output_capacity;
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
        overflow_policy=excluded.overflow_policy RETURNING * INTO capacity;
      IF capacity.overflow_policy='block_ingest' AND capacity.overflow_activity_id IS NULL
        AND (capacity.used_rows>=capacity.max_rows OR capacity.used_bytes>=capacity.max_payload_bytes)
      THEN
        PERFORM correlia_mark_overflow(lane.id,'saturated',0,0,0,clock_timestamp());
      END IF;
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
  IF used_delta=0 AND live_delta=0 AND NOT old_used THEN RETURN NULL; END IF;
  byte_delta := CASE WHEN new_used THEN octet_length(NEW.payload)::bigint ELSE 0 END
              - CASE WHEN old_used THEN octet_length(OLD.payload)::bigint ELSE 0 END;
  IF used_delta=0 AND live_delta=0 AND byte_delta=0 THEN RETURN NULL; END IF;
  intent := CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
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
CREATE FUNCTION correlia_queue_pressure(pending bigint,incoming integer,p_output_blocked boolean DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  policy pipeline_queue_policy;
  age_cutoff timestamptz;
BEGIN
  SELECT * INTO policy FROM pipeline_queue_policy WHERE singleton=1;
  IF correlia_disk_pressure() THEN RETURN 'storage'; END IF;
  IF coalesce(p_output_blocked,EXISTS (SELECT 1 FROM pipeline_output_capacity WHERE overflow_policy='block_ingest' AND (
      used_rows >= max_rows OR used_bytes >= max_payload_bytes
      OR demand_rows > max_rows - used_rows OR demand_bytes > max_payload_bytes - used_bytes
  ))) THEN RETURN 'output'; END IF;
  IF pending > policy.pending_max_rows - incoming THEN RETURN 'inbox'; END IF;
  age_cutoff := clock_timestamp()-make_interval(secs=>policy.pending_max_age_seconds);
  IF EXISTS (SELECT 1 FROM raw_inbox WHERE status='pending'
    AND coalesce(queued_at,observed_at)<=age_cutoff
  ) THEN RETURN 'inbox'; END IF;
  RETURN NULL;
END;
$$;

CREATE FUNCTION correlia_reserve_raw(incoming integer) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
  pending bigint;
BEGIN
  SELECT pending_rows INTO pending FROM pipeline_pending WHERE singleton=1 FOR UPDATE;
  RETURN correlia_queue_pressure(pending,incoming);
END;
$$;

ALTER TABLE pipeline_output_capacity
  ADD COLUMN discarded_count bigint NOT NULL DEFAULT 0,
  ADD COLUMN overflow_activity_id bigint;
CREATE INDEX pipeline_active_output_idx ON pipeline_output_capacity (output_id) WHERE active;

CREATE TABLE pipeline_overflow_notice (
  activity_id bigint PRIMARY KEY,
  output_id uuid NOT NULL,
  occurred_at timestamptz NOT NULL,
  reason text NOT NULL,
  evidence text NOT NULL,
  handled boolean NOT NULL DEFAULT false
);
CREATE INDEX pipeline_overflow_pending_idx ON pipeline_overflow_notice (activity_id) WHERE NOT handled;

CREATE FUNCTION correlia_mark_overflow(
  p_output uuid, p_reason text, p_discarded integer, p_rows integer, p_bytes bigint,
  p_now timestamptz
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  episode bigint;
BEGIN
  UPDATE pipeline_output_capacity SET
    discarded_count=discarded_count+p_discarded,
    demand_rows=CASE WHEN overflow_policy='block_ingest' THEN greatest(demand_rows,p_rows) ELSE 0 END,
    demand_bytes=CASE WHEN overflow_policy='block_ingest' THEN greatest(demand_bytes,p_bytes) ELSE 0 END
  WHERE output_id=p_output RETURNING overflow_activity_id INTO episode;
  IF episode IS NULL THEN
    INSERT INTO activity
      (occurred_at,entity_kind,entity_id,entity_version,change_kind,actor_kind,actor_ref)
    VALUES (p_now,'output_queue',0,0,'output_overflow','system',p_output::text)
    RETURNING id INTO episode;
    INSERT INTO pipeline_overflow_notice (activity_id,output_id,occurred_at,reason,evidence)
    VALUES (episode,p_output,p_now,p_reason,
      jsonb_build_object('activity_id',episode,'output_id',p_output,'reason',p_reason)::text);
    UPDATE pipeline_output_capacity SET overflow_activity_id=episode WHERE output_id=p_output;
  END IF;
  IF p_discarded>0 THEN
    INSERT INTO activity
      (occurred_at,entity_kind,entity_id,entity_version,change_kind,actor_kind,actor_ref)
    VALUES (p_now,'output_queue',episode,p_discarded,'output_discarded','system',p_output::text);
  END IF;
END;
$$;

CREATE FUNCTION correlia_close_satisfied_overflow() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  -- A change of policy invalidates the old deficit, but not actual usage.
  IF NEW.overflow_policy IS DISTINCT FROM OLD.overflow_policy THEN
    NEW.demand_rows := 0;
    NEW.demand_bytes := 0;
  END IF;
  IF NEW.used_rows<NEW.max_rows AND NEW.used_bytes<NEW.max_payload_bytes
    AND NEW.demand_rows<=NEW.max_rows-NEW.used_rows
    AND NEW.demand_bytes<=NEW.max_payload_bytes-NEW.used_bytes
  THEN
    NEW.demand_rows := 0;
    NEW.demand_bytes := 0;
    NEW.overflow_activity_id := NULL;
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER output_capacity_recovered BEFORE UPDATE OF
  used_rows,used_bytes,max_rows,max_payload_bytes,overflow_policy ON pipeline_output_capacity
  FOR EACH ROW WHEN (OLD.overflow_activity_id IS NOT NULL)
  EXECUTE FUNCTION correlia_close_satisfied_overflow();

SELECT correlia_publish_queue_policy(s."publicJson"::jsonb)
FROM ingest_active_config a JOIN ingest_config_snapshot s USING ("snapshotId")
WHERE a.singleton=1;

CREATE TABLE pipeline_dead_letter (
  occurrence_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kind text NOT NULL CHECK (kind IN ('raw','delivery')),
  scope_id uuid NOT NULL,
  failed_at timestamptz NOT NULL,
  error_class text NOT NULL,
  work_at timestamptz NOT NULL,
  work_id uuid NOT NULL,
  snapshot_id text,
  field_path text,
  UNIQUE (kind,work_at,work_id)
);
CREATE INDEX pipeline_dead_letter_time_idx ON pipeline_dead_letter (failed_at,occurrence_id);
CREATE INDEX pipeline_dead_letter_kind_idx ON pipeline_dead_letter (kind,failed_at,occurrence_id);
CREATE INDEX pipeline_dead_letter_scope_idx ON pipeline_dead_letter (kind,scope_id,failed_at,occurrence_id);
CREATE INDEX pipeline_dead_letter_class_idx ON pipeline_dead_letter (kind,error_class,failed_at,occurrence_id);
CREATE INDEX pipeline_dead_letter_scope_class_idx ON pipeline_dead_letter
  (kind,scope_id,error_class,failed_at,occurrence_id);

CREATE INDEX pipeline_failure_work_idx ON pipeline_failures ("rawObservedAt","rawId");
CREATE INDEX raw_terminal_age_idx ON raw_inbox (observed_at,raw_id) WHERE status IN ('done','discarded');
CREATE INDEX raw_drop_protected_idx ON raw_inbox (observed_at) WHERE status NOT IN ('done','discarded');
CREATE INDEX outbox_terminal_age_idx ON outbox (terminal_at,created_at,delivery_id)
  WHERE status IN ('delivered','discarded');
CREATE INDEX raw_replayable_age_idx ON raw_inbox (observed_at) WHERE status IN ('pending','failed');
CREATE INDEX events_observation_key_idx ON events (event_id);
CREATE INDEX transport_expiry_idx ON transport_keys ("expiresAt",id);
CREATE INDEX observation_expiry_idx ON observation_keys (greatest("sourceTime","firstSeenAt"),id);

INSERT INTO pipeline_dead_letter (kind,scope_id,failed_at,error_class,work_at,work_id,snapshot_id,field_path)
SELECT 'raw',r.source_id,coalesce(f."createdAt" AT TIME ZONE 'UTC',transaction_timestamp()),
  coalesce(f."errorClass",'processing_failed'),r.observed_at,r.raw_id,r.config_snapshot_id,f."fieldPath"
FROM raw_inbox r LEFT JOIN LATERAL (
  SELECT "createdAt","errorClass","fieldPath" FROM pipeline_failures
  WHERE ("rawObservedAt","rawId")=(r.observed_at AT TIME ZONE 'UTC',r.raw_id)
  ORDER BY "createdAt" DESC,id DESC LIMIT 1
) f ON true WHERE r.status='failed';
INSERT INTO pipeline_dead_letter (kind,scope_id,failed_at,error_class,work_at,work_id,snapshot_id)
SELECT 'delivery',output_id,terminal_at,coalesce(dead_reason,'delivery_failed'),
  created_at,delivery_id,config_snapshot_id FROM outbox WHERE status='dead';

CREATE FUNCTION correlia_record_raw_failure(
  observed timestamptz, raw_id uuid, source_id uuid, snapshot text, error text, path text, failed timestamptz
) RETURNS void LANGUAGE sql AS $$
  INSERT INTO pipeline_dead_letter (kind,scope_id,failed_at,error_class,
    work_at,work_id,snapshot_id,field_path)
  VALUES ('raw',source_id,failed,error,observed,raw_id,snapshot,path)
$$;

-- The relay and direct imports share the same terminal-time and failure fence.
CREATE FUNCTION correlia_stamp_delivery_terminal() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status NOT IN ('dead','delivered','discarded') THEN
    NEW.terminal_at := NULL;
  ELSIF TG_OP='UPDATE' AND OLD.status IS DISTINCT FROM NEW.status THEN
    IF NEW.terminal_at IS NULL OR NEW.terminal_at IS NOT DISTINCT FROM OLD.terminal_at THEN
      NEW.terminal_at := clock_timestamp();
    END IF;
  ELSE
    NEW.terminal_at := coalesce(NEW.terminal_at,clock_timestamp());
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER outbox_terminal_timestamp BEFORE INSERT OR UPDATE OF status ON outbox
  FOR EACH ROW EXECUTE FUNCTION correlia_stamp_delivery_terminal();

CREATE FUNCTION correlia_track_dead_delivery() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP <> 'INSERT' AND OLD.status='dead' AND (TG_OP='DELETE' OR NEW.status<>'dead') THEN
    DELETE FROM pipeline_dead_letter WHERE (kind,work_at,work_id)=('delivery',OLD.created_at,OLD.delivery_id);
  ELSIF TG_OP <> 'DELETE' AND NEW.status='dead' AND (TG_OP='INSERT' OR OLD.status<>'dead') THEN
    INSERT INTO pipeline_dead_letter (kind,scope_id,failed_at,error_class,work_at,work_id,snapshot_id)
    VALUES ('delivery',NEW.output_id,NEW.terminal_at,coalesce(NEW.dead_reason,'delivery_failed'),
      NEW.created_at,NEW.delivery_id,NEW.config_snapshot_id);
  END IF;
  RETURN NULL;
END;
$$;
CREATE TRIGGER outbox_dead_directory AFTER INSERT OR UPDATE OF status OR DELETE ON outbox
  FOR EACH ROW EXECUTE FUNCTION correlia_track_dead_delivery();

CREATE FUNCTION correlia_remove_raw_failure() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM pipeline_dead_letter WHERE (kind,work_at,work_id)=('raw',OLD.observed_at,OLD.raw_id);
  DELETE FROM pipeline_failures WHERE ("rawObservedAt","rawId")=(OLD.observed_at AT TIME ZONE 'UTC',OLD.raw_id);
  RETURN NULL;
END;
$$;
CREATE TRIGGER raw_failure_deleted AFTER DELETE ON raw_inbox
  FOR EACH ROW WHEN (OLD.status='failed') EXECUTE FUNCTION correlia_remove_raw_failure();
CREATE TRIGGER raw_failure_resolved AFTER UPDATE OF status ON raw_inbox
  FOR EACH ROW WHEN (OLD.status='failed' AND NEW.status<>'failed')
  EXECUTE FUNCTION correlia_remove_raw_failure();

CREATE FUNCTION correlia_reset_dead_directory() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM pipeline_dead_letter WHERE kind=TG_ARGV[0];
  RETURN NULL;
END;
$$;
CREATE TRIGGER raw_truncate_dead AFTER TRUNCATE ON raw_inbox
  FOR EACH STATEMENT EXECUTE FUNCTION correlia_reset_dead_directory('raw');
CREATE TRIGGER outbox_truncate_dead AFTER TRUNCATE ON outbox
  FOR EACH STATEMENT EXECUTE FUNCTION correlia_reset_dead_directory('delivery');

CREATE TABLE pipeline_retired_delivery (
  created_at timestamptz NOT NULL,
  delivery_id uuid NOT NULL,
  PRIMARY KEY (created_at,delivery_id)
);
CREATE TABLE pipeline_retention_cursor (
  lane text PRIMARY KEY,
  last_time timestamptz NOT NULL,
  last_id uuid NOT NULL,
  last_disposition text NOT NULL,
  last_serial bigint NOT NULL DEFAULT 0,
  last_created_at timestamptz NOT NULL DEFAULT '-infinity'
);
CREATE TABLE pipeline_maintenance_outcome (
  singleton integer PRIMARY KEY CHECK (singleton=1),
  lane text NOT NULL,
  outcome text NOT NULL,
  finished_at timestamptz NOT NULL,
  affected integer NOT NULL
);

CREATE SEQUENCE pipeline_partition_attempt_id;
CREATE TABLE pipeline_partition_retry (
  parent_name text NOT NULL,
  day date NOT NULL,
  attempt_id bigint NOT NULL,
  retry_at timestamptz NOT NULL,
  problem text,
  PRIMARY KEY (parent_name,day)
);

CREATE FUNCTION correlia_partition_covered(p_parent text, p_day date)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM pipeline_partition_range r JOIN pg_inherits h
      ON h.inhrelid=to_regclass(r.child_name) AND h.inhparent=to_regclass(r.parent_name)
    WHERE r.parent_name=p_parent AND r.first_day<=p_day AND r.end_day>p_day)
$$;

CREATE FUNCTION correlia_reserve_partition(p_parent text,p_day date,p_now timestamptz)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  id bigint;
BEGIN
  IF p_parent NOT IN ('raw_inbox','events','outbox')
    OR NOT pg_try_advisory_xact_lock(1129271900) THEN RETURN NULL; END IF;
  IF correlia_partition_covered(p_parent,p_day) THEN RETURN NULL; END IF;
  INSERT INTO pipeline_partition_retry (parent_name,day,attempt_id,retry_at)
  VALUES (p_parent,p_day,nextval('pipeline_partition_attempt_id'),p_now+interval '30 seconds')
  ON CONFLICT (parent_name,day) DO UPDATE
  SET attempt_id=excluded.attempt_id,retry_at=excluded.retry_at
  WHERE pipeline_partition_retry.retry_at<=p_now
  RETURNING attempt_id INTO id;
  RETURN id;
END;
$$;

CREATE FUNCTION correlia_attach_partition(p_parent text,p_day date,p_attempt bigint)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE
  occupied boolean;
  child text;
  key text;
BEGIN
  IF p_parent NOT IN ('raw_inbox','events','outbox')
    OR NOT pg_try_advisory_xact_lock(1129271900) THEN RETURN false; END IF;
  IF NOT EXISTS (SELECT 1 FROM pipeline_partition_retry
    WHERE (parent_name,day,attempt_id)=(p_parent,p_day,p_attempt)) THEN RETURN false; END IF;
  IF correlia_partition_covered(p_parent,p_day) THEN
    DELETE FROM pipeline_partition_retry WHERE (parent_name,day)=(p_parent,p_day);
    RETURN false;
  END IF;
  key := CASE WHEN p_parent='outbox' THEN 'created_at' ELSE 'observed_at' END;
  EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I WHERE %I >= $1 AND %I < $2)',
    p_parent || '_default',key,key) INTO occupied
    USING p_day::timestamp AT TIME ZONE 'UTC',(p_day+1)::timestamp AT TIME ZONE 'UTC';
  IF occupied THEN
    UPDATE pipeline_partition_retry SET problem=NULL
    WHERE (parent_name,day,attempt_id)=(p_parent,p_day,p_attempt);
    RETURN false;
  END IF;
  child := p_parent || '_' || to_char(p_day,'YYYYMMDD');
  -- PostgreSQL still validates the default range under the bounded DDL lock.
  EXECUTE format('CREATE TABLE %I PARTITION OF %I FOR VALUES FROM (%L) TO (%L)',
    child,p_parent,p_day::timestamp AT TIME ZONE 'UTC',(p_day+1)::timestamp AT TIME ZONE 'UTC');
  INSERT INTO pipeline_partition_range (parent_name,child_name,first_day,end_day)
  VALUES (p_parent,child,p_day,p_day+1);
  DELETE FROM pipeline_partition_retry WHERE (parent_name,day)=(p_parent,p_day);
  RETURN true;
END;
$$;

CREATE FUNCTION correlia_partition_failed(
  p_parent text,p_day date,p_attempt bigint,p_problem text,p_now timestamptz
) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(1129271900);
  IF correlia_partition_covered(p_parent,p_day) THEN RETURN false; END IF;
  UPDATE pipeline_partition_retry SET problem=p_problem,retry_at=p_now+interval '30 seconds'
  WHERE (parent_name,day,attempt_id)=(p_parent,p_day,p_attempt);
  RETURN FOUND;
END;
$$;

CREATE FUNCTION correlia_drop_old_partition(p_parent text,p_now timestamptz)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE
  part pipeline_partition_range;
  days integer;
  blocked boolean;
BEGIN
  IF p_parent NOT IN ('raw_inbox','events','outbox')
    OR NOT pg_try_advisory_xact_lock(1129271900) THEN RETURN false; END IF;
  SELECT CASE p_parent WHEN 'events' THEN event_retention_days
    WHEN 'outbox' THEN outbox_retention_days ELSE raw_retention_days END INTO days
  FROM pipeline_queue_policy WHERE singleton=1;
  SELECT r.* INTO part FROM pipeline_partition_range r JOIN pg_inherits h
    ON h.inhrelid=to_regclass(r.child_name) AND h.inhparent=to_regclass(r.parent_name)
  WHERE r.parent_name=p_parent AND r.end_day::timestamp AT TIME ZONE 'UTC' <= p_now-make_interval(days=>days)
  ORDER BY r.checked_at NULLS FIRST,r.end_day LIMIT 1;
  IF NOT FOUND THEN RETURN false; END IF;
  EXECUTE format('LOCK TABLE ONLY %I, ONLY %I IN ACCESS EXCLUSIVE MODE',p_parent,part.child_name);
  -- Publication may extend the window while DDL is blocked. Share-lock
  -- the current policy now, without waiting on a publisher holding it.
  SELECT CASE p_parent WHEN 'events' THEN event_retention_days
    WHEN 'outbox' THEN outbox_retention_days ELSE raw_retention_days END INTO days
  FROM pipeline_queue_policy WHERE singleton=1 FOR SHARE NOWAIT;
  IF part.end_day::timestamp AT TIME ZONE 'UTC' > p_now-make_interval(days=>days)
    OR NOT EXISTS (SELECT 1 FROM pg_inherits h
      WHERE h.inhrelid=to_regclass(part.child_name) AND h.inhparent=to_regclass(p_parent))
  THEN RETURN false; END IF;
  IF p_parent='events' THEN
    SELECT EXISTS (SELECT 1 FROM pipeline_event_reference
      WHERE observed_at>=part.first_day::timestamp AT TIME ZONE 'UTC'
        AND observed_at<part.end_day::timestamp AT TIME ZONE 'UTC') INTO blocked;
  ELSIF p_parent='raw_inbox' AND NOT EXISTS (SELECT 1 FROM icinga2_raw_origin) THEN
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I WHERE status NOT IN (''done'',''discarded''))',
      part.child_name) INTO blocked;
  ELSE
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I)',part.child_name) INTO blocked;
  END IF;
  IF blocked THEN
    UPDATE pipeline_partition_range SET checked_at=p_now WHERE child_name=part.child_name;
    RETURN false;
  END IF;
  EXECUTE format('DROP TABLE %I',part.child_name);
  DELETE FROM pipeline_partition_range WHERE child_name=part.child_name;
  RETURN true;
END;
$$;

CREATE FUNCTION correlia_expire_dead_letters(p_now timestamptz,p_cutoff timestamptz,p_cap integer)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
  cursor_row pipeline_retention_cursor;
  occurrences bigint[];
  locked_occurrences bigint[];
  expired integer := 0;
  deliveries integer;
BEGIN
  SELECT * INTO cursor_row FROM pipeline_retention_cursor WHERE lane='expiry';
  WITH page AS MATERIALIZED (
    SELECT failed_at,occurrence_id FROM pipeline_dead_letter WHERE failed_at<=p_cutoff
      AND (failed_at,occurrence_id)>(
        coalesce(cursor_row.last_time,'-infinity'),coalesce(cursor_row.last_serial,0))
    ORDER BY failed_at,occurrence_id LIMIT p_cap
  ), advanced AS (
    INSERT INTO pipeline_retention_cursor (lane,last_time,last_id,last_disposition,last_serial)
    SELECT 'expiry',coalesce(tail.failed_at,'-infinity'),'00000000-0000-0000-0000-000000000000','',
      coalesce(tail.occurrence_id,0)
    FROM (VALUES (1)) seed LEFT JOIN (SELECT * FROM page OFFSET p_cap-1) tail ON true
    ON CONFLICT (lane) DO UPDATE SET
      (last_time,last_serial)=(excluded.last_time,excluded.last_serial)
  )
  SELECT array_agg(occurrence_id) INTO occurrences FROM page;
  IF occurrences IS NULL THEN RETURN 0; END IF;

  SELECT array_agg(h.occurrence_id) INTO locked_occurrences FROM (
    SELECT f.occurrence_id FROM pipeline_dead_letter f JOIN raw_inbox r
      ON (r.observed_at,r.raw_id)=(f.work_at,f.work_id)
    WHERE f.occurrence_id=ANY(occurrences) AND f.kind='raw' AND r.status='failed'
    ORDER BY r.observed_at,r.raw_id FOR UPDATE OF r SKIP LOCKED
  ) h;
  -- Re-read the directory after the work lock: the same work key can fail
  -- again with a different occurrence between selection and acquisition.
  UPDATE raw_inbox r SET status='discarded',next_attempt_at=NULL FROM pipeline_dead_letter f
  WHERE f.kind='raw' AND f.occurrence_id=ANY(locked_occurrences)
    AND (r.observed_at,r.raw_id)=(f.work_at,f.work_id) AND r.status='failed';
  GET DIAGNOSTICS expired=ROW_COUNT;

  SELECT array_agg(h.occurrence_id) INTO locked_occurrences FROM (
    SELECT f.occurrence_id FROM pipeline_dead_letter f JOIN outbox o
      ON (o.created_at,o.delivery_id)=(f.work_at,f.work_id)
    WHERE f.occurrence_id=ANY(occurrences) AND f.kind='delivery' AND o.status='dead'
    ORDER BY o.created_at,o.delivery_id FOR UPDATE OF o SKIP LOCKED
  ) h;
  WITH held AS MATERIALIZED (
    SELECT o.created_at,o.delivery_id,o.output_id,o.event_observed_at,o.event_id,o.event_disposition
    FROM pipeline_dead_letter f JOIN outbox o ON (o.created_at,o.delivery_id)=(f.work_at,f.work_id)
    WHERE f.occurrence_id=ANY(locked_occurrences) AND f.kind='delivery' AND o.status='dead'
  ), lanes AS MATERIALIZED (
    SELECT c.output_id FROM pipeline_output_capacity c
    WHERE c.output_id IN (SELECT output_id FROM held) ORDER BY c.output_id FOR UPDATE
  ), refs AS MATERIALIZED (
    SELECT r.event_id FROM (
      SELECT DISTINCT event_observed_at,event_id,event_disposition FROM held
    ) h JOIN pipeline_event_reference r ON
      (h.event_observed_at,h.event_id,h.event_disposition)=(r.observed_at,r.event_id,r.disposition)
    WHERE (SELECT count(*) FROM lanes)>0
    ORDER BY r.observed_at,r.event_id,r.disposition FOR UPDATE OF r
  )
  UPDATE outbox o SET status='discarded',terminal_at=p_now FROM held h
  WHERE (o.created_at,o.delivery_id)=(h.created_at,h.delivery_id) AND (SELECT count(*) FROM refs)>0;
  GET DIAGNOSTICS deliveries=ROW_COUNT;
  expired := expired+deliveries;
  IF expired>0 THEN
    INSERT INTO activity (occurred_at,entity_kind,entity_id,entity_version,change_kind,actor_kind)
    VALUES (p_now,'pipeline_queue',0,expired,'dead_letter_expired','system');
  END IF;
  RETURN expired;
END;
$$;

-- Cursor advancement uses the page, not the deleted subset. Protected
-- prefixes and locked rows cannot cause an unbounded scan or starve later work.
CREATE FUNCTION correlia_reclaim_events(p_cutoff timestamptz,p_cap integer)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
  cursor_row pipeline_retention_cursor;
  deleted integer;
BEGIN
  SELECT * INTO cursor_row FROM pipeline_retention_cursor WHERE lane='events';
  WITH page AS MATERIALIZED (
    SELECT observed_at,event_id,disposition FROM events WHERE observed_at<p_cutoff
      AND (observed_at,event_id,disposition)>(
        coalesce(cursor_row.last_time,'-infinity'),
        coalesce(cursor_row.last_id,'00000000-0000-0000-0000-000000000000'),
        coalesce(cursor_row.last_disposition,''))
    ORDER BY observed_at,event_id,disposition LIMIT p_cap
  ), locked AS MATERIALIZED (
    SELECT e.observed_at,e.event_id,e.disposition FROM events e JOIN page p
      USING (observed_at,event_id,disposition)
    WHERE NOT EXISTS (SELECT 1 FROM pipeline_event_reference r
      WHERE (r.observed_at,r.event_id,r.disposition)=(e.observed_at,e.event_id,e.disposition))
    ORDER BY e.observed_at,e.event_id,e.disposition FOR UPDATE OF e SKIP LOCKED
  ), removed AS (
    DELETE FROM events e USING locked l
    WHERE (e.observed_at,e.event_id,e.disposition)=(l.observed_at,l.event_id,l.disposition)
    RETURNING 1
  ), advanced AS (
    INSERT INTO pipeline_retention_cursor VALUES ('events',
      coalesce((SELECT observed_at FROM page OFFSET p_cap-1 LIMIT 1),'-infinity'),
      coalesce((SELECT event_id FROM page OFFSET p_cap-1 LIMIT 1),'00000000-0000-0000-0000-000000000000'),
      coalesce((SELECT disposition FROM page OFFSET p_cap-1 LIMIT 1),''))
    ON CONFLICT (lane) DO UPDATE SET
      (last_time,last_id,last_disposition)=(excluded.last_time,excluded.last_id,excluded.last_disposition)
  )
  SELECT count(*) INTO deleted FROM removed;
  RETURN deleted;
END;
$$;

CREATE FUNCTION correlia_reclaim_observation_keys(p_now timestamptz,p_cap integer)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
  cursor_row pipeline_retention_cursor;
  horizon timestamptz;
  removed integer;
BEGIN
  PERFORM 1 FROM raw_admission_cutoff WHERE singleton=1 FOR UPDATE;
  SELECT least(c.cutoff,(SELECT min(observed_at) FROM raw_inbox WHERE status IN ('pending','failed')),p_now)
    - interval '7 days 5 minutes' INTO horizon FROM raw_admission_cutoff c WHERE singleton=1;
  SELECT * INTO cursor_row FROM pipeline_retention_cursor WHERE lane='observation';
  WITH page AS MATERIALIZED (
    SELECT id,greatest("sourceTime","firstSeenAt") AS seen FROM observation_keys
    WHERE greatest("sourceTime","firstSeenAt")<horizon AT TIME ZONE 'UTC'
      AND (greatest("sourceTime","firstSeenAt"),id)>
          (coalesce(cursor_row.last_time AT TIME ZONE 'UTC','-infinity'),
           coalesce(cursor_row.last_serial,0))
    ORDER BY seen,id LIMIT p_cap
  ), locked AS MATERIALIZED (
    SELECT k.id FROM observation_keys k JOIN page p USING (id)
    WHERE NOT EXISTS (SELECT 1 FROM events e WHERE e.event_id=k."eventId")
    FOR UPDATE OF k SKIP LOCKED
  ), deleted AS (
    DELETE FROM observation_keys k USING locked l WHERE k.id=l.id RETURNING 1
  ), advanced AS (
    INSERT INTO pipeline_retention_cursor (lane,last_time,last_id,last_disposition,last_serial)
    VALUES ('observation',
      coalesce((SELECT seen AT TIME ZONE 'UTC' FROM page OFFSET p_cap-1 LIMIT 1),'-infinity'),
      '00000000-0000-0000-0000-000000000000','',
      coalesce((SELECT id FROM page OFFSET p_cap-1 LIMIT 1),0))
    ON CONFLICT (lane) DO UPDATE SET
      (last_time,last_serial)=(excluded.last_time,excluded.last_serial)
  )
  SELECT count(*) INTO removed FROM deleted;
  RETURN removed;
END;
$$;

CREATE FUNCTION correlia_maintain(p_lane text,p_now timestamptz,p_cap integer DEFAULT 500)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
  policy pipeline_queue_policy;
  cursor_row pipeline_retention_cursor;
  affected integer;
  pruned integer;
  retired pipeline_retired_delivery;
BEGIN
  IF p_cap<1 OR p_cap>500 THEN RAISE EXCEPTION 'invalid maintenance batch cap'; END IF;
  IF NOT pg_try_advisory_xact_lock(1129271901) THEN RETURN 0; END IF;
  -- Publication takes this row before output lanes. Don't wait on it
  -- during maintenance, and keep the chosen policy through commit.
  IF p_lane IN ('expiry','raw','events','outbox') THEN
    SELECT * INTO policy FROM pipeline_queue_policy WHERE singleton=1 FOR SHARE NOWAIT;
  END IF;
  IF p_lane IN ('raw','outbox','transport') THEN
    SELECT * INTO cursor_row FROM pipeline_retention_cursor WHERE lane=p_lane;
  END IF;
  IF p_lane='expiry' THEN
    RETURN correlia_expire_dead_letters(p_now,p_now-make_interval(days=>policy.dead_letter_retention_days),p_cap);
  ELSIF p_lane='raw' THEN
    WITH page AS MATERIALIZED (
      SELECT observed_at,raw_id FROM raw_inbox
      WHERE observed_at<p_now-make_interval(days=>policy.raw_retention_days)
        AND status IN ('done','discarded')
        AND (observed_at,raw_id)>(coalesce(cursor_row.last_time,'-infinity'),
          coalesce(cursor_row.last_id,'00000000-0000-0000-0000-000000000000'))
      ORDER BY observed_at,raw_id LIMIT p_cap
    ), held AS MATERIALIZED (
      SELECT r.observed_at,r.raw_id FROM raw_inbox r JOIN page p USING (observed_at,raw_id)
      WHERE r.status IN ('done','discarded')
      ORDER BY r.observed_at,r.raw_id FOR UPDATE OF r SKIP LOCKED
    ), removed AS (
      DELETE FROM raw_inbox r USING held h WHERE (r.observed_at,r.raw_id)=(h.observed_at,h.raw_id)
      RETURNING r.raw_id
    ), origins AS (
      DELETE FROM icinga2_raw_origin o USING removed r WHERE o.raw_id=r.raw_id
    ), advanced AS (
      INSERT INTO pipeline_retention_cursor (lane,last_time,last_id,last_disposition)
      SELECT p_lane,coalesce(tail.observed_at,'-infinity'),
        coalesce(tail.raw_id,'00000000-0000-0000-0000-000000000000'),''
      FROM (VALUES (1)) seed LEFT JOIN (SELECT * FROM page OFFSET p_cap-1) tail ON true
      ON CONFLICT (lane) DO UPDATE SET (last_time,last_id)=(excluded.last_time,excluded.last_id)
    )
    SELECT count(*) INTO affected FROM removed;
  ELSIF p_lane='events' THEN
    RETURN correlia_reclaim_events(p_now-make_interval(days=>policy.event_retention_days),p_cap);
  ELSIF p_lane='outbox' THEN
    WITH page AS MATERIALIZED (
      SELECT terminal_at,created_at,delivery_id FROM outbox
      WHERE status IN ('delivered','discarded')
        AND terminal_at<p_now-make_interval(days=>policy.outbox_retention_days)
        AND (terminal_at,created_at,delivery_id)>(coalesce(cursor_row.last_time,'-infinity'),
          coalesce(cursor_row.last_created_at,'-infinity'),
          coalesce(cursor_row.last_id,'00000000-0000-0000-0000-000000000000'))
      ORDER BY terminal_at,created_at,delivery_id LIMIT p_cap
    ), held AS MATERIALIZED (
      SELECT o.created_at,o.delivery_id FROM outbox o JOIN page p USING (created_at,delivery_id)
      WHERE o.status IN ('delivered','discarded')
        AND o.terminal_at<p_now-make_interval(days=>policy.outbox_retention_days)
      ORDER BY o.created_at,o.delivery_id FOR UPDATE OF o SKIP LOCKED
    ), removed AS (
      DELETE FROM outbox o USING held h WHERE (o.created_at,o.delivery_id)=(h.created_at,h.delivery_id)
      RETURNING o.created_at,o.delivery_id
    ), tracked AS (
      INSERT INTO pipeline_retired_delivery SELECT * FROM removed RETURNING 1
    ), advanced AS (
      INSERT INTO pipeline_retention_cursor (lane,last_time,last_created_at,last_id,last_disposition)
      SELECT p_lane,coalesce(tail.terminal_at,'-infinity'),coalesce(tail.created_at,'-infinity'),
        coalesce(tail.delivery_id,'00000000-0000-0000-0000-000000000000'),''
      FROM (VALUES (1)) seed LEFT JOIN (SELECT * FROM page OFFSET p_cap-1) tail ON true
      ON CONFLICT (lane) DO UPDATE SET
        (last_time,last_created_at,last_id)=(excluded.last_time,excluded.last_created_at,excluded.last_id)
    )
    SELECT count(*) INTO affected FROM tracked;
  ELSIF p_lane='attempts' THEN
    affected := 0;
    FOR retired IN SELECT * FROM pipeline_retired_delivery
      ORDER BY created_at,delivery_id LIMIT p_cap FOR UPDATE
    LOOP
      WITH page AS MATERIALIZED (
        SELECT id FROM delivery_attempts WHERE
          ("outboxCreatedAt","deliveryId")=(retired.created_at AT TIME ZONE 'UTC',retired.delivery_id)
        ORDER BY "attemptNumber" LIMIT p_cap-affected
      )
      DELETE FROM delivery_attempts a USING page p WHERE a.id=p.id;
      GET DIAGNOSTICS pruned=ROW_COUNT;
      affected := affected+pruned;
      IF NOT EXISTS (SELECT 1 FROM delivery_attempts WHERE
          ("outboxCreatedAt","deliveryId")=(retired.created_at AT TIME ZONE 'UTC',retired.delivery_id)) THEN
        DELETE FROM pipeline_retired_delivery WHERE
          (created_at,delivery_id)=(retired.created_at,retired.delivery_id);
      END IF;
      EXIT WHEN affected=p_cap;
    END LOOP;
  ELSIF p_lane='transport' THEN
    WITH page AS MATERIALIZED (
      SELECT "expiresAt",id FROM transport_keys WHERE "expiresAt"<=
        (SELECT least(cutoff,p_now) AT TIME ZONE 'UTC' FROM raw_admission_cutoff WHERE singleton=1)
        AND ("expiresAt",id)>(coalesce(cursor_row.last_time AT TIME ZONE 'UTC','-infinity'),
          coalesce(cursor_row.last_serial,0))
      ORDER BY "expiresAt",id LIMIT p_cap
    ), held AS MATERIALIZED (
      SELECT t.id FROM transport_keys t JOIN page p USING (id)
      WHERE t."expiresAt"<=(SELECT least(cutoff,p_now) AT TIME ZONE 'UTC'
        FROM raw_admission_cutoff WHERE singleton=1)
      ORDER BY t.id FOR UPDATE OF t SKIP LOCKED
    ), removed AS (
      DELETE FROM transport_keys t USING held h WHERE t.id=h.id RETURNING 1
    ), advanced AS (
      INSERT INTO pipeline_retention_cursor (lane,last_time,last_id,last_disposition,last_serial)
      SELECT p_lane,coalesce(tail."expiresAt" AT TIME ZONE 'UTC','-infinity'),
        '00000000-0000-0000-0000-000000000000','',coalesce(tail.id,0)
      FROM (VALUES (1)) seed LEFT JOIN (SELECT * FROM page OFFSET p_cap-1) tail ON true
      ON CONFLICT (lane) DO UPDATE SET
        (last_time,last_serial)=(excluded.last_time,excluded.last_serial)
    )
    SELECT count(*) INTO affected FROM removed;
  ELSIF p_lane='observation' THEN
    RETURN correlia_reclaim_observation_keys(p_now,p_cap);
  ELSE
    RAISE EXCEPTION 'unknown maintenance lane';
  END IF;
  RETURN affected;
END;
$$;

-- Lock all lanes and commitment keys before reserving under the inbox count.
CREATE FUNCTION correlia_lock_replay_pins(p_pin text,p_sources jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  c record;
BEGIN
  PERFORM cap.output_id FROM pipeline_output_capacity cap WHERE cap.output_id IN (
    SELECT r.output_id FROM jsonb_array_elements_text(p_sources) s(id)
    CROSS JOIN LATERAL correlia_raw_pin_routes(p_pin,s.id::uuid) r
  ) ORDER BY cap.output_id FOR UPDATE;
  FOR c IN SELECT DISTINCT r.* FROM jsonb_array_elements_text(p_sources) s(id)
    CROSS JOIN LATERAL correlia_pin_commitments(p_pin,s.id::uuid) r
    ORDER BY reference,commitment,kind
  LOOP
    INSERT INTO pipeline_output_commitment (reference,commitment,kind)
    VALUES (c.reference,c.commitment,c.kind)
    ON CONFLICT (reference,commitment,kind) DO UPDATE
      SET pinned_count=pipeline_output_commitment.pinned_count;
  END LOOP;
END;
$$;

CREATE FUNCTION correlia_cleanup_replay_pins(p_pin text,p_sources jsonb)
RETURNS void LANGUAGE sql AS $$
  DELETE FROM pipeline_output_commitment c USING (
    SELECT DISTINCT r.* FROM jsonb_array_elements_text(p_sources) s(id)
    CROSS JOIN LATERAL correlia_pin_commitments(p_pin,s.id::uuid) r
  ) wanted WHERE (c.reference,c.commitment,c.kind)=(wanted.reference,wanted.commitment,wanted.kind)
    AND c.pinned_count=0 AND c.live_count=0
$$;

CREATE FUNCTION correlia_lock_delivery_replay_keys(p_rows jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  c record;
BEGIN
  FOR c IN SELECT DISTINCT r.* FROM jsonb_array_elements(p_rows) d
    CROSS JOIN LATERAL correlia_intent_commitments(d->>'pin',(d->>'output')::uuid,
      d->>'kind',d->>'reference',d->>'commitment') r
    ORDER BY reference,commitment,kind
  LOOP
    INSERT INTO pipeline_output_commitment (reference,commitment,kind)
    VALUES (c.reference,c.commitment,c.kind)
    ON CONFLICT (reference,commitment,kind) DO UPDATE
      SET live_count=pipeline_output_commitment.live_count;
  END LOOP;
END;
$$;

CREATE INDEX pipeline_reported_output_idx ON pipeline_output_capacity (
  (overflow_policy='block_ingest' AND (used_rows>=max_rows OR used_bytes>=max_payload_bytes
    OR demand_rows>max_rows-used_rows OR demand_bytes>max_payload_bytes-used_bytes)) DESC,
  output_id
) WHERE active OR used_rows>0 OR pinned_rows>0 OR overflow_activity_id IS NOT NULL
    OR overflow_policy='block_ingest';
