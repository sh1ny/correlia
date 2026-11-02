#!/usr/bin/env bash
# Single branch-read and write boundary for Git and colocated jj repositories.
set -euo pipefail

py=
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1; then py=$c; break; fi
done
[ -n "$py" ] || { echo '{"ok":false,"error":"no_python","message":"vcs.sh needs python 3.8+"}'; exit 2; }
VCS_DIR=$(cd "$(dirname "$0")" && pwd -P)
VCS_BASH=${BASH:-bash}
if command -v cygpath >/dev/null 2>&1; then VCS_DIR=$(cygpath -m "$VCS_DIR"); VCS_BASH=$(cygpath -w "$VCS_BASH"); fi
export VCS_DIR VCS_BASH
exec "$py" -I -X utf8 - "$@" <<'PYSRC'
import json
import os
import posixpath
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import urlsplit

VCS_DIR = Path(os.environ["VCS_DIR"])
BASH = os.environ.get("VCS_BASH") or shutil.which("bash") or "bash"
PR_PAIR = VCS_DIR / "pr-pair.sh"
AS_SH = VCS_DIR / "as.sh"
SETTINGS_FILE = "openspec/specwright.yaml"  # what every step reads from the code work tree


class Stop(Exception):
    def __init__(self, error, message, code=1, **extra):
        super().__init__(message)
        self.error, self.message, self.code, self.extra = error, message, code, extra

    def object(self):
        return {"ok": False, "error": self.error, "message": self.message, **self.extra}


def emit(obj, code=0):
    print(json.dumps(obj, ensure_ascii=False).replace("\u2028", "\\u2028").replace("\u2029", "\\u2029"))
    raise SystemExit(code)


def usage(message):
    raise Stop("usage", message, 2)


def process_arguments(argv):
    args = list(map(str, argv))
    if os.name != "nt":
        return args
    # MSYS expands unquoted braces and wildcards in native Windows argv.
    # Quote every argument, including those list2cmdline leaves unquoted.
    quoted = []
    for arg in args:
        arg = re.sub(r'(\\*)"', lambda match: "\\" * (2 * len(match.group(1)) + 1) + '"', arg)
        arg = re.sub(r'(\\+)$', lambda match: match.group(1) * 2, arg)
        quoted.append('"' + arg + '"')
    return " ".join(quoted)


def run(argv, cwd=None, env=None, input=None):
    try:
        return subprocess.run(process_arguments(argv), cwd=str(cwd) if cwd else None,
                              env=env or os.environ.copy(), capture_output=True, text=True, input=input,
                              encoding="utf-8", errors="surrogateescape")  # git and jj write UTF-8, whatever the locale
    except OSError as exc:
        return subprocess.CompletedProcess(argv, 127, "", str(exc))


def bash_command(repo, *args, env=None, input=None):
    return run([BASH, "-c", 'exec "$@"', "vcs", *args], cwd=repo, env=env, input=input)


def bash_script(repo, script, *args, env=None):
    return run([BASH, str(script), *args], cwd=repo, env=env)


def git(repo, *args, env=None, input=None):
    return bash_command(repo, "git", *args, env=env, input=input)


def jj(repo, *args):
    return bash_command(repo, "jj", *args)


def path_text(path):
    return str(path).replace("\\", "/")


def parse_porcelain(out):
    """`git status --porcelain -z`: unquoted names, NUL-ended; a rename or copy is followed by its source."""
    paths, entries = [], []
    records = out.split("\0")
    while records:
        record = records.pop(0)
        if len(record) < 4:
            continue
        status, name = record[:2], path_text(record[3:])
        entry = {"status": status, "path": name}
        paths.append(name)
        if "R" in status or "C" in status:
            entry["from"] = path_text(records.pop(0)) if records else ""
            paths.append(entry["from"])
        entries.append(entry)
    return paths, entries


def git_root(repo):
    result = git(repo, "rev-parse", "--show-toplevel")
    if result.returncode:
        raise Stop("not_repository", "not inside a Git work tree: " + result.stderr.strip())
    return Path(result.stdout.strip()).resolve()


def get_settings(code, repo, role):
    result = bash_script(None, PR_PAIR, "vcs", "--code", str(code))
    if result.returncode:
        try:
            data = json.loads(result.stdout)
        except ValueError:
            data = {"error": "settings_error", "message": result.stderr.strip() or result.stdout.strip()}
        raise Stop(data.get("error", "settings_error"), data.get("message", "could not read VCS settings"),
                   min(result.returncode, 3))
    try:
        choices = json.loads(result.stdout)
    except ValueError:
        raise Stop("settings_error", "pr-pair.sh vcs returned invalid JSON")
    backend = choices.get("code" if role == "code" else "store")
    if backend not in ("git", "jj", "gitbutler") or (backend == "gitbutler" and role != "code"):
        raise Stop("settings_error", "pr-pair.sh vcs did not return a valid backend")
    context_args = ["context", "--code", str(code), "--only", "repos"]  # login and main only: merge settings are not validated
    if role == "store":
        context_args.extend(("--store", str(repo)))
    context = bash_script(None, PR_PAIR, *context_args)
    try:
        ctx = json.loads(context.stdout)
    except ValueError:
        raise Stop("settings_error", "pr-pair.sh context returned invalid JSON")
    if context.returncode:
        raise Stop(ctx.get("error", "settings_error"), ctx.get("message", "could not read repository settings"),
                   min(context.returncode, 3))
    item = (ctx.get("store") if role == "store" else ctx.get("code")) or {}
    main = str(item.get("main") or "")
    return backend, main, {"login": str(item.get("login") or "")}


def detect_main(repo, configured):
    if configured:
        return configured
    for name in ("main", "master"):
        if git(repo, "show-ref", "--verify", "--quiet", "refs/heads/" + name).returncode == 0:
            return name
    return "main"


def gitbutler_managed(root):
    """Git reads only: `.git/gitbutler/` in the common git dir and a `gitbutler.project.targetRef`; returns the target or None."""
    common = git(root, "rev-parse", "--git-common-dir")
    common_dir = (root / common.stdout.strip()) if common.returncode == 0 and common.stdout.strip() else root / ".git"
    if not (common_dir / "gitbutler").is_dir():
        return None
    target = git(root, "config", "--get", "gitbutler.project.targetRef")
    return target.stdout.strip() if target.returncode == 0 and target.stdout.strip() else None


def probe_gitbutler(repo, configured_main, settings):
    root = git_root(repo)
    main = detect_main(root, configured_main)
    target = gitbutler_managed(root)
    if target is None:
        raise Stop("not_managed", "vcs: gitbutler selected, but GitButler does not manage this repo (no .git/gitbutler/ "
                   "and gitbutler.project.targetRef); open the repo with GitButler first (the app, or run `but status` "
                   "yourself); Specwright never sets it up")
    if target not in ("refs/heads/" + main, "refs/remotes/origin/" + main):
        raise Stop("target_mismatch", "GitButler target is %s, but the main branch is %s (expected refs/heads/%s or "
                   "refs/remotes/origin/%s)" % (target, main, main, main))
    with tempfile.TemporaryDirectory(prefix="swb-probe-") as outside:  # installed skills live inside the code checkout
        version = bash_command(outside, "but", "--version")
    if version.returncode == 127:
        raise Stop("tool_missing", "vcs: gitbutler is selected but but is not installed or not on PATH: but")
    found = re.search(r"\b(\d+)\.(\d+)\.(\d+)", version.stdout + version.stderr)
    if version.returncode or not found:
        raise Stop("tool_version_unknown", "could not determine but version from but --version")
    current = tuple(map(int, found.groups()))
    if current < (0, 23, 0):
        raise Stop("tool_too_old", "but version %s.%s.%s is too old; minimum supported version is 0.23" % current)
    return {"backend": "gitbutler", "main": main, "repo": str(root), "login": settings["login"]}


