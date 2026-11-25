DO $body$
BEGIN
  PERFORM pg_advisory_xact_lock(1129271884);
  PERFORM singleton FROM ingest_active_config WHERE singleton = 1 FOR UPDATE;
END;
$body$;

CREATE FUNCTION correlia_pinned_output_routes()
RETURNS TABLE(snapshot_id text, output_id text)
LANGUAGE sql STABLE AS $body$
  WITH pending AS (
    SELECT DISTINCT config_snapshot_id, source_id FROM raw_inbox
    WHERE status = 'pending' AND config_snapshot_id IS NOT NULL
  ), enabled AS MATERIALIZED (
    SELECT p.config_snapshot_id, c."publicJson"::jsonb AS doc, source
    FROM pending p
    JOIN ingest_config_snapshot c ON c."snapshotId" = p.config_snapshot_id
    CROSS JOIN LATERAL jsonb_array_elements(c."publicJson"::jsonb->'sources') source
    WHERE source->>'id' = p.source_id::text AND source->'enabled' = 'true'::jsonb
  )
  SELECT config_snapshot_id, route
  FROM enabled CROSS JOIN LATERAL jsonb_array_elements_text(source->'output_ids') route
  UNION
  SELECT config_snapshot_id, action->>'output_id'
  FROM (SELECT DISTINCT config_snapshot_id, doc FROM enabled) snapshots
  CROSS JOIN LATERAL jsonb_array_elements(doc->'matcher'->'rules') rule
  CROSS JOIN LATERAL jsonb_array_elements(rule->'actions') action
  WHERE action->>'type' = 'route';
$body$;

CREATE FUNCTION correlia_retained_output_ids() RETURNS TABLE(output_id text)
LANGUAGE sql STABLE AS $body$
  SELECT output_id FROM correlia_pinned_output_routes()
  UNION
  SELECT output_id::text FROM outbox WHERE status IN ('queued', 'delivering');
$body$;

DO $body$
BEGIN
  IF (SELECT count(*) FROM (
    SELECT output_id FROM correlia_retained_output_ids()
    UNION
    SELECT output->>'id'
    FROM ingest_active_config a
    JOIN ingest_config_snapshot c ON c."snapshotId" = a."snapshotId"
    CROSS JOIN LATERAL jsonb_array_elements(c."publicJson"::jsonb->'outputs') output
    WHERE a.singleton = 1
  ) lanes) > 64 THEN
    RAISE EXCEPTION USING ERRCODE = '55000',
      MESSAGE = 'retained output capacity exceeded; drain work on the older release before upgrading';
  END IF;
END;
$body$;

CREATE OR REPLACE FUNCTION correlia_require_publisher_version() RETURNS trigger
LANGUAGE plpgsql AS $body$
BEGIN
  IF COALESCE(NULLIF(current_setting('correlia.publisher_version', true), ''), '0')::integer < 3 THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'outdated configuration publisher';
  END IF;
  RETURN NEW;
END;
$body$;

CREATE FUNCTION correlia_require_pin_worker() RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN
  IF current_setting('correlia.pin_worker_version', true) IS DISTINCT FROM '3' THEN
    IF TG_OP = 'UPDATE' THEN
      IF OLD.config_snapshot_id IS NULL AND NEW.config_snapshot_id IS NOT NULL THEN
        RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'outdated first-pin worker';
      END IF;
    END IF;
    IF OLD.status = 'pending' AND EXISTS (
      SELECT FROM ingest_config_snapshot c
      WHERE c."snapshotId" = OLD.config_snapshot_id AND c."publicJson"::jsonb ? 'matcher'
    ) THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'outdated matcher worker';
    END IF;
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$body$;

CREATE TRIGGER correlia_require_pin_worker
BEFORE UPDATE OR DELETE ON raw_inbox FOR EACH ROW EXECUTE FUNCTION correlia_require_pin_worker();
