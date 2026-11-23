---
name: specwright-review
description: "Reviewer routes and the pre-ship review for Specwright changes. Chooses the reviewer (codex, claude, omp CLI or the specwright-reviewer subagent) from review.order, runs it isolated and read-only through the project's `sw` binary, validates the output and fails closed. Pre-ship mode reviews the finished main...<change branch tip> diff before the first PR or a local merge, blocks on P0/P1 findings, and sets the rules for fixes, waivers and spec amendments. Triggers: 'review before ship', 'run the pre-ship review', a design review step (FULL tier, roadmap baseline) choosing its reviewer, or specwright-commit, specwright-pr ship and specwright-finish calling it."
metadata:
  version: 0.39.1
---

# Specwright Review

**`<sw>`.** Specwright's own work runs in one binary, `sw`, which the install prompt places. Read `openspec/.specwright/VERSION` in the code checkout; it must be `x.y.z` with an optional `-<pre-release>` and `+<build>` suffix and nothing else. Any other value (a path, a space, an empty file, no file): stop before building any path and tell the user to rerun the install prompt. `<sw>` is `<home>/.specwright/bin/<VERSION>/sw` (`sw.exe` on Windows); `<home>` is `SPECWRIGHT_HOME` when set, else the user's home. Never run an `sw` found on `PATH`, another version's binary or a copy elsewhere. When that file does not exist, stop the step and tell the user to rerun the install prompt. Before the first other `<sw>` command of a run, run `<sw> version --json` with a 10-second tool timeout and stop unless it exits 0 in time and prints one JSON object whose `version` is `<VERSION>` and which reports interface 3: on any other result run no other `<sw>` command and tell the user to rerun the install prompt. A project at an older version, whose binary reports interface 2 or 1, stops the same way; tell the user to update this project. Any `<sw>` command that prints a `sw_mismatch` document (the binary and the project's `VERSION` differ) stops the step the same way, showing its `message`. Every `<sw>` command prints one JSON document unless its section says otherwise.

Run `<sw> review <sub>` from the code checkout; it has eight subcommands and needs git, not Python, Bash or Node. No `gh` call; one JSON document per call. Exit 0 = ok, 1 = stop (show its `message`), 2 = usage error, 3 = failed review.

## Settings

Read from `openspec/specwright.yaml`; every key is optional:

```yaml
review:
  cross_model: true          # false = the specwright-reviewer subagent only, no CLI
  order: [codex, claude, omp] # routes tried in order; the current harness is skipped
  models:                    # per route; omit = the CLI's default
    omp: "@default"          # an OMP role (@slow) or provider/id
  thinking: {}               # per route: codex reasoning effort, claude --effort, omp --thinking (provider/id only)
  timeout: 20m               # per review run; the reviewer is killed after it
  max_diff_kb: 1024          # pre-ship input bound (code + store diff); over it, no review runs
  preship: true              # false = no pre-ship review and no ship/merge gate
  routes:
    codex:
      disable: []            # additive; never removes fixed feature disables
      args: []               # extra argv tokens, not a shell command
    claude:
      tools: [Read, Grep, Glob]
      args: []
    omp:
      tools: [read, grep, glob]
      args: []
```

`tools` replaces the Claude/OMP tool list; an empty list means no tools. Codex has no `tools` setting. Codex `disable` adds to its fixed feature disables; an empty list cannot restore a disabled feature. All lists contain strings. Extra `args` cannot replace or weaken fixed isolation, tool selection, model/thinking, output capture or settings. Use `review.models`, `review.thinking` and the route's `tools` instead of their CLI flags. Known unsafe tools, protected flags and their aliases (including Codex `--yolo` and `--not-so-yolo`) stop with `route_setting_unsafe`; malformed route controls stop with `bad_route_setting`. Unsupported YAML (a plain `yes` or `no` for a boolean: write `true` or `false`) stops with `bad_settings`, naming its line. Validate every route before any CLI probe, even when `cross_model: false` or another route would run.

Refuse Codex `-c profile=...` and every `profiles` table/child override as aliases of protected profile/settings sources. Refuse `model_provider` and `model_providers` overrides, including tables and children: provider `auth.command` programs run outside the tool sandbox. Refuse `notify` overrides for the same host-command boundary. Refuse OMP `fetch` both in route settings and in the fixed hook, independently of its disabled overlay.

Codex always disables `apps`, `browser_use`, `browser_use_external`, `computer_use`, `in_app_browser`, `image_generation`, `memories`, `hooks`, `plugins`, `remote_plugin`, `tool_suggest`, `skill_search`, `skill_mcp_dependency_install`, `goals` and `sleep_tool`.