def probe(repo, code, role):
    backend, configured_main, settings = get_settings(code, repo, role)
    if backend == "gitbutler":
        return probe_gitbutler(repo, configured_main, settings)
    if backend == "jj":
        version = jj(repo, "--version")
        if version.returncode == 127:
            raise Stop("tool_missing", "jj is selected but jj is not installed or not on PATH: jj")
        found = re.search(r"\b(\d+)\.(\d+)\.(\d+)", version.stdout + version.stderr)
        if version.returncode or not found:
            raise Stop("tool_version_unknown", "could not determine jj version from jj --version")
        current = tuple(map(int, found.groups()))
        if current < (0, 46, 0):
            raise Stop("tool_too_old", "jj version %s.%s.%s is too old; minimum supported version is 0.46" % current)
        try:
            root = git_root(repo)
        except Stop:
            if (repo / ".jj").exists():
                raise Stop("not_colocated", "jj workspace has no Git work tree at the same toplevel")
            raise Stop("not_managed", "vcs: jj selected, but no .jj/ metadata was found")
        if not (root / ".jj").exists():
            raise Stop("not_managed", "vcs: jj selected, but the Git work tree has no .jj/ metadata")
        main = detect_main(root, configured_main)
        jroot = jj(repo, "root")
        if jroot.returncode or Path(jroot.stdout.strip()).resolve() != root:
            raise Stop("not_colocated", "jj workspace and Git work tree do not share the same toplevel")
        return {"backend": "jj", "main": main, "repo": str(root), "login": settings["login"]}
    root = git_root(repo)
    main = detect_main(root, configured_main)
    if backend == "git":
        if gitbutler_managed(root) is not None:
            raise Stop("gitbutler_workspace", "GitButler manages this repo, and the Git backend must not write in its "
                       "workspace: set vcs: gitbutler (with finish: pr) in openspec/specwright.yaml, or take the repo "
                       "out of GitButler before using Git")
        return {"backend": "git", "main": main, "repo": str(root), "login": settings["login"],
                "jj_present": (root / ".jj").exists()}


def context(argv):
    if len(argv) < 1:
        usage("missing command")
    command, args = argv[0], argv[1:]
    allowed = {"--repo": "repo", "--role": "role", "--code": "code", "--branch": "branch",
               "--message-file": "message_file", "--scope": "scope", "--operation": "operation",
               "--login": "login", "--main": "main", "--prefix": "prefix", "--merged-commit": "merged_commit"}
    flags = {"--force": "force", "--no-tags": "no_tags", "--quiet": "quiet", "--remote-branch": "remote_branch"}
    opts, paths, after = {}, [], False
    i = 0
    while i < len(args):
        value = args[i]
        if after:
            paths.append(value)
            i += 1
        elif value == "--":
            after = True
            i += 1
        elif value in allowed:
            if i + 1 >= len(args):
                usage(value + " requires a value")
            opts[allowed[value]] = args[i + 1]
            i += 2
        elif value in flags:
            opts[flags[value]] = True
            i += 1
        else:
            usage("unknown option: " + value)
    if command not in {"probe", "state", "branch-create", "switch", "commit", "merge", "delete-branch",
                       "fetch-main", "pull", "push", "advance", "plan"}:
        usage("unknown command: " + command)
    if not opts.get("repo") or opts.get("role") not in ("code", "store"):
        usage("usage: vcs.sh <command> --repo <dir> --role code|store [--code <dir>] [options] [-- paths...]")
    if opts["role"] == "store" and not opts.get("code"):
        usage("--code is required when --role store")
    if opts["role"] == "code" and not opts.get("code"):
        opts["code"] = opts["repo"]
    if not Path(opts["repo"]).is_dir() or not Path(opts["code"]).is_dir():
        raise Stop("not_repository", "--repo and --code must name existing directories")
    return command, opts, paths


def require_branch(opts):
    if not opts.get("branch"):
        usage("missing --branch")
    return opts["branch"]


def git_current(repo):
    result = git(repo, "branch", "--show-current")
    if result.returncode:
        raise Stop("git_error", result.stderr.strip() or "git branch --show-current failed")
    return result.stdout.strip()


def git_state(repo, info, scope=None):
    branch = git_current(repo)
    status = git(repo, "status", "--porcelain", "-z")
    if status.returncode:
        raise Stop("git_error", status.stderr.strip() or "git status --porcelain -z failed")
    paths, entries = parse_porcelain(status.stdout)
    return {"ok": True, "backend": "git", "main": info["main"], "branch": branch,
            "on_main": branch == info["main"], "clean": not paths, "dirty_paths": paths,
            "dirty": entries, "behind": [], "behind_truncated": False,
            **({"jj_present": True} if info.get("jj_present") else {})}


def jj_result(repo, *args):
    result = jj(repo, *args)
    if result.returncode:
        raise Stop("jj_error", result.stderr.strip() or result.stdout.strip() or "jj command failed")
    return result.stdout


def jj_log(repo, revset, template, limit=None):
    args = ["log", "--no-graph", "--color=never", "-r", revset, "-T", template]
    if limit is not None:
        args.extend(("-n", str(limit)))
    return jj_result(repo, *args)


# stringify() keeps the conditional lazy: a conflicted bookmark has no normal_target.
BOOKMARK_TEMPLATE = ('if(remote, "", json({"name" => name, "conflict" => conflict, '
                     '"target" => stringify(if(normal_target, normal_target.commit_id(), ""))})) ++ "\\n"')


def jj_state(repo, info, scope=None):
    parent_text = jj_log(repo, "@", 'parents.map(|c| json(c.commit_id())).join("\\t") ++ "\\n"').strip()
    parent_ids = [json.loads(item) for item in parent_text.split("\t")] if parent_text else []
    if len(parent_ids) != 1:
        raise Stop("ambiguous_branch", "working copy @ must have exactly one parent; found %d" % len(parent_ids))
    parent = parent_ids[0]
    template = BOOKMARK_TEMPLATE
    bookmarks_raw = jj_result(repo, "bookmark", "list", "--revision", "@-", "-T", template)
    bookmarks = []
    for line in bookmarks_raw.splitlines():
        if not line.strip():
            continue
        try:
            item = json.loads(line)
        except ValueError:
            raise Stop("jj_error", "jj bookmark list returned invalid JSON")
        if item.get("name"):
            bookmarks.append(item)
    main_names = {info["main"]}
    candidates = [b["name"] for b in bookmarks if b.get("name") != info["main"]]
    main_at_parent = any(b.get("name") == info["main"] for b in bookmarks)
    relevant_names = set(candidates) | main_names
    scoped = []
    if scope:
        scoped_raw = jj_result(repo, "bookmark", "list", scope, "glob:**/" + scope, "-T", template)
        scoped = [json.loads(line) for line in scoped_raw.splitlines() if line.strip()]
        scoped = [b for b in scoped if b.get("name") == scope or b.get("name", "").endswith("/" + scope)]
        relevant_names.update(b["name"] for b in scoped)
    conflicts = []
    for name in sorted(relevant_names):
        conflicted = jj_result(repo, "bookmark", "list", "--conflicted", name, "-T", template)
        conflicts.extend(json.loads(line)["name"] for line in conflicted.splitlines() if line.strip())
    if conflicts:
        raise Stop("ambiguous_branch", "conflicted local bookmark(s): " + ", ".join(sorted(set(conflicts))))
    if len(candidates) > 1:
        raise Stop("ambiguous_branch", "multiple local bookmarks point at @-: " + ", ".join(sorted(candidates)))
    branch = candidates[0] if candidates else ""
    selected = next((b for b in bookmarks if b.get("name") == branch), None)
    behind, truncated = [], False
    if not branch and scope:
        scoped = [b for b in scoped if b.get("target") and b["name"] != info["main"]]
        if len(scoped) == 1 and git_ancestor(repo, scoped[0]["target"], parent):
            selected = scoped[0]
            branch = selected["name"]
    if branch and scope and selected and selected.get("target") and selected["target"] != parent:
        template = 'json({"commit" => commit_id, "subject" => description.first_line(), "parents" => parents.len()}) ++ "\\n"'
        revset = selected["target"] + ".." + parent
        record = jj_log(repo, revset, template, limit=51)
        behind = [json.loads(line) for line in record.splitlines() if line.strip()]
        if len(behind) > 50:
            behind, truncated = behind[:50], True
        if any(item.get("parents", 0) != 1 for item in behind):
            raise Stop("ambiguous_branch", "bookmark recovery range is not linear")
    status = jj_result(repo, "diff", "--summary", "-r", "@")
    entries = []
    for line in status.splitlines():
        if len(line) >= 3 and line[0] in "AMDRC" and line[1].isspace():
            entries.append({"status": line[0], "path": path_text(line[2:])})
    paths = [entry["path"] for entry in entries]
    return {"ok": True, "backend": "jj", "main": info["main"], "branch": branch,
            "on_main": not branch and main_at_parent, "clean": not paths,
            "dirty_paths": paths, "dirty": entries, "behind": behind, "behind_truncated": truncated}



