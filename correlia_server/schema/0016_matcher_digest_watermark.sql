-- The snapshot table ID through which the matcher digest fill has read. Each
-- start and publication reads only the snapshots after it, so a snapshot that
-- a previous binary stored after an earlier fill, during an offline
-- downgrade, still gets its digest. The default makes the first fill after
-- this step read every snapshot again; its inserts are idempotent.
ALTER TABLE matcher_content_digest_fill
  ADD COLUMN filled_through bigint NOT NULL DEFAULT 0;
