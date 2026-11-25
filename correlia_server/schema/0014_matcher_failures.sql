CREATE TABLE matcher_failure (
  id bigserial PRIMARY KEY,
  snapshot_id text NOT NULL,
  rule_id text NOT NULL,
  failure_count bigint NOT NULL CHECK (failure_count > 0),
  UNIQUE (snapshot_id, rule_id)
);

CREATE FUNCTION correlia_record_matcher_failure(
  pin text, rule text, failures bigint, raw uuid, occurred timestamptz
) RETURNS void LANGUAGE plpgsql AS $body$
DECLARE first_id bigint;
BEGIN
  INSERT INTO matcher_failure (snapshot_id, rule_id, failure_count)
    VALUES (pin, rule, failures)
    ON CONFLICT (snapshot_id, rule_id) DO NOTHING
    RETURNING id INTO first_id;
  IF FOUND THEN
    INSERT INTO activity (occurred_at, entity_kind, entity_id, entity_version,
                          change_kind, actor_kind, cause_raw_id)
      VALUES (occurred, 'matcher_failure', first_id, 1,
              'rule_failed', 'pipeline', raw);
  ELSE
    UPDATE matcher_failure SET failure_count = failure_count + failures
      WHERE snapshot_id = pin AND rule_id = rule;
  END IF;
END;
$body$;

CREATE FUNCTION correlia_record_matcher_batch(
  pin text, failures jsonb, raw uuid, occurred timestamptz
) RETURNS void LANGUAGE plpgsql AS $body$
DECLARE item record;
BEGIN
  FOR item IN SELECT key, value FROM jsonb_each_text(failures) ORDER BY key COLLATE "C"
  LOOP
    PERFORM correlia_record_matcher_failure(pin, item.key, item.value::bigint, raw, occurred);
  END LOOP;
END;
$body$;
