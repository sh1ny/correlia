# Phase 2: Icinga2 Ingress, Topology, and Rule Decisions - Pattern Map

**Mapped:** 2026-06-08
**Files analyzed:** 11 new
**Analogs found:** 5 / 11 (the rest are greenfield in this repo and must lean on the in-place contracts plus RESEARCH.md code examples)

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `app/api/routers/ingress.py` | router (FastAPI APIRouter) | request-response | `app/api/routers/health.py` | role-match |
| `app/api/deps.py` (extend) | middleware/dependency | request-response | `app/api/deps.py` (existing) | exact (extend, not replace) |
| `app/main.py` (extend) | app factory | startup | `app/main.py` (existing) | exact (extend lifespan to load rules/topology) |
| `app/domain/rules.py` | domain model | transform | `app/domain/incidents.py` (`DecisionContext`) | role-match (strict Pydantic boundary model) |
| `app/processing/enrichment.py` | service | transform (pure) | `app/persistence/incidents.py` (pure upsert builder) | partial — closest pure-transformation module |
| `app/processing/rule_engine.py` | service | transform (pure) | `app/persistence/incidents.py` (pure builder + invariants) | partial — same load-time invariants style |
| `app/plugins/interfaces.py` | interfaces (Protocol) | n/a (typing) | none — `Protocol` is new to the repo | none |
| `app/plugins/inputs/icinga2.py` | input plugin (Protocol impl) | transform (pure) | none | none — first plugin implementation |
| `app/config/rules.py` | config loader (YAML→Pydantic) | startup | `app/config/settings.py` (strict Pydantic settings) | role-match (strict, `extra="forbid"`) |
| `app/config/topology.py` | config loader (YAML→Pydantic) | startup | `app/config/settings.py` | role-match |
| `tests/test_icinga2_input.py`, `tests/test_topology_enrichment.py`, `tests/test_rule_engine.py`, `tests/test_rule_topology_yaml.py`, `tests/test_ingress_router.py` | tests | n/a | `tests/test_domain_events.py`, `tests/test_health.py`, `tests/test_domain_incidents.py` | exact (Pydantic + FastAPI ASGI test client style) |

> There is **no existing input plugin, topology enricher, or rule engine** in the codebase. `app/persistence/incidents.py` is the only "pure builder" analog, and it is the right style anchor for compile-at-load-time invariants and explicit `ValueError` rejection. Phase 2 has to establish the new `app/processing/` and `app/plugins/` package shape.

## Pattern Assignments

### `app/api/routers/ingress.py` (router, request-response)

**Analog:** `app/api/routers/health.py`

**Imports + router declaration** (`app/api/routers/health.py:1-12`):
```python
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.api.deps import get_app_settings, get_sessionmaker
from app.config.settings import Settings
from app.persistence.database import check_database_ready

router = APIRouter()
```

**Handler style** (`app/api/routers/health.py:15-22,24-35`):
```python
@router.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@router.get("/readyz")
async def readyz(
    settings: Annotated[Settings, Depends(get_app_settings)],
    sessionmaker: Annotated[
        async_sessionmaker[AsyncSession], Depends(get_sessionmaker)
    ],
) -> dict[str, str]:
    try:
        await check_database_ready(sessionmaker)
    except Exception as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="not ready",
        ) from exc

    return {"status": "ready"}
```

**Patterns to apply:**
- `router = APIRouter()` at module top; one router per file (no nested routers).
- `Annotated[Settings, Depends(get_app_settings)]` for settings injection; add a sibling `get_icinga2_processor` (or similar) in `app/api/deps.py` that returns the loaded `Icinga2Processor` from `app.state`.
- Wrap unexpected exceptions in `HTTPException(status_code=500, detail="ingest failed")`; never leak raw exception text in the response body (the existing `test_readyz_returns_non_secret_503_when_database_check_fails` asserts this).
- Strict Pydantic request model bound via `payload: Icinga2WebhookPayload = Body(...)` so OpenAPI is generated and validation errors come from Pydantic, not hand-rolled checks.
- Webhook handler must remain thin: validate → call processor → return envelope. All state mapping, fingerprint, enrichment, and rule evaluation live behind the processor.

