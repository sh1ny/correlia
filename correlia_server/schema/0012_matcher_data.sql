-- Project CloudEvent data without changing stored bytes. Valid JSON never
-- contains raw U+0001..U+0003; use those as temporary placeholders so a token
-- emitted by one replacement cannot be consumed by the next.
CREATE FUNCTION correlia_matcher_data(value bytea) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $body$
DECLARE
  document text := translate(convert_from(value, 'UTF8'), '~!^', chr(1) || chr(2) || chr(3));
BEGIN
  IF strpos(document, $slash$\$slash$) > 0 THEN
    -- Consume only an actual Unicode escape, retaining pairs of preceding
    -- backslashes. In particular, a literal "\u0000" is not a NUL.
    document := regexp_replace(document, $p$(?<!\\)((?:\\\\)*)\\u0000$p$, $r$\1~!!$r$, 'g');
    document := regexp_replace(document, $p$(?<!\\)((?:\\\\)*)\\u0021$p$, $r$\1~!^$r$, 'g');
    document := regexp_replace(document, $p$(?<!\\)((?:\\\\)*)\\u005[eE]$p$, $r$\1~^!$r$, 'g');
    document := regexp_replace(document, $p$(?<!\\)((?:\\\\)*)\\u007[eE]$p$, $r$\1~^^$r$, 'g');
  END IF;
  RETURN replace(replace(replace(document, chr(1), '~^^'), chr(2), '~!^'), chr(3), '~^!')::jsonb->'data';
END;
$body$;
