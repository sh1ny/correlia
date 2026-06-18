# Phase 6: Canonical Incident API Operation Parity - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-06-17
**Phase:** 6-Canonical Incident API Operation Parity
**Areas discussed:** Offset pagination metadata, ACKNOWLEDGED status semantics, Status mutation aliases, Summary mutation rejection

---

## Offset Pagination Metadata

| Option | Description | Selected |
|--------|-------------|----------|
| Yes, offset drives offset pagination | When `offset` is provided, return Vigilo-style page with total/limit/offset. Cursor stays default when only `cursor` is supplied. | ✓ |
| Only with a compat flag | Keep cursor as default; require an explicit parameter like `pagination=offset` to switch modes. | |
| You decide | Choose the simplest implementation consistent with existing code. | |

**User's choice:** Yes, offset drives offset pagination

| Option | Description | Selected |
|--------|-------------|----------|
| Yes, compute total | Run a COUNT query so Vigilo clients get accurate total/limit/offset metadata. | ✓ |
| No, omit total | Return items/limit/offset but leave total null or 0 to avoid extra count query. | |
| You decide | Choose based on expected query cost and Vigilo client needs. | |

**User's choice:** Yes, compute total

| Option | Description | Selected |
|--------|-------------|----------|
| Prefer cursor | Cursor is the canonical Correlia mode; ignore offset when cursor is present. | ✓ |
| Prefer offset | Offset is the Vigilo-style mode; ignore cursor when offset is present. | |
| Return 400 | Reject ambiguous requests with a clear error. | |
| You decide | Choose the safest default. | |

**User's choice:** Prefer cursor

| Option | Description | Selected |
|--------|-------------|----------|
| Always include | Return total/limit/offset on every list response (null/0 when using cursor mode) so the schema is stable. | ✓ |
| Only with offset | Include total/limit/offset only when offset pagination is requested; cursor mode keeps the existing items+next_cursor shape. | |
| You decide | Choose the cleaner schema design. | |

**User's choice:** Always include

**Notes:** Canonical response schema will remain stable. Cursor pagination stays the default; offset is used only when `offset` is explicitly supplied. If both are supplied, cursor wins.

---

## ACKNOWLEDGED Status Semantics

| Option | Description | Selected |
|--------|-------------|----------|
| Yes, derive acknowledged filter | `ACKNOWLEDGED` is a compatibility filter alias; canonical incident status stays OPEN and the existing acknowledgement object is returned. | ✓ |
| Add ACKNOWLEDGED as real status | Extend `IncidentStatus` enum and database status values. This changes Correlia's lifecycle invariant. | |
| You decide | Choose the approach that preserves lifecycle correctness while satisfying compatibility. | |

**User's choice:** Yes, derive acknowledged filter

| Option | Description | Selected |
|--------|-------------|----------|
| Call ack_open_incident and keep status OPEN | Use the existing acknowledgement path; canonical response returns status OPEN with acknowledgement populated. | ✓ |
| Reject with 422 | Only explicit POST /ack is allowed; PATCH status mutation is not supported for acknowledgement. | |
| You decide | Choose the path that best matches Vigilo client expectations while preserving existing endpoints. | |

**User's choice:** Call ack_open_incident and keep status OPEN

| Option | Description | Selected |
|--------|-------------|----------|
| OPEN, ACKNOWLEDGED, CLOSED only | Omit RESOLVED from the compatibility surface; keep it for Correlia's internal recovery path only. | ✓ |
| OPEN, ACKNOWLEDGED, CLOSED, RESOLVED | Expose all Correlia statuses, including RESOLVED, to Vigilo-style callers. | |
| You decide | Choose the minimal set needed for Vigilo parity. | |

**User's choice:** OPEN, ACKNOWLEDGED, CLOSED only

| Option | Description | Selected |
|--------|-------------|----------|
| Include acknowledged incidents | Correlia lifecycle view: OPEN means not RESOLVED/CLOSED, regardless of acknowledgement. Status filters are not mutually exclusive. | ✓ |
| Only unacknowledged | Vigilo-style mutually-exclusive view: OPEN means not acknowledged and not closed. Acknowledged incidents only match status=ACKNOWLEDGED. | |
| You decide | Choose the semantics that keep filters predictable for Vigilo clients. | |

**User's choice:** Include acknowledged incidents

**Notes:** `RESOLVED` remains a valid canonical filter value. The compatibility filter surface focuses on OPEN/ACKNOWLEDGED/CLOSED, and `ACKNOWLEDGED` is derived from `acknowledged_at IS NOT NULL` rather than being a stored status.

---

## Status Mutation Aliases

| Option | Description | Selected |
|--------|-------------|----------|
| ACKNOWLEDGED and CLOSED only | PATCH can ack or close; OPEN is not a meaningful target from a Vigilo client. | ✓ |
| OPEN, ACKNOWLEDGED, and CLOSED | Allow PATCH to any compatibility status; OPEN is a no-op if already open. | |
| You decide | Choose the minimal useful set. | |

**User's choice:** ACKNOWLEDGED and CLOSED only

| Option | Description | Selected |
|--------|-------------|----------|
| Yes, DELETE closes | DELETE maps to close with reason="vigilo-compat-delete" and operator="vigilo-compat". | ✓ |
| No, DELETE is unsupported | Return 405 or 422; only PATCH status=CLOSED and POST /close close incidents. | |
| You decide | Choose based on Vigilo client needs. | |

**User's choice:** Yes, DELETE closes

| Option | Description | Selected |
|--------|-------------|----------|
| operator="vigilo-compat", reason="vigilo-compat" | Use a single compatibility actor/reason for both PATCH and DELETE mutations. | ✓ |
| operator="vigilo-compat", reason="vigilo-compat-delete" for DELETE | Differentiate DELETE with a distinct reason while PATCH uses "vigilo-compat". | |
| You decide | Choose defaults that preserve audit traceability. | |

**User's choice:** operator="vigilo-compat", reason="vigilo-compat"

| Option | Description | Selected |
|--------|-------------|----------|
| Idempotent | Return 200 with the current incident state; matches existing POST /ack and POST /close idempotency. | ✓ |
| Reject duplicates | Return 409 or 422 if the incident is already in the target state. | |
| You decide | Choose the behavior consistent with existing endpoints. | |

**User's choice:** Idempotent

**Notes:** Existing explicit `POST /ack` and `POST /close` endpoints remain unchanged and continue to require caller-supplied operator/reason.

---

## Summary Mutation Rejection

| Option | Description | Selected |
|--------|-------------|----------|
| status only | Reject any body that contains fields other than status. | ✓ |
| status and optional operator/reason | Allow status plus operator/reason fields that are passed through to ack/close. | |
| You decide | Choose the minimal accepted set. | |

**User's choice:** status only

| Option | Description | Selected |
|--------|-------------|----------|
| summary mutation is not supported | Use this deterministic detail string. | ✓ |
| only status updates are supported | Alternative detail string. | |
| You decide | Choose the clearer message. | |

**User's choice:** summary mutation is not supported

| Option | Description | Selected |
|--------|-------------|----------|
| 422 status is required | Reject empty or missing status with this detail. | ✓ |
| You decide | Choose the error contract. | |

**User's choice:** 422 status is required

**Notes:** The rejection mechanism is a planner-level implementation detail; the externally visible contract is status-only PATCH with deterministic 422 detail.

---

## Claude's Discretion

No areas were deferred to Claude's discretion during this discussion.

## Deferred Ideas

No ideas were deferred to future phases during this discussion.

---

*Phase: 6-Canonical Incident API Operation Parity*
*Discussion logged: 2026-06-17*
