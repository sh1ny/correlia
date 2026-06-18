# Phase 3: Problem Aggregation and Notification Dispatch - Pattern Map

**Mapped:** 2026-06-08
**Files analyzed:** 18 (new + modified)
**Analogs found:** 18 / 18 (every Phase 3 file has at least one role/dataflow match in the existing codebase)

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `app/processing/incident_manager.py` (NEW) | service | request-response → persistence | `app/processing/ingress.py` (`Icinga2DecisionProcessor`) | role-match (async pipeline step that calls into persistence) |
| `app/processing/notification_dispatcher.py` (NEW) | service | request-response → external (SMTP) | `app/plugins/inputs/icinga2.py` (`Icinga2InputPlugin.process_payload`) | role-match (thin async adapter) |
| `app/processing/task_runner.py` (NEW) | service | request-response → fire-and-forget | none (no async background-task seam exists) | no-analog (rely on `asyncio` stdlib patterns) |
| `app/persistence/incidents.py` (MODIFIED) | repository | CRUD | `app/persistence/incidents.py` (current `build_open_incident_upsert` / `upsert_open_incident`) | exact (extend in place) |
| `app/persistence/models.py` (MODIFIED) | model | persistence schema | `app/persistence/models.py` (current `Incident`) | exact (extend in place) |
| `app/plugins/interfaces.py` (MODIFIED) | protocol/contract | n/a | `app/plugins/interfaces.py` (current `InputPlugin` / `TopologyEnricher`) | exact (add Protocols alongside) |
| `app/plugins/loader.py` (NEW) | service | config-driven load | `app/config/rules.py` (`load_rules_config`) | role-match (yaml → pydantic → cache) |
| `app/plugins/outputs/email.py` (NEW) | plugin adapter | external (SMTP) | `app/plugins/inputs/icinga2.py` (`Icinga2InputPlugin`) | role-match (concrete plugin in `app/plugins/<inputs\|outputs>/`) |
| `app/config/plugins.py` (NEW) | config | YAML → pydantic | `app/config/rules.py` (`RuleConfig` + `load_rules_config`) | exact (clone the yaml-safe_load + model_validate + config_hash pattern) |
| `app/config/settings.py` (MODIFIED) | config | env-bound pydantic | `app/config/settings.py` (current `Settings`) | exact (add `plugins_path`, optional smtp fields) |
| `app/domain/incidents.py` (MODIFIED) | domain model | n/a | `app/domain/incidents.py` (current `DecisionContext` + `Acknowledgement`) | exact (extend `DecisionContext.notes` schema) |
| `app/domain/rules.py` (MODIFIED) | domain model | n/a | `app/domain/rules.py` (current `IngressDecisionEnvelope`, `IncidentEffectSummary`) | exact (extend envelope) |
| `app/processing/ingress.py` (MODIFIED) | service | request-response | `app/processing/ingress.py` (current `Icinga2DecisionProcessor`) | exact (wire `IncidentManager` + `TaskRunner` into envelope builder) |
| `app/api/deps.py` (MODIFIED) | middleware/dependency | request-response | `app/api/deps.py` (current `get_app_settings`, `get_sessionmaker`, `get_icinga2_processor`) | exact (add `get_task_runner`, `get_plugin_registry`) |
| `app/api/routers/ingress.py` (MODIFIED) | router | request-response | `app/api/routers/ingress.py` (current `/webhooks/icinga2`) | exact (extend handler to call manager) |
| `app/api/routers/plugins.py` (NEW) | router | request-response | `app/api/routers/health.py` (`/health`, `/readyz`) | exact (clone lightweight read-only router) |
| `app/main.py` (MODIFIED) | app factory | lifespan | `app/main.py` (current `create_app` + `lifespan`) | exact (add TaskRunner + plugin registry to state) |
| `migrations/versions/0002_add_threshold_state.py` (NEW) | migration | schema | `migrations/versions/0001_create_incidents.py` | exact (clone `op.create_table` + `op.create_index` shape) |

## Pattern Assignments

### `app/processing/incident_manager.py` (NEW — service, request-response)

**Analog:** `app/processing/ingress.py:22-100` (`Icinga2DecisionProcessor.process_payload`)

**Why this analog:** the manager is the next pipeline stage after rule evaluation. It must (1) accept typed domain inputs (`NormalizedEvent` + `RuleDecision`), (2) call a persistence operation against an `AsyncSession`, and (3) return a typed result envelope. `Icinga2DecisionProcessor` shows the exact seam shape.

**Imports pattern** (mirrors `app/processing/ingress.py:1-13`):
```python
from __future__ import annotations

from uuid import UUID
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession

from app.domain.events import NormalizedEvent
from app.domain.rules import RuleDecision
from app.persistence.incidents import IncidentUpsertInput, upsert_open_incident
```

