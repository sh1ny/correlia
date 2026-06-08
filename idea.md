# Technical Design Document: "Correlia" Event Aggregator (v1.2)

## 1. Project Overview
**Goal:** Build a modular, API-first event aggregation system in Python. It ingests alerts (specifically from Icinga2 for the start, but it should also be able to capture from any other alerting system ), normalizes them, enriches them with topology data, applies complex aggregation rules, manages state in PostgreSQL, and dispatches notifications via pluggable output channels.

**Core Philosophy:**
* **API-First:** No built-in frontend; all data is exposed via REST.
* **Fully Pluggable Architecture:** Inputs, Outputs, Storage, AND **Task Execution** must be modular.
* **Stateless Logic / Stateful Storage:** Logic resides in code/rules; state resides strictly in Postgres.
* **Topology Aware:** Capable of inferring location/context from hostnames or IPs.

## 2. Technology Stack
* **Language:** Python 3.13+
* **Package Manager:** `uv` (for ultra-fast dependency management and venv creation).
* **Web Framework:** FastAPI (for high-performance Async I/O).
* **Database:** PostgreSQL (using `SQLAlchemy` 2.0+ with `asyncpg` driver).
* **Schema Validation:** Pydantic V2.
* **Configuration:** PyYAML (for rules, topology, and plugin registry).
* **Task Execution:** Abstracted (Defaulting to `asyncio` for v1, extensible to Celery/Redis for v2).

## 3. Data Architecture

### 3.1 The "Normalized Event" Model
Every input (Icinga2 Webhook, API Poll) must be converted into this Pydantic model before processing:

```python
class EventType(str, Enum):
    """Semantic classification: PROBLEM (alert) or RECOVERY (resolved)."""
    PROBLEM = "PROBLEM"
    RECOVERY = "RECOVERY"

class NormalizedEvent(BaseModel):
    fingerprint: str      # Unique hash (e.g., md5(host+service+severity))
    source_id: str        # e.g., "icinga-prod-1"
    host: str
    service: Optional[str] = None
    severity: Literal["OK", "WARNING", "CRITICAL", "UNKNOWN"]
    event_type: EventType # PROBLEM or RECOVERY (see Phase 6)
    timestamp: datetime
    tags: Dict[str, str]  # e.g., {"env": "prod", "dc": "london"}
    message: str
    ip_address: Optional[str] = None # Used for topology enrichment
```

*Note:* The `event_type` field enables proper incident lifecycle management. Input plugins map their source-specific states to this plugin-agnostic classification. See Phase 6 for details.

### 3.2 Database Schema (PostgreSQL)
We need two primary tables.

**Table 1: `incidents`** (Represents the *aggregated* alert state)
* `id` (UUID, PK)
* `rule_name` (The rule that created this aggregation)
* `group_key` (The unique signature of the aggregation group, e.g., "dc:london")
* `status` (Enum: OPEN, ACKNOWLEDGED, RESOLVED, CLOSED)
* `severity` (Current max severity)
* `start_time`, `last_update_time`
* `summary` (Text)
* `event_count` (Integer)
* `affected_hosts` (JSONB list - to track unique hosts involved)

**Status Definitions:**
| Status | Description |
|--------|-------------|
| OPEN | Active incident receiving events |
| ACKNOWLEDGED | Manually acknowledged by operator |
| RESOLVED | Auto-closed by recovery event (see Phase 6) |
| CLOSED | Manually closed or expired by window timeout |

*Constraint Note:* To prevent race conditions on OPEN incidents, use a **partial unique index** on (`rule_name`, `group_key`) WHERE `status = 'OPEN'`. This allows only one open incident per rule+group combination while permitting multiple closed/resolved incidents with the same rule+group (from different time periods). Use `ON CONFLICT ... index_where` in the code.

**Table 2: `raw_events`** (Optional/Rotated)
* Logs individual events for debugging/audit.

### 3.3 Topology Enrichment Configuration (`topology.yaml`)
A set of rules to derive tags (like `datacenter` or `environment`) from Hostnames or IPs.

```yaml
topology_rules:
  # Priority 1: Hostname Pattern Matching
  hostname_patterns:
    - name: "Standard Naming Convention"
      # Regex: Capture Group 1 is the Datacenter
      regex: "^([a-z0-9]+)-prd-.*"
      target_tag: "datacenter"

  # Priority 2: IP Subnet Mapping (Fallback)
  ip_subnets:
    - cidr: "10.10.0.0/16"
      value: "prm1"
      target_tag: "datacenter"
```

