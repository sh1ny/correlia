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