BUT_STATUS_CAP = 16 * 1024 * 1024  # `but status --json` is read up to this many bytes (design: Resource Bounds)


def but_run(root, *args, cap=None):
    """Run `but` in the repo and return its stdout; with `cap`, stop reading past that many bytes."""
    argv = [BASH, "-c", 'exec "$@"', "vcs", "but", *args]
    with tempfile.TemporaryFile() as errors:
        try:
            proc = subprocess.Popen(process_arguments(argv), cwd=str(root), env=os.environ.copy(),
                                    stdout=subprocess.PIPE, stderr=errors)
        except OSError as exc:
            raise Stop("tool_missing", "but could not run: " + str(exc))
        data = proc.stdout.read(cap + 1) if cap else proc.stdout.read()
        if cap and len(data) > cap:
            proc.kill()
            proc.stdout.close()
            proc.wait()
            raise Stop("but_output_too_large", "but %s printed more than %d bytes; nothing was changed" % (args[0], cap))
        proc.stdout.close()
        code = proc.wait()
        errors.seek(0)
        stderr = errors.read().decode("utf-8", errors="replace")
    out = data.decode("utf-8", errors="replace")
    if code:
        message = (stderr or out).strip() or "but %s failed" % " ".join(args)
        if args[0] not in ("status", "--version"):
            message += autocrlf_hint(root)
        raise Stop("but_error", message)
    return out


AUTOCRLF_HINT = "hint: core.autocrlf is true; GitButler checkouts can conflict on line endings"


def autocrlf_hint(root):
    """A failed `but` write in a repo whose effective core.autocrlf is true gets the line-ending hint (design: Risks)."""
    found = git(root, "config", "--type=bool", "--get", "core.autocrlf")
    return "\n" + AUTOCRLF_HINT if found.returncode == 0 and found.stdout.strip() == "true" else ""


def but_status(root):
    """`but status --json`, the only read of the workspace: names and paths are the keys, never the short IDs."""
    try:
        status = json.loads(but_run(root, "status", "--json", cap=BUT_STATUS_CAP))
    except ValueError:
        raise Stop("but_error", "but status --json returned invalid JSON")
    if not isinstance(status, dict):
        raise Stop("but_error", "but status --json returned an unexpected document")
    return status


def stack_names(stack):
    return [b.get("name", "") for b in stack.get("branches") or []]


def change_file(entry):
    return path_text(entry.get("filePath") or entry.get("path") or "")


def gitbutler_state(root, info, opts):
    """D4: the change branch is the one the caller names; HEAD (the workspace commit or another branch) is never read."""
    branch = opts.get("branch") or ""
    status = but_status(root)
    stacks = status.get("stacks") or []
    applied_branches = [name for stack in stacks for name in stack_names(stack)]
    applied = bool(branch) and branch in applied_branches
    target = (status.get("mergeBase") or {}).get("commitId") or ""
    tip = ""
    if branch:
        found = git(root, "rev-parse", "--verify", "-q", "refs/heads/" + branch + "^{commit}")
        tip = found.stdout.strip() if found.returncode == 0 else ""
    if applied and tip:
        require_settings_pinned(root, branch, status)
    owner = {}  # path -> index of the stack that holds it
    for index, stack in enumerate(stacks):
        for entry in stack.get("assignedChanges") or []:
            owner.setdefault(change_file(entry), index)
    uncommitted = [change_file(entry) for entry in status.get("uncommittedChanges") or []]
    touched = set()
    if tip and target:
        diff = git(root, "diff", "--name-only", "--no-renames", "-z", target, tip)
        touched = set(path_text(name) for name in diff.stdout.split("\0") if name)
    change_dir = ""
    if branch:
        prefix = (opts.get("prefix") or "openspec").replace("\\", "/").strip("/")
        change_dir = "%s/changes/%s/" % (prefix, branch.split("/", 1)[1] if "/" in branch else branch)
    change_paths, unassigned_paths, other_paths = [], [], []
    for path, index in owner.items():
        if applied and branch in stack_names(stacks[index]):
            change_paths.append(path)
        else:
            names = stack_names(stacks[index])
            other_paths.append({"path": path, "branch": names[0] if names else ""})
    for path in uncommitted:
        if path in owner or path in unassigned_paths or path in change_paths:
            continue
        if branch and (path.startswith(change_dir) or path in touched):
            change_paths.append(path)  # the change's own: its artifacts, or a file the branch already touched
        else:
            unassigned_paths.append(path)
    paths = []
    for path in change_paths + unassigned_paths + [item["path"] for item in other_paths]:
        if path not in paths:
            paths.append(path)
    return {"ok": True, "backend": "gitbutler", "main": info["main"], "branch": branch if applied else "",
            "on_main": not applied, "applied": applied, "head": tip, "target": target,
            "applied_branches": applied_branches, "change_paths": change_paths, "unassigned_paths": unassigned_paths,
            "other_branch_paths": other_paths, "clean": not change_paths,
            "dirty_paths": paths, "dirty": [{"status": "", "path": path} for path in paths],
            "behind": [], "behind_truncated": False}


def require_settings_pinned(root, branch, status=None):
    """The settings every Specwright step reads from the shared work tree must be the change branch's own: a sibling
    branch's committed or assigned edit of openspec/specwright.yaml (its validate command, review.preship) stops."""
    status = status if status is not None else but_status(root)
    for stack in status.get("stacks") or []:
        names = stack_names(stack)
        if branch in names:
            continue
        if any(change_file(entry) == SETTINGS_FILE for entry in stack.get("assignedChanges") or []):
            raise Stop("settings_not_pinned", "%s holds an uncommitted edit of %s from branch %s; Specwright reads it from the "
                       "shared work tree, so unapply that branch or move the edit first" % (root, SETTINGS_FILE, names[0] if names else "?"))
    diff = git(root, "diff", "--quiet", "refs/heads/" + branch, "HEAD", "--", SETTINGS_FILE)
    if diff.returncode == 1:
        raise Stop("settings_not_pinned", "another applied branch changes %s, so the work tree's settings are not those of %s; "
                   "unapply that branch, or bring the change onto %s, first" % (SETTINGS_FILE, branch, branch))
    if diff.returncode not in (0, 1):
        raise Stop("git_error", "git diff of %s failed: %s" % (SETTINGS_FILE, diff.stderr.strip()))