OMP must be version 18.19.0 or newer; older or unparseable versions are skipped. Its fixed overlay sets `autolearn.enabled`, `memories.enabled`, `find.enabled` and `fetch.enabled` to `false`, and it uses a private session. Never remove these controls or permit user settings, extensions or skills to restore the refused capabilities.

## Routes

Every review (design or pre-ship) picks its reviewer the same way:

1. **Select:** `<sw> review select --runtime <claude|codex|omp|other>`, where `--runtime` is the harness you are running in (`other` skips nothing). It prints `route` (`codex`, `claude`, `omp` or `subagent`), `skipped` (each route with its reason: `current runtime`, `not installed`, a failed probe, or OMP's `Model "<m>" not found`), `model` and `thinking`. Save the output to a temp file: `run` takes it as `--selection` so the receipt lists the skipped routes. Exit 1 (an unknown name in `review.order`) → stop and show the message.
2. **CLI route** → `run` (below). `<sw> review` builds the fixed isolation flags plus validated route controls; never construct a reviewer command line yourself.
3. **`subagent`** → dispatch the `specwright-reviewer` agent with file paths, never your reasoning, then validate what it wrote with `record` (below). If no such agent is installed, stop and tell the user.
4. **Background.** A review takes minutes, up to `review.timeout`. Start `run` in the background (Claude Code: `run_in_background`; other harnesses: their background or blocking exec) and wait for it to finish; do not poll it.
5. **Exit 3 is a failed review** (`status: invalid`, `timeout`, or the reviewer crashed): nothing was reviewed. Never try the next route, never review the change yourself, and never treat it as a pass. Report the route, the status and the error, and offer to run it again. A failed pre-ship review stops ship and the local merge until a review passes.
6. **Receipt.** Report the receipt from the output: route, skipped routes and reasons, requested and actual model and level (`unknown` when the CLI does not say), effective tools, feature disables, extra args and overlay. OMP also reports `policy_id` and `policy_sha256` for the exact fixed module. `process_group` says how the reviewer's processes were held together (`job` on Windows, `session` on POSIX); `none` (with `process_group_reason`) means Windows could not make a job object, and a stopped reviewer's tree was then stopped from the reviewer's own process.

## OMP target boundary

With `--no-extensions` retained, Specwright loads exactly one fixed Specwright-owned `--trusted-extension` module inside OMP. User trusted-module arguments are refused; there is no custom policy setting or separate production interpreter. The hook rejects tool-directed remote targets before dispatch, including encoded, compound and aliased forms; optional `lsp` is restricted to its nine read-only actions. The fetch overlay also disables HTTP reads.

For a single bare extensionless open-ended read selector, the hook schema-replaces the path with its explicit local form (`README:50-` → `./README:50-`) and checks that effective input before dispatch. Widening only the guard regex is unsafe because native opaque-resource routing can remain reachable. Compound/encoded/aliased ambiguity still fails closed.

This is not an OS network or filesystem sandbox. Provider transport, underlying filesystem mounts, trusted native tools and language servers remain outside the lexical target boundary. Do not present the tool policy as a general no-network guarantee.

## CLI version checks

Before accepting a changed reviewer CLI, apply ADRs 0035 and 0036:

1. Record its version, exact argv and effective settings. Capture native tool definitions and the complete mounted-tool inventory. Prove their equivalence to the exact reviewer invocation in that version's source, accounting for diagnostic/RPC defaults, settings sources and tool mounting. Use version-matched source instrumentation when the CLI exposes no complete native capture.
2. Check refused capabilities against both captures. Add new writing, execution, network, agent-starting or memory tools to the route's refused list; extend fixed feature disables as needed. Inspect CLI option aliases and add aliases of protected flags to the static refused-flag lists.
3. Obtain direct child denied-write evidence, not a parent-relayed report. Keep all fixed isolation flags, including Codex's `--ephemeral` and `-s read-only`; request `fork_turns="none"` for the fresh child. Record the actual denied attempt and `git status --porcelain` before and after; the output must be unchanged.
4. For OMP, replay the production module with actual native tool calls. Pair every remote request with its tool error or denial; cover HTTP(S), SSH, encoded and compound targets, aliases, selectors and optional LSP actions. Count every accepted TCP connection, not only completed HTTP requests: both counters must be zero. Show successful local read, grep and glob results, including content, literal delimiters, selectors and multiple roots. Inject module-load and callback failures and prove that affected calls fail closed. Record the effective overlay, module identity/digest and matching controller receipt.
5. Model-authored lists and refusals are corroboration only. Missing proof or an infrastructure failure does not pass; stop dependent work.

Policy tests use Node 22 as development-only tooling; Node is not a production dependency. The emitted module runs in OMP's own runtime.

## Design reviews

The schema's review step (FULL tier) and the `specwright-roadmap` baseline review use the routes above:
- **CLI route:** write the review request (the same request the review step describes: the files to read, the installed project skills that apply, the review template) to a temp file, then `<sw> review run --kind design --route <route> --prompt-file <request file> --out <review file> --change <change-name> --selection <select output>` (store-backed: `--store <store toplevel>`, so the Claude route can read the planning files). `<review file>` is the change's `review.md`; for the roadmap baseline it is `openspec/architecture-review.md` and `<change-name>` is `baseline`. The script writes it only after the output has exactly one `VERDICT: <v>` line (`<v>` is `APPROVE`, `APPROVE_WITH_CHANGES` or `REVISE`) and exactly one `CHANGES_APPLIED: <c>` line (`no` or `yes` after `APPROVE_WITH_CHANGES`, `n/a` after the other two); `BLOCKED`, `USER_OVERRIDE`, `SKIPPED_LIGHT`, `DEFERRED`, `WAIVED` or any other value is invalid, and the error names it. On exit 3 the file is untouched.
- **`subagent`:** first ask the script for a result file, `<sw> review record --kind design --change <change-name> --scratch`, which prints `scratch`, a fresh result file under the state dir, outside the change. The `specwright-reviewer` agent writes its review to that file, never to the review file. Then `<sw> review record --kind design --change <change-name> --result <scratch> --out <review file> --route subagent --selection <select output>`: it writes `<review file>` atomically only when the review validates (the same check as above) and removes the scratch file. Report its `receipt` (Routes step 6). Exit 3 → the review is invalid: `<review file>` is left as it was (an earlier review stays), the output names the scratch file, the tasks step does not start; run the review again. Bare `record` without `--out` still validates a file in place, but design reviews do not use it.

**Windows and codex.** The codex route always ignores the user's codex config (`--ignore-user-config`). On Windows only, native `sw` reads that config as TOML: when `[windows] sandbox` is a plain name (such as `elevated`), it passes just that setting as `-c windows.sandbox="<name>"` and lists it in the receipt as `windows_sandbox`. Nothing else is forwarded. Missing, unreadable, malformed or unsafe values are ignored.

## Pre-ship review

Reviews the finished change, `<main>...<branch>` of the code repo (the tip of the change branch, which is HEAD on Git and jj) and, store-backed, of the store, before the change's first PR or a local merge. With `review.preship: false`, skip this whole section and the gate.

**Branch.** Every `<sw> review` call below that reads the change takes `--branch <prefix>/<change-name>` (the roadmap's `<branch>` for a roadmap branch, such as `docs/project-baseline`). The script resolves `refs/heads/<branch>` itself on every call for the diff, the record key, the `Preship-Round` count, the after-archive lookup, `heads_moved`, `gate` and `waive`; never pass a SHA. On GitButler HEAD is the workspace commit or another applied branch, so `--branch` is required there: without it the script stops with a usage error naming `--branch` and no review runs. On Git and jj pass it too; the tip equals HEAD, so ranges and record keys are the same as without it. Store-backed, the store side reads the store's HEAD (`--store-branch <name>` names its branch when needed).

**When.** `specwright-commit` step 3 runs it once every task is committed. `specwright-pr` ship (before the change's first PR) and `specwright-finish` (before a local merge) run the **gate** first and come here only on `missing`.

1. **Review.** Resolve the planning repo as the calling skill does. Select (Routes step 1), then:
   - CLI route, in the background: `<sw> review run --kind preship --route <route> --change <change-name> --branch <prefix>/<change-name> --out <findings file> --base <main> --prefix <P> --selection <select output>`, store-backed adding `--store <store toplevel> --store-base <store main>`. `<P>` is the planning prefix, as `specwright-pr` defines it (default `openspec`, relative to the code toplevel). The script builds the input itself (both diffs, the changed files, the change's artifact paths, `references/brief.md`), checks it against the findings schema, and records the result for the reviewed head.
   - `subagent`: first `<sw> review preflight --kind preship --change <change-name> --branch <prefix>/<change-name> --base <main> --prefix <P>` (store-backed: `--store <store toplevel> --store-base <store main>`) and save its output. It applies `review.max_diff_kb` to the same combined diff `run` reads, before any reviewer starts (exit 1 `diff_too_large`: handle it as below), and prints the heads the review covers. Then dispatch `specwright-reviewer` in pre-ship mode with the change name, the preflight `artifacts` (the artifact paths to read: archived ones once the change is archived), the base and the change branch `<prefix>/<change-name>` (the reviewer diffs `<base>...<branch>`, never HEAD), the planning root (`root.path`) and `<P>`, the store id when the session selected a store (the agent passes it to `openspec list --json` as `--store <id>`), the store toplevel and base when store-backed, `references/brief.md`, `references/findings.schema.json` and the path of the findings file to write; then `<sw> review record --kind preship --change <change-name> --branch <prefix>/<change-name> --result <findings file> --route subagent --preflight <preflight output> --selection <select output>` (store-backed: `--store <store toplevel>`). If the branch tip moved since the preflight, `record` exits 3 with `heads_moved` and writes nothing: run the review again.
   - Exit 1 `diff_too_large` → no reviewer ran. Report the size and ask the user to raise `review.max_diff_kb` or set `review.preship: false`. Never review a cut-down diff.
   - Exit 3 → Routes step 5.
2. **Read the result.** P0 and P1 findings block; P2 and P3 do not. No P0/P1 → the review passed: report it and hand back to the caller. Leave P2/P3 findings as they are: the PR description lists them, and fixing them now would leave the new head without a pass. Fix them only when the user asks, or in a round commit you make anyway (step 4).
3. **Blocked.** Show every open P0/P1 finding (id, file, title) with the options: fix, or waive. A waiver comes only from the user: run `<sw> review waive --change <change-name> --branch <prefix>/<change-name> --prefix <P> --finding <id> --reason "<the user's reason>"` (store-backed: `--store <store toplevel>`) only after the user explicitly answers that this finding is accepted, with their reason. Never waive a finding on your own judgement. No answer → no pass, and ship does not start. Once every P0/P1 is waived, `gate` reports `pass`.
4. **Fix round.** Before fixing anything, `<sw> review rounds --change <change-name> --branch <prefix>/<change-name>` (store-backed: `--store <store toplevel>`) gives `n`, the highest `Preship-Round:` trailer on the branch in either repo. When `n` is 2 or more and the review still has an unwaived P0/P1, stop fixing: list the open findings and ask the user how to proceed (another round, waive, or stop). Otherwise this is round `n+1`:
   - fix each `code` and `test` finding, test-first where it changes behaviour, and run the tests;
   - commit the fixed files by name under the `specwright-commit` rules (`<sw> vcs commit --repo <toplevel> --role code --branch <branch> --message-file <msgfile> -- <files>`; the store: `--repo "<store toplevel>" --role store --code "<code toplevel>"`), one commit per changed repo (store-backed: the store first, same subject and trailer in both), with the subject `<type>(<change-name>): address pre-ship review` and the trailer `Preship-Round: <n+1>`. Never use `address review feedback` or a `Feedback-Round:` trailer for these: those count PR fix rounds;
   - run a new pre-ship review (step 1): the new head has no pass until one passes.
5. **Spec findings** (`category: spec`) carry the reviewer's `spec_class`:
   - **clarification:** one reading of the spec fits every other scenario, and the code and tests already match it. Check that yourself. If it holds, edit the wording in the planning repo and commit it by name (`<sw> vcs commit`, as above) as `<type>(<change-name>): amend specs` with the trailer `Amendment: clarification`, then run a new pre-ship review. If it does not hold, treat it as a behaviour change.
   - **behaviour_change:** after the edit, the requirement or scenario would allow something different. Do not edit the spec. Ask the user whether to change the behaviour (the spec, then the code) or the code to fit the spec. Only on their approval: follow the apply drift rule (an `amend specs` commit with the trailer `Amendment: behaviour-change`, a new design review step when the tier is FULL, test and code updates), then run a new pre-ship review.
   - You may treat a clarification as a behaviour change and ask; never the other way round.
6. **Report:** the route and receipt, the findings by priority, what was fixed, amended or waived, and the P2/P3 findings left open.

## Gate

`<sw> review gate --change <change-name> --branch <prefix>/<change-name> --prefix <P>` (store-backed: `--store <store toplevel>`) prints `status`:
- `pass`: a record for the current head (or the head before the change's archive commit) has no unwaived P0/P1. Continue.
- `missing`: no record for this head (a new commit, another machine, a lost state dir). Run the pre-ship review.
- `blocked`: the record has open P0/P1 findings (`open`). Go to Pre-ship review step 3.
Records are machine-local (ADR 0007), so a `missing` from another checkout only costs a review.

## Archive-only check

`specwright-pr` watch runs `<sw> review archive-only --base <ready head> --head <archive head> --change <change-name> --dir <planning repo toplevel> --prefix <P>` after the archive push. `archive_only: true` means the only commit is the change's `archive change` commit and it touches only the archive paths and the synced main specs.

## Credits

The reviewer brief and findings format draw on compound-engineering's [`ce-code-review`](https://github.com/EveryInc/compound-engineering-plugin) skill and oh-my-pi's [`reviewer.md`](https://github.com/can1357/oh-my-pi) agent.