---

## 4. The "Brain": Rule Engine

### 4.1 Rule Configuration (`rules.yaml`)
Includes `priority` to handle overlapping rules.

```yaml
rules:
  - name: "DC-Level Outage Aggregator"
    priority: 100            # Higher number = processed first
    match:
      severity: ["CRITICAL", "WARNING"]
      tags:
        datacenter: "*"
    window:
      duration_seconds: 300
      group_by: ["datacenter"]
      trigger_threshold: 5
    output_summary: "Major outage detected in Datacenter {datacenter}"
    actions: ["email-ops"]

  - name: "Single Host Deduplication"
    priority: 10
    match:
      host: "*"
    window:
      duration_seconds: 3600
      group_by: ["host", "service"]
      trigger_threshold: 1
    output_summary: "Alert on {host}: {service}"
    actions: ["email-ops"]
```

---

## 5. Plugin System & Task Abstraction

### 5.1 Abstract Base Classes (`app/core/interfaces.py`)

We introduce `TaskRunner` to abstract *how* code is executed (AsyncIO vs Celery).

```python
class OutputPlugin(ABC):
    @abstractmethod
    async def send_notification(self, incident: IncidentModel, config: dict):
        pass

class InputPlugin(ABC):
    @abstractmethod
    async def process_payload(self, request: Request) -> NormalizedEvent:
        pass

class TaskRunner(ABC):
    """
    Abstracts the execution strategy.
    v1: Runs purely via asyncio.create_task
    v2: Can serialize arguments and push to Redis/Celery
    """
    @abstractmethod
    async def submit(self, task_name: str, payload: dict):
        """Submit a task for execution"""
        pass
```

### 5.2 Plugin Registry (`plugins.yaml`)
We explicitly define the runner here.

```yaml
# The Execution Engine
task_runner:
  module: "app.plugins.runners.asyncio_runner"
  class: "AsyncIOTaskRunner"

# Output Channels
outputs:
  email-ops:
    module: "app.plugins.outputs.email"
    class: "EmailPlugin"
    config:
      smtp_host: "smtp.example.com"
```

---

## 6. Detailed Implementation Phases

### Phase 1: Skeleton, UV Setup & Models
**Goal:** Initialize the project environment and database ORM.

1.  **Environment Setup:**
    * Use `uv init` to create the project.
    * Add dependencies: `uv add fastapi uvicorn sqlalchemy asyncpg pydantic-settings pyyaml`.
2.  **Directory Structure:**
    * `app/api/endpoints` (Routes)
    * `app/core` (Config, Database, Interfaces)
    * `app/models` (Pydantic & SQLAlchemy models)
    * `app/plugins` (Inputs/Outputs/Runners)
3.  **Deliverables:**
    * `app/core/database.py`: Async engine setup.
    * `app/models/event.py`: The `NormalizedEvent` Pydantic model.
    * `app/models/incident.py`: The SQLAlchemy `Incident` model.
    * `docker-compose.yml`: For a local PostgreSQL instance.

### Phase 2: Ingress & Topology Enrichment
**Goal:** Accept Icinga2 alerts and enrich them with datacenter context.

1.  **Topology Logic (`app/core/enrichment.py`):**
    * Create `TopologyEnricher` class.
    * Load `topology.yaml`.
    * Implement `enrich(event)`:
        * Check for existing tags.
        * Run Regex against `event.host`.
        * Run `ipaddress.ip_network` check against `event.ip_address`.
2.  **Icinga2 Input Plugin (`app/plugins/inputs/icinga2.py`):**
    * Implement parsing logic to map Icinga2 JSON to `NormalizedEvent`.
3.  **API Endpoint (`app/api/endpoints/ingress.py`):**
    * POST `/webhook/icinga2`.
    * Flow: Receive JSON -> Parse -> Enrich -> Print to Console (stub for Phase 3).

### Phase 3: The Task Runner & Plugin Loader (Abstraction Layer)
**Goal:** Implement the abstraction layer so v2 is easy later.

1.  **Plugin Loader (`app/core/plugins.py`):**
    * Implement `load_plugin_from_config(yaml_section)`.
2.  **AsyncIO Runner (`app/plugins/runners/asyncio_runner.py`):**
    * It should maintain a registry of "Task Names" mapped to python functions.
    * `submit()` simply awaits or creates an asyncio task for the mapped function.
3.  **Registration:** Ensure the Core Engine can register a function (e.g., `process_notification`) with the Runner.

