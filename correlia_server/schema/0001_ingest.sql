CREATE TABLE raw_inbox (
  observed_at timestamptz NOT NULL,
  raw_id uuid NOT NULL,
  source_id uuid NOT NULL,
  body bytea NOT NULL,
  body_sha256 text NOT NULL,
  content_type text NOT NULL,
  status text NOT NULL DEFAULT 'pending',
  config_snapshot_id text,
  attempt_count integer NOT NULL DEFAULT 0,
  next_attempt_at timestamptz,
  outcome_json text,
  PRIMARY KEY (observed_at, raw_id)
);
CREATE INDEX raw_inbox_eligibility_idx ON raw_inbox (status, next_attempt_at);

CREATE TABLE events (
  observed_at timestamptz NOT NULL,
  event_id uuid NOT NULL,
  disposition text NOT NULL,
  raw_observed_at timestamptz NOT NULL,
  raw_id uuid NOT NULL,
  source_id uuid NOT NULL,
  config_snapshot_id text NOT NULL,
  source_time timestamptz NOT NULL,
  payload bytea NOT NULL,
  PRIMARY KEY (observed_at, event_id, disposition)
);

CREATE TABLE outbox (
  created_at timestamptz NOT NULL,
  delivery_id uuid NOT NULL,
  event_observed_at timestamptz NOT NULL,
  event_id uuid NOT NULL,
  event_disposition text NOT NULL,
  output_id uuid NOT NULL,
  config_snapshot_id text NOT NULL,
  target_url text NOT NULL,
  signing_key_ref text NOT NULL,
  signing_key_commitment text NOT NULL,
  payload bytea NOT NULL,
  status text NOT NULL DEFAULT 'queued',
  claim_id uuid,
  lease_until timestamptz,
  attempt_count integer NOT NULL DEFAULT 0,
  next_attempt_at timestamptz,
  dead_reason text,
  PRIMARY KEY (created_at, delivery_id)
);
CREATE INDEX outbox_eligibility_idx ON outbox (status, next_attempt_at, output_id);
