"use strict";
/**
 * Loop Resolver — ADR-857 phase 3c registry-consuming query
 *
 * Given a loop point (one of the 12 canonical points from loop-host-contract.cjs),
 * filters the materialized Capability Registry by config activation and returns
 * the active hooks as a JSON envelope with a rendered-markdown field.
 *
 * REGISTRY-ONLY: no workflow calls this yet (phase-6 cutover is out of scope).
 *
 * Command surface: gsd-tools loop render-hooks <point>
 *
 * Exports (three things):
 *   resolveLoopHooks({ point, registry, config }) → { point, activeHooks }
 *   renderLoopHooks(resolved) → markdown string
 *   cmdLoopRenderHooks(cwd, point, raw, options) — I/O entry point
 *
 * Both pure functions (resolveLoopHooks, renderLoopHooks) take explicit
 * registry/config arguments so they are trivially testable without I/O.
 *
 * Dependencies (leaf modules only — no core.cjs circular risk):
 *   - node:fs / node:path  (raw config.json read for capability-key activation)
 *   - ./config-loader.cjs  (loadConfig)
 *   - ./planning-workspace.cjs  (planningDir — to locate config.json)
 *   - ./core.cjs           (output, error)
 *   - loop-host-contract.cjs (CANONICAL_POINTS via LOOP_HOST_CONTRACT)
 *   - capability-registry.cjs (byLoopPoint, consumed at call time)
 */
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
const node_fs_1 = __importDefault(require("node:fs"));
const node_path_1 = __importDefault(require("node:path"));
// eslint-disable-next-line @typescript-eslint/no-require-imports
const core = require("./core.cjs");
const { output: coreOutput, error: coreError } = core;
// eslint-disable-next-line @typescript-eslint/no-require-imports
const configLoaderModule = require("./config-loader.cjs");
const { loadConfig } = configLoaderModule;
// eslint-disable-next-line @typescript-eslint/no-require-imports
const planningWorkspaceMod = require("./planning-workspace.cjs");
const { planningDir, planningRoot } = planningWorkspaceMod;
// ─── Canonical points (derived from LOOP_HOST_CONTRACT — authoritative 12) ───
// FIX 2: Derive the authoritative canonical set from LOOP_HOST_CONTRACT so it
// cannot drift from the host contract. CANONICAL_POINTS_FALLBACK is kept as an
// alias for backward compatibility in tests and exports.
// eslint-disable-next-line @typescript-eslint/no-require-imports
const _loopHostContract = require('./loop-host-contract.cjs');
const CANONICAL_POINTS = (() => {
    try {
        const contract = _loopHostContract.LOOP_HOST_CONTRACT;
        if (Array.isArray(contract)) {
            const pts = [];
            for (const step of contract) {
                if (step && Array.isArray(step.points)) {
                    for (const p of step.points) {
                        if (typeof p === 'string')
                            pts.push(p);
                    }
                }
            }
            if (pts.length > 0)
                return pts;
        }
    }
    catch { /* fall through to hardcoded fallback */ }
    return [
        'discuss:pre',
        'discuss:post',
        'plan:pre',
        'plan:post',
        'execute:pre',
        'execute:wave:pre',
        'execute:wave:post',
        'execute:post',
        'verify:pre',
        'verify:post',
        'ship:pre',
        'ship:post',
    ];
})();
// Alias for backward compatibility (tests import this name)
const CANONICAL_POINTS_FALLBACK = CANONICAL_POINTS;
// FIX 2: _getCanonicalPoints now returns the authoritative CANONICAL_POINTS set
// derived from LOOP_HOST_CONTRACT — not the registry's byLoopPoint keys.
// The registry's byLoopPoint is only used to READ hooks, not to define valid points.
function _getCanonicalPoints(_registry) {
    return CANONICAL_POINTS;
}
// ─── Prototype-pollution guard (inline literal, CodeQL barrier) ───────────────
/**
 * Traverse a dotted config key through a nested config object.
 * E.g. "workflow.ui_phase" in { workflow: { ui_phase: true } } → { found: true, value: true }
 * Returns { found: false } if any segment is a forbidden key or not an own property.
 */
function _getNestedConfigValue(config, dotKey) {
    const segments = dotKey.split('.');
    let current = config;
    for (const seg of segments) {
        // Inline literal prototype-pollution guard (CodeQL barrier)
        if (seg === '__proto__' || seg === 'constructor' || seg === 'prototype') {
            return { found: false, value: undefined };
        }
        if (typeof current !== 'object' || current === null) {
            return { found: false, value: undefined };
        }
        const cur = current;
        if (!Object.prototype.hasOwnProperty.call(cur, seg)) {
            return { found: false, value: undefined };
        }
        current = cur[seg];
    }
    return { found: true, value: current };
}
// ─── Single-key activation resolver (FIX 1) ───────────────────────────────────
/**
 * Warn-once set for raw config.json parse errors.
 * Avoids noisy per-call stderr from a single malformed file.
 */
