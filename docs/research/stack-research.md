# Correlia: Dart full-stack options (researched 2026-11-03)

Status: research. Context: a new product, an event/alert aggregator. It ingests webhooks from Icinga2 and
Alertmanager/Thanos, correlates them into incidents, and offers a realtime UI, a REST/webhook API and RBAC.
Target databases: Postgres in prod, SQLite for local dev. One Dart/Flutter developer.

Sources: ctx7 (`/websites/serverpod_dev`, `/schultek/jaspr`), docs.serverpod.dev (4.1 docs), pub.dev
changelogs, docs.flutter.dev/ai, github.com/dart-lang/ai, Google Open Source blog. Claims marked
*(unverified)* come from general knowledge and were not confirmed against a source today.

---

## TL;DR

- **Serverpod 4.1.0** is the current release (pub.dev, published ~2026-11-01). The 4.0 line (~mid-Sept 2026,
  date unconfirmed) was a big overhaul. It added an SQLite dialect, embedded PostgreSQL (no Docker),
  `serverpod start` with hot reload, a built-in MCP server and agent skills, recurring future calls, and
  `dart test` support via `withServerpod`.
- **Blocker for "SQLite in dev, Postgres in prod": the docs require every run mode to use the same database
  backend.** Server-side SQLite exists (`database: filePath: server.db`), but you can't mix backends across
  run modes. Use **embedded Postgres for dev and tests** instead. It's zero-setup with no Docker, which is what
  SQLite-for-dev was meant to buy.
- **Webhooks work:** a custom Relic `Route` at `/hooks/alertmanager/:source` can accept arbitrary JSON.
- **Jaspr 0.23.5** is stable, with 0.24.0-beta.0 in prerelease and no 1.0 yet. It's production-proven: Google
  rebuilt dart.dev, flutter.dev and docs.flutter.dev on it. However, **`jaspr_serverpod` is pinned to
  `serverpod <3.0.0`**, including the 0.7.0-beta.0 published ~2026-10-22, so it doesn't work with Serverpod 4.
  Jaspr + Serverpod 4 today means a Jaspr **client-mode** SPA served as static files that talks to the
  generated `serverpod_client`.
- **Verdict: Flutter web for the console.** Mitigate its web weaknesses: no browser find-in-page, text
  selection is opt-in, accessibility semantics need forcing, and the initial download is heavy. Consider Jaspr
  later for a public status page or shareable incident pages.
- **Testing needs no Docker and no Testcontainers.** Set `dataPath` in `config/test.yaml` and `withServerpod`
  boots an embedded Postgres. See also `testcontainers-dart.md` in this folder.
- **Agent tooling is first-class:**
  - `dart mcp-server` is official.
  - The `flutter/agent-plugins` plugin (formerly `flutter/skills`) installs with
    `claude plugin install dart-flutter@dart-flutter` and the Codex equivalent.
  - `dart-lang/skills` exists.
  - Serverpod ships `serverpod mcp-server` plus skills via `dart install skills && skills get --ide claude`.
  - Jaspr has `jaspr install-skills`.

---

## 1. Serverpod (latest: 4.1.0)

### Versions and timeline

| Version | Notes |
|---|---|
| 3.0.0 | Web server rebuilt on **Relic**. 3.3.0 moved to Relic 1.0.0. 3.3 scaffold introduced the Dart workspace. |
| 4.0.0 | SQLite dialect and client-side databases (`database:` keyword on tables: `client`, `all`, `sync` (experimental, `serverpod_offline_sync`)). Embedded PostgreSQL binaries (with pgvector and PostGIS). `serverpod start` unified TUI with hot reload. MCP server, skills and agent instructions generated at create. Full test isolation and `dart test` via `withServerpod`. At-least-once future calls plus `callRecurring` (interval or cron). Auth: account merging, `ServerpodCloudEmailIdpConfig` default email IdP, OAuth2 PKCE web sign-in. Insights query optimisations. Web server health endpoint. Requires **Flutter 3.44.4 / Dart 3.12.2** and **Postgres 16+**. |
| 4.0.3 | Option to opt out of the ephemeral test DB. `futureCall.executionEnabled` / `futureCall.enabled` flags. |
| 4.0.4 | `serverpod clean`. The generated agent file switched from CLAUDE.md to **AGENTS.md**. |
| **4.1.0** | SQLite 1.1x-55x faster. `Model.db.watch` (reactive client ORM). Passwordless **email OTP** is the default for new projects. **`serverpod runner`** runs several worktrees concurrently, which is relevant for Orca worktrees. `serverpod doctor`. `tail_runner_logs` MCP tool. FVM and other SDK sources supported. Depends on `relic ^2.0.0-rc.1` and `dart_mcp`. |