---

### `app/api/deps.py` (extend, request-response dependency)

**Analog:** `app/api/deps.py` (existing) — extend, do not replace.

**Existing shape** (`app/api/deps.py:1-13`):
```python
from typing import cast

from fastapi import Request
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.config.settings import Settings


def get_app_settings(request: Request) -> Settings:
    return cast(Settings, request.app.state.settings)


def get_sessionmaker(request: Request) -> async_sessionmaker[AsyncSession]:
    return cast(async_sessionmaker[AsyncSession], request.app.state.sessionmaker)
```

**Patterns to apply:**
- `cast(...)` typing of `request.app.state.*` — copy that idiom.
- Add `get_icinga2_processor(request)` returning `cast(Icinga2Processor, request.app.state.icinga2_processor)`. Phase 2 does not need a sessionmaker for ingest; the processor is built once in `lifespan`.
- Keep dependency functions synchronous and request-scoped (no `async def`); they only read state.

---

### `app/main.py` (extend, startup)

**Analog:** `app/main.py` (existing) — extend lifespan to load rules and topology.

**Existing pattern** (`app/main.py:7-22,33-43`):
```python
@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    if not hasattr(app.state, "settings"):
        app.state.settings = get_settings()

    engine = getattr(app.state, "engine", None)
    if not hasattr(app.state, "sessionmaker"):
        engine = create_engine(app.state.settings)
        app.state.engine = engine
        app.state.sessionmaker = create_sessionmaker(engine)

    try:
        yield
    finally:
        engine = getattr(app.state, "engine", None)
        if engine is not None:
            await engine.dispose()


def create_app(
    settings: Settings | None = None,
    sessionmaker: async_sessionmaker[AsyncSession] | None = None,
) -> FastAPI:
    app = FastAPI(lifespan=lifespan)

    if settings is not None:
        app.state.settings = settings
    if sessionmaker is not None:
        app.state.sessionmaker = sessionmaker

    app.include_router(health_router)
    return app
```

**Patterns to apply:**
- Default-attribute pattern: only build resource if `not hasattr(app.state, ...)` so tests can inject prebuilt processors via `create_app(...)` (mirrors how `settings=` and `sessionmaker=` are injected).
- Add `app.state.icinga2_processor = build_icinga2_processor(app.state.settings)` in `lifespan`, plus an optional keyword arg on `create_app` so tests can pass a prebuilt processor.
- Add `app.include_router(ingress_router)` next to `health_router`; do not introduce a top-level `APIRouter(prefix="/api/v1")` — keep one router per file and let the file declare the path prefix.
- Lifespan must `dispose()`/`None`-out the engine today and any future async resources, mirroring the existing `engine.dispose()` line. If Phase 2 introduces only synchronous resources (rules + topology), no teardown is needed; document that.
- Tests will need a way to construct `create_app()` without a real database (Phase 2 does not touch the DB in the happy path). Provide a `sessionmaker=None` path that still works (the current code sets it during lifespan only if missing). The same pattern must hold for `icinga2_processor`.

---

### `app/domain/rules.py` (domain model, transform)

**Analog:** `app/domain/incidents.py` (`DecisionContext` style).

**Existing style** (`app/domain/incidents.py:1-25,28-60`):
```python
from __future__ import annotations

from datetime import datetime
from enum import StrEnum
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

from app.domain.events import TagKey, TagValue


class IncidentStatus(StrEnum):
    OPEN = "OPEN"
    RESOLVED = "RESOLVED"
    CLOSED = "CLOSED"


BoundedString = Annotated[str, Field(min_length=1, max_length=256)]
BoundedStringTuple = Annotated[tuple[BoundedString, ...], Field(max_length=20)]


class DecisionContext(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    schema_version: Literal[1] = 1
    fingerprint: BoundedString | None = None
    source_id: BoundedString | None = None
    rule_name: BoundedString | None = None
    group_key: BoundedString | None = None
    matched_rule_names: BoundedStringTuple = ()
    enrichment_refs: BoundedStringTuple = ()
    event_count: int | None = Field(default=None, ge=0)
    config_hash: str | None = Field(default=None, max_length=128)
    notes: dict[TagKey, TagValue] = Field(default_factory=dict, max_length=20)
```