**Constructor pattern** (mirrors `app/processing/ingress.py:22-30`):
```python
class IncidentManager:
    def __init__(
        self,
        session: AsyncSession,
        task_runner: TaskRunner,
        plugin_registry: Mapping[str, OutputPlugin],
    ) -> None:
        self._session = session
        self._task_runner = task_runner
        self._plugin_registry = plugin_registry
```

**Pipeline + return pattern** (mirrors `app/processing/ingress.py:32-101`):
```python
async def apply_problem(
    self, event: NormalizedEvent, decision: RuleDecision
) -> IncidentResult:
    input = self._build_upsert_input(event, decision)
    incident = await upsert_open_incident(self._session, input)
    await self._session.commit()  # D-02/D-21: durable BEFORE submit
    ...
    return IncidentResult(...)
```

**Dataclass result pattern** (mirrors `app/processing/enrichment.py:11-21` — `@dataclass(frozen=True, slots=True)`):
```python
@dataclass(frozen=True, slots=True)
class IncidentResult:
    incident_id: UUID
    effect: Literal["inserted", "updated"]
    threshold_crossed: bool
    notification_triggered: bool
    no_dispatch_reason: str | None = None
```

---

### `app/processing/notification_dispatcher.py` (NEW — service, request-response → external)

**Analog:** `app/plugins/inputs/icinga2.py:103-110` (`Icinga2InputPlugin.process_payload`)

**Why this analog:** the dispatcher is a thin async adapter. It receives a typed payload (a dict from `TaskRunner`), looks up an external resource (a plugin by name), invokes it, and converts exceptions into a typed result. `Icinga2InputPlugin` shows the same shape in a different direction (inbound webhook → typed event).

**Imports pattern** (mirrors `app/plugins/inputs/icinga2.py:1-9`):
```python
from __future__ import annotations

import logging
from collections.abc import Mapping
from typing import Any

logger = logging.getLogger(__name__)
```

**Async adapter pattern** (mirrors `app/plugins/inputs/icinga2.py:103-110`):
```python
class NotificationDispatcher:
    def __init__(
        self,
        session: AsyncSession,
        plugin_registry: Mapping[str, OutputPlugin],
    ) -> None:
        self._session = session
        self._plugin_registry = plugin_registry

    async def process(self, payload: Mapping[str, Any]) -> NotificationResult:
        ...
        try:
            await plugin.send_notification(...)
        except Exception as exc:
            logger.warning("notification dispatch failed: %s", type(exc).__name__)
            return NotificationResult(success=False, category="plugin_exception", message="")
        return NotificationResult(success=True, category="dispatched", message="")
```

**Failure mapping pattern:** convert every exception class to a closed `Literal` category. Mirror the strict-pydantic approach in `app/domain/incidents.py:14-21` (`_FORBIDDEN_NOTE_FRAGMENTS` style — closed allowlist, no raw strings).

---

### `app/processing/task_runner.py` (NEW — service, fire-and-forget)

**Analog:** none — no async background-task seam exists in the current codebase.

**Why no analog:** the only async work today happens inline inside FastAPI handlers. The `asyncio` stdlib is the standard, so copy from `asyncio` docs / stdlib patterns, not from a project file.

**Reference patterns (stdlib):**
- `asyncio.create_task(coro, *, name=None)` — submit work
- `asyncio.Task.add_done_callback(cb)` — exception logging
- `asyncio.gather(*tasks, return_exceptions=False)` — drain on shutdown

**Protocol shape** (mirrors `app/plugins/interfaces.py:13-19` — `Protocol` style):
```python
class TaskRunner(Protocol):
    def register(self, task_name: str, handler: Callable[..., Awaitable[Any]]) -> None: ...
    async def submit(self, task_name: str, payload: Mapping[str, Any]) -> None: ...
    async def drain(self) -> None: ...
```

**Implementation pattern** (from stdlib; no project source):
```python
class AsyncIOTaskRunner:
    def __init__(self) -> None:
        self._handlers: dict[str, Callable[..., Awaitable[Any]]] = {}
        self._tasks: set[asyncio.Task[Any]] = set()

    async def submit(self, task_name: str, payload: Mapping[str, Any]) -> None:
        handler = self._handlers.get(task_name)
        if handler is None:
            raise ValueError(f"unknown task: {task_name}")
        task = asyncio.create_task(handler(**payload))
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)
        task.add_done_callback(self._log_exception)

    @staticmethod
    def _log_exception(task: asyncio.Task[Any]) -> None:
        exc = task.exception()
        if exc is not None:
            logger.exception("task %r failed", task.get_name(), exc_info=exc)
```