### Phase 4: Rule Engine & State Management (Concurrency Safe)
**Goal:** The Logic Engine and DB Persistence.

1.  **Rule Parser (`app/core/rules.py`):**
    * Create `RuleLoader` to parse `rules.yaml` considering `priority`.
2.  **Matching Engine:**
    * Implement `RuleEvaluator.match(event, rule)`.
3.  **Grouping Logic:**
    * Implement `generate_group_key(event, group_by_fields)`.
4.  **DB Upsert (Concurrency Critical):**
    * Implement `update_incident` using **PostgreSQL ON CONFLICT**.
    * *Instruction:* "Do not do a SELECT then INSERT. Use `dialects.postgresql.insert(...).on_conflict_do_update()` to ensure that if two events arrive at the exact same millisecond, only one incident row is created or updated."

### Phase 5: Action Dispatcher
**Goal:** Connect Incidents to Outputs via the Task Runner.

1.  **Notification Dispatcher (`app/core/notification_dispatcher.py`):**
    * Create `process_notification(payload)` async function
    * Load output plugin by name from `plugins.yaml` outputs section
    * Fetch incident from database using `incident_id`
    * Call `plugin.send_notification(incident, config)`
    * Handle errors: missing plugin, invalid incident, plugin failures
    * Exception types: `NotificationError`, `PluginNotFoundError`, `IncidentNotFoundError`

2.  **Plugin Loader Updates (`app/core/plugins.py`):**
    * Add `get_output_plugin(name)` to load and cache output plugins
    * Add `get_available_output_plugins()` to list configured plugins
    * Replace stub registration with real `process_notification`
    * Cache loaded plugins for efficiency

3.  **The Trigger (implemented in Phase 4):**
    * When threshold crossed: `task_runner.submit("notify", {...})`
    * Payload includes: `incident_id`, `plugin`, `rule_name`

4.  **Email Plugin Enhancement (`app/plugins/outputs/email.py`):**
    * Format incident details (ID, rule, status, severity, summary)
    * Include statistics (event count, affected hosts list)
    * Include timeline (start time, last update)
    * Log notification details for debugging
    * Respect configuration (smtp_host, to_addresses, subject_prefix)

5.  **Notification Flow:**
    ```
    EventProcessor → TaskRunner.submit("notify", payload)
                          ↓
                   process_notification(payload)
                          ↓
                   get_output_plugin(plugin_name)
                          ↓
                   session.get(Incident, incident_id)
                          ↓
                   plugin.send_notification(incident, config)
    ```

6.  **Tests:**
    * Unit tests for notification dispatcher (`test_notification_dispatcher.py`)
    * Unit tests for email plugin formatting (`test_email_plugin.py`)
    * Integration tests for end-to-end notification flow

### Phase 6: Incident Lifecycle Management
**Goal:** Implement proper incident lifecycle with recovery handling and window-based expiration.

#### 6.1 Event Type Classification

Events are semantically classified as either **PROBLEM** (an issue is occurring) or **RECOVERY** (an issue has resolved). This classification is plugin-agnostic, allowing different monitoring systems to map their native states to Correlia's internal types.

```python
class EventType(str, Enum):
    """Semantic classification of an event.
    
    Plugin-agnostic: each input plugin maps its source-specific
    states to these universal types.
    """
    PROBLEM = "PROBLEM"      # Alert/issue detected (WARNING, CRITICAL, UNKNOWN)
    RECOVERY = "RECOVERY"    # Issue resolved (OK state)
```

The `NormalizedEvent` model is extended with an `event_type` field:

```python
class NormalizedEvent(BaseModel):
    # ... existing fields ...
    event_type: EventType  # PROBLEM or RECOVERY
```

#### 6.2 Input Plugin Event Type Mapping

Each input plugin is responsible for mapping its source-specific states to `EventType`. A default helper is provided in the `InputPlugin` base class:

```python
class InputPlugin(ABC):
    @staticmethod
    def derive_event_type(severity: str) -> EventType:
        """Default mapping from severity to event type.
        
        Plugins can override for custom mappings.
        """
        return EventType.RECOVERY if severity == "OK" else EventType.PROBLEM
```

**Icinga2 Mapping:**
| Icinga2 State | Severity | EventType |
|---------------|----------|-----------|
| Host UP (0) | OK | RECOVERY |
| Host DOWN (1) | CRITICAL | PROBLEM |
| Service OK (0) | OK | RECOVERY |
| Service WARNING (1) | WARNING | PROBLEM |
| Service CRITICAL (2) | CRITICAL | PROBLEM |
| Service UNKNOWN (3) | UNKNOWN | PROBLEM |

