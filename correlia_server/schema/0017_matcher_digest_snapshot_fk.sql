-- A matcher content digest must never outlive the snapshot it names. Rows whose
-- snapshot is already gone are removed, and the fill watermark is reset when
-- any was, so the next fill reads every snapshot again and records content a
-- surviving snapshot still holds. The foreign key then refuses to delete a
-- snapshot while a digest row names it.
WITH gone AS (
  DELETE FROM matcher_content_digest d
  WHERE NOT EXISTS (
    SELECT 1 FROM ingest_config_snapshot s
    WHERE s."snapshotId" = d.first_snapshot_id
  )
  RETURNING 1
)
UPDATE matcher_content_digest_fill SET filled_through = 0
WHERE EXISTS (SELECT 1 FROM gone);

ALTER TABLE matcher_content_digest
  ADD CONSTRAINT matcher_content_digest_first_snapshot_fk
  FOREIGN KEY (first_snapshot_id) REFERENCES ingest_config_snapshot ("snapshotId");