---

### `app/persistence/incidents.py` (MODIFIED — repository, CRUD)

**Analog:** `app/persistence/incidents.py:18-110` (the current module — extend in place)

**Why this analog:** there is exactly one incident-repository file. Phase 3 adds columns and updates the upsert `set_` and the input dataclass; do not create a second file.

**Extend `IncidentUpsertInput` pattern** (extends `app/persistence/incidents.py:57-100`):
```python
@dataclass(frozen=True, slots=True)
class IncidentUpsertInput:
    rule_name: str
    group_key: str
    severity: Severity
    event_time: datetime
    summary: str
    affected_hosts: tuple[str, ...]
    affected_services: tuple[str, ...] = ()
    decision_context: DecisionContext | None = None
    window_state: Mapping[str, Any] = field(default_factory=dict)        # NEW
    threshold_crossed: bool = False                                        # NEW
```

**Extend the upsert `set_` pattern** (extends `app/persistence/incidents.py:141-152`):
```python
set_={
    Incident.event_count: Incident.event_count + 1,
    Incident.last_update_time: func.greatest(
        Incident.last_update_time, stmt.excluded.last_update_time
    ),
    Incident.severity: new_severity,
    Incident.summary: stmt.excluded.summary,
    Incident.affected_hosts: new_hosts,
    Incident.affected_services: new_services,
    Incident.window_state: _jsonb_window_state_merge(
        Incident.window_state, stmt.excluded.window_state
    ),
    Incident.threshold_crossed: case(
        (Incident.threshold_crossed == False, stmt.excluded.threshold_crossed),
        else_=Incident.threshold_crossed,
    ),
    Incident.updated_at: func.now(),
},
```

**Insert-path `values()` pattern** (extends `app/persistence/incidents.py:101-117`):
```python
stmt: Any = insert(Incident).values(
    id=uuid4(),
    rule_name=input.rule_name,
    group_key=input.group_key,
    status=IncidentStatus.OPEN.value,
    severity=input.severity.value,
    summary=input.summary,
    event_count=1,
    affected_hosts=list(input.affected_hosts),
    affected_services=list(input.affected_services),
    decision_context=decision_data,
    start_time=input.event_time,
    last_update_time=input.event_time,
    window_state=dict(input.window_state),     # NEW
    threshold_crossed=input.threshold_crossed,  # NEW
)
```

**RETURNING pattern** (reuse `app/persistence/incidents.py:153-156` — unchanged):
```python
.returning(*Incident.__table__.columns)
```
Detection of inserted vs updated should use `xmax` (in RETURNING) — see `tests/test_incident_repository.py` (the `test_no_select_inside_upsert` test enforces no SELECT in the repository function).

---

### `app/persistence/models.py` (MODIFIED — model, persistence schema)

**Analog:** `app/persistence/models.py:18-58` (current `Incident`)

**Why this analog:** the SQLAlchemy declarative model lives in exactly one file. Append columns to the existing `Incident` class.

**Append columns pattern** (mirrors `app/persistence/models.py:34-41` for `JSONB` columns):
```python
window_state: Mapped[dict[str, Any]] = mapped_column(
    JSONB, nullable=False, default=dict, server_default="'{}'::jsonb"
)
threshold_crossed: Mapped[bool] = mapped_column(
    nullable=False, default=False, server_default="false"
)
notified_at: Mapped[datetime | None] = mapped_column(
    DateTime(timezone=True), nullable=True
)
```

**Constants for partial unique index** (reuse `app/persistence/models.py:8-9`):
```python
OPEN_INCIDENT_UNIQUE_INDEX_NAME = "incidents_one_open_per_rule_group"
OPEN_INCIDENT_UNIQUE_PREDICATE_SQL = "status = 'OPEN'"
```
Do NOT modify these; the upsert in `incidents.py:139-150` uses them.

---

### `app/plugins/interfaces.py` (MODIFIED — protocol/contract)

**Analog:** `app/plugins/interfaces.py:13-19` (current `InputPlugin` / `TopologyEnricher`)

**Why this analog:** the file is the canonical seam for plugin contracts; phase 3 adds `OutputPlugin` and `TaskRunner` Protocols here in the same style.

**Append Protocol pattern** (mirrors `app/plugins/interfaces.py:13-19`):
```python
class OutputPlugin(Protocol):
    async def send_notification(
        self,
        incident_view: "IncidentView",
        config: Mapping[str, Any],
    ) -> None: ...
    def plugin_status(self) -> "PluginStatus": ...
```

Use `Protocol` (not `ABC`) to match the existing style.

