CREATE TABLE activity (
  id bigserial PRIMARY KEY,
  txid xid8 NOT NULL DEFAULT pg_current_xact_id(),
  occurred_at timestamptz NOT NULL,
  entity_kind text NOT NULL,
  entity_id bigint NOT NULL,
  entity_version bigint NOT NULL,
  change_kind text NOT NULL,
  actor_kind text NOT NULL,
  actor_ref text,
  cause_event_id uuid,
  cause_raw_id uuid
);
CREATE INDEX activity_txid_id_idx ON activity (txid, id);

ALTER TABLE events ADD COLUMN state_outcome text
  CHECK (state_outcome IN ('applied', 'stale'));
