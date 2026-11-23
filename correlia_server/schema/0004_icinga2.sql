-- Records the effective source time of each event.
--
-- A nullable column with no default and no backfill is a catalog-only change:
-- no row is rewritten. Rows written by this release always set it. A null
-- marks a row written before this step, whose effective time is the source
-- time capped at the observed time plus the five minute skew allowance that
-- the alert state service already applied to those rows without recording it.
ALTER TABLE events ADD COLUMN effective_source_time timestamptz;

-- The one way to read the effective source time of any event row.
CREATE FUNCTION events_effective_source_time(e events) RETURNS timestamptz
LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT COALESCE(
    e.effective_source_time,
    LEAST(e.source_time, e.observed_at + interval '5 minutes')
  )
$$;
