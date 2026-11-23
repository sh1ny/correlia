# Integration catalog and plan

The integration backlog for Correlia up to 1.0 and beyond: the owner's list, common alert sources and
targets in self-hosted operations, and the plugin capabilities each needs.

## How integrations are built

Every integration is a **plugin** behind the Correlia plugin interface (ADR 0020). It runs either built in
(Dart, in-process) or as an external process over gRPC. One plugin declares one or more **capabilities**
in its manifest, and each capability has its own config schema, required secrets and health check:

| Capability | Meaning | Example |
|---|---|---|
| `source.push` | Receives webhooks on `/hooks/<kind>/<instance>` | Alertmanager, Grafana, Uptime Kuma |
| `source.pull` | Polls an API on a schedule | Icinga2 state sync, Zabbix problems |
| `source.consume` | Reads a stream or queue with a durable cursor | Icinga2 event stream, NATS, Kafka, Kubernetes events |
| `decoder` | Turns raw bytes from a source into canonical events | one per source format |
| `enricher` | Adds context to an event (tags, owner, links) as a patch | NetBox, Prometheus query, GeoIP |
| `output` | Publishes canonical events or incidents | NATS, Kafka, webhook-out |
| `notify` | Sends a human notification from a template | email, Slack, Teams, Telegram |
| `action` | A typed action a workflow may call | create Jira issue, PagerDuty trigger, Icinga2 ack |
| `query` | Reads context for the console or a workflow | Prometheus query, Loki logs |
| `sync` | Keeps state in both directions | Icinga2 ack/downtime, Jira status, PagerDuty ack |
| `topology` | Pulls a service or dependency map | NetBox, Kubernetes, Argo CD |

**Built in vs external.**
- **Built in:** the P0 sources (Icinga2, Alertmanager, Thanos, generic webhook) and the simple HTTP-based
  P1 plugins. They ship in the server and cost no extra process.
- **External:** anything that needs a mature non-Dart client library (NATS JetStream, Kafka, cloud SDKs,
  Kubernetes watch), and any third-party plugin.

**Definition of done for every integration:**
1. A mapping spec: `openspec/specs/integration-<name>/spec.md`. It covers field by field how the source
   maps to `correlia.event.v1`, how severity and status map, the fingerprint inputs, and what is dropped
   and why.
