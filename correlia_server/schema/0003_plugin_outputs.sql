ALTER TABLE outbox
  ADD COLUMN output_kind text NOT NULL DEFAULT 'webhook',
  ADD COLUMN definition_digest text,
  ALTER COLUMN target_url DROP NOT NULL,
  ALTER COLUMN signing_key_ref DROP NOT NULL,
  ALTER COLUMN signing_key_commitment DROP NOT NULL,
  ADD CONSTRAINT outbox_output_kind_check CHECK (output_kind IN ('webhook', 'plugin')),
  ADD CONSTRAINT outbox_output_definition_check CHECK (
    (output_kind = 'webhook' AND target_url IS NOT NULL AND signing_key_ref IS NOT NULL AND signing_key_commitment IS NOT NULL)
    OR (output_kind = 'plugin' AND definition_digest IS NOT NULL)
  );
CREATE INDEX outbox_definition_status_idx ON outbox (output_id, definition_digest, status);
