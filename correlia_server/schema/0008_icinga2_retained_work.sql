CREATE INDEX raw_stream_retained_idx ON raw_inbox (source_id)
  WHERE status IN ('pending', 'failed');
