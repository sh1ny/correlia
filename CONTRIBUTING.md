# Contributing to Correlia

Thanks for helping. Correlia is an event and alert aggregator and correlator. It ingests alerts from monitoring systems, normalizes and enriches them into one versioned event, publishes them to outputs such as NATS, and correlates them into incidents worked in a Flutter web console. It is built on Dart, Serverpod and PostgreSQL.

Correlia is pre-release and under active development. Milestones and their state are in the [roadmap](openspec/roadmap.md).

## Ways to help

- **Report a bug or suggest an idea.** Open an [issue](https://github.com/sh1ny/correlia/issues/new/choose). Each form marks the few fields you need to fill in.
- **Fix something small** (a typo, a doc, an obvious bug): send a pull request straight away.
- **Anything bigger** (a new feature, a new dependency, or a change to how the parts talk to each other): open an issue first, so we can agree on the approach before you spend time on it.
- **Found a security problem?** Don't open an issue. Report it privately as [SECURITY.md](SECURITY.md) describes.

## How the project is planned

Maintainers plan work with [OpenSpec](https://github.com/Fission-AI/OpenSpec) and [Specwright](https://github.com/sh1ny/specwright): milestones live in `openspec/roadmap.md` and each larger change gets a folder under `openspec/changes/`. You don't need either tool to contribute. If your change is larger, a maintainer may write it up as an OpenSpec change and ask you a question or two. Please don't edit `openspec/changes/` in your pull request unless you're asked to.

Much of the maintainers' own work is done with AI coding agents, and an automated reviewer may comment on your pull request. A person makes every decision. AI-assisted contributions are welcome too, as long as you understand and have tested what you send.

## Setup

Install [mise](https://mise.jdx.dev/); it provides the pinned toolchain. Use it for every command (`mise run <task>` or `mise exec -- <command>`).

```sh
mise install
mise run doctor      # checks your setup
mise run setup
mise run check       # the full gate: validation, analysis, format and tests
```

`mise run test` runs the fast tests. `mise run test -- --tags db` (or `e2e`, `plugin`) runs one slower tier, and `mise run test:all` runs every tier except load. Tests start their own embedded PostgreSQL; they never use a database you already run.

## Making a change

- Branch from `main` and keep each pull request to one change.
- **Tests.** Add or update tests for behaviour you change. A test must never fail because a machine is slow: wait for an event or a result, never sleep for a fixed time.
- **Commit messages** follow [Conventional Commits](https://www.conventionalcommits.org/): `type(scope): summary`, for example `fix(ingest): reject malformed alerts`. If you get it wrong, a maintainer will fix it when merging.
- **Write it yourself.** Don't copy code from other projects, including translating it from another language. Adding a dependency is fine when its licence is compatible, but mention it in the pull request.

### Rules specific to Correlia

- Don't copy another product's code, schemas, templates or provider configs, even ones you have access to at work. Describe the behaviour you want and write it yourself.
- The event contract is generated: change the `.proto` files and run `mise run proto`, then `mise run proto:check`. See [docs/event-contract-tooling.md](docs/event-contract-tooling.md).
- Develop and test on Linux. On Windows, use WSL and keep the checkout on the Linux filesystem.

## Pull requests

The template asks for three things: a short **Summary**, what it's **Linked** to (an issue, or "none"), and how you **tested** it. Everything else is optional. Tick the project checks at the end; they are the rules above that most often surprise people.

CI runs on every pull request. If it fails and you can't see why, say so in the pull request and we'll help. A maintainer reviews and merges.

## Licence

Correlia is under the [Elastic License 2.0](LICENSE): you may use, change and run it yourself, including at your company, but not offer it to others as a hosted or managed service.

Third-party files with their own licence notices keep those licences.

Contributions need the short [contributor licence agreement](CLA.md). You keep the copyright in your work; the agreement lets the project offer Correlia under other terms later, for example a commercial licence for a service provider. You agree to it by ticking its box in the pull request template.