**Patterns to apply to `app/domain/rules.py`:**
- `from __future__ import annotations` at top, then `ConfigDict(strict=True, extra="forbid")` on **every** model — no exceptions.
- Reuse `BoundedString` / `BoundedStringTuple` for `rule_name`, `group_key`, `matched_rule_names` rather than redefining bounds.
- Reuse `TagKey` / `TagValue` from `app.domain.events` for rule match criteria that look at tags.
- `Literal[...]` discriminators for any `schema_version` field on `RuleDecision` / `ThresholdDecision` / `NoOpDecision` so future versions break loudly.
- `field_validator(mode="after")` for invariants that Pydantic types can't express (mirroring `reject_secret_note_content` in `app/domain/incidents.py:46-54` and `require_timezone` in `app/domain/events.py:62-67`).
- Use `StrEnum` (not `str, Enum`) for any new state enumeration so `.value` comparisons match Icinga2 string state names.
- `app/domain/__init__.py` is **empty** in this repo — do not add re-exports there. Keep `app.domain.rules` importable as a module.

---

### `app/processing/enrichment.py` (service, transform)

**Analog:** `app/persistence/incidents.py` (pure builder, no I/O in the body; error type is `ValueError` for invariants).

**Existing pattern** (`app/persistence/incidents.py:24-46`, the `_jsonb_sorted_union` helper):
```python
def _jsonb_sorted_union(existing_column: Any, excluded_name: str, max_items: int) -> Any:
    existing_elems = select(
        func.jsonb_array_elements_text(existing_column).label("elem")
    ).subquery("e1")
    ...
```

**Patterns to apply:**
- Build all "compiled" structures (`re.compile(...)` for hostname patterns, `ipaddress.ip_network(...)` for subnets) at `__init__`, **not per event**. This is the most important rule from `RESEARCH.md` Pattern 3.
- Public classes stay `frozen=True, slots=True` dataclasses (mirror `IncidentUpsertInput` at `app/persistence/incidents.py:48-83`) for `EnrichmentDiagnostic`, `EnrichmentResult`. This keeps enrichment outputs immutable and trivially testable.
- Validate input invariants in `__post_init__` (mirrors `IncidentUpsertInput.__post_init__`); raise `ValueError` with a clear message — Pydantic models raise their own errors so this only applies to the runtime dataclass outputs.
- Hostname match must short-circuit the subnet loop (D-09). Encode that as `if matched_hostname: break` plus a `if not matched: ...subnet...` block; do not combine into a single priority loop.
- Tag conflict resolution (D-08) belongs here, not in the rule engine. Topology wins on `topology.*` keys; record `(key, old, new)` triples in `tags_overridden` (see `RESEARCH.md` Code Examples).
- Pure function signature: `async def enrich(self, event: NormalizedEvent) -> EnrichmentResult` — no DB, no clock, no global state.
- Avoid `re.compile` on user input without a try/except that surfaces a clear `ValueError` at config load time, not at runtime. (The host/subnet compile belongs in `app/config/topology.py`; this module only consumes precompiled structures.)

---

### `app/processing/rule_engine.py` (service, transform)

**Analog:** `app/persistence/incidents.py` (load-time invariants + pure `evaluate(...)`).

**Existing pattern** (`app/persistence/incidents.py:48-83`, the `IncidentUpsertInput` dataclass with `__post_init__`):
```python
@dataclass(frozen=True, slots=True)
class IncidentUpsertInput:
    rule_name: str
    group_key: str
    ...
    def __post_init__(self) -> None:
        if not self.rule_name or not self.rule_name.strip():
            raise ValueError("rule_name must be non-empty")
        ...
```