def require_applied(root, branch):
    status = but_status(root)
    if branch not in [name for stack in status.get("stacks") or [] for name in stack_names(stack)]:
        raise Stop("branch_not_applied", "branch %s is not applied in the GitButler workspace; Specwright never applies "
                   "one (it can conflict with the other branches): apply it yourself, or choose another branch" % branch,
                   branch=branch)
    return status


def gitbutler_branch_create(root, info, opts):
    branch = require_branch(opts)
    if git(root, "show-ref", "--verify", "--quiet", "refs/heads/" + branch).returncode == 0:
        raise Stop("branch_exists", "branch %s already exists (applied or not): resume it, choose another name, or "
                   "abort; nothing was changed" % branch, branch=branch)
    but_run(root, "branch", "new", branch, "--json")
    status = but_status(root)
    stack = next((s for s in status.get("stacks") or [] if branch in stack_names(s)), None)
    target = (status.get("mergeBase") or {}).get("commitId") or ""
    found = git(root, "rev-parse", "--verify", "-q", "refs/heads/" + branch + "^{commit}")
    tip = found.stdout.strip() if found.returncode == 0 else ""
    mine = [b for b in (stack or {}).get("branches") or [] if b.get("name") == branch]
    if stack is None or not tip or tip != target or (mine and mine[0].get("commits")):
        raise Stop("branch_create_mismatch", "branch %s was created but is not applied on the target with no commits "
                   "(tip %s, target %s)" % (branch, tip or "-", target or "-"))
    return {"ok": True, "backend": "gitbutler", "branch": branch, "commit": tip, "applied": True}


def gitbutler_path(root, raw):
    """D5 step 5: repo-relative, `/` separators, no `./`; a directory ends in `/`. Globs and escapes stop."""
    text = raw.replace("\\", "/")
    if re.search(r"[*?\[\]{}]", text):
        raise Stop("bad_path", "%s contains glob characters; name the file or its directory" % raw, path=raw)
    is_dir = text.endswith("/") or os.path.isdir(os.path.join(root, text))
    norm = posixpath.normpath(text)
    if not text or norm in (".", "") or norm.startswith("/") or norm == ".." or norm.startswith("../") \
            or re.match(r"^[A-Za-z]:", norm) or ".git" in norm.split("/"):
        raise Stop("bad_path", "%s is not a path inside the repository" % raw, path=raw)
    return norm + "/" if is_dir else norm


def path_covers(named, changed):
    return changed == named or (named.endswith("/") and changed.startswith(named))


def gitbutler_commit(root, info, opts, paths):
    """D5: `but commit -b <branch> -F <file> --json <paths>` for the named paths only, then Git reads verify it."""
    branch = require_branch(opts)
    if not opts.get("message_file") or not paths:
        usage("commit requires --message-file and at least one path after --")
    status = require_applied(root, branch)
    named = []
    for raw in paths:
        path = gitbutler_path(root, raw)
        if path not in named:
            named.append(path)
    stacks = status.get("stacks") or []
    own = [s for s in stacks if branch in stack_names(s)]
    others = [s for s in stacks if branch not in stack_names(s)]
    for stack in others:  # a named path that covers another stack's change would move it silently
        for entry in stack.get("assignedChanges") or []:
            file = change_file(entry)
            for path in named:
                if path_covers(path, file):
                    owner = next(iter(stack_names(stack)), "")
                    raise Stop("path_owned_elsewhere", "%s is assigned to branch %s, not %s; nothing was committed"
                               % (file, owner, branch), path=file, branch=owner)
    changed = [change_file(e) for e in status.get("uncommittedChanges") or []]
    changed += [change_file(e) for s in own for e in s.get("assignedChanges") or []]
    given = [p for p in named if any(path_covers(p, f) for f in changed)]
    if not given:
        raise Stop("nothing_to_commit", "no changes to commit in the named paths")
    jj_commit_argv_check(given, opts["message_file"])  # the same command-line size bound as Git and jj
    with open(opts["message_file"], encoding="utf-8", newline="") as stream:
        message = stream.read()
    applied = [name for stack in stacks for name in stack_names(stack)]

    def tip_of(name):
        found = git(root, "rev-parse", "--verify", "-q", "refs/heads/" + name + "^{commit}")
        return found.stdout.strip() if found.returncode == 0 else ""

    before = {name: tip_of(name) for name in applied}
    but_run(root, "commit", "-b", branch, "-F", opts["message_file"], "--json", *given)
    new = tip_of(branch)
    old = before[branch]
    problems = []
    parent = git(root, "rev-parse", "--verify", "-q", new + "^{commit}^") if new else None
    if not new or parent is None or parent.returncode or parent.stdout.strip() != old:
        problems.append("the new tip's parent is not the old tip")
    committed = []
    if new:
        diff = git(root, "diff-tree", "--no-commit-id", "--name-only", "--no-renames", "-r", "-z", new)
        committed = sorted(path_text(n) for n in diff.stdout.split("\0") if n)
    extra = [f for f in committed if not any(path_covers(p, f) for p in named)]
    missing = [f for f in changed if any(path_covers(p, f) for p in named) and f not in committed]
    if extra:
        problems.append("it holds files outside the named paths: " + ", ".join(extra))
    if missing:
        problems.append("it lacks named changes: " + ", ".join(missing))
    body = git(root, "log", "-1", "--format=%B", "refs/heads/" + branch).stdout if new else ""
    if body.rstrip("\n") != message.rstrip("\n"):
        problems.append("its message differs from the message file")
    moved = [name for name in applied if name != branch and tip_of(name) != before[name]]
    if moved:
        problems.append("another branch's tip moved: " + ", ".join(moved))
    if problems:
        raise Stop("commit_mismatch", "the GitButler commit on %s is not what was asked: %s; the commit was left in place "
                   "(tip %s, was %s); files taken: %s" % (branch, "; ".join(problems), new or "-", old,
                                                          ", ".join(committed) or "-"),
                   old_tip=old, new_tip=new, files=committed)
    return {"ok": True, "backend": "gitbutler", "branch": branch, "commit": new, "files": committed}


def fenced_but_pull(root, login):
    """`as.sh <login> but pull --json` for a GitHub origin (D7); plain `but pull --json` for any other remote."""
    github = is_github_url(remote_url(root))
    who = fence_login(root, github, login)
    result = bash_script(root, AS_SH, who, "but", "pull", "--json") if github else bash_command(root, "but", "pull", "--json")
    if result.returncode:
        message = (result.stderr or result.stdout).strip() or "but pull failed"
        if github and result.returncode == 3 and message.startswith("as.sh:"):
            raise Stop("fence_failed", message, 3)
        raise Stop("but_error", message + autocrlf_hint(root) + "\nGitButler keeps its own undo (`but undo`); "
                   "Specwright runs none")
    return result.stdout


def linked_worktrees(root):
    """D7: every worktree after the main one in `git worktree list --porcelain`."""
    listed = git(root, "worktree", "list", "--porcelain")
    if listed.returncode:
        raise Stop("git_error", (listed.stderr or listed.stdout).strip() or "git worktree list failed")
    paths = [path_text(line[len("worktree "):]) for line in listed.stdout.splitlines() if line.startswith("worktree ")]
    return paths[1:]


def gitbutler_pull(root, info, opts, login):
    """D7: `but pull` rebases every applied branch, so it runs only when the cleaned-up branch is alone and no linked
    worktree exists. A skipped pull is a result, not a failure."""
    branch = require_branch(opts)
    status = but_status(root)
    others = [name for stack in status.get("stacks") or [] for name in stack_names(stack) if name != branch]
    worktrees = linked_worktrees(root)
    if others or worktrees:
        return {"ok": True, "backend": "gitbutler", "branch": branch, "pulled": False, "reason": "pull_skipped",
                "applied_branches": others, "worktrees": worktrees}
    out = fenced_but_pull(root, login)
    result = {"ok": True, "backend": "gitbutler", "branch": branch, "pulled": True}
    try:
        report = json.loads(out)
        if isinstance(report, dict) and report.get("status"):
            result["status"] = report["status"]
    except ValueError:
        pass
    after = but_status(root)
    result["target"] = (after.get("mergeBase") or {}).get("commitId") or ""
    result["applied_branches"] = [name for stack in after.get("stacks") or [] for name in stack_names(stack)]
    return result