---

### `app/plugins/loader.py` (NEW — service, config-driven load)

**Analog:** `app/config/rules.py:169-208` (`load_rules_config`)

**Why this analog:** the loader takes a YAML path, parses with `yaml.safe_load`, validates with a Pydantic config model, and returns a cached mapping keyed by name. This is exactly `load_rules_config`'s shape, just for output plugins.

**Imports pattern** (mirrors `app/config/rules.py:1-8`):
```python
from __future__ import annotations

import importlib
from pathlib import Path
from typing import Any

import yaml

from app.config.plugins import PluginRegistryConfig
```

**Trusted import pattern** (new — D-08 disallows arbitrary exec):
```python
def load_plugin_registry(path: Path) -> dict[str, OutputPlugin]:
    data = yaml.safe_load(path.read_text()) or {"outputs": []}
    config = PluginRegistryConfig.model_validate(data)
    registry: dict[str, OutputPlugin] = {}
    for entry in config.outputs:
        if not entry.module.startswith("app.plugins.outputs."):
            raise ValueError(f"plugin module must live under app.plugins.outputs: {entry.module}")
        mod = importlib.import_module(entry.module)
        cls = getattr(mod, entry.class_name)
        if not callable(getattr(cls, "send_notification", None)):
            raise ValueError(f"{entry.class_name} does not implement OutputPlugin")
        registry[entry.name] = cls(**entry.options)
    return registry
```

The allowlist prefix `app.plugins.outputs.` is the security boundary per D-08.

---

### `app/plugins/outputs/email.py` (NEW — plugin adapter, external SMTP)

**Analog:** `app/plugins/inputs/icinga2.py:103-130` (`Icinga2InputPlugin` class layout)

**Why this analog:** the file structure (class with `__init__` + one async method, returning/raising typed results) is identical. Only the direction (outbound SMTP) and the dependency (`aiosmtplib`) differ.

**Class layout pattern** (mirrors `app/plugins/inputs/icinga2.py:103-110`):
```python
class SmtpOutputPlugin:
    def __init__(
        self,
        host: str = "localhost",
        port: int = 1025,
        from_addr: str = "correlia@localhost",
    ) -> None:
        self._host = host
        self._port = port
        self._from_addr = from_addr

    async def send_notification(
        self, incident_view: IncidentView, config: Mapping[str, Any]
    ) -> None:
        msg = EmailMessage()
        msg["From"] = self._from_addr
        msg["To"] = config.get("to_addr", "ops@localhost")
        msg["Subject"] = f"[{incident_view.severity}] {incident_view.summary}"
        ...
        await aiosmtplib.send(msg, hostname=self._host, port=self._port)
```

**Plugin config kwargs (constructor parameters) come from `PluginRegistryEntry.options`** — the loader spreads them with `cls(**entry.options)`.

---

### `app/config/plugins.py` (NEW — config, YAML → pydantic)

**Analog:** `app/config/rules.py:13-37` (Pydantic config models) + `app/config/rules.py:169-208` (`load_rules_config`)

**Why this analog:** the project already has a strict pattern for YAML → pydantic → compiled/config dataclass. Mirror it exactly.

**Model pattern** (mirrors `app/config/rules.py:13-22`):
```python
class PluginRegistryEntry(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")
    name: Annotated[str, Field(min_length=1, max_length=64)]
    plugin_type: Literal["email", "webhook"]  # extend as needed
    module: Annotated[str, Field(min_length=1)]  # must start with app.plugins.outputs.
    class_name: Annotated[str, Field(min_length=1)]
    options: dict[str, Any] = Field(default_factory=dict)
```

**Top-level wrapper pattern** (mirrors `app/config/rules.py:35-40`):
```python
class PluginRegistryConfigFile(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")
    outputs: list[PluginRegistryEntry] = Field(default_factory=list)
```

**Loader function pattern** (mirrors `app/config/rules.py:169-208`):
```python
def load_plugin_registry_config(path: Path) -> tuple[PluginRegistryConfigFile, str]:
    data = yaml.safe_load(path.read_text()) or {"outputs": []}
    config = PluginRegistryConfigFile.model_validate(data)
    config_text = yaml.safe_dump(config.model_dump(mode="json"))
    config_hash = hashlib.sha256(config_text.encode()).hexdigest()
    return config, config_hash
```

`config_hash` mirrors `app/config/rules.py:199-204` — the same deterministic-hash pattern used for rule observability.

---

### `app/config/settings.py` (MODIFIED — config, env-bound pydantic)

**Analog:** `app/config/settings.py:11-21` (current `Settings`)