const _warnedRawConfigPaths = new Set();
/**
 * Read a raw config.json file and perform a guarded nested-lookup of a single
 * dotted key. Returns { found: false } if the file is missing (ENOENT) or if
 * the key is absent/forbidden. On a genuine JSON parse error: warns once to
 * stderr and returns { found: false } — never throws.
 */
function _readRawConfigKey(filePath, dotKey) {
    try {
        const raw = node_fs_1.default.readFileSync(filePath, 'utf8');
        let parsed;
        try {
            parsed = JSON.parse(raw);
        }
        catch {
            if (!_warnedRawConfigPaths.has(filePath)) {
                _warnedRawConfigPaths.add(filePath);
                try {
                    process.stderr.write(`gsd-tools: warning: failed to parse ${filePath} as JSON — skipping for activation resolution\n`);
                }
                catch { /* stderr might be closed */ }
            }
            return { found: false, value: undefined };
        }
        return _getNestedConfigValue(parsed, dotKey);
    }
    catch {
        // ENOENT (missing file) is expected → skip silently. All other errors → also skip (defensive).
        return { found: false, value: undefined };
    }
}
/**
 * FIX 1: Resolve the effective value for a hook's `when` key using the
 * four-level precedence:
 *
 * 1. loadConfig result (`config` arg) — guarded nested-lookup of the dotted key.
 *    This is the post-cutover federated path (covers keys that loadConfig now exposes).
 * 2. Raw workstream `.planning/.../config.json` — guarded single-key lookup.
 *    Workstream wins over root (mirrors loadConfig inheritance).
 * 3. Raw root `.planning/config.json` — guarded single-key lookup.
 * 4. `registry.configSchema[when]?.default` — schema default.
 *    A `default: true` hook is active out-of-the-box without any config.
 * 5. Absent → inactive (return false).
 *
 * Never constructs a merged object from raw JSON keys — only reads the single
 * leaf value at the guarded dotted path.  Prototype-pollution sink is eliminated.
 */
function _resolveActivationValue(dotKey, config, cwd, registry) {
    // Level 1: loadConfig result
    const fromConfig = _getNestedConfigValue(config, dotKey);
    if (fromConfig.found)
        return Boolean(fromConfig.value);
    // Level 2 + 3: raw config.json files (only when cwd is available)
    if (cwd) {
        // Level 2: workstream config (planningDir respects GSD_WORKSTREAM env)
        const wsConfigPath = node_path_1.default.join(planningDir(cwd), 'config.json');
        // Level 3: root config (planningRoot = cwd/.planning always)
        const rootConfigPath = node_path_1.default.join(planningRoot(cwd), 'config.json');
        // Workstream wins over root (mirroring loadConfig root→workstream precedence:
        // workstream overlays root, so workstream value takes precedence).
        const fromWs = _readRawConfigKey(wsConfigPath, dotKey);
        if (fromWs.found)
            return Boolean(fromWs.value);
        // Only read root if it differs from the workstream path (avoids double-read
        // when no workstream is active and both paths resolve to the same file).
        if (wsConfigPath !== rootConfigPath) {
            const fromRoot = _readRawConfigKey(rootConfigPath, dotKey);
            if (fromRoot.found)
                return Boolean(fromRoot.value);
        }
    }
    // Level 4: registry configSchema default
    const schemaEntry = registry['configSchema']?.[dotKey];
    if (schemaEntry && typeof schemaEntry === 'object' && schemaEntry !== null) {
        const def = schemaEntry['default'];
        if (def !== undefined)
            return Boolean(def);
    }
    // Level 5: absent → inactive
    return false;
}
// ─── Pure resolver ─────────────────────────────────────────────────────────────
/**
 * Pure resolver: given a point, registry, and config, returns the active hooks.
 *
 * Throws if `point` is not one of the 12 canonical points (caller converts to
 * core.error). Never throws for malformed registry/hook entries — skips and
 * continues.
 *
 * Ordering: steps first, then contributions, then gates. Within each array,
 * the materialized registry order is preserved.
 *
 * Activation: a hook with no `when` is always active. With `when` (dotted key),
 * resolved against `config`; active iff truthy. Inactive hooks are filtered out.
 */