def gitbutler_push(root, info, opts, login):
    """D6: the fenced Git push of the branch's own ref; no force, no -u, no tags (push.followTags), never `but push` or `but pr`."""
    branch = require_branch(opts)
    require_applied(root, branch)
    require_settings_pinned(root, branch)
    pinned = bash_script(None, PR_PAIR, "context", "--code", str(opts["code"]), "--only", "repos", "--branch", branch)
    if pinned.returncode:  # D8: the single comparison lives in pr-pair.sh; its error and message pass through
        try:
            data = json.loads(pinned.stdout)
        except ValueError:
            data = {"error": "settings_error", "message": pinned.stderr.strip() or pinned.stdout.strip()}
        extra = {k: v for k, v in data.items() if k in ("file", "ref")}
        raise Stop(data.get("error", "settings_error"), data.get("message", "could not check the settings"),
                   min(pinned.returncode, 3), **extra)
    refspec = "refs/heads/%s:refs/heads/%s" % (branch, branch)
    try:
        network_git(root, ["push", "--no-follow-tags", "origin", refspec], login)
    except Stop as exc:
        if exc.error == "git_network_error" and re.search(r"\[rejected\]|non-fast-forward|fetch first", exc.message):
            raise Stop("push_rejected", "the remote rejected the push of %s as non-fast-forward; Specwright never forces "
                       "it: the user decides (%s)" % (branch, exc.message.replace("\n", " ").strip()), 1, branch=branch)
        raise
    return {"ok": True, "backend": "gitbutler", "branch": branch}


def gitbutler_delete(root, info, opts, login):
    """D8: delete only a merged branch whose merge the workspace base already holds; never a Git write."""
    branch = require_branch(opts)
    merged_commit = opts.get("merged_commit") or ""
    if merged_commit and not re.fullmatch(r"[0-9a-fA-F]{7,40}", merged_commit):
        usage("--merged-commit must be a commit id of 7 to 40 hex digits")
    found = git(root, "rev-parse", "--verify", "-q", "refs/heads/" + branch + "^{commit}")
    if found.returncode:
        return {"ok": True, "backend": "gitbutler", "branch": branch, "deleted": False, "reason": "already_deleted"}
    tip = found.stdout.strip()
    status = require_applied(root, branch)
    if not opts.get("force"):  # no caller proved a merged PR: the tip must be in the fetched main
        fetched = jj_fetch_main(root, info["main"], opts, login)
        if not git_ancestor(root, tip, fetched):
            raise Stop("not_merged", "branch %s is not merged into the fetched %s; nothing was deleted" % (branch, info["main"]),
                       branch=branch)
    base = (status.get("mergeBase") or {}).get("commitId") or ""
    proofs = [tip]
    if merged_commit:
        resolved = git(root, "rev-parse", "--verify", "-q", merged_commit + "^{commit}")
        if resolved.returncode == 0:
            proofs.append(resolved.stdout.strip())
    if not base or not any(git_ancestor(root, proof, base) for proof in proofs):
        return {"ok": True, "backend": "gitbutler", "branch": branch, "deleted": False, "reason": "left_applied",
                "base": base, "message": "branch %s stays applied: the workspace base %s does not hold its merge yet; "
                "the user's next `but pull` removes it" % (branch, base or "(unknown)")}
    but_run(root, "branch", "delete", branch, "--json")
    return {"ok": True, "backend": "gitbutler", "branch": branch, "deleted": True}


def run_gitbutler_operation(command, info, opts, paths):
    root = info["repo"]
    if command == "branch-create":
        return gitbutler_branch_create(root, info, opts)
    if command == "switch":
        branch = require_branch(opts)
        if branch != info["main"]:  # the workspace is always based on main: only another branch needs to be applied
            require_applied(root, branch)
        return {"ok": True, "backend": "gitbutler", "branch": branch, "switched": False}
    if command == "commit":
        return gitbutler_commit(root, info, opts, paths)
    login = opts.get("login") or info.get("login", "")
    if command == "push":
        return gitbutler_push(root, info, opts, login)
    if command == "pull":
        return gitbutler_pull(root, info, opts, login)
    if command == "fetch-main":
        sha = jj_fetch_main(root, info["main"], opts, login)
        return {"ok": True, "backend": "gitbutler", "ref": sha, "commit": sha}
    if command == "delete-branch":
        return gitbutler_delete(root, info, opts, login)
    if command in ("merge", "advance"):
        raise Stop("unsupported_combination", "%s has no GitButler meaning: vcs: gitbutler runs only with finish: pr, "
                   "where the PR merges on GitHub" % command)
    raise Stop("unsupported", "the GitButler backend does not implement %s yet" % command)


def main_and_context(info, opts):
    if opts.get("main"):
        info["main"] = opts["main"]
    return info["main"]


def current_state(repo, info, opts):
    if info["backend"] == "gitbutler":
        return gitbutler_state(info["repo"], info, opts)
    state = git_state(repo, info, opts.get("scope")) if info["backend"] == "git" else jj_state(repo, info, opts.get("scope"))
    # D4: HEAD is the change's commit on Git and jj; `--branch` is reported, never a stop (finish asks from main)
    head = git(repo, "rev-parse", "--verify", "-q", "HEAD^{commit}")
    state["head"] = head.stdout.strip() if head.returncode == 0 else ""
    if opts.get("branch"):
        state["branch_matches"] = state["branch"] == opts["branch"]
    return state


def git_checked(repo, *args, env=None, error="git_error"):
    result = git(repo, *args, env=env)
    if result.returncode:
        raise Stop(error, (result.stderr or result.stdout).strip() or "git " + " ".join(args) + " failed")
    return result


def remote_url(repo, remote="origin"):
    result = git(repo, "remote", "get-url", remote)
    return result.stdout.strip() if result.returncode == 0 else ""


def is_github_url(url):
    if re.match(r"^[A-Za-z]:[\\\\/]", url):
        return False
    if "://" in url:
        host = urlsplit(url).hostname
    else:
        match = re.match(r"^(?:[^@/]+@)?([^/:]+):", url)
        host = match.group(1) if match else None
    return host is not None and host.lower().rstrip(".") in ("github.com", "ssh.github.com")


def network_git(repo, args, login):
    github = is_github_url(remote_url(repo))
    who = login or ""
    if github and not who:
        resolved = bash_script(repo, AS_SH, "--resolve")
        if resolved.returncode:
            raise Stop("fence_failed", resolved.stderr.strip() or "as.sh could not resolve GitHub login", 3)
        who = resolved.stdout.strip()
    result = (bash_script(repo, AS_SH, who, "git", *args) if github
              else git(repo, *args))
    if result.returncode:
        message = (result.stderr or result.stdout).strip() or "Git network operation failed"
        if args[0] == "pull" and re.search(r"not possible to fast-forward|divergent branches", message, re.I):
            raise Stop("not_fast_forward", message)
        error = "fence_failed" if github and result.returncode == 3 else "git_network_error"
        raise Stop(error, message, 3)
    return result


def check_branch(repo, expected):
    current = git_current(repo)
    if current != expected:
        raise Stop("wrong_branch", "expected branch %r, currently on %r" % (expected, current))
    return current


