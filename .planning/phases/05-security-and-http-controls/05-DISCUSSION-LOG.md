# Phase 5: Security and HTTP Controls - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-06-14
**Phase:** 5-Security and HTTP Controls
**Areas discussed:** Protected route boundary, Unauthorized response contract, Rate-limit policy, Request-size policy

---

## Protected Route Boundary

### Default protected scope
| Option | Description | Selected |
|--------|-------------|----------|
| All /v1 except health | Protect incidents, ingress, config, plugins, metrics, and readyz unless explicitly made public; /v1/health remains public. | ✓ with clarification |
| Operator APIs only | Protect incidents/config/plugins/metrics, leave ingress and readyz public by default. | |
| Incidents only | Protect only incident read/mutation routes. | |

**User's choice:** Option 1, but exclude metrics or make it configurable.
**Notes:** Final decision: protect existing operator/config routes, make metrics exposure configurable, keep `/v1/health` public.

### Ingress token
| Option | Description | Selected |
|--------|-------------|----------|
| Yes, same token | One static token protects both operator and sender traffic. | |
| Separate ingress token | Sender-side token can rotate independently from operator clients. | ✓ |
| Public ingress | No auth on ingress; rely on network controls. | |

**User's choice:** Separate ingress token.
**Notes:** `/v1/icinga2/events` should not use the operator token.

### Readiness exposure
| Option | Description | Selected |
|--------|-------------|----------|
| Private by default | Requires operator token unless explicitly public. | |
| Public by default | Keeps current easy readiness checks while response stays bounded. | ✓ |
| Separate readiness token | Allows probes without full operator token. | |

**User's choice:** Public by default.
**Notes:** Exposure still configurable because readiness reports dependency status.

### Public path configuration
| Option | Description | Selected |
|--------|-------------|----------|
| Named exposure flags | Settings like public_readyz and public_metrics. | ✓ |
| Explicit path allowlist | Env-configured exact public paths. | |
| Both flags and paths | Flags plus exact path override. | |

**User's choice:** Named exposure flags.
**Notes:** Avoid arbitrary path allowlists.

---

## Unauthorized Response Contract

### Unauthorized status/body
| Option | Description | Selected |
|--------|-------------|----------|
| 401 compact JSON | Return 401 with `{"detail":"unauthorized"}` for missing and invalid tokens. | ✓ |
| 401 structured code | Return a richer error object. | |
| 403 invalid token | 401 missing, 403 invalid. | |

**User's choice:** 401 compact JSON.
**Notes:** Missing and invalid tokens intentionally share one response.

### Authenticate challenge header
| Option | Description | Selected |
|--------|-------------|----------|
| Yes | Include `WWW-Authenticate: Bearer`. | ✓ |
| No | Omit the challenge header. | |

**User's choice:** Yes.
**Notes:** Standard Bearer challenge is acceptable.

### Missing token config
| Option | Description | Selected |
|--------|-------------|----------|
| Fail startup | Misconfiguration is obvious; no silent unprotected routes. | ✓ |
| Return 503 on protected routes | Service starts but protected routes fail. | |
| Disable auth locally | Convenience bypass. | |

**User's choice:** Fail startup.
**Notes:** No development-mode bypass.

### Token-class response symmetry
| Option | Description | Selected |
|--------|-------------|----------|
| Same response | Operator, ingress, and metrics failures use the same 401 shape. | ✓ |
| Ingress-specific detail | Distinct ingress message. | |
| Metrics separate detail | Distinct metrics message. | |

**User's choice:** Same response.
**Notes:** Do not reveal which token class failed.

---

## Rate-limit Policy

### Rate-limited routes
| Option | Description | Selected |
|--------|-------------|----------|
| All protected routes | Applies to incidents, config/plugins, ingress, and optionally protected metrics. | ✓ |
| Write-heavy routes only | Ingress plus incident mutations. | |
| Ingress only | Only sender path. | |

**User's choice:** All protected routes.
**Notes:** Rate limits follow the protected route boundary.

### Rate-limit identity
| Option | Description | Selected |
|--------|-------------|----------|
| Token then IP | Use token/client class when authenticated, otherwise remote IP. | ✓ |
| IP only | Simple but proxy/NAT-hostile. | |
| Route only | Shared route bucket. | |

**User's choice:** Token then IP.
**Notes:** Covers authenticated and unauthenticated bursts.

### Default posture
| Option | Description | Selected |
|--------|-------------|----------|
| Conservative enabled defaults | Enabled defaults configurable per named route class. | ✓ |
| Configured but disabled | Settings exist but no limit applies until configured. | |
| Ingress strict, operator loose | Different default profiles. | |

**User's choice:** Conservative enabled defaults.
**Notes:** Planner should choose exact values.

### Over-limit response
| Option | Description | Selected |
|--------|-------------|----------|
| 429 compact JSON | `{"detail":"rate limit exceeded"}` plus `Retry-After` when computable. | ✓ |
| 429 structured code | Richer error object. | |
| Silent drop | No JSON response. | |

**User's choice:** 429 compact JSON.
**Notes:** Keep deterministic compact error style.

---

## Request-size Policy

### Default max body size
| Option | Description | Selected |
|--------|-------------|----------|
| 1 MiB default | Enough for normal Icinga2 payloads and operator mutations. | ✓ |
| 256 KiB default | Stricter abuse posture. | |
| 10 MiB default | Migration-friendly but weaker. | |

**User's choice:** 1 MiB default.
**Notes:** Route-class overrides may raise/lower this.

### Size-limit scope
| Option | Description | Selected |
|--------|-------------|----------|
| Global plus overrides | One default max body size, named overrides for ingress/operator route classes. | ✓ |
| Global only | Simpler, less flexible. | |
| Route-class only | Every class explicit. | |

**User's choice:** Global plus overrides.
**Notes:** Keep named class pattern consistent with route exposure/rate limits.

### Oversized response
| Option | Description | Selected |
|--------|-------------|----------|
| 413 compact JSON | `{"detail":"request body too large"}`. | ✓ |
| 413 structured code | Richer error with limit information. | |
| Close connection | No JSON response. | |

**User's choice:** 413 compact JSON.
**Notes:** Do not expose configured limit unless planner decides headers are safe.

### Missing Content-Length/chunked uploads
| Option | Description | Selected |
|--------|-------------|----------|
| Count bytes while reading | Allow unknown length until cap exceeded, then return 413 before handler logic. | ✓ |
| Reject unknown length | Return 411/413 when length absent. | |
| Allow unknown length | No pre-handler enforcement. | |

**User's choice:** Count bytes while reading.
**Notes:** Must fail before route handler logic once cap is exceeded.

---

## Claude's Discretion

- Planner may choose exact conservative rate-limit numeric defaults.
- Planner may choose the smallest safe in-process mechanism consistent with the single-worker default.

## Deferred Ideas

None.