pub.dev: https://pub.dev/packages/serverpod (746 likes, 107k downloads, verified publisher serverpod.dev).
Changelog: https://pub.dev/packages/serverpod_cli/changelog

### ORM, migrations, databases

- **Models:** `*.spy.yaml` files with `table:`, relations and indexes. The ORM is type-safe
  (`Model.db.find/insertRow/...`), with transactions and row locking.
- **Migrations:** run `serverpod create-migration [--tag ..] [--force]`. Files live in `<project>_server/migrations/`.
  Apply them with `--apply-migrations` or the `M` key in `serverpod start`. Repair migrations come from `P` or
  `create_repair_migration`.
- **Postgres:** production needs an external **Postgres 16+**. Dev and test use **embedded Postgres** when
  `dataPath` is set (e.g. `.serverpod/development/pgdata`):
  - It downloads binaries once into a per-user cache.
  - Platforms: Linux and macOS (x64 and arm64), Windows x64.
  - It connects over a Unix socket. Use `serverpod database start` to expose TCP for psql or pgAdmin.
  - It's not for production: no backups, replication or supervision.
  - Docker Compose is still an alternative (`ghcr.io/serverpod/postgres:16`). `serverpod start` auto-starts it
    when the config points at localhost and has no `dataPath`.
- **SQLite (since 4.0.0):**
  - **Client side:** devices get SQLite through the `database: client|all|sync` table keyword. Flutter web runs
    it as WASM in a worker and needs `sqlite3.wasm` and `db_worker.js` in `web/`.
  - **Server side:** set `database: filePath: server.db` (API class `SqliteDatabaseConfig`). Docs:
    https://docs.serverpod.dev/concepts/server-fundamentals/configuration
  - **Hard rule:** "All run modes must use the same backend." So SQLite-dev/Postgres-prod is not supported.
