-- Matcher content already stored, keyed by the SHA-256 of its canonical JSON.
-- Publication and startup use one primary-key probe to tell a restore of
-- earlier content from new content. Both tables are SQL-owned.
CREATE TABLE matcher_content_digest (
  digest bytea PRIMARY KEY,
  first_snapshot_id text NOT NULL
);

-- One row once the digests of every snapshot stored before this step exist.
CREATE TABLE matcher_content_digest_fill (
  singleton integer PRIMARY KEY CHECK (singleton = 1),
  completed_at timestamptz NOT NULL DEFAULT now()
);
