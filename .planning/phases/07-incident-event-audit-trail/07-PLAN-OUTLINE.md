# Phase 07 Plan Outline: Incident Event Audit Trail

| Plan ID | Objective | Wave | Depends On | Requirements |
|---------|-----------|------|------------|--------------|
| 07-01 | Create the audit schema/domain/persistence foundation: `incident_events` migration/model, `AuditDecisionSummary` and response/filter models, redaction/HMAC/cursor repository helpers, audit settings, and focused unit/migration/persistence tests. | 1 | none | AUD-01, AUD-02 |
| 07-02 | Refactor ingress and manager commit ownership so every accepted event writes exactly one audit row in the incident transaction without using audit data for aggregation, thresholds, recovery, or lifecycle decisions. | 2 | 07-01 | AUD-02, AUD-03, AUD-04 |
| 07-03 | Expose the read-only `/v1/incident-events` operator API with cursor pagination, required filters, operator route classification, bounded response projection, and integration coverage for incident/no-op correlation. | 3 | 07-02 | AUD-02, AUD-03, AUD-04 |

## Locked Decision Coverage

| Plan ID | Locked Decisions Covered |
|---------|--------------------------|
| 07-01 | D-04, D-05, D-06, D-07, D-08, D-13, D-17, D-18, D-19 |
| 07-02 | D-01, D-02, D-03, D-12, D-14 |
| 07-03 | D-08, D-09, D-10, D-11, D-12, D-15, D-16 |

## OUTLINE COMPLETE — 3 plans
