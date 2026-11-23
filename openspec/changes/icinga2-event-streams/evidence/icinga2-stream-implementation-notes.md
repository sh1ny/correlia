# Event Streams implementation run notes

## A4: embedded PostgreSQL version (task 7.1)

On 2026-11-23 a `withServerpod` database test ran `SHOW server_version` against the project's owned embedded test cluster. PostgreSQL reported `16.13`; the probe passed. `transaction_timeout` is not available on this server. Use the D13 statement and lock timeouts and the dedicated connection's local stop deadline; do not set `transaction_timeout` on PostgreSQL 16.