- **SQLite limitations vs Postgres** (https://docs.serverpod.dev/concepts/data-and-the-database/models/field-types):
  - **Writes:** one writer at a time. `maxConnectionCount` only limits concurrent readers.
  - **Transactions:** isolation levels are ignored (always serialized), and row locks are no-ops.
  - **Type mappings:**
    - `bool` is stored as INTEGER.
    - `DateTime` is stored as epoch ms.
    - UUIDs are stored as a 16-byte BLOB.
    - `json` is stored as TEXT.
    - `jsonb` is stored as a BLOB via `jsonb()`.
  - **Search and serial:** `like` and `ilike` are both case-insensitive for ASCII. `serial` works only on `id`.
  - **Indexes and extensions:** non-btree indexes are omitted with a warning, and there are no vector or
    spatial operators.
  - **Logs:** **no persistent session logs**, so Insights log viewing is limited. You must set
    `persistentEnabled: false`.
- **Implication for Correlia:** run Postgres everywhere: embedded Postgres in dev and test, managed or
  self-hosted in prod. Correlation queries will want Postgres features anyway: `jsonb` labels with GIN
  indexes, `ilike` semantics, row locking for incident merges, and concurrent ingest writers. Keep SQLite in
  mind only for a hypothetical tiny single-node edition. That would be a separate build/config, not a dev
  convenience.

### Realtime (streaming, websockets)

- Endpoint methods that return or accept `Stream<T>` are streamed over **one shared WebSocket** per client.
- The server pings every 30 s (`SERVERPOD_WEBSOCKET_PING_INTERVAL`).
- Auth is checked when a stream opens, and a stream closes if auth is revoked.
- When the socket drops, all streams close. The client has to resubscribe, so write a reconnect/backfill layer
  (e.g. "events since cursor").
- **Server events:** `session.messages.postMessage(channel, msg)` plus a streaming method that listens on a
  filtered channel (e.g. `incidents:<teamId>`). Delivery across instances **requires Redis**.
- Docs: https://docs.serverpod.dev/concepts/endpoints-and-apis/streaming and `/server-events`

### Future calls and scheduling

- Calls are DB-persisted, survive restarts and are shared across instances. Each due call is claimed by one
  instance.
- Execution is **at least once**, so make handlers idempotent. Failures are logged, not retried, but recurring
  calls always reschedule.
- You can run a call after a delay, at a time, or with `callRecurring` (fixed interval or cron).
- Calls run on `monolith` or `maintenance` server roles. With a `serverless` role, run a `maintenance` process
  from cron.
- Good fit for escalation timers, flap windows, auto-resolve, re-notify and retention jobs.
- Docs: https://docs.serverpod.dev/concepts/scheduling/overview

### Auth (`serverpod_auth_idp_*`; legacy `serverpod_auth` still works)

- **Built-in IdPs:**
  - email (passwordless OTP default since 4.1; password flows also exist)
  - Google, Apple, GitHub, Microsoft
  - passkey
  - Facebook and Firebase (via extra packages)
- **No generic OIDC provider is documented.** For Keycloak, Authentik or another OIDC IdP, write a
  **custom IdP**:
  - Server side: an `IdentityProvider`, an `IdentityProviderBuilder` config, an endpoint extending
    `IdpBaseEndpoint`, and an account model.
  - Client side: a controller.
  - Serverpod's OAuth2 utilities handle PKCE and token exchange.
  - Microsoft covers Entra ID.
- **Token managers:**
  - **JWT:** HS512, HS256 or ES512. Short access tokens plus rotating hashed refresh tokens (pepper). On web,
    the refresh token lives in an httpOnly cookie. Custom claims via `extraClaimsProvider`, and
    `revokeToken`.
  - **Server-side sessions:** the DB-backed alternative.
- **RBAC:** endpoint `requiredScopes` with app-defined `Scope` subclasses. Logic is **AND-only, flat, with no
  hierarchy**. Good enough for coarse roles (admin, operator, viewer). Per-team or per-service permissions
  (who can ack which incidents) need your own model and checks.
- **Machine auth for webhook senders: not built in.** Implement your own:
  - Store per-integration tokens (or HMAC secrets) in your DB and check them in the webhook Route or
    middleware.
  - Alertmanager's `webhook_config` supports `http_config` bearer/basic auth.
  - Icinga2 notification commands are just curl/scripts, so they can carry a header.
- Docs: https://docs.serverpod.dev/concepts/authentication/token-managers/jwt-token-manager ,
  `/providers/custom-providers/overview`

### Caching and Redis

- `session.caches.local`, `localPrio` and `query` are in-memory, with 10k entries and FIFO eviction.
- `session.caches.global` uses Redis. **Without Redis it silently falls back to a per-process cache, and the
  readiness probe still passes.**
- Redis is optional and disabled by default (`redis: enabled: false`). It's needed for multi-instance
  messaging and the global cache. Serverpod Cloud has **no managed Redis**.
- Docs: https://docs.serverpod.dev/concepts/endpoints-and-apis/caching

### Web server (Relic) and raw HTTP routes: yes, arbitrary JSON webhooks at custom paths

```dart
class AlertmanagerHook extends Route {
  AlertmanagerHook() : super(methods: {Method.post});
  @override
  Future<Result> handleCall(Session session, Request request) async {
    final payload = jsonDecode(await request.readAsString()); // body readable once
    // path param :source via request.pathParameters ...
    return Response.ok(body: Body.fromString('{"ok":true}', mimeType: MimeType.json));
  }
}
pod.webServer.addRoute(AlertmanagerHook(), '/hooks/alertmanager/:source');
```

- **Path parameters:** `:param` segments, with typed accessors like `IntPathParam(#id)`. Requests with the wrong
  method get an automatic 405. Duplicate method+path registrations throw at startup.
- **Bodies:** stream large ones with `request.read()`. Add middleware for webhook auth.
- **Route types:** `FlutterRoute`, `SpaRoute`, static, and `WidgetRoute` (server HTML).
- **Ports:** the web server is a separate listener (**8082**) from the RPC API (**8080**) and Insights
  (**8081**). Expose webhooks on 8082 behind the load balancer, or path-route them.
- **Size limit:** check `maxRequestSize` (default 512 KiB), since large Alertmanager group payloads could hit
  it.
- Docs: https://docs.serverpod.dev/concepts/web-server/routing , `/request-data`

### File uploads

- **Flow:** the server creates an upload description, the client uploads directly to storage, then the server
  verifies the upload.
- **Storage:** defaults to DB storage (`public`/`private`), which is for dev. For prod, use S3, GCS, R2,
  S3-compatible storage or Serverpod Cloud storage.
- **Limits:** DB storage is capped by `maxRequestSize` (512 KiB) and `maxFileSize` (10 MiB).
- **Gaps:** there's no progress reporting.
- Probably irrelevant for Correlia, apart from attachments or runbooks.

### Logging, health, Insights

- **Session logs:** console and/or persistent (DB). Persistent logs are not available on SQLite.
- **Health probes:** `/livez`, `/readyz` (DB, Redis and custom `HealthIndicator`s) and `/startupz` on port
  8080. Health metrics (CPU, memory, DB latency) are recorded every minute on monolith/maintenance roles, but
  not on Windows.
- **Insights:** a desktop app for **Mac and Windows only** (Linux "coming soon") that reads logs and metrics
  via the Insights server on 8081. Its version must match the Serverpod version.
- Docs: https://docs.serverpod.dev/concepts/operations/health-checks , https://docs.serverpod.dev/tools/insights

### Testing

See section 4.

### Deployment

- **Docker:** `docker build -f <project>_server/Dockerfile .`, built from the **workspace root**.
  - 4.0 replaced `dart compile exe` with **`dart build cli`**, using the `dart:3.12.2+` base image.
  - Environment variables: `runmode`, `serverid`, `logging` and `role` (`monolith|serverless|maintenance`).
  - Put it behind a TLS load balancer.
  - 4.0 GitHub Actions templates: `analyze.yml`, `format.yml`, `tests.yml`.
- **Serverpod Cloud:** deploy with `serverpod cloud launch`. It includes:
  - managed Postgres (optional), backups and auto-migrations
  - storage, secrets, custom domains with TLS, Flutter web hosting, logs, and CI deploys
  - **no managed Redis**
  - pricing advertised only as "predictable", with no numbers found
  - Docs: https://docs.serverpod.dev/cloud
- **Self-host fit:** an ops tool for internal monitoring will likely be self-hosted on-prem next to
  Icinga/Thanos, so plan on Docker plus a site Postgres.

### CLI install and mise

- `dart install serverpod_cli` (the old `dart pub global activate` path is deprecated; deactivate it first).
  Verify with `serverpod version` or `serverpod doctor` (4.1).
- **Requires Flutter >= 3.44.4 (Dart 3.12.2).**
- **mise:** Serverpod docs don't mention it. 4.1 "adds support for FVM and other Flutter/Dart installation
  sources". So pin Flutter with mise or FVM, then `dart install serverpod_cli`. *(The exact mise plugin for
  Flutter wasn't verified today.)*
- **Key commands:**
  - `serverpod create <name>` uses the `fullstack|server|module` templates, plus
    `--[no-]database --[no-]redis --[no-]auth --[no-]webapp --[no-]website --ide claude,codex,... --no-interactive`.
    There's **no `--sqlite` create flag**: configure SQLite by hand.
  - `serverpod start` is the TUI: R restarts, M migrates, P repairs.
  - `serverpod runner start` runs in the background, `serverpod generate` generates code, and
    `serverpod database start` exposes the embedded DB.

### Generated project layout (fullstack template)

```
correlia/                      # Dart workspace root (pubspec.yaml with workspace:)
  AGENTS.md, .mcp.json, .codex/config.toml ...   # per --ide selection
  correlia_server/
    bin/main.dart  lib/server.dart  lib/src/**/*.spy.yaml  lib/src/endpoints/...
    config/{development,test,staging,production}.yaml  config/passwords.yaml  config/generator.yaml
    migrations/   web/app/ (Flutter web build output)   test/integration/test_tools/
    Dockerfile  docker-compose.yaml (if Docker alternative)  .serverpod/ (embedded pg data, gitignored)
  correlia_client/             # generated, pure Dart client (works on VM, Flutter, and plain web)
  correlia_flutter/            # Flutter app
```

### Flutter web support

- `serverpod run flutter_build` writes the app to `<server>/web/app`, and `FlutterRoute` serves it at `/`.
  - It falls back to `index.html` for deep links.
  - Its default `Cache-Control: no-cache, private` can be swapped for `CacheBustingConfig`.
  - Use `--base-href /app/` to serve it under a sub-path.
- **WASM:** build with `flutter build web --wasm` and set `enableWasmHeaders: true` to get COOP/COEP headers.
  Generated projects leave it false because those headers block cross-origin resources. The build falls back
  to JS without WasmGC.
- **Gaps:** client-side SQLite on web needs the worker and WASM files. There's no Insights on Linux.
- Docs: https://docs.serverpod.dev/concepts/web-server/flutter-web

---

## 2. Jaspr (latest stable 0.23.5, ~2026-09-26; prerelease 0.24.0-beta.0)

- **Modes:** set `jaspr: mode:` in pubspec to one of:
  - `static` (SSG)
  - `server` (SSR, with automatic hydration and state sync)
  - `client` (pure SPA)
- **Component model:** Flutter-like. `StatelessComponent` and `StatefulComponent` (`State`, `initState`,
  `dispose`) and `InheritedComponent`; `build` returns one `Component`. Markup comes from a typed HTML DSL
  (`div(classes:, [ .text('..') ])`), and you style with real CSS (Tailwind is common). Rendering uses
  fine-grained DOM updates rather than a canvas.
- **0.23.x changes:**
  - Agent Skills (`jaspr install-skills`), installed with `dart install jaspr_cli`
  - `jaspr convert-html`
  - `styles: standalone`
  - `basePath` sub-path hosting
  - SSR error/hang fixes
  - The `jaspr tooling-daemon` command was removed.
- **Packages:**
  - `jaspr`, `jaspr_cli`, `jaspr_builder`
  - `jaspr_router`
  - `jaspr_riverpod` (unofficial port)
  - `jaspr_content` (docs and blog sites)
  - `jaspr_flutter_embed` (embed Flutter widgets in a Jaspr page)
  - `jaspr_test`, `jaspr_lints`
  - `jaspr_serverpod`
- **`jaspr_serverpod`:** latest 0.6.1, with 0.7.0-beta.0 published ~2026-10-22. **Both depend on
  `serverpod >=2.3.0 <3.0.0`**, and the code uses the pre-Relic `dart:io HttpRequest` Route API. **It doesn't
  work with Serverpod 3 or 4.** Today, use Jaspr in **client mode**:
  1. Build to static files.
  2. Serve them with Serverpod's `SpaRoute` or static route.
  3. Call endpoints and streams through the generated `correlia_client`, which is pure Dart and browser-safe.
  4. Write your own connectivity monitor.

  With no SSR from Serverpod, you lose Jaspr's main advantage over a plain SPA. Alternatively, run a separate
  Jaspr server process.
- **UI kits:** thin.
  - `shadcn_jaspr` 0.4.3: a community port with ~60 components including charts, dialogs and sheets. It needs
    Tailwind, has an unverified publisher and few downloads.
  - Otherwise you build on plain HTML/CSS, Tailwind or DaisyUI-style CSS, or JS libraries via interop.
  - **There's no mature data-grid component.** You'd hand-roll a virtualized table or wrap a JS grid
    (AG Grid, TanStack) via `dart:js_interop`.
- **Maturity:**
  - Google rebuilt dart.dev, flutter.dev and docs.flutter.dev (3,900+ pages, more than 1M MAU) on Jaspr and
    `jaspr_content` (Google Open Source blog, April 2026).
  - About 2.5k GitHub stars.
  - It's effectively a single-maintainer project (Kilian Schulte), and still pre-1.0 with breaking changes
    between minors.
  - It's proven for content sites. It's much less proven for complex app UIs.
- **Links:** https://pub.dev/packages/jaspr , https://github.com/schultek/jaspr , https://docs.jaspr.site ,
  https://opensource.googleblog.com/2026/04/jaspr-why-web-development-in-dart-might-just-be-a-good-idea.html

---

## 3. Recommendation: Flutter web vs Jaspr for the ops console

| Criterion | Flutter web | Jaspr (client mode) |
|---|---|---|
| Dense data tables | Good. `two_dimensional_scrollables` (TableView), community grids (Trina/Pluto grid, Syncfusion DataGrid), and virtualization out of the box. | Hand-rolled HTML tables are fine up to a few thousand rows. Beyond that, you need virtualization or a JS grid via interop. |
| Live updates | Same: `serverpod_client` streams plus state management. | Same: `serverpod_client` streams. |
| Filters and forms | Rich widget set. | HTML forms; you style everything. |
| Keyboard use | `Shortcuts`/`Actions` and focus system, very good. | Native DOM focus and keys; you write the handlers. |
| Deep links | `go_router` plus `FlutterRoute` index fallback. Works, and the URL bar is fine. | Native `<a href>`: middle-click and open-in-new-tab just work. |
| Initial load | Heavy: engine, CanvasKit/skwasm and app, typically a few MB *(unverified estimate)*. Cached after first load. | Small, typically tens to low hundreds of KB *(unverified estimate)*. |
| Browser find (Ctrl+F) | **Doesn't work** on canvas-rendered text, a real annoyance for operators searching labels. Build in-app search instead. | Works. |
| Text selection and copy | Opt-in (`SelectionArea`/`SelectableText`). Easy to forget, and annoying for copying hostnames and labels. | Native. |
| Accessibility | Semantics tree off until enabled. You can force it with `SemanticsBinding.instance.ensureSemantics()`; it's improving (3.44 fixes). | Native DOM, the best you can get. |
| DevTools | Flutter DevTools (widget inspector, perf), but browser DOM tools are useless. | Browser devtools plus Dart debugging, hot reload. |
| SEO | Irrelevant. | Irrelevant. |
| Your existing skills | 100% reuse. You already ship Flutter apps. | New component model is close to Flutter's, but you're back to CSS, layout and HTML semantics. |
| Serverpod integration | First-class: `FlutterRoute`, `serverpod_flutter`, auth UI widgets. | `jaspr_serverpod` is broken for 4.x, so the setup is DIY. |
| Mobile and desktop for free | Yes. An on-call phone app from the same code is a real plus for an alerting tool. | No. |

**Verdict: Flutter web.** For a single Flutter developer, the deciding factors are:

- **Reuse:** skills, widgets and Serverpod's first-class integration.
- **Free mobile/desktop:** an on-call phone app with push notifications is a natural future feature for an
  incident tool.
- **Data grids:** Flutter's are more mature than anything in Jaspr's ecosystem.

Budget for the known web papercuts from day one:

1. Wrap the app in `SelectionArea`.
2. Force semantics.
3. Build an in-app search/filter bar, since Ctrl+F doesn't work.
4. Use `Link` widgets so row links open in new tabs.
5. Try a WASM build with `enableWasmHeaders`.
6. Accept the first-load size, since it's an internal tool used all day.

**When Jaspr would be the better choice:**

- A **public or customer status page**, or **shareable incident permalinks** viewed by people without the app.
  These should be light, linkable, server-rendered and accessible. A static or SSR Jaspr site is a good
  separate artifact there, once `jaspr_serverpod` supports Serverpod 4 or as a standalone Jaspr server
  calling the API.
- If the console must be **embedded in other web tools** (iframes in Grafana or a wiki), run on weak NOC
  kiosk/TV browsers, or be opened as dozens of tabs. DOM wins on memory and startup.
- If accessibility compliance becomes a hard requirement (public sector or enterprise procurement).
- If the team later gains web/CSS people, or you want browser-native behaviour (find, select, middle-click)
  without fighting the framework.

---

## 4. Testing a Serverpod app against real Postgres

- **No Docker is needed.** Put `database: dataPath: .serverpod/test/pgdata` in `config/test.yaml` and run plain
  `dart test`. `withServerpod` then:
  - boots the embedded Postgres (downloaded once)
  - gives **each test group its own randomly named ephemeral database**, dropped at teardown
  - applies migrations
  - rolls back after each test (`rollbackDatabase: afterEach | afterAll | disabled`)
- **Useful options:** `ephemeralDatabase: false` (shared DB, then run with `--concurrency=1`),
  `configOverride`, `runMode`, `enableSessionLogging`, `serverDirectory` (for running from the workspace root),
  `testGroupTagsOverride` (default `['integration']`) and `serverpodStartTimeout`.
- **Layout:** tools are generated into `test/integration/test_tools/serverpod_test_tools.dart`. Import that, not
  `serverpod_test` directly.
- **Caveat:** if a test process is hard-killed, the embedded Postgres can keep running and leave data behind.
  Delete the data directory.
- **Without `dataPath`:** tests connect to an already-running Postgres (Docker Compose or a CI service
  container). The 4.0 CI templates still reference `DB_TEST_PASSWORD`/`REDIS_TEST_PASSWORD`, so check whether
  the default `tests.yml` uses service containers. Embedded Postgres also works on Linux x64 CI runners.
- **A Dart Testcontainers package is not needed** for Postgres. You'd only want containers to test against
  Redis or other real services (e.g. a real Alertmanager sending webhooks). For that, `testainers` 0.4.0
  (Postgres/Redis modules, Docker CLI based) or a compose file is enough. Full assessment:
  `research/correlia/testcontainers-dart.md` (verdict: don't build a port).
- **Correlia-specific:** test webhook Routes by calling them over HTTP against the test server. The
  `withServerpod` `endpoints` helper covers RPC endpoints, not Relic Routes. *(Whether `withServerpod` exposes
  the web server port for HTTP route tests was not verified.)* Keep correlation logic as pure Dart with fast
  unit tests, and run DB integration via `withServerpod`.

---

## 5. Agent tooling: Dart MCP server and skills

### Dart and Flutter MCP server (`dart mcp-server`)

- Ships with the Dart SDK (>= 3.9). Repo: https://github.com/dart-lang/ai/tree/main/pkgs/dart_mcp_server.
  Docs: https://docs.flutter.dev/ai/mcp-server (dart.dev/tools/mcp-server redirects there).
- **Tools on by default:**
  - `analyze_files`, `lsp`, `pub`, `pub_dev_search`, `read_package_uris`, `rip_grep_packages`, `roots`
  - `dtd`, `vm_service`, `widget_inspector`, `hot_reload`, `hot_restart`, `get_runtime_errors`
  - `flutter_driver_command`
- **Tools off by default** (enable with `--enable <tool|category>`):
  - `run_tests`, `dart_fix`, `dart_format`, `create_project`
  - `launch_app`, `stop_app`, `list_devices`, `list_running_apps`, `get_app_logs`
  - `get_active_location`
- **Config:**
  - Generic: `{"mcpServers":{"dart":{"command":"dart","args":["mcp-server"]}}}`.
  - VS Code uses `servers`.
  - Gemini CLI uses `.gemini/settings.json`.
  - For **Codex**, Serverpod's docs pass `--force-roots-fallback`.
  - Claude Code CLI: `claude mcp add --scope project dart -- dart mcp-server` *(standard Claude Code syntax,
    not on the Flutter page)*.
  - Codex CLI: `codex mcp add dart -- dart mcp-server --force-roots-fallback`, or in `.codex/config.toml` add
    `[mcp_servers.dart] command = "dart"` and `args = ["mcp-server","--force-roots-fallback"]` *(syntax from
    Codex conventions, unverified today)*.

### Official Flutter plugin: `flutter/agent-plugins` (renamed from `flutter/skills`)

It bundles skills, the MCP config, a rules dir and an a11y agent. Docs: https://docs.flutter.dev/ai/agent-skills

| Harness | Install |
|---|---|
| Claude Code | `claude plugin marketplace add flutter/agent-plugins` then `claude plugin install dart-flutter@dart-flutter`. Rules aren't auto-loaded; copy them from `flutter/agent-plugins/rules` into CLAUDE.md or AGENTS.md. |
| Codex | `codex plugin marketplace add flutter/agent-plugins` then `codex plugin add dart-flutter@dart-flutter` (verify with `codex plugin list`). |
| Cursor | Marketplace "Dart and Flutter", or `/add-plugin dart-flutter`. |
| Antigravity / agy, Copilot, OMP, generic | MCP JSON above plus `npx skills add flutter/agent-plugins --skill '*' --agent universal --yes` |

### Official Dart skills

`dart-lang/skills`: `npx skills add dart-lang/skills --skill '*' --agent universal --yes`.

### Serverpod's own (4.0+)

- `serverpod create --ide claude,codex,cursor,vscode,antigravity,opencode` writes:
  - `.mcp.json` (Claude)
  - `.codex/config.toml`
  - `.cursor/mcp.json`
  - `.vscode/mcp.json`
  - `opencode.json`
  - `.agents/plugins/serverpod-local/mcp_config.json`
  - plus skills and **AGENTS.md**
- `serverpod create .` adds these to an existing project, **but it overwrites scaffold files**, so be careful.
- `.mcp.json` registers **two** servers: `serverpod mcp-server --server-dir <project>_server` and
  `dart mcp-server`.
- **Serverpod MCP tools** need `serverpod start` or `serverpod runner start` running:
  - `create_migration`, `create_repair_migration`, `apply_migrations` (no params; applies everything, so
    review it)
  - `hot_reload`, `hot_restart`, `spawn_flutter_app`, `get_flutter_app_dtd`
  - `tail_server_logs`, `tail_flutter_logs`, `tail_runner_logs`
  - resource `serverpod://vm-service`
- **Skills:** `dart install skills`, then `skills get --ide <antigravity|claude|cline|codex|copilot|cursor|opencode|generic>`.
  Use `generic` to put them in `.agents/` for other harnesses such as OMP.
- Docs: https://docs.serverpod.dev/concepts/cli/commands/mcp-server ,
  https://docs.serverpod.dev/upgrading/upgrade-to-four

### Jaspr

`jaspr install-skills` (since 0.23.0). Skills live in the repo under `packages/jaspr/skills/`
(e.g. `jaspr-fundamentals`).

---

## Open questions / to verify before committing to the stack

1. Confirm the "all run modes must use the same backend" rule is enforced (it's stated on the config page).
   If it is, drop the SQLite-for-dev plan.
2. Can `withServerpod` hit Relic web routes over HTTP, or do webhook routes need a separate HTTP test harness?
3. Does `jaspr_serverpod` get a Serverpod 4 / Relic release? Watch https://pub.dev/packages/jaspr_serverpod.
4. The `maxRequestSize` default (512 KiB) vs real Alertmanager/Icinga payload sizes.
5. There's no generic OIDC IdP, so estimate the custom-provider effort if Keycloak/Authentik SSO is a v1
   requirement.
