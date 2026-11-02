# Testcontainers for Dart: worth building? (assessed 2026-11-03)

Status: research. Question: is a Dart port of Testcontainers a worthwhile side project, given the owner
would use it for a Serverpod + Postgres project tested from WSL?

**Short answer: don't build it.** A fairly complete port already exists (`testcontainers_core`, May 2026,
including Ryuk). Demand is close to zero. And Serverpod 4 removed the main reason you would want one: its
test tooling now starts its own embedded PostgreSQL with no Docker at all.

---

## 1. What exists on pub.dev (checked 2026-11-03)

| Package | Version / last publish | Likes / downloads (30d) | Transport | Notes |
|---|---|---|---|---|
| `testcontainers_core` + `testcontainers_compose` ([repo](https://github.com/mridang/testcontainers-dart)) | 1.0.14, ~June 2026 (repo created 2026-05-08, last push 2026-06-19) | 0 likes, 262 / 53 downloads, 155 pub points, 0 GitHub stars, unverified uploader | Raw Docker Engine API over a Unix socket or TCP (HTTP/1.0, one connection per request), API v1.41 | A port of testcontainers-python core + compose, about 75 commits. Has **Ryuk/Reaper** (session labels `org.testcontainers.*`, `TESTCONTAINERS_RYUK_DISABLED`). Wait strategies: log, HTTP, healthcheck, port, file-exists, container-status, exec, composite. Has networks, image pull/build, copy-to/from (tar), private registry auth (`DOCKER_AUTH_CONFIG`), `~/.testcontainers.properties` / `tc.host`, `DOCKER_HOST` (unix/tcp/ssh), rootless socket via `XDG_RUNTIME_DIR`, `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE`, connection modes (bridge/gateway/docker_host). **Missing:** no modules (no Postgres or Redis class, you use the generic container), no Windows named pipe (`npipe://`), no explicit Podman or Testcontainers Cloud handling. Since June the repo has had only dependabot activity. It looks like a one-person, possibly AI-assisted, burst port. |
| `testainers` ([repo](https://github.com/testainers/testainers)) | 0.4.0, 2026-05-24 | 8 likes, ~950 downloads, 13 stars, verified publisher testainers.com | Shells out to the `docker` CLI (`Process.run`) | Has modules: PostgreSQL (18-alpine), Redis, MongoDB, sshd, httpbin, httpbucket, http-https-echo, plus compose and network. No Ryuk; cleanup is up to you in `tearDownAll`. Small and active about once a year since 2023. |
| `docker_commander` | 3.1.0, ~Oct 2026 | 16 likes, 6.3k downloads | Local daemon, or a remote via its own server | Not Testcontainers-shaped, but it has an ephemeral PostgreSQL preset (`hostPort: 0`, tmpfs), session labels with `cleanupSession()`, and a `docker_commander_test` companion. The most-used of the lot. |
| `docker2` | 6.3.0, Nov 2026 | 16 likes, 526 downloads | Docker CLI wrapper | Generic image and container control, no test focus. |
| `docker_process` | 1.3.2, ~2024 | 7 likes, 437 downloads | CLI | Runs a container like a process. Unmaintained. |
| `dart_docker` | 0.0.1, ~2024 | 4 likes, 337 downloads | Engine API over a Unix socket | Abandoned stub. |
| `docker` | 0.3.5, 8 years old | not Dart 3 compatible | CLI | Dead. |

**Serverpod test tooling (`serverpod_test`, Serverpod 4.x):**
- `withServerpod` gives each test group its own randomly named, ephemeral database and drops it on teardown.
- Each test runs in a transaction that is rolled back by default (`rollbackDatabase: afterEach`, with `afterAll` and `disabled` as the other options). Migrations are applied automatically.
- Since 4.0, setting `database.dataPath` in `config/test.yaml` makes Serverpod start an **embedded PostgreSQL**. The binaries download once into a per-user cache. It covers Linux and macOS on x64 and arm64, plus Windows x64, and the custom builds include pgvector and PostGIS.
- It needs no Docker and connects over a Unix socket.
- The docs say: "Integration tests bring their own database, so there is nothing to install or start first."
- Caveat: if the test process is hard-killed, the Postgres server stays running and leaves data behind (disk only, no correctness impact).
- Without `dataPath`, it uses an externally running Postgres, which in Serverpod 3 was the docker compose setup.

## 2. Official status

- testcontainers.com lists Java, Go, .NET, Node.js, Python, Rust, Ruby, PHP, Haskell, Clojure, Elixir, Scala and Native. **There is no Dart entry.**
- Docker's docs say Docker sponsors some implementations and the rest are community-maintained. Getting listed in practice means a credible, maintained community implementation that someone proposes to the testcontainers org (website repo or Slack).
- There is **no published "specification" or conformance checklist** for new languages. The closest thing is the de-facto reference behaviour of the Java, Go and Node implementations. testcontainers-node merged an AGENTS.md "Cross-language implementations" note (PR #1391) saying the mature ports serve as that reference.
- The things a port is implicitly expected to have:
  - Docker host strategy chain: env, properties file, socket, npipe, Docker Desktop, Testcontainers Cloud, Podman.
  - Ryuk with session labels.
  - The standard `TESTCONTAINERS_*` env vars.
  - Wait strategies.
  - Modules.
- I found **no open request** for a Dart implementation in the testcontainers GitHub org (an issue search for "dart" in org:testcontainers returned nothing). It has not been discussed publicly.

## 3. Effort to build a credible MVP yourself

The scope: an Engine API client (unix socket, npipe, TCP), container lifecycle, wait strategies, Ryuk, a
Postgres module, and `package:test` integration.

| Piece | Effort (one developer, evenings) | Notes |
|---|---|---|
| Engine API over a Unix socket or TCP (create, start, inspect, stop, remove, pull with progress stream) | 3–5 days | `dart:io` supports `InternetAddress(path, type: InternetAddressType.unix)`, so a hand-written HTTP/1.1 over a socket is needed. `HttpClient` cannot dial a Unix socket directly; mridang's version shows the raw-socket approach. |
| Log streaming / attach | 1–2 days | Logs on non-TTY containers use 8-byte multiplexed frame headers, which is easy to parse. Hijacked attach/exec streams need `Connection: Upgrade` handling on a raw socket. That is doable but fiddly with chunked encoding and half-close. |
| Wait strategies (log, port, HTTP, healthcheck, exec) | 2–3 days | Plain code. |
| Ryuk | 1–2 days | A TCP socket kept open, plus the label filter protocol. Annoyances: Docker Desktop and rootless sockets need a privileged mount, and Ryuk must be disabled for Podman. |
| Postgres module plus `setUpAll`/`tearDownAll` helpers | 1 day | |
| **Windows named pipe (`npipe:////./pipe/docker_engine`)** | 3–7 days, risky | `dart:io` has **no named-pipe socket support**. You need FFI with win32 `CreateFile` and overlapped I/O (as the `dart_ipc` package does), or a fallback to the `docker` CLI or TCP 2375. This is the real hard part. AF_UNIX on Windows is also not reliably supported by `dart:io`. |
| Host detection matrix (Docker Desktop on macOS/Windows, WSL2 ↔ Desktop, rootless, Podman socket, Colima, Testcontainers Cloud) | 1–2 weeks of edge cases | This is where the established ports spent years, and CI testing it needs runners on every OS. |

- **Linux/WSL-only MVP:** about 2–3 weeks part-time and about 2–3k lines of code.
- **"Credible for official listing":** cross-platform, a handful of modules, docs and CI across operating systems. That is 2–3 months of part-time work plus permanent maintenance as Docker API versions change and Docker Desktop shifts.
- For scale, the existing `testcontainers_core` lib is about 200 KB of source (14 files), mostly `inspect.dart` models and `docker_client.dart`.

## 4. Demand signals and what people do instead

**Demand is very low:**
- The only Engine-API port has 0 stars and about 260 downloads.
- `testainers`, with modules, has 13 stars.
- Searches found no Reddit, StackOverflow or GitHub threads asking for "Testcontainers for Dart".
- No issue in the testcontainers org mentions Dart.

Dart's backend user base is small, and its biggest backend framework (Serverpod) solved the database case itself.

**What people use instead:**
1. **Serverpod 3 and earlier:** `docker compose up -d` with the generated `docker-compose.yaml`, which has a separate test Postgres and Redis on their own ports. CI does the same.
2. **Serverpod 4:** the embedded PostgreSQL through `dataPath`, needing no Docker locally or in CI.
3. **CI:** GitHub Actions `services: postgres:` containers.
4. sqlite or in-memory fakes for pure unit tests (a fidelity risk with Postgres-specific SQL).
5. For ad-hoc containers: `testainers` (CLI-based) or `docker_commander`.

## 5. Verdict

**Don't build a Dart Testcontainers port. If you need containers at all, write a small internal helper
(or use `testcontainers_core`).**

Reasoning for this owner (one developer, many projects, Serverpod + Postgres, tests run from WSL):
- **The problem you'd use it for is already solved.**
  - On Serverpod 4, `dataPath` in `config/test.yaml` gives per-group ephemeral databases, transaction rollback per test, and automatic migrations, with no Docker.
  - Inside WSL it's plain Linux: x64 binaries and a Unix socket.
  - Start there. Check for orphaned Postgres processes after killed test runs.
- **If you stay on Serverpod 3, or need Redis or other services:** keep the generated docker compose. Optionally add a tiny Dart helper (about 50–150 lines):
  - `Process.run('docker', ['compose', ...])` in `setUpAll` / `tearDownAll`;
  - wait with `pg_isready` or a TCP probe;
  - a random project name for isolation.

  That is about an afternoon of work and has nothing to maintain.
- **If you want real per-test containers:** use `testcontainers_core` as-is. In WSL it talks to `/var/run/docker.sock` directly (Docker Desktop's WSL integration or native dockerd) and already has Ryuk. Its gaps (a Postgres module, npipe) don't matter from WSL. A Postgres wrapper is about 30 lines in your own repo. Pin the version; it is a bus-factor-1 package with dependabot-only activity since June.
- **As a side project for its own sake:** low payoff.
  - A competent port already exists, so you would be at best the second of three.
  - Official listing has no clear criteria and needs long-term maintenance commitment.
  - The only technically interesting gap (Windows named pipes over FFI) is exactly the part you would not use from WSL.
  - The audience is tiny and shrinking, because Serverpod embeds Postgres.
  - It fails the token/time-budget test.
- **One version that could be worthwhile:** upstream contributions to `testcontainers_core`, such as an npipe transport and `PostgresContainer`/`RedisContainer` modules. Do this only if a real need appears.

## Sources
- pub.dev: [testcontainers_core](https://pub.dev/packages/testcontainers_core), [testainers](https://pub.dev/packages/testainers), [docker_commander](https://pub.dev/packages/docker_commander), [search "docker"](https://pub.dev/packages?q=docker), [search "testcontainers"](https://pub.dev/packages?q=testcontainers)
- GitHub: [mridang/testcontainers-dart](https://github.com/mridang/testcontainers-dart) (source read: `docker_client.dart`, `config.dart`, `container.dart`, `labels.dart`), [testainers/testainers](https://github.com/testainers/testainers) (`testainers_base.dart` uses `Process.run`)
- [testcontainers.com getting started](https://testcontainers.com/getting-started/), [Docker docs: Testcontainers](https://docs.docker.com/testcontainers/), [testcontainers-node PR #1391](https://github.com/testcontainers/testcontainers-node/pull/1391)
- Serverpod: [testing get started](https://docs.serverpod.dev/concepts/testing/get-started), [testing configuration](https://docs.serverpod.dev/concepts/testing/configuration), [embedded PostgreSQL](https://docs.serverpod.dev/next/concepts/data-and-the-database/database/embedded-postgres), [upgrade to 4.0](https://docs.serverpod.dev/next/upgrading/upgrade-to-four.md)
- Dart named pipes: [dart-lang/sdk#49917](https://github.com/dart-lang/sdk/issues/49917) (anonymous pipes, Windows limits), [dart_ipc](https://pub.dev/packages/dart_ipc) (named pipes via FFI/win32)