**Patterns to apply:**
- Constructor takes preloaded `list[CompiledRule]` (regex/CIDR already compiled in the config loader). Enforce duplicate-priority rejection in the constructor or in the config loader — pick one and document it; D-13 requires strict validation.
- Sort rules by priority **once in the constructor** (`self._rules = sorted(rules, key=lambda r: r.priority)`); never re-sort per event.
- `evaluate(event)` returns a **typed** decision: `RuleDecision` (matched) or `NoOpDecision` (no match OR missing group-by field). Do not return a `None` or a bare bool.
- Group key generation (`_build_group_key`) returns `str | None`. When `None`, the engine returns a `NoOpDecision` with reason `"missing required group-by field: <name>"` (D-15). Never substitute `""`.
- Threshold decision is computed in-process: a `ThresholdDecision` instance with `counted_fingerprints: tuple[str, ...]`, `window_start`/`window_end` from `event.timestamp - window`, `threshold: int`, `crossed: bool`, and a `replay_or_skip_reasons: tuple[str, ...]` list (D-21). The set of "active" fingerprints in the window must be kept in-memory only for Phase 2; persistence is Phase 3 (A4).
- Do **not** import `app.persistence.*` here. The rule engine must not open DB sessions, and the test for that should be a static check: `inspect.getsource` test asserting no `AsyncSession` import.
- Pure function: `evaluate(event)` reads no clock; the caller passes `event.timestamp` and the rule's `window_seconds`. Tests can pass a fixed `datetime` and assert the window bounds exactly.

---

### `app/plugins/interfaces.py` (interfaces, typing only)

**Analog:** none — this is the first `Protocol` in the repo. Anchor on the project's Pydantic + `from __future__ import annotations` style.

**Patterns to apply:**
- Use `typing.Protocol` (not `abc.ABC`); the project already has `from __future__ import annotations` in every file, and Protocol with structural typing is what `RESEARCH.md` Pattern 2 calls for.
- Keep protocols minimal — one method per boundary:
  ```python
  class InputPlugin(Protocol):
      async def process_payload(self, payload: Mapping[str, Any]) -> NormalizedEvent: ...
  class TopologyEnricher(Protocol):
      async def enrich(self, event: NormalizedEvent) -> EnrichmentResult: ...
  ```
- Do not put dataclass-style diagnostics in this file; they belong in `app/processing/enrichment.py` next to their producer.
- `app/plugins/__init__.py` and `app/plugins/inputs/__init__.py` are new — leave them empty (matches `app/api/__init__.py`, `app/domain/__init__.py`, `app/config/__init__.py` convention).

---

### `app/plugins/inputs/icinga2.py` (input plugin, transform)

**Analog:** none — first input plugin. Mirror the strictness of `app/domain/events.py` for the request model and the dataclass output style of `IncidentUpsertInput` for the diagnostic object.

**Existing strict-model pattern** (`app/domain/events.py:39-67`):
```python
class NormalizedEvent(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    fingerprint: Annotated[str, Field(min_length=1)]
    source_id: Annotated[str, Field(min_length=1)]
    host: Annotated[str, Field(min_length=1)]
    service: Annotated[str, Field(min_length=1)] | None = None
    severity: Severity
    event_type: EventType
    timestamp: datetime
    tags: dict[TagKey, TagValue]
    message: Annotated[str, Field(min_length=1, max_length=4096)]
    ip_address: Annotated[str, Field(min_length=1)] | None = None

    @field_validator("timestamp", mode="after")
    @classmethod
    def require_timezone(cls, value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("timestamp must be timezone-aware")
        return value
```

