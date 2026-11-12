# Alertmanager webhook captures

One firing and one resolved notification from the latest patch of each Alertmanager minor release, 0.16.2 to
0.35.0, captured on 2026-11-12. Each release ran as the `prom/alertmanager:<version>` Docker image with
`--network host`, its webhook receiver pointing at a local capture server. One test alert (`CapTest`, our own
data) was posted to its `/api/v2/alerts` API, then resolved by posting it again with `endsAt`.

Changes after capture: the JSON is pretty-printed with sorted keys, and `externalURL` (the capture host's name
and port) is replaced with `http://alertmanager.example:9093`. Nothing else was changed.

See the [compatibility runbook](../../../../../docs/runbooks/alertmanager-compatibility.md) for the
capture script, adding a release, and the real-Alertmanager end-to-end check.