def run_git_operation(command, repo, info, opts, paths, ctx):
    main = main_and_context(info, opts)
    backend = info["backend"]
    branch = opts.get("branch")
    if command == "branch-create":
        branch = require_branch(opts)
        result = git_checked(repo, "checkout", "-b", branch)
        return {"ok": True, "backend": backend, "branch": branch, "output": result.stdout.strip()}
    if command == "switch":
        branch = require_branch(opts)
        result = git_checked(repo, "checkout", branch)
        return {"ok": True, "backend": backend, "branch": branch, "output": result.stdout.strip()}
    if command == "commit":
        branch = require_branch(opts)
        if not opts.get("message_file") or not paths:
            usage("commit requires --message-file and at least one path after --")
        if os.name == "nt" and sum(len(os.fsencode(path)) + 1 for path in paths) + len(os.fsencode(opts["message_file"])) > 32000:
            raise Stop("too_many_paths", "named Git paths exceed the Windows command-line limit; name a containing directory instead")
        check_branch(repo, branch)
        args = ["add", "--", *paths]
        git_checked(repo, *args)
        result = git(repo, "commit", "-F", opts["message_file"], "--", *paths)
        if result.returncode:
            raise Stop("git_commit_failed", (result.stderr or result.stdout).strip() or "git commit failed")
        head = git_checked(repo, "rev-parse", "HEAD").stdout.strip()
        return {"ok": True, "backend": backend, "branch": branch, "commit": head}
    if command == "merge":
        branch = require_branch(opts)
        if not opts.get("message_file"):
            usage("merge requires --message-file")
        check_branch(repo, main)
        result = git_checked(repo, "merge", "--no-ff", branch, "-F", opts["message_file"], error="merge_failed")
        return {"ok": True, "backend": backend, "branch": branch, "commit": git_checked(repo, "rev-parse", "HEAD").stdout.strip()}
    if command == "delete-branch":
        branch = require_branch(opts)
        if opts.get("force") and git_current(repo) == branch:
            raise Stop("branch_is_current", "refusing to force-delete the currently checked out branch")
        flag = "-D" if opts.get("force") else "-d"
        result = git_checked(repo, "branch", flag, branch, error="branch_delete_failed")
        return {"ok": True, "backend": backend, "branch": branch}
    if command == "fetch-main":
        args = ["fetch"]
        if opts.get("quiet"):
            args.append("-q")
        if opts.get("no_tags"):
            args.append("--no-tags")
        args.extend(("origin", main))
        result = network_git(repo, args, opts.get("login") or ctx.get("login"))
        ref = "refs/remotes/origin/" + main
        commit = git_checked(repo, "rev-parse", "--verify", ref + "^{commit}", error="fetch_failed").stdout.strip()
        return {"ok": True, "backend": backend, "ref": "origin/" + main, "commit": commit}
    if command == "pull":
        args = ["pull", "--ff-only"]
        if opts.get("remote_branch"):
            args.extend(("origin", main))
        network_git(repo, args, opts.get("login") or ctx.get("login"))
        return {"ok": True, "backend": backend, "branch": git_current(repo)}
    if command == "push":
        branch = require_branch(opts)
        check_branch(repo, branch)
        network_git(repo, ["push", "-u", "origin", "HEAD"], opts.get("login") or ctx.get("login"))
        return {"ok": True, "backend": backend, "branch": branch}
    if command == "advance":
        if opts.get("scope") is None:
            usage("advance requires --scope")
        return {"ok": True, "backend": backend, "branch": git_current(repo), "advanced": False}
    usage(command + " is not implemented for the Git backend")


def revset_text(name):
    return '"' + name.replace("\\", "\\\\").replace('"', '\\"') + '"'


def fileset_text(path):
    return 'root:' + revset_text(path)


def jj_path(path):
    """The repo-relative spelling jj and `jj file list` use: `./a`, `a/../a` and `a/` all name `a`."""
    return posixpath.normpath(path.replace("\\", "/") if os.name == "nt" else path)


def jj_one(repo, revset, template):
    return jj_log(repo, revset, template, limit=1).strip()


def snapshot_limit(repo):
    result = jj(repo, "config", "get", "snapshot.max-new-file-size")
    text = result.stdout.strip() if result.returncode == 0 else ""
    found = re.fullmatch(r"(\d+)\s*([KMGT]?)(i?)B?", text, re.I)
    if not found:
        return 1024 * 1024
    base = 1024 if found.group(3) else 1000
    return int(found.group(1)) * base ** "BKMGT".index(found.group(2).upper() or "B")


def jj_commit_argv_check(filesets, message):
    argv = ["jj", "commit", *filesets, "-m", message]
    if os.name == "nt":
        size, limit = len(os.fsencode(process_arguments(argv))), 32000
    else:
        try:
            limit = os.sysconf("SC_ARG_MAX") - sum(len(k) + len(v) + 2 for k, v in os.environb.items()) - 4096
        except (ValueError, OSError):
            limit = 100000
        size = sum(len(os.fsencode(arg)) + 1 for arg in argv)
    if size > limit:
        raise Stop("too_many_paths", "named paths and message exceed the command-line limit; name a containing directory instead")


def check_directory_snapshot(repo, path, listed):
    """One snapshotted file does not cover a named directory: jj leaves out a new file over the size limit."""
    limit, oversize = snapshot_limit(repo), []
    for top, dirs, files in os.walk(os.path.join(repo, path)):
        dirs[:] = [name for name in dirs if name not in (".jj", ".git")]
        for name in files:
            full = os.path.join(top, name)
            rel = path_text(os.path.relpath(full, repo))
            if rel not in listed and os.path.isfile(full) and not os.path.islink(full) and os.path.getsize(full) > limit:
                oversize.append(rel)
    if not oversize:
        return
    names = "".join(rel + "\0" for rel in oversize)  # NUL-separated both ways: git quotes a non-ASCII path otherwise
    listed_ignored = git(repo, "check-ignore", "-z", "--stdin", input=names).stdout.split("\0")
    ignored = set(path_text(name) for name in listed_ignored if name)
    for rel in oversize:
        if rel not in ignored:
            raise Stop("path_not_tracked", "%s is not tracked in the jj working copy: it is larger than "
                       "snapshot.max-new-file-size (%d bytes)" % (rel, limit), path=rel)


def check_tracked(repo, paths, filesets):
    present = [(p, f) for p, f in zip(paths, filesets) if os.path.lexists(os.path.join(repo, p))]
    if not present:
        return
    listed = [path_text(line) for line in jj_result(repo, "file", "list", "-r", "@", *[f for _, f in present]).splitlines()]
    parent_listed = None
    for path, _ in present:
        norm = path.rstrip("/") or "."
        covered = norm == "." or any(item == norm or item.startswith(norm + "/") for item in listed)
        if not covered and os.path.isdir(os.path.join(repo, path)):
            # a directory whose tracked files were all deleted names those deletions
            if parent_listed is None:
                parent_listed = [path_text(line) for line in
                                 jj_result(repo, "file", "list", "-r", "@-", *[f for _, f in present]).splitlines()]
            covered = any(item.startswith(norm + "/") for item in parent_listed)
        if covered:
            if os.path.isdir(os.path.join(repo, path)):
                check_directory_snapshot(repo, path, set(listed))
            continue
        full = Path(repo) / path
        if full.is_file() and not full.is_symlink() and full.stat().st_size > snapshot_limit(repo):
            reason = "it is larger than snapshot.max-new-file-size (%d bytes)" % snapshot_limit(repo)
        else:
            reason = "it is ignored, or larger than snapshot.max-new-file-size"
        raise Stop("path_not_tracked", "%s is not tracked in the jj working copy: %s" % (path, reason), path=path)


def jj_verify_head(repo, branch):
    head = git_checked(repo, "rev-parse", "HEAD").stdout.strip()
    tip = git_checked(repo, "rev-parse", "refs/heads/" + branch).stdout.strip()
    if head != tip:
        raise Stop("jj_error", "Git HEAD %s differs from bookmark %s at %s" % (head, branch, tip))
    return head