**Why this analog:** all env-bound settings live in this one pydantic-settings class. The `plugins_path` slot already exists (locked in Phase 1). Phase 3 needs no new required field; optional SMTP defaults can be added as `None` so the SMTP plugin reads them from its own registry entry.

**Append pattern** (no change required if `plugins_path` is already there — verify `app/config/settings.py:21`):
```python
plugins_path: Path | None = None   # already present in current Settings
```

If SMTP host/port defaults are to live in env config (rather than per-registry-entry), add them with safe bounded pydantic types. Otherwise keep SMTP config per-registry-entry and do not change `Settings`.

---

### `app/domain/incidents.py` (MODIFIED — domain model)

**Analog:** `app/domain/incidents.py:24-50` (current `DecisionContext`)

**Why this analog:** `DecisionContext.notes` is the established seam for "small debug/audit facts that ride with the incident." Phase 3 threshold/notification facts should land here (D-13) rather than in a separate table (D-04, D-18).

**Extend `notes` usage pattern** (no schema change — uses existing `dict[TagKey, TagValue] = Field(default_factory=dict, max_length=20)`):
```python
context = DecisionContext(
    schema_version=1,
    fingerprint=event.fingerprint,
    source_id=event.source_id,
    rule_name=decision.rule_name,
    group_key=decision.group_key,
    matched_rule_names=tuple(decision.matched_rules),
    event_count=incident.event_count,
    config_hash=config_hash,
    notes={
        "threshold.crossed": "true" if td.crossed else "false",
        "threshold.counted": str(td.counted),
        "threshold.window_start": td.window_start.isoformat(),
        "threshold.replay": "true" if td.replay_or_skip_reasons else "false",
        "plugin.name": plugin_name,
        "plugin.status": plugin_status_value,
        "dispatch.category": result.category,  # "dispatched", "below_threshold", ...
    },
)
```

Respect the `_FORBIDDEN_NOTE_FRAGMENTS` allowlist at `app/domain/incidents.py:14-21` — keys/values must not contain `raw_payload`, `payload`, `credential`, `password`, `token`, `secret`, `plugin_config`.

---

### `app/domain/rules.py` (MODIFIED — domain model)

**Analog:** `app/domain/rules.py:103-123` (current `IngressDecisionEnvelope`)

**Why this analog:** the envelope is the established API-response shape. Phase 3 must extend it without removing Phase 2 fields (see `tests/test_ingress_router.py` — many existing tests assert on every current field).

**Append fields pattern** (extends `app/domain/rules.py:111-122`):
```python
class IngressDecisionEnvelope(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")
    # ... existing fields ...
    incident_id: BoundedString | None = None
    incident_effects: IncidentEffectSummary  # existing
    threshold_crossed: bool = False
    notification_triggered: bool = False
    notification_results: list[NotificationResult] = Field(default_factory=list)
    notification_count: int = Field(default=0, ge=0)  # existing, now REAL count
    notification_failed: int = Field(default=0, ge=0)
    no_dispatch_reason: str | None = Field(default=None, max_length=64)
    closure_count: int = Field(default=0, ge=0)  # existing, still 0 in v1
```

**New typed model** (mirrors `app/domain/incidents.py:14-21` — closed category literals + bounded string):
```python
class NotificationResult(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")
    success: bool
    category: Literal[
        "dispatched",
        "below_threshold",
        "already_notified",
        "replay",
        "missing_plugin",
        "missing_incident",
        "plugin_exception",
        "dispatch_failed",
    ]
    message: BoundedString = ""
    plugin_name: BoundedString | None = None
```

---

### `app/processing/ingress.py` (MODIFIED — service)

**Analog:** `app/processing/ingress.py:18-130` (current module)

**Why this analog:** the file is the only ingress processor. Phase 3 adds the `IncidentManager` + `TaskRunner` to the same class.

**Constructor change** (extends `app/processing/ingress.py:22-30`):
```python
class Icinga2DecisionProcessor:
    def __init__(
        self,
        plugin: InputPlugin,
        topology_enricher: TopologyEnricher | None = None,
        rule_engine: RuleEngine | None = None,
        incident_manager: IncidentManager | None = None,   # NEW
        task_runner: TaskRunner | None = None,             # NEW
    ) -> None:
        ...
```

**`process_payload` extension** (extends `app/processing/ingress.py:32-101`): after collecting `RuleDecision`, hand off to the manager:
```python
if isinstance(decision, RuleDecision):
    ...
    if self._incident_manager is not None:
        result = await self._incident_manager.apply_problem(event, decision)
        incident_effects = IncidentEffectSummary(
            inserted=1 if result.effect == "inserted" else 0,
            updated=1 if result.effect == "updated" else 0,
        )
        threshold_crossed = result.threshold_crossed
        notification_triggered = result.notification_triggered
        notification_results = result.notification_results
        no_dispatch_reason = result.no_dispatch_reason
```