**Future Plugin Example (Prometheus Alertmanager):**
| Alertmanager Status | EventType |
|---------------------|-----------|
| `firing` | PROBLEM |
| `resolved` | RECOVERY |

#### 6.3 Incident Status Extensions

The `IncidentStatus` enum is extended to distinguish how incidents were closed:

```python
class IncidentStatus(enum.Enum):
    OPEN = "OPEN"              # Active incident
    ACKNOWLEDGED = "ACKNOWLEDGED"  # Manually acknowledged
    RESOLVED = "RESOLVED"      # Auto-closed by recovery event
    CLOSED = "CLOSED"          # Manually closed or expired by timeout
```

#### 6.4 Recovery Event Handling

When a RECOVERY event is received, Correlia finds and resolves matching open incidents:

1.  **Incident Manager (`app/core/incident_manager.py`):**
    * Add `resolve_incidents_for_host_service(host, service, message)` method
    * Query OPEN incidents where `host` is in `affected_hosts`
    * For service-level recovery: also check `service` appears in `group_key`
    * Set status to `RESOLVED`, append resolution message to summary

2.  **Event Processor (`app/core/event_processor.py`):**
    * Branch processing based on `event.event_type`
    * PROBLEM events: existing flow (match rules → upsert incident → notify if threshold)
    * RECOVERY events: call `resolve_incidents_for_host_service()`

3.  **Recovery Flow:**
    ```
    RECOVERY Event (severity=OK)
           ↓
    EventProcessor._process_recovery()
           ↓
    IncidentManager.resolve_incidents_for_host_service()
           ↓
    Find OPEN incidents with host in affected_hosts
           ↓
    Set status=RESOLVED, update summary
           ↓
    (Optional) Trigger recovery notifications
    ```

4.  **Matching Logic:**
    * **Host-level recovery** (service=None): Resolves all incidents containing that host
    * **Service-level recovery** (service="http"): Only resolves incidents where `group_key` contains `service:http`

#### 6.5 Window-Based Expiration

Incidents that receive no events for longer than their rule's `window.duration_seconds` are automatically expired.

1.  **Lifecycle Module (`app/core/lifecycle.py`):**
    * Create background asyncio task that runs every N seconds
    * Query: `SELECT * FROM incidents WHERE status = 'OPEN'`
    * For each incident, look up its rule's `window.duration_seconds`
    * If `now - last_update_time > duration_seconds`: set status to `CLOSED`

2.  **Expiration Logic:**
    ```python
    async def expire_stale_incidents(session: AsyncSession) -> int:
        rule_loader = get_rule_loader()
        now = datetime.now(timezone.utc)
        
        for incident in open_incidents:
            rule = rule_loader.get_rule_by_name(incident.rule_name)
            window_duration = timedelta(seconds=rule.window.duration_seconds)
            
            if now > incident.last_update_time + window_duration:
                incident.status = IncidentStatus.CLOSED
                incident.summary += " | EXPIRED: No events received"
    ```

3.  **Application Lifecycle (`main.py`):**
    * Start expiration task in FastAPI lifespan startup
    * Cancel expiration task in lifespan shutdown
    * Configurable check interval via `settings.expiration_check_interval`

4.  **Configuration (`app/core/config.py`):**
    ```python
    class Settings(BaseSettings):
        expiration_check_interval: int = 60  # seconds
    ```

#### 6.6 Updated Processing Result

The `ProcessingResult` dataclass is extended to report closed incidents:

```python
@dataclass
class ProcessingResult:
    event: NormalizedEvent
    matched_rules: list[Rule]
    incidents: list[tuple[Incident, bool, bool]]
    notifications_triggered: int
    incidents_closed: int = 0  # NEW: count of resolved incidents
```

#### 6.7 API Response Updates

The ingress endpoint response includes event type and resolution information:

```json
{
    "status": "accepted",
    "fingerprint": "abc123...",
    "host": "lon-prd-web01",
    "service": "http",
    "severity": "OK",
    "event_type": "RECOVERY",
    "tags": {"datacenter": "lon"},
    "matched_rules": [],
    "incidents_updated": 0,
    "incidents_closed": 2,
    "notifications_triggered": 0
}
```

#### 6.8 Tests

* Unit tests for event type derivation in input plugins
* Unit tests for `resolve_incidents_for_host_service()` method
* Unit tests for recovery event processing flow
* Unit tests for expiration logic (`test_lifecycle.py`)
* Integration tests for full recovery scenarios