def jj_switch(repo, target):
    if jj_one(repo, "@", 'if(empty, "1", "0")') == "1":
        jj_result(repo, "new", revset_text(target))
        return {}
    old = jj_one(repo, "@-", "commit_id")
    jj_result(repo, "rebase", "-r", "@", "-o", revset_text(target))
    if jj_one(repo, "@", 'if(conflict, "1", "0")') != "1":
        return {}
    listed = jj(repo, "resolve", "--list", "-r", "@")
    names = [path_text(re.split(r"\s{2,}", line.strip())[0]) for line in listed.stdout.splitlines() if line.strip()]
    jj_result(repo, "rebase", "-r", "@", "-o", revset_text(old))
    raise Stop("carry_conflict", "edits conflict with %s in: %s; nothing was moved" % (target, ", ".join(names)), paths=names)


def jj_advance(repo, info, opts):
    scope = opts.get("scope")
    if scope is None:
        usage("advance requires --scope")
    state = jj_state(repo, info, scope)
    branch = state["branch"]
    if opts.get("branch") and opts["branch"] != branch:
        raise Stop("wrong_branch", "expected branch %r, resolved %r" % (opts["branch"], branch))
    behind = state["behind"]
    if not behind:
        return {"ok": True, "backend": "jj", "branch": branch, "advanced": False}
    tip = git_checked(repo, "rev-parse", "refs/heads/" + branch).stdout.strip()
    if not jj_one(repo, revset_text(tip) + " & ::@-", "commit_id"):
        raise Stop("ambiguous_branch", "bookmark %s is not an ancestor of @-" % branch)
    pattern = re.compile(r"^[A-Za-z][A-Za-z0-9-]*\(" + re.escape(scope) + r"\): ")
    if state["behind_truncated"] or not all(pattern.match(item.get("subject", "")) for item in behind):
        listing = "; ".join("%s %s" % (item["commit"], item.get("subject", "")) for item in behind)
        raise Stop("bookmark_behind", "bookmark %s is behind commits outside scope %s%s: %s" % (
            branch, scope, " (first %d shown)" % len(behind) if state["behind_truncated"] else "", listing), commits=behind)
    target = jj_one(repo, "@-", "commit_id")
    jj_result(repo, "bookmark", "set", branch, "-r", revset_text(target))
    return {"ok": True, "backend": "jj", "branch": branch, "advanced": True, "commit": jj_verify_head(repo, branch)}


def exact_pattern(name):
    return "exact:" + revset_text(name)


def jj_bookmark(repo, name, allow_conflict=False):
    raw = jj_result(repo, "bookmark", "list", exact_pattern(name), "-T", BOOKMARK_TEMPLATE)
    items = [json.loads(line) for line in raw.splitlines() if line.strip()]
    if not items:
        raise Stop("no_such_branch", "bookmark %s does not exist" % name)
    item = items[0]
    if item.get("conflict") or not item.get("target"):
        if allow_conflict:
            return ""
        raise Stop("ambiguous_branch", "bookmark %s is conflicted" % name)
    return item["target"]


def git_ancestor(repo, ancestor, descendant):
    result = git(repo, "merge-base", "--is-ancestor", ancestor, descendant)
    if result.returncode not in (0, 1):
        raise Stop("git_error", (result.stderr or result.stdout).strip() or "git merge-base --is-ancestor failed")
    return result.returncode == 0


def conflict_paths(repo, revision):
    listed = jj(repo, "resolve", "--list", "-r", revision)
    return [path_text(re.split(r"\s{2,}", line.strip())[0]) for line in listed.stdout.splitlines() if line.strip()]


def fence_login(repo, github, login):
    who = login or ""
    if github and not who:
        resolved = bash_script(repo, AS_SH, "--resolve")
        if resolved.returncode:
            raise Stop("fence_failed", resolved.stderr.strip() or "as.sh could not resolve GitHub login", 3)
        who = resolved.stdout.strip()
    return who


def network_jj(repo, args, login):
    github = is_github_url(remote_url(repo))
    who = fence_login(repo, github, login)
    result = bash_script(repo, AS_SH, who, "jj", *args) if github else jj(repo, *args)
    if result.returncode:
        message = (result.stderr or result.stdout).strip() or "jj network operation failed"
        raise Stop("fence_failed" if github and result.returncode == 3 else "git_network_error", message, 3)
    return result


def jj_fetch_main(repo, main, opts, login):
    args = ["fetch"]
    if opts.get("quiet"):
        args.append("-q")
    if opts.get("no_tags"):
        args.append("--no-tags")
    args.extend(("--refmap=", "origin", "refs/heads/" + main))
    network_git(repo, args, login)
    return git_checked(repo, "rev-parse", "--verify", "FETCH_HEAD^{commit}", error="fetch_failed").stdout.strip()


def jj_find_merge(repo, main_id, branch_id, subject):
    revset = "merges() & children(%s) & children(%s)" % (revset_text(main_id), revset_text(branch_id))
    template = ('json({"commit" => commit_id, "subject" => description.first_line(), '
                '"parents" => stringify(parents.map(|c| c.commit_id()).join(" "))}) ++ "\\n"')
    for line in jj_log(repo, revset, template).splitlines():
        if not line.strip():
            continue
        item = json.loads(line)
        if item["parents"].split(" ") == [main_id, branch_id] and item["subject"].rstrip("\r") == subject:
            return item["commit"]
    return ""


def jj_merge(repo, info, opts):
    branch = require_branch(opts)
    if not opts.get("message_file"):
        usage("merge requires --message-file")
    main = info["main"]
    state = jj_state(repo, info)
    main_id, branch_id = jj_bookmark(repo, main), jj_bookmark(repo, branch)
    if jj_one(repo, revset_text(branch_id) + " & ::" + revset_text(main_id), "commit_id"):
        return {"ok": True, "backend": "jj", "branch": branch, "commit": main_id, "already_merged": True}
    with open(opts["message_file"], encoding="utf-8", newline="") as stream:
        message = stream.read()
    subject = (message.splitlines() or [""])[0]
    merge = jj_find_merge(repo, main_id, branch_id, subject)
    resumed = bool(merge) and jj_one(repo, "@-", "commit_id") == merge
    if not resumed and not state["on_main"]:
        raise Stop("wrong_branch", "expected to be on %r, currently on %r" % (main, state["branch"]))
    if not merge:
        jj_result(repo, "new", "--no-edit", "-m", message, revset_text(main_id), revset_text(branch_id))
        merge = jj_find_merge(repo, main_id, branch_id, subject)
        if not merge:
            raise Stop("jj_error", "could not find the merge commit that jj new created")
    if not resumed:
        if jj_one(repo, revset_text(merge), 'if(conflict, "1", "0")') == "1":
            names = conflict_paths(repo, merge)
            jj_result(repo, "abandon", revset_text(merge))
            raise Stop("conflicted", "merging %s into %s conflicts in: %s; the merge was abandoned" % (
                branch, main, ", ".join(names)), paths=names)
        try:
            jj_switch(repo, merge)
        except Stop as exc:
            if exc.error == "carry_conflict":
                jj_result(repo, "abandon", revset_text(merge))
            raise
    jj_result(repo, "bookmark", "set", main, "-r", revset_text(merge))
    return {"ok": True, "backend": "jj", "branch": branch, "commit": jj_verify_head(repo, main)}


