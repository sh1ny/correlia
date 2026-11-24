ALTER TABLE icinga2_sync_progress
  ADD COLUMN generation bigint NOT NULL DEFAULT 0,
  ADD COLUMN connection_id text,
  ADD COLUMN samples jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN last_object text;

CREATE INDEX icinga2_sync_open_idx ON icinga2_sync_progress (source_id)
  WHERE read_end_at IS NULL;

-- Reader and pipeline call this after recording their effects, in the same
-- transaction. A stalled sync can still complete; a terminal one cannot change.
CREATE FUNCTION icinga2_finalize_sync(wanted uuid, allow_stall boolean)
RETURNS text LANGUAGE sql AS $$
  WITH held AS MATERIALIZED (
    SELECT * FROM icinga2_sync_progress WHERE sync_id=wanted FOR UPDATE
  ), decided AS (
    SELECT held.*, CASE
      WHEN phase IN ('complete','failed') THEN phase
      WHEN rows_failed>0 OR read_problem IS NOT NULL THEN 'failed'
      WHEN read_end_at IS NOT NULL AND rows_done=rows_admitted THEN 'complete'
      WHEN phase='stalled' OR (allow_stall AND
        read_end_at<=clock_timestamp()-interval '15 minutes') THEN 'stalled'
      WHEN read_end_at IS NOT NULL THEN 'applying'
      ELSE 'reading' END AS next_phase
    FROM held
  )
  UPDATE icinga2_sync_progress AS p SET
    phase=d.next_phase,
    reason=CASE d.next_phase WHEN 'failed' THEN coalesce(d.read_problem,'row_failed')
      WHEN 'stalled' THEN 'applying_timeout' ELSE NULL END,
    ended_at=CASE WHEN d.next_phase IN ('complete','failed') THEN clock_timestamp()
      ELSE d.ended_at END
  FROM decided d WHERE p.sync_id=d.sync_id AND d.phase<>d.next_phase
  RETURNING p.phase
$$;