The `build_icinga2_processor` factory at `app/processing/ingress.py:105-129` must be extended to wire `IncidentManager` and `TaskRunner` the same way it wires `topology_enricher` and `rule_engine` today (lazy imports inside the factory function).

**Dependency rule (preserved from existing test):** `app/processing/ingress.py` MUST NOT import from `app.persistence`. The test at `tests/test_ingress_router.py` `test_processing_ingress_does_not_import_persistence` enforces this. The `IncidentManager` (which lives in `app/processing/`) is the one that touches `app.persistence.incidents`. The `IncidentManager` does not need to import `app.persistence.models` either; it talks to the repository function only.

---

### `app/api/deps.py` (MODIFIED — middleware/dependency)

**Analog:** `app/api/deps.py:1-17` (current module — `get_app_settings`, `get_sessionmaker`, `get_icinga2_processor`)

**Why this analog:** the file is the canonical FastAPI dependency seam; the existing three `get_*` functions show the exact `cast(..., request.app.state.X)` pattern.

**Append dependency pattern** (mirrors `app/api/deps.py:5-17`):
```python
def get_task_runner(request: Request) -> TaskRunner:
    return cast(TaskRunner, request.app.state.task_runner)

def get_plugin_registry(request: Request) -> Mapping[str, OutputPlugin]:
    return cast(Mapping[str, OutputPlugin], request.app.state.plugin_registry)
```

**Do NOT add:** a `get_incident_manager` dependency. The manager is created per-request by the ingress processor (it owns a session). The FastAPI `get_sessionmaker` dependency is what the manager needs.

---

### `app/api/routers/ingress.py` (MODIFIED — router)

**Analog:** `app/api/routers/ingress.py:11-30` (current module)

**Why this analog:** there is exactly one ingress router. The current shape (`processor: Annotated[..., Depends(...)]` + `try/except → HTTPException(500)`) must be preserved.

**Extend the handler** (extends `app/api/routers/ingress.py:15-29`):
```python
@router.post("/webhooks/icinga2")
async def ingest_icinga2(
    processor: Annotated[Icinga2DecisionProcessor, Depends(get_icinga2_processor)],
    payload: Icinga2WebhookPayload = Body(...),
) -> IngressDecisionEnvelope:
    try:
        return await processor.process_payload(payload)
    except Exception as exc:
        logger.exception("icinga2 ingest failed")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="ingest failed",
        ) from exc
```

The processor now does the manager + dispatch internally; the router stays nearly identical.

---

### `app/api/routers/plugins.py` (NEW — router)

**Analog:** `app/api/routers/health.py:7-40` (lightweight read-only router)

**Why this analog:** the health router shows the minimal FastAPI router pattern (no auth, no DB session, returns a dict) that fits the plugin-status endpoint shape.

**File shape pattern** (mirrors `app/api/routers/health.py:1-7`):
```python
from typing import Annotated

from fastapi import APIRouter, Depends

from app.api.deps import get_plugin_registry

router = APIRouter()


@router.get("/plugins")
async def list_plugins(
    registry: Annotated[Mapping[str, OutputPlugin], Depends(get_plugin_registry)],
) -> dict[str, object]:
    return {
        "plugins": [
            {"name": name, "status": plugin.plugin_status()}
            for name, plugin in registry.items()
        ],
    }
```

---

### `app/main.py` (MODIFIED — app factory, lifespan)

**Analog:** `app/main.py:7-56` (current module)

**Why this analog:** `lifespan` and `create_app` already wire `settings` → `sessionmaker` → `icinga2_processor` into `app.state`. Phase 3 adds the same wiring for `task_runner` and `plugin_registry`.

**Extend `lifespan` pattern** (extends `app/main.py:10-35`):
```python
if not hasattr(app.state, "task_runner"):
    app.state.task_runner = AsyncIOTaskRunner()
if not hasattr(app.state, "plugin_registry"):
    plugins_path = getattr(app.state.settings, "plugins_path", None)
    app.state.plugin_registry = (
        load_plugin_registry(plugins_path) if plugins_path is not None else {}
    )

try:
    yield
finally:
    runner = getattr(app.state, "task_runner", None)
    if runner is not None:
        await runner.drain()    # graceful shutdown
    engine = getattr(app.state, "engine", None)
    if engine is not None:
        await engine.dispose()
```