**Patterns to apply:**
- Define `Icinga2WebhookPayload` (request) and `Icinga2Rejection` (output for SOFT states) as Pydantic v2 with `ConfigDict(strict=True, extra="forbid")`. Both must reject unknown fields.
- State mapping (`_ICINGA_HOST_STATES`, `_ICINGA_SERVICE_STATES`) lives at module top as plain `dict` literals — see `RESEARCH.md` Code Examples section. Do not put it inside the plugin class.
- Fingerprint computation is a free function `fingerprint_icinga_event(...)` (D-05). Test it as a pure function in isolation.
- SOFT-state handling (D-01): the plugin returns a typed `Icinga2Rejection(state_type="SOFT", ...)` rather than raising. The router decides whether to surface it as `200 OK` with `state_accepted: false` (per PITFALL 1 mitigation) or another status; the plugin does not decide HTTP semantics.
- The plugin must not import `app.config.*` or `app.persistence.*` — its only input is the validated payload dict. Any Icinga2-specific I/O (e.g., HMAC verification in a future v1.x hardening) belongs in a separate auth dependency, not here.
- The plugin's normal output is a `NormalizedEvent` (already a strict Pydantic model in `app/domain/events.py`); do not redefine its shape — call `NormalizedEvent.model_validate({...})` so all Phase 1 invariants (timezone, tag regex, severity enum) are enforced.

---

### `app/config/rules.py` (config loader, startup)

**Analog:** `app/config/settings.py` (strict Pydantic settings model with `extra="forbid"`).

**Existing pattern** (`app/config/settings.py:1-26`):
```python
from pathlib import Path
from typing import Literal

from pydantic import Field, PostgresDsn
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="CORRELIA_",
        case_sensitive=False,
        extra="forbid",
    )

    database_url: PostgresDsn = Field(validation_alias="DATABASE_URL")
    environment: Literal["local", "test", "production"] = "local"
    log_level: Literal["DEBUG", "INFO", "WARNING", "ERROR"] = "INFO"
    rules_path: Path | None = None
    topology_path: Path | None = None
    plugins_path: Path | None = None
```

**Patterns to apply:**
- Loader is **not** a `BaseSettings` subclass — it's a plain `BaseModel`. Env binding belongs to `Settings` only.
- Entry point: `load_rules_config(path: Path) -> RuleConfig` parses with `yaml.safe_load()` and then `RuleConfig.model_validate(data)`. Mirror the "parse then validate" pattern called out in `RESEARCH.md` "Don't Hand-Roll" — never use `yaml.load()`.
- All nested models use `ConfigDict(strict=True, extra="forbid")`. Use `Annotated` for min/max length, regex patterns, and CIDR validation.
- Use `model_validator(mode="after")` for cross-field invariants: duplicate priority rejection (D-13), unique rule names, at-most-one match criteria block, valid action list, placeholder syntax check.
- Compile regexes and sort rules at load time, not in the consumer (RESEARCH.md Pattern 3). Easiest: return a `CompiledRuleConfig` dataclass that contains the validated Pydantic model **plus** precompiled structures, built by a private `_compile(config: RuleConfig) -> CompiledRuleConfig` function in the same module.
- `app/config/__init__.py` is empty today; do not re-export loaders from there. Importers use `from app.config.rules import load_rules_config`.
- Settings already has `rules_path: Path | None`. The loader should take the resolved `Path` as an argument; do not reach back to `get_settings()` from inside the loader — keeps the loader testable in isolation (the `tests/conftest.py` env-isolation fixture does not need to set up a full settings object for rule-loading tests).

---

### `app/config/topology.py` (config loader, startup)

**Analog:** `app/config/rules.py` (sister loader, same conventions). Also use `app/config/settings.py` as the `extra="forbid"` and `Path | None` style anchor.