def jj_delete(repo, info, opts):
    branch = require_branch(opts)
    jj_bookmark(repo, branch, allow_conflict=bool(opts.get("force")))
    if not opts.get("force"):
        main_id = jj_bookmark(repo, info["main"])
        if not jj_one(repo, revset_text(branch) + " & ::" + revset_text(main_id), "commit_id"):
            raise Stop("not_merged", "branch %s is not merged into %s" % (branch, info["main"]))
    jj_result(repo, "bookmark", "forget", exact_pattern(branch))
    return {"ok": True, "backend": "jj", "branch": branch}


def jj_pull(repo, info, opts, login):
    main = info["main"]
    was_on_main = jj_state(repo, info)["on_main"]
    old = jj_bookmark(repo, main)
    fetched = jj_fetch_main(repo, main, opts, login)
    if git_ancestor(repo, fetched, old):
        return {"ok": True, "backend": "jj", "branch": main if was_on_main else "", "commit": old, "moved": False}
    if not git_ancestor(repo, old, fetched):
        raise Stop("not_fast_forward", "local %s at %s and origin %s at %s have diverged" % (main, old, main, fetched))
    network_jj(repo, ["git", "fetch", "--remote", "origin", "--branch", exact_pattern(main)], login)
    current = jj_bookmark(repo, main, allow_conflict=True)
    remote = jj_one(repo, revset_text(main) + "@" + revset_text("origin"), "commit_id")
    if current and remote and current != remote and git_ancestor(repo, current, remote):
        jj_result(repo, "bookmark", "set", main, "-r", revset_text(remote))
        current = remote
    if not current or not git_ancestor(repo, old, current):
        jj_result(repo, "bookmark", "set", main, "-r", revset_text(old), "--allow-backwards")
        raise Stop("not_fast_forward", "origin %s moved during the pull; local %s was set back to %s" % (main, main, old))
    if was_on_main:
        try:
            jj_switch(repo, current)
        except Stop as exc:
            if exc.error == "carry_conflict":  # a failed switch leaves main where the pull found it
                jj_result(repo, "bookmark", "set", main, "-r", revset_text(old), "--allow-backwards")
            raise
    return {"ok": True, "backend": "jj", "branch": main if was_on_main else "", "commit": current, "moved": True}


def jj_push(repo, info, opts, login):
    branch = require_branch(opts)
    current = jj_state(repo, info)["branch"]
    if current != branch:
        raise Stop("wrong_branch", "expected branch %r, currently on %r" % (branch, current))
    template = ('json({"commit" => commit_id, "conflict" => conflict, "subject" => description.first_line(), '
                '"described" => if(description.trim(), "1", "0")}) ++ "\\n"')
    commits = [json.loads(line) for line in
               jj_log(repo, revset_text(info["main"]) + ".." + revset_text(branch), template).splitlines() if line.strip()]
    bad = [item["commit"] for item in commits if item.get("conflict")]
    if bad:
        raise Stop("conflicted", "commit(s) in %s..%s are conflicted: %s" % (info["main"], branch, ", ".join(bad)), commits=bad)
    bad = [item["commit"] for item in commits if item.get("described") != "1"]
    if bad:
        raise Stop("undescribed", "commit(s) in %s..%s have no description: %s" % (info["main"], branch, ", ".join(bad)), commits=bad)
    network_jj(repo, ["git", "push", "--remote", "origin", "--bookmark", exact_pattern(branch)], login)
    return {"ok": True, "backend": "jj", "branch": branch}


def run_jj_operation(command, repo, info, opts, paths, ctx):
    main_and_context(info, opts)
    repo = info["repo"]
    if command == "branch-create":
        branch = require_branch(opts)
        jj_result(repo, "bookmark", "create", branch, "-r", "@-")
        return {"ok": True, "backend": "jj", "branch": branch, "commit": jj_verify_head(repo, branch)}
    if command == "switch":
        branch = require_branch(opts)
        jj_state(repo, info)
        jj_switch(repo, branch)
        return {"ok": True, "backend": "jj", "branch": branch}
    if command == "advance":
        return jj_advance(repo, info, opts)
    if command == "commit":
        branch = require_branch(opts)
        if not opts.get("message_file") or not paths:
            usage("commit requires --message-file and at least one path after --")
        state = jj_state(repo, info)
        current = state["branch"]
        if state["on_main"]:  # jj_state reads main as branch ""; a commit on main names it, as on Git (#153)
            current = info["main"]
        if current != branch:
            raise Stop("wrong_branch", "expected branch %r, currently on %r" % (branch, current))
        paths = [jj_path(p) for p in paths]
        filesets = [fileset_text(p) for p in paths]
        with open(opts["message_file"], encoding="utf-8", newline="") as stream:
            message = stream.read()
        jj_commit_argv_check(filesets, message)
        check_tracked(repo, paths, filesets)
        if not jj_result(repo, "diff", "-r", "@", "--name-only", *filesets).strip():
            raise Stop("nothing_to_commit", "no changes to commit in the named paths")
        jj_result(repo, "commit", *filesets, "-m", message)
        jj_result(repo, "bookmark", "set", branch, "-r", "@-")
        return {"ok": True, "backend": "jj", "branch": branch, "commit": jj_verify_head(repo, branch)}
    login = opts.get("login") or ctx.get("login")
    if command == "merge":
        return jj_merge(repo, info, opts)
    if command == "delete-branch":
        return jj_delete(repo, info, opts)
    if command == "fetch-main":
        sha = jj_fetch_main(repo, info["main"], opts, login)
        return {"ok": True, "backend": "jj", "ref": sha, "commit": sha}
    if command == "pull":
        return jj_pull(repo, info, opts, login)
    if command == "push":
        return jj_push(repo, info, opts, login)
    usage("unknown command: " + command)


def plan(repo, code, role, info, opts):
    operation = opts.get("operation")
    if operation not in ("switch", "pull", "delete-branch"):
        usage("plan --operation must be switch, pull or delete-branch")
    branch = require_branch(opts)
    subcommand = "delete-branch" if operation == "delete-branch" else operation
    args = ["bash", str(VCS_DIR / "vcs.sh"), subcommand, "--repo", str(repo), "--role", role, "--code", str(code),
            "--branch", branch]
    if opts.get("force"):
        args.append("--force")
    if opts.get("remote_branch"):
        args.append("--remote-branch")
    if opts.get("login"):
        args.extend(("--login", opts["login"]))
    if opts.get("merged_commit"):
        if not re.fullmatch(r"[0-9a-fA-F]{7,40}", opts["merged_commit"]):
            usage("--merged-commit must be a commit id of 7 to 40 hex digits")
        args.extend(("--merged-commit", opts["merged_commit"]))
    return {"ok": True, "backend": info["backend"], "commands": [" ".join(map(shlex.quote, args))]}


def main(argv):
    command, opts, paths = context(argv)
    repo = Path(opts["repo"]).resolve()
    code = Path(opts["code"]).resolve()
    role = opts["role"]
    info = probe(repo, code, role)
    if opts.get("main"):
        info["main"] = opts["main"]
    if command == "probe":
        result = {"ok": True, "backend": info["backend"], "main": info["main"]}
        if info["backend"] == "git" and info.get("jj_present"):
            result["jj_present"] = True
        return result
    if command == "state":
        return current_state(repo, info, opts)
    if command == "plan":  # the commands to run, for every backend (GitButler: switch no-op, pull --branch, delete-branch --force)
        return plan(repo, code, role, info, opts)
    if info["backend"] == "gitbutler":
        return run_gitbutler_operation(command, info, opts, paths)
    if info["backend"] == "git":
        return run_git_operation(command, repo, info, opts, paths, {"login": info.get("login", "")})
    return run_jj_operation(command, repo, info, opts, paths, {"login": info.get("login", "")})


try:
    emit(main(sys.argv[1:]))
except Stop as exc:
    emit(exc.object(), exc.code)
except SystemExit:
    raise
except Exception as exc:
    emit({"ok": False, "error": "internal_error", "message": str(exc)}, 1)
PYSRC