**Extend `create_app` pattern** (extends `app/main.py:38-56`):
```python
def create_app(
    settings: Settings | None = None,
    sessionmaker: async_sessionmaker[AsyncSession] | None = None,
    icinga2_processor: Icinga2DecisionProcessor | None = None,
    task_runner: TaskRunner | None = None,
    plugin_registry: Mapping[str, OutputPlugin] | None = None,
) -> FastAPI:
    app = FastAPI(lifespan=lifespan)
    ...
    if task_runner is not None:
        app.state.task_runner = task_runner
    if plugin_registry is not None:
        app.state.plugin_registry = plugin_registry
    app.include_router(health_router)
    app.include_router(ingress_router)
    app.include_router(plugins_router)   # NEW
    return app
```

Test override path must remain — see `tests/test_health.py:36-43` and `tests/test_ingress_router.py` `get_client` fixture for the existing override pattern; Phase 3 must add `task_runner` / `plugin_registry` overrides to test fixtures too.

---

### `migrations/versions/0002_add_threshold_state.py` (NEW — migration, schema)

**Analog:** `migrations/versions/0001_create_incidents.py:21-79` (current migration)

**Why this analog:** Alembic migration files in this repo use a single `upgrade()` + `downgrade()` shape, `op.create_table` / `op.create_index`, and import `from sqlalchemy.dialects import postgresql`. The new migration follows the same skeleton.

**File structure pattern** (mirrors `migrations/versions/0001_create_incidents.py:1-19`):
```python
"""add threshold state to incidents

Revision ID: 0002_add_threshold_state
Revises: 0001_create_incidents
Create Date: 2026-06-08 00:00:00.000000
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision: str = "0002_add_threshold_state"
down_revision: Union[str, Sequence[str], None] = "0001_create_incidents"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "incidents",
        sa.Column(
            "window_state",
            postgresql.JSONB(),
            nullable=False,
            server_default=sa.text("'{}'::jsonb"),
        ),
    )
    op.add_column(
        "incidents",
        sa.Column(
            "threshold_crossed",
            sa.Boolean(),
            nullable=False,
            server_default=sa.text("false"),
        ),
    )
    op.add_column(
        "incidents",
        sa.Column("notified_at", sa.DateTime(timezone=True), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("incidents", "notified_at")
    op.drop_column("incidents", "threshold_crossed")
    op.drop_column("incidents", "window_state")
```

The partial unique index `incidents_one_open_per_rule_group` from migration 0001 must NOT be touched.

---

## Shared Patterns

### Strict pydantic models with `extra="forbid"` and bounded strings

**Source:** `app/domain/incidents.py:24-50`, `app/domain/rules.py:103-123`, `app/config/rules.py:13-40`
**Apply to:** `app/domain/incidents.py` (extend `DecisionContext.notes` usage), `app/domain/rules.py` (new `NotificationResult` model), `app/config/plugins.py` (registry models), `app/persistence/incidents.py` (`IncidentUpsertInput`)

```python
class NotificationResult(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")
    success: bool
    category: Literal["dispatched", "missing_plugin", ...]
    message: Annotated[str, Field(min_length=0, max_length=256)] = ""
```

Use `BoundedString` (defined in `app/domain/rules.py:9` and `app/domain/incidents.py:11`) for any user-facing string.

### Atomic PostgreSQL upsert with partial unique index

**Source:** `app/persistence/incidents.py:101-156` (`build_open_incident_upsert`)
**Apply to:** the same file — extend the existing `set_` dict and the `values()` dict.

Always use `index_where=text(f"status = '{IncidentStatus.OPEN.value}'")` from `app/persistence/models.py:9`. Never SELECT-then-INSERT (enforced by `tests/test_incident_repository.py` `test_no_select_inside_upsert`).

### Closed-allowlist note validation (no raw payloads / secrets)

**Source:** `app/domain/incidents.py:14-21` (`_FORBIDDEN_NOTE_FRAGMENTS`)
**Apply to:** any code that writes into `DecisionContext.notes` or any other JSONB debug field.

```python
_FORBIDDEN_NOTE_FRAGMENTS = (
    "raw_payload", "payload", "credential",
    "password", "token", "secret", "plugin_config",
)
```

The same allowlist must gate the `options` dict in `PluginRegistryEntry` if it ever lands in a note (D-14). Currently SMTP options are not stored in `decision_context`; do not start.

### `asyncio.create_task` + `add_done_callback` for fire-and-forget

**Source:** `asyncio` stdlib (no project source — see `app/processing/task_runner.py` assignment)
**Apply to:** `AsyncIOTaskRunner.submit()` only.

```python
task = asyncio.create_task(handler(**payload), name=f"{task_name}-{uuid4().hex[:8]}")
self._tasks.add(task)
task.add_done_callback(self._tasks.discard)
task.add_done_callback(self._log_exception)
```