**Patterns to apply:**
- Same parse-then-validate flow as `app/config/rules.py`: `yaml.safe_load` → `TopologyConfig.model_validate(...)` → compile regexes / parse CIDRs.
- Use `ipaddress.ip_network(r.subnet)` inside a `model_validator(mode="after")` to fail at load time on bad CIDR strings; do not defer this to per-event evaluation.
- Hostname regex compilation also belongs here; `re.error` should be wrapped in a `ValueError` with a clear message naming the rule and the bad pattern.
- Reject overlapping CIDRs that assign different tags at load time (PITFALL 3) — `ipaddress.ip_network(...).overlaps(...)` is the standard library tool (`RESEARCH.md` "Don't Hand-Roll").
- File order is the hostname matching order (D-09, first match wins). Do not sort hostname rules by anything other than file order; document this in the module docstring.
- Settings already exposes `topology_path: Path | None`; use the same loader signature as `app/config/rules.py`.

---

### `tests/test_icinga2_input.py` (and other Phase 2 tests)

**Analog:** `tests/test_domain_events.py` (Pydantic + `model_validate`), `tests/test_health.py` (FastAPI ASGI test client), `tests/test_domain_incidents.py` (parametrized forbidden inputs).

**Existing Pydantic test style** (`tests/test_domain_events.py:8-33`):
```python
def valid_event_data() -> dict[str, object]:
    return {
        "fingerprint": "icinga:web-01:http",
        "source_id": "icinga2",
        "host": "web-01",
        ...
    }


def test_event_type_and_severity_contracts_are_explicit() -> None:
    assert set(EventType) == {EventType.PROBLEM, EventType.RECOVERY}
    ...
```

**Existing FastAPI test style** (`tests/test_health.py:27-47,40-54`):
```python
async def get_client(app) -> AsyncIterator[AsyncClient]:
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client


async def test_health_returns_ok_without_database_readiness() -> None:
    failure = RuntimeError("DATABASE_URL postgresql://user:password@host/token-secret")
    app = create_app(
        settings=Settings(DATABASE_URL=VALID_DATABASE_URL),
        sessionmaker=lambda: FailingSession(failure),
    )

    async for client in get_client(app):
        response = await client.get("/health")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}
```

**Existing parametrized forbidden-input style** (`tests/test_domain_incidents.py:69-99` — the `parametrize` block uses tuples):
```python
@pytest.mark.parametrize(
    ("current", "target"),
    [
        ...
    ],
)
def test_allowed_incident_transitions(current: IncidentStatus, target: IncidentStatus) -> IncidentStatus:
    assert validate_incident_transition(current, target) is target
```

**Patterns to apply:**
- One `valid_*_data()` helper per input file returning a dict that the model accepts as-is; tests then `model_validate({**valid_..., "extra": "field"})` to assert `extra="forbid"`.
- `asyncio_mode = "auto"` is configured in `pyproject.toml`; tests can use plain `async def test_*` without a decorator (mirror `tests/test_health.py`).
- Webhook tests build a payload with `valid_event_data()`-style helper, post via `AsyncClient` against `create_app(settings=..., sessionmaker=lambda: Session(), icinga2_processor=prebuilt_processor)`.
- Topology/rule YAML tests use `tmp_path` (pytest built-in) to write a minimal valid YAML, call the loader, and assert both happy and rejected paths. A "factory fixture" producing small valid YAML strings is the cleanest style.
- `tests/conftest.py` already isolates `CORRELIA_*` env vars; Phase 2 tests do not need a parallel mechanism, but loader tests should still pass an explicit `Path` to the loader to keep the env-fixture's behavior unchanged.
- No Testcontainers required for Phase 2 tests — no DB writes in the ingest path. Reserve `testcontainers` for future Phase 3 tests that will call `upsert_open_incident` (the existing `tests/test_migrations.py:1-30` shows the pattern).
- The existing `test_health.py:90-101` test `test_phase_one_does_not_expose_out_of_scope_routes` is a useful precedent: Phase 2 should add a mirror test that asserts `/webhooks/icinga2` is exposed **and** the other `/api/v1/*` or `/incidents/*` routes (deferred) are not.

---

## Shared Patterns

### Strict Pydantic v2 at Every Boundary
**Source:** `app/domain/events.py:39-67`, `app/domain/incidents.py:28-65`, `app/config/settings.py:11-19`
**Apply to:** Every new model in `app/domain/rules.py`, `app/config/rules.py`, `app/config/topology.py`, `app/plugins/inputs/icinga2.py`, and any response model in the ingress router.