function resolveLoopHooks(input) {
    const { point, registry, config, cwd } = input;
    // Validate point
    const canonicalPoints = _getCanonicalPoints(registry);
    if (!canonicalPoints.includes(point)) {
        throw new Error(`Invalid loop point: "${point}". Valid points: ${canonicalPoints.join(', ')}`);
    }
    // Guard: registry missing byLoopPoint
    const byLoopPoint = registry['byLoopPoint'];
    if (!byLoopPoint || typeof byLoopPoint !== 'object' || Array.isArray(byLoopPoint)) {
        return { point, activeHooks: [] };
    }
    const byLoopPointMap = byLoopPoint;
    // Guard: point missing in registry
    const entry = byLoopPointMap[point];
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) {
        return { point, activeHooks: [] };
    }
    const entryMap = entry;
    const activeHooks = [];
    // Helper: check activation using single-key precedence resolver (FIX 1 + FIX 3)
    function isActive(hook) {
        const when = hook['when'];
        // No `when` → unconditional hook, always active
        if (when === undefined || when === null)
            return true;
        // FIX 3: `when` present but not a non-empty string → malformed registry data → INACTIVE
        if (typeof when !== 'string' || when.length === 0)
            return false;
        return _resolveActivationValue(when, config, cwd, registry);
    }
    // Helper: safe string array
    function toStringArray(v) {
        if (!Array.isArray(v))
            return [];
        return v.filter((x) => typeof x === 'string');
    }
    // Process steps
    const stepsRaw = entryMap['steps'];
    const steps = Array.isArray(stepsRaw) ? stepsRaw : [];
    for (const hook of steps) {
        if (!hook || typeof hook !== 'object')
            continue;
        if (!isActive(hook))
            continue;
        const capId = typeof hook['capId'] === 'string' ? hook['capId'] : '';
        const ref = (typeof hook['ref'] === 'object' && hook['ref'] !== null)
            ? hook['ref']
            : undefined;
        const when = typeof hook['when'] === 'string' ? hook['when'] : undefined;
        const produces = toStringArray(hook['produces']);
        const consumes = toStringArray(hook['consumes']);
        const onError = typeof hook['onError'] === 'string' ? hook['onError'] : undefined;
        const active = { capId, kind: 'step' };
        if (ref !== undefined)
            active.ref = ref;
        if (when !== undefined)
            active.when = when;
        if (produces.length > 0)
            active.produces = produces;
        if (consumes.length > 0)
            active.consumes = consumes;
        if (onError !== undefined)
            active.onError = onError;
        activeHooks.push(active);
    }
    // Process contributions
    const contributionsRaw = entryMap['contributions'];
    const contributions = Array.isArray(contributionsRaw) ? contributionsRaw : [];
    for (const hook of contributions) {
        if (!hook || typeof hook !== 'object')
            continue;
        if (!isActive(hook))
            continue;
        const capId = typeof hook['capId'] === 'string' ? hook['capId'] : '';
        const into = typeof hook['into'] === 'string' ? hook['into'] : undefined;
        const when = typeof hook['when'] === 'string' ? hook['when'] : undefined;
        const produces = toStringArray(hook['produces']);
        const consumes = toStringArray(hook['consumes']);
        const onError = typeof hook['onError'] === 'string' ? hook['onError'] : undefined;
        const active = { capId, kind: 'contribution' };
        if (into !== undefined)
            active.into = into;
        if (when !== undefined)
            active.when = when;
        if (produces.length > 0)
            active.produces = produces;
        if (consumes.length > 0)
            active.consumes = consumes;
        if (onError !== undefined)
            active.onError = onError;
        activeHooks.push(active);
    }
    // Process gates
    const gatesRaw = entryMap['gates'];
    const gates = Array.isArray(gatesRaw) ? gatesRaw : [];
    for (const hook of gates) {
        if (!hook || typeof hook !== 'object')
            continue;
        if (!isActive(hook))
            continue;
        const capId = typeof hook['capId'] === 'string' ? hook['capId'] : '';
        const when = typeof hook['when'] === 'string' ? hook['when'] : undefined;
        const check = hook['check'] !== undefined ? hook['check'] : undefined;
        const blocking = typeof hook['blocking'] === 'boolean' ? hook['blocking'] : undefined;
        const onError = typeof hook['onError'] === 'string' ? hook['onError'] : undefined;
        const active = { capId, kind: 'gate' };
        if (when !== undefined)
            active.when = when;
        if (check !== undefined)
            active.check = check;
        if (blocking !== undefined)
            active.blocking = blocking;
        if (onError !== undefined)
            active.onError = onError;
        activeHooks.push(active);
    }
    return { point, activeHooks };
}
// ─── Pure renderer ─────────────────────────────────────────────────────────────
/**
 * Pure renderer: given a resolved result, returns a deterministic markdown string.
 *
 * Empty active set → returns a "no active hooks" placeholder line.
 * Steps: heading with ordinal + skill ref + capId, produces/consumes lines.
 * Contributions: labeled block.
 * Gates: check name, blocking flag, onError.
 */