`add_done_callback` is mandatory — `asyncio.create_task` exceptions are never retrieved otherwise (Pitfall 3).

### yaml.safe_load → pydantic model_validate → deterministic config hash

**Source:** `app/config/rules.py:169-208` (`load_rules_config`)
**Apply to:** `app/config/plugins.py` (`load_plugin_registry_config`).

```python
data = yaml.safe_load(path.read_text()) or {"outputs": []}
config = PluginRegistryConfigFile.model_validate(data)
config_text = yaml.safe_dump(config.model_dump(mode="json"))
config_hash = hashlib.sha256(config_text.encode()).hexdigest()
```

Never use `yaml.load` (unsafe), `eval`, `exec`, or `__import__` on YAML values.

### FastAPI dependency-injection via `app.state`

**Source:** `app/api/deps.py:5-17`, `app/main.py:10-35`
**Apply to:** `app/api/deps.py` (add `get_task_runner`, `get_plugin_registry`); `app/main.py` (wire into lifespan + `create_app` overrides).

```python
def get_task_runner(request: Request) -> TaskRunner:
    return cast(TaskRunner, request.app.state.task_runner)
```

Tests override via `app.state.X = ...` in `create_app(..., task_runner=...)` — see `tests/test_health.py:36-43`.

### Dataclass results with `frozen=True, slots=True`

**Source:** `app/persistence/incidents.py:57-100` (`IncidentUpsertInput`), `app/processing/enrichment.py:11-21` (`EnrichmentResult`, `EnrichmentDiagnostic`)
**Apply to:** `IncidentResult` (new), `PluginStatus` (new), `NotificationResult` (pydantic version, see above).

```python
@dataclass(frozen=True, slots=True)
class IncidentResult:
    incident_id: UUID
    effect: Literal["inserted", "updated"]
    threshold_crossed: bool
    notification_triggered: bool
    no_dispatch_reason: str | None = None
```

Use `@dataclass` for internal results, Pydantic `BaseModel` for anything crossing the API boundary.

### Logging via `logging.getLogger(__name__)` and `logger.exception`

**Source:** `app/api/routers/ingress.py:8,24` (`logger = logging.getLogger(__name__)`)
**Apply to:** all new modules.

```python
import logging
logger = logging.getLogger(__name__)
...
logger.exception("ingest failed")  # includes stack trace at ERROR level
```

Never use `print`; never include `str(exc)` in API response bodies (D-15).

### Strict ordering: upsert → commit → submit task

**Source:** `.planning/phases/03-problem-aggregation-and-notification-dispatch/03-CONTEXT.md` D-02, D-21
**Apply to:** `app/processing/incident_manager.py` (`apply_problem`).

```python
incident = await upsert_open_incident(self._session, input)
await self._session.commit()  # durable boundary FIRST
if first_crossing:
    await self._task_runner.submit("notify", payload)  # only after commit
```

Never submit work inside an uncommitted transaction (Pitfall 2).

---

## No Analog Found

Files where the new code introduces a capability with no existing seam. The planner should rely on stdlib/external library patterns documented in `03-RESEARCH.md`, not on local code.

| File | Role | Data Flow | Reason |
|------|------|-----------|--------|
| `app/processing/task_runner.py` | service | fire-and-forget | No async background-task seam exists today; use `asyncio` stdlib (Pattern 3 in RESEARCH). |

All other Phase 3 files have at least a role-match analog in the existing codebase.

---

## Metadata

**Analog search scope:** `app/`, `migrations/`, `tests/`
**Files scanned:** 28 source files + 8 test files (all files referenced in the workspace tree)
**Pattern extraction date:** 2026-06-08
**Key conventions identified:**
- Strict pydantic v2 with `extra="forbid"`, `ConfigDict(strict=True)`, bounded string types, closed-allowlist validators
- Pydantic v2 `model_dump(mode="json")` is the standard way to serialize domain models into `decision_context` JSONB
- SQLAlchemy 2.0 `insert(...).on_conflict_do_update(...)` with `index_where` for partial unique index; RETURNING is mandatory
- `@dataclass(frozen=True, slots=True)` for internal results, `BaseModel` for API/domain boundaries
- FastAPI dependency injection via `app.state` with `cast(...)` and `Depends(get_*)` helpers
- yaml.safe_load + Pydantic model_validate + SHA-256 config hash (reused for plugin registry)
- `logger = logging.getLogger(__name__)` + `logger.exception(...)` for error visibility
- `tests/` enforce source-level invariants (e.g., `test_processing_ingress_does_not_import_persistence`) — any new code that violates layering will fail these tests