```python
model_config = ConfigDict(strict=True, extra="forbid")
```

### Pydantic Field Validators for Invariants
**Source:** `app/domain/incidents.py:46-54` (`reject_secret_note_content`), `app/domain/events.py:62-67` (`require_timezone`).
**Apply to:** Timezone-aware timestamps in any new response model; secret-bearing note rejection (D-08/V8 Data Protection) in the new `DecisionContext`-style envelope types.

```python
@field_validator("timestamp", mode="after")
@classmethod
def require_timezone(cls, value: datetime) -> datetime:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("timestamp must be timezone-aware")
    return value
```

### Frozen Dataclass with `__post_init__` Validation
**Source:** `app/persistence/incidents.py:48-83` (`IncidentUpsertInput`).
**Apply to:** `EnrichmentDiagnostic`, `EnrichmentResult`, `CompiledRule`, `ThresholdDecision`. The `@dataclass(frozen=True, slots=True)` + `__post_init__` raises-`ValueError` idiom is the project's preferred shape for internal typed outputs.

### FastAPI Lifespan + `create_app(...)` Keyword Injection
**Source:** `app/main.py:7-43`.
**Apply to:** Loading rules/topology at startup. The `if not hasattr(app.state, X)` guard plus a matching keyword arg on `create_app` is the testability anchor the project already uses for `settings` and `sessionmaker`; add the same for `icinga2_processor`.

### Reuse `BoundedString` / `BoundedStringTuple` / `TagKey` / `TagValue`
**Source:** `app/domain/incidents.py:18-20`, `app/domain/events.py:23-24`.
**Apply to:** `Rule.name`, `RuleDecision.rule_name`, `RuleDecision.group_key`, any `matched_rule_names` tuple, any tag dict in rule match criteria. Do not redefine bounds.

### Settings Has Reserved `Path` Slots
**Source:** `app/config/settings.py:23-25`.
**Apply to:** `load_rules_config(settings.rules_path)` and `load_topology_config(settings.topology_path)` calls in `lifespan`. Do not add new `CORRELIA_*` env vars; consume the existing slots.

### ASGI Test Client with `ASGITransport`
**Source:** `tests/test_health.py:27-47`.
**Apply to:** `tests/test_ingress_router.py` and any end-to-end ingest test.

### Pytest `parametrize` for Forbidden-Input Coverage
**Source:** `tests/test_domain_incidents.py:43-65,69-99`, `tests/test_domain_events.py:36-58`.
**Apply to:** Icinga2 payload invalid-state tests, topology YAML overlap tests, rule YAML duplicate-priority tests. Parametrize over `("kwargs", "expected_error")` or `("current", "target")` tuples.

## No Analog Found

Files with no close in-repo analog — the planner should treat the patterns above as the only anchors and consult `RESEARCH.md` Code Examples for the rest. None of these have a direct match in the current codebase:

| File | Role | Data Flow | Why no analog |
|------|------|-----------|---------------|
| `app/processing/enrichment.py` | service | transform (pure) | First pure transform service; closest is `app/persistence/incidents.py` `_jsonb_sorted_union` helper |
| `app/processing/rule_engine.py` | service | transform (pure) | First priority-ordered matcher; closest is `IncidentUpsertInput.__post_init__` invariants |
| `app/plugins/interfaces.py` | interfaces (Protocol) | n/a | First `Protocol` usage; project uses Pydantic + dataclasses elsewhere |
| `app/plugins/inputs/icinga2.py` | input plugin | transform (pure) | First input plugin; closest is the strict-Pydantic request model pattern in `app/domain/events.py` |
| `app/config/rules.py` | config loader (YAML) | startup | First YAML loader; closest is the strict-`extra="forbid"` style of `app/config/settings.py` |
| `app/config/topology.py` | config loader (YAML) | startup | Same as `app/config/rules.py` |
| `tests/test_icinga2_input.py` | test | n/a | First plugin test; closest is `tests/test_domain_events.py` shape |
| `tests/test_topology_enrichment.py` | test | n/a | First enricher test; closest is `tests/test_domain_incidents.py` |
| `tests/test_rule_engine.py` | test | n/a | First engine test; closest is `tests/test_domain_incidents.py` |
| `tests/test_rule_topology_yaml.py` | test | n/a | First YAML loader test; closest is `tests/test_settings.py` |
| `tests/test_ingress_router.py` | test | n/a | First router test beyond health; closest is `tests/test_health.py` |

