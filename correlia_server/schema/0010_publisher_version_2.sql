SELECT pg_advisory_xact_lock(1129271884);

CREATE OR REPLACE FUNCTION correlia_require_publisher_version() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF COALESCE(NULLIF(current_setting('correlia.publisher_version', true), ''), '0')::integer < 2 THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'outdated configuration publisher';
  END IF;
  RETURN NEW;
END;
$$;
