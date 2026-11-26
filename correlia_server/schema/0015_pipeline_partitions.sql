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
