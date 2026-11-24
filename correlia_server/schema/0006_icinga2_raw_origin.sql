CREATE TABLE icinga2_raw_origin (
  raw_id uuid PRIMARY KEY,
  origin text NOT NULL CHECK (origin IN ('stream', 'sync')),
  sync_id uuid,
  admission_snapshot_id text NOT NULL REFERENCES ingest_config_snapshot ("snapshotId"),
  CHECK ((origin = 'sync') = (sync_id IS NOT NULL))
);