function renderLoopHooks(resolved) {
    const { point, activeHooks } = resolved;
    if (activeHooks.length === 0) {
        return `_No active hooks at ${point}._`;
    }
    const lines = [];
    let stepOrdinal = 0;
    for (const hook of activeHooks) {
        if (hook.kind === 'step') {
            stepOrdinal += 1;
            const refStr = hook.ref?.skill
                ? `skill:${hook.ref.skill}`
                : JSON.stringify(hook.ref ?? {});
            lines.push(`### Step ${stepOrdinal}: ${refStr} (${hook.capId})`);
            if (hook.produces && hook.produces.length > 0) {
                lines.push(`- produces: ${hook.produces.join(', ')}`);
            }
            if (hook.consumes && hook.consumes.length > 0) {
                lines.push(`- consumes: ${hook.consumes.join(', ')}`);
            }
            if (hook.when) {
                lines.push(`- when: \`${hook.when}\``);
            }
            if (hook.onError) {
                lines.push(`- onError: ${hook.onError}`);
            }
            lines.push('');
        }
        else if (hook.kind === 'contribution') {
            lines.push(`<contribution from="${hook.capId}" into="${hook.into ?? '(unset)'}"/>`);
            if (hook.produces && hook.produces.length > 0) {
                lines.push(`- produces: ${hook.produces.join(', ')}`);
            }
            if (hook.consumes && hook.consumes.length > 0) {
                lines.push(`- consumes: ${hook.consumes.join(', ')}`);
            }
            if (hook.when) {
                lines.push(`- when: \`${hook.when}\``);
            }
            lines.push('');
        }
        else if (hook.kind === 'gate') {
            let checkStr = '(none)';
            if (hook.check !== undefined && hook.check !== null) {
                checkStr = typeof hook.check === 'object'
                    ? JSON.stringify(hook.check)
                    : typeof hook.check === 'string' || typeof hook.check === 'number' || typeof hook.check === 'boolean'
                        ? String(hook.check)
                        : '(complex)';
            }
            lines.push(`**Gate** (${hook.capId}): check=${checkStr}, blocking=${String(hook.blocking ?? false)}, onError=${hook.onError ?? 'skip'}`);
            if (hook.when) {
                lines.push(`- when: \`${hook.when}\``);
            }
            lines.push('');
        }
    }
    // Trim trailing blank line
    while (lines.length > 0 && lines[lines.length - 1] === '') {
        lines.pop();
    }
    return lines.join('\n');
}
// ─── I/O command handler ───────────────────────────────────────────────────────
/**
 * Command entry point: load registry + config, resolve + render, emit envelope.
 *
 * Envelope: { point, activeHooks, rendered }
 * On invalid point, emits core.error instead of throwing.
 *
 * Config note: FIX 1 replaced _loadMergedConfig (whole-config deep-merge) with a
 * per-hook single-key activation resolver (_resolveActivationValue). The resolver
 * checks loadConfig result first, then raw config.json files directly (workstream
 * then root), then the registry's configSchema default. This eliminates the
 * merged-object-from-untrusted-keys security concern and correctly handles
 * pre-cutover keys like `workflow.ui_phase` that live in config.json but are not
 * yet exposed through loadConfig's whitelist.
 */
function cmdLoopRenderHooks(cwd, point, raw, _options = {}) {
    if (!point) {
        coreError('loop render-hooks requires a <point> argument. Valid points: ' + CANONICAL_POINTS.join(', '));
        return;
    }
    // Load registry at call time (generated file, not at module load time)
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const registry = require('./capability-registry.cjs');
    // FIX 1: Pass loadConfig result as `config` (level 1 of precedence);
    // raw config.json reads (levels 2+3) happen per-hook inside _resolveActivationValue
    // via the `cwd` argument passed to resolveLoopHooks.
    const config = loadConfig(cwd);
    let resolved;
    try {
        resolved = resolveLoopHooks({ point, registry, config, cwd });
    }
    catch (err) {
        const msg = (err instanceof Error) ? err.message : String(err);
        coreError(msg);
        return;
    }
    const rendered = renderLoopHooks(resolved);
    const envelope = {
        point: resolved.point,
        activeHooks: resolved.activeHooks,
        rendered,
    };
    coreOutput(envelope, raw);
}
module.exports = {
    resolveLoopHooks,
    renderLoopHooks,
    cmdLoopRenderHooks,
    // Exported for tests
    _getNestedConfigValue,
    _resolveActivationValue,
    _readRawConfigKey,
    CANONICAL_POINTS_FALLBACK,
    CANONICAL_POINTS,
};