2. Fixtures captured from a real system (or the vendor's documented examples, marked as such). Golden
   tests run decoder output against them.
3. Health check and status in the console's plugin page.
4. A setup guide with screenshots of the source side.
5. Secrets are stored encrypted and never logged.

## Tiers

- **P0:** needed for the owner's real traffic. Delivered in M1-M3.
- **P1:** planned for M6, M7 and M9, and for the 1.x integration wave that the owner moved out of M8 on
  2026-11-22. Not a 1.0 blocker: each ships when it meets the definition of done, in its milestone or in a
  1.x point release (owner, 2026-11-03, D27).
- **P2:** after 1.0, on demand. The plugin SDK makes them community-buildable.
- **Avoid:** do not build.

## P0: core (M1-M3)

| Integration | Capabilities | Runs | Milestone | Notes |
|---|---|---|---|---|
| Prometheus Alertmanager | source.push, decoder | built in | M1 | Webhook v4. One canonical event per alert in the notification group. Original selected labels determine identity; the upstream fingerprint is evidence only (ADR 0024). Supports `send_resolved` and the `truncatedAlerts` count. |
| NATS / JetStream | output | external Go | M1 | The reference external plugin (ADR 0018). Its consume side is P1, in the event bus table below. |
| Icinga2 | source.push, source.consume (event streams API), source.pull (state sync), decoder, sync (ack, downtime), action | built in | M2 | Host and service state changes, check output, acknowledgement/downtime/flapping flags, soft vs hard state. Pull is used for state reconciliation after downtime of Correlia itself. |
| Thanos (Ruler, Query) | source.push via the Alertmanager decoder; query via Prometheus query | built in | M2 | A tested configuration plus tenant headers and auth, not a separate decoder. |
| Generic inbound webhook | source.push, decoder (declarative mapping) | built in | M2 | Any JSON mapped by a versioned mapping document (JSON pointer/path + matcher functions), with a preview against a pasted sample. |
| Generic webhook out | output, notify, action | built in | M1 (output), M6 (notify) | Signed (HMAC) JSON, CloudEvents structured mode, retry with backoff. |

## P1: planned for M6, M7, M9 and 1.x, not a 1.0 blocker

### Monitoring sources (1.x unless noted)

| Integration | Capabilities | Runs | Notes |
|---|---|---|---|
| Prometheus / Thanos / VictoriaMetrics query | query, enricher | built in | M2 for enrichment basics. PromQL instant queries for console context and enrichment. |
| VictoriaMetrics / vmalert | source.push | built in | Alertmanager-compatible; a tested configuration. |
| Grafana alerting | source.push, decoder, query (dashboards/panels links) | built in | Unified alerting webhook. Maps labels and annotations, `dashboardURL`, `panelURL` and `silenceURL`. |
| Zabbix | source.push (media type), source.pull (problem.get), decoder, sync (ack) | built in | |
| Nagios Core / XI | source.push (notification command), decoder | built in | Shares the state model with Icinga2 (hard/soft). |
| Checkmk | source.push (notification plugin), decoder | built in | Nagios lineage. |
| Uptime Kuma | source.push, decoder | built in | |
| Datadog | source.push, decoder, query | built in | |
| Elastic / Kibana | source.push (Kibana connector), decoder, query | built in | One plugin. |
| Grafana Loki | source.push (Loki ruler via Alertmanager format), query (logs around the event) | built in | |
| Sentry | source.push (internal integration webhook), decoder | built in | |
| AWS CloudWatch | source.push (SNS HTTPS subscription), decoder | external Go | Signature verification of SNS messages. |
| Azure Monitor | source.push (common alert schema), decoder | built in | |
| GCP Cloud Monitoring | source.push (webhook channel), decoder | built in | |
| Kubernetes | source.consume (events watch), topology, action (rollout restart, guarded) | external Go | AKS/EKS/GKE/OpenShift are credential strategies of this one plugin. |
| Syslog | source.consume (UDP/TCP/TLS listener, RFC 5424/3164) | external Go | Network shops ask for it. |
| SNMP traps | source.consume (v2c/v3 trap listener, MIB-based decode) | external Go | |
| Email in (IMAP) | source.consume | external | For tools that can only send mail. |

### Notification targets (M6)

| Integration | Capabilities | Notes |
|---|---|---|
| Email (SMTP; SendGrid and Resend as transports) | notify | Subject lines are sanitized: the legacy B11 newline defect. |
| Slack | notify, action (update message on ack/resolve), sync (ack button, M7) | Bot token + Block Kit. Interactive buttons need an inbound route. |
| Microsoft Teams | notify | Workflows/Power Automate webhook; Adaptive Cards. |
| Mattermost | notify, sync (interactive buttons) | |
| Telegram | notify | Bot API. |
| PagerDuty | notify (Events API v2), sync (ack/resolve both ways) | |
| Webhook out | notify | Shared with the output. |

### Ticketing and incident management (M7)

| Integration | Capabilities | Notes |
|---|---|---|
| Jira Cloud and Data Center | action (create, comment, transition), sync (status back to the incident) | One plugin; auth variants. |
| ServiceNow | action (incident create/update), sync | |
| Jira Service Management ops | notify, sync | Instead of Opsgenie, which is being shut down by Atlassian (unverified; check before building). |

### Context and topology (M9)

| Integration | Capabilities | Notes |
|---|---|---|
| NetBox | enricher (device, site, tenant, owner, role by hostname/IP), topology | The enrichment side is worth more to an Icinga shop than change webhooks. |
| Static CMDB (CSV/YAML import) | enricher, topology | For teams with no NetBox. |

### Event bus

| Integration | Capabilities | Milestone | Notes |
|---|---|---|---|
| Kafka | output, source.consume | 1.x | Cheap once NATS exists; same Go SDK. |
| NATS / JetStream consume | source.consume | 1.x | Moved out of M8 by the owner, 2026-11-22. A leased durable consumer with explicit ack. |

## P2: after 1.0 (on demand, community-buildable)

- **Sources:** Centreon, LibreNMS, Netdata, Graylog, Splunk (first enterprise promotion candidate),
  Dynatrace, New Relic, AppDynamics, SignalFx, Sumo Logic, Coralogix, Axiom, Dash0, OpenObserve,
  Parseable, VictoriaLogs, Vector, Pingdom, StatusCake, Site24x7, Checkly, ThousandEyes, Rollbar, Wazuh.
- **Incident management:** incident.io, ilert, Grafana Incident / Cloud IRM, AWS Incident Manager,
  Squadcast, PagerTree, Zenduty, SIGNL4, Flashduty. Grafana OnCall OSS and Opsgenie were demoted because
  their vendors are winding them down (unverified).
- **Chat:** Discord, Google Chat, Zoom Chat, ntfy (cheap, popular with self-hosters), Pushover, Twilio
  (SMS/voice).
- **Ticketing:** YouTrack, Redmine, Linear, GitLab issues, GitHub issues, Asana, Trello, Monday,
  Microsoft Planner.
- **CI/CD and change events:** GitHub Actions, GitLab pipelines, Argo CD and Flux CD (useful for "what
  changed before this incident" correlation), Airflow.
- **Cloud and queues:** AWS SQS, S3, Cilium/Hubble.
- **Databases as query targets:** PostgreSQL, MySQL, ClickHouse, MongoDB, BigQuery, Snowflake,
  OpenSearch.
- **AI:** one OpenAI-compatible endpoint plugin (covers LiteLLM, vLLM, Ollama, llama.cpp and hosted
  gateways) instead of nine provider plugins. Out of scope for 1.0 by strategy.

## Avoid

- **Bash, Python and SSH steps:** remote code execution as a feature. If remediation is ever wanted, a
  separate, explicitly enabled runbook runner with allow-listed commands and an audit trail.
- **QuickChart:** render charts in the console instead.
