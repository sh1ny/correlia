-- The index only projects the canonical subject (a fingerprint), never
-- payload data. JSONB refuses U+0000 escapes even in ignored fields. Replace
-- actual NUL escapes in this projection only; leave escaped backslashes
-- and all stored CloudEvent bytes untouched. Old indexed values are unchanged.
CREATE OR REPLACE FUNCTION correlia_event_subject(value bytea) RETURNS text
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $body$
DECLARE
  document text := convert_from(value, 'UTF8');
BEGIN
  IF strpos(document, $nul$\u0000$nul$) > 0 THEN
    document := regexp_replace(
      document,
      $pattern$(?<!\\)((?:\\\\)*)\\u0000$pattern$,
      $replacement$\1\\u0001$replacement$,
      'g'
    );
  END IF;
  RETURN document::jsonb->>'subject';
END;
$body$;