## Risks and Open Patterns

1. **No precedent for `Protocol` usage in this repo.** The first import of `typing.Protocol` will be in `app/plugins/interfaces.py`. Confirm with `mypy strict = true` (set in `pyproject.toml`) and at least one structural test (`isinstance(obj, InputPlugin)` on a duck-typed instance) before committing to Protocol over ABC.
2. **No precedent for in-process mutable state outside `app.state`.** The threshold counter is per-process and tied to a `RuleEngine` instance, not `app.state`. If the lifespan is restarted in tests (it is — `tests/test_health.py:39` uses `app.router.lifespan_context`), the engine must be re-injected; mirror the `sessionmaker=` keyword pattern.
3. **No precedent for `re.compile` of operator-supplied patterns at load time.** Pattern 3 of `RESEARCH.md` and the PITFALLS Performance Traps entry is the only guide. Add a load-time test that asserts a `re.error`-producing pattern in topology YAML is rejected with a message that includes the rule name and the bad pattern.
4. **No precedent for `yaml.safe_load` in this repo.** Pydantic v2 strict mode is the only existing validation; YAML is new. Test both: a syntactically valid YAML with semantic violations (rejected by Pydantic) and a syntactically invalid YAML (rejected by PyYAML before Pydantic).
5. **Health-router tests already assert that secret fragments are not leaked (`tests/test_health.py:80-93`).** The ingress router response body must follow the same rule: no raw Icinga2 payload, no internal error text, no env-var values. Add a parametrized test for it.
6. **`tests/conftest.py:1-16` autouse-cleanup fixture does not currently cover rules/topology paths.** Loader tests should not rely on env injection; pass `Path` arguments explicitly. If a future fixture is added, it must clear the same set of `CORRELIA_*` keys.
7. **Empty `__init__.py` files are the convention.** Do not start re-exporting from `app/processing/__init__.py`, `app/plugins/__init__.py`, or `app/plugins/inputs/__init__.py`. Importers should use full module paths (`from app.processing.rule_engine import RuleEngine`).
8. **`app/main.py:24-25` initializes resources only if `not hasattr(app.state, ...)`.** Phase 2 must follow the same guard so tests can inject prebuilt processors via `create_app(..., icinga2_processor=prebuilt)` without conflicting with the lifespan's defaults.
9. **Phase 1 `DecisionContext` is the closest thing to a "compact non-secret decision envelope"** (`app/domain/incidents.py:28-65`). The Phase 2 `IngressDecisionEnvelope` should reuse `DecisionContext` rather than redefining schema_version/notes; this keeps a single secret-rejection validator in one place.
10. **`app/persistence/incidents.py:48-83` enforces non-empty, non-whitespace strings in `__post_init__`.** Apply the same `.strip()` check to `rule.name`, `rule.group_by` keys, topology rule names, and the Icinga2 `host`/`service` values inside the plugin's strict model.

## Metadata

**Analog search scope:** `app/`, `tests/`, `migrations/`, `pyproject.toml`, `Makefile`.
**Files scanned:** 16 source files (`app/main.py`, `app/api/deps.py`, `app/api/routers/health.py`, `app/config/settings.py`, `app/domain/events.py`, `app/domain/incidents.py`, `app/persistence/database.py`, `app/persistence/models.py`, `app/persistence/incidents.py`, plus 7 test files and the migration).
**Pattern extraction date:** 2026-06-08.
