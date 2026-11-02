#!/usr/bin/env bash
# Decisions for a change that lives in two repos (code + planning store): which
# PRs are expected, how they link, what watch does, and how an interrupted
# feedback pass resumes. Every subcommand prints ONE JSON line.
#
# Usage: bash pr-pair.sh <subcommand> [options]
#   identity <dir>                    fetch URL + every push URL of origin -> owner/name
#   context --code <dir> [--store <dir>] [--only repos] [--branch b [--after-merge]]
#                                     per-repo login, main, validate, reviewers (role, timeout, request, report), reviewer_config,
#                                     merge_ready (specwright.yaml + planning_store:); settle (pr.settle in seconds, default 300, strictly
#                                     <int><s|m|h>, 1m to 1h);
#                                     reviewer_config is the path of the repo's reviewer set written as canonical JSON
#                                     {"format":1,"reviewers":[{login,role,timeout,report}]} (sorted keys and logins, no request) to
#                                     <state dir>/reviewers/<sha256 of the bytes>.json, else <system temp>/specwright/reviewers/ when the
#                                     state dir is unwritable (null only if neither is); equal settings give the same file, so the name
#                                     is the digest of the rules;
#                                     settings_problem (only when set; the first one, never an exit): the strict reader's `line N: why`
#                                     for the whole settings file, else a bad pr.settle, a reviewer `report` that is not a mapping of
#                                     strings, or more than 20 reviewers in a set (too_many_reviewers), each naming its key;
#                                     merge (user|agent), merge_method, delete_branch (bad value = exit 2 bad_setting;
#                                     --only repos skips that check, for callers that never merge, such as vcs.sh)
#                                     With `vcs: gitbutler` the settings must be those the change branch committed (the shared work tree
#                                     can hold a sibling branch's or an unassigned edit): --branch b compares git hash-object
#                                     --path=openspec/specwright.yaml <work-tree file> (the repo's clean and eol filters apply, so CRLF
#                                     checkouts compare equal) with refs/heads/b:openspec/specwright.yaml. A difference, or the file on one
#                                     side only, is exit 1 settings_not_pinned (names the file and the ref; commit the edit on b); a git
#                                     failure is exit 1 git_error. --after-merge --branch b, for cleanup after its pull and delete,
#                                     compares with the tip of refs/heads/b while that branch exists (pull skipped or left applied), else
#                                     with gitbutler.project.targetRef; its message names that ref and says to run `but pull` or undo the
#                                     work-tree edit. A merge-settings call (anything but --only repos) without --branch is exit 2 usage
#                                     on GitButler. GitButler here means `vcs: gitbutler` in the work-tree file or a GitButler-managed
#                                     repo (gitbutler/ in the common git dir and gitbutler.project.targetRef set, as vcs.sh decides),
#                                     so an unpinned edit of the vcs line cannot turn the check off. Other Git and jj repos (a leftover
#                                     target ref alone included) never pin; they accept and ignore --branch.
#   vcs --code <dir>                  independent backend settings -> {"ok":true,"code":"git|jj|gitbutler","store":"git|jj"};
#                                     absent settings default independently to git; unknown values stop with unknown_vcs; gitbutler is code-repo only and needs finish: pr
#   tier --code <dir>                 cheap_tier.enabled: {"ok": true, "cheap_tier": bool} (true only for a parsed true; anything else
#                                     is false, with a "note" when the value or the section is not true/false/a map). Reads no other
#                                     setting, so a bad pr.merge_method cannot change it; exit 0 for any readable settings file
#   merge --repo o/n --pr N --method merge|squash|rebase --head sha
#                                     one PUT repos/o/n/pulls/N/merge (merge_method, sha), then always a read-back: merged (also when a
#                                     person merged first), refused (reason head_changed on 409, else refused; exit 1) or, when the state
#                                     cannot be read or the PUT got a 5xx, unknown (exit 3). Never a second PUT, auto-merge or a queue call; bad input = exit 2
#   policy --repo o/n --head sha --snapshot code=f [--reviewed-head code=sha] [--store --snapshot store=f --reviewed-head store=sha]
#                                     the merge policy from GitHub, never the work tree: default_branch (repos/o/n), then openspec/specwright.yaml
#                                     read through the contents API at the default branch and at the PR head, both as the run login. Prints
#                                     main and head (pr.merge, pr.merge_method, pr.delete_branch, pr.reviewers; with --store also
#                                     planning_store.reviewers), compared normalized, never as bytes, drift [{key, main, head}] and, from
#                                     main alone: merge, merge_method, delete_branch, merge_ready {code[, store]}, merge_reason, merge_note.
#                                     No file on main is user mode; a bad merge_method/delete_branch on main with merge: agent is exit 2
#                                     bad_setting (a bad head value is only drift). A failed, cut-off or unreadable read (not a file, not
#                                     base64, or YAML the reader would skip or misread: block sequences, anchors, tags, duplicate keys,
#                                     tabs in indentation), or no file at the head, is exit 3 lookup_failed "merge policy unknown:
#                                     <reason>"; a malformed file names its first bad line.
#                                     Also reported.{main,head}.{code[,store]} {ok, missing, head_mismatch, rules_mismatch, snapshot_head, reviewed_head}:
#                                     ok when the snapshot is of that repository's reviewed head (code: --head, or --reviewed-head code= for
#                                     the archive carry-over; store: --reviewed-head store=, required) and every required reviewer of that
#                                     side's authorizing set (store: planning_store.reviewers, else pr.reviewers) is reported in it; a set
#                                     with no required reviewer is never ok. Heads match when equal or one is a prefix of the other.
#                                     rules_mismatch is true when the snapshot's reviewer_config digest differs from the digest of that
#                                     set's config (the wait ran with other rules); then ok is false. Each side's snapshot is checked
#                                     against that side's set; digests are compared, never paths.
#                                     reviewer_config.{main,head}.{code[,store]}: the path of each set's config file, written as for
#                                     `context` (null if no place is writable), for pr-snapshot.sh --reviewer-config. A reviewer's
#                                     report is part of the pr.reviewers value, so a changed rule is drift.
#                                     On main, a bad pr.settle, a reviewer report that is not a mapping of strings (exit 2 bad_setting)
#                                     and more than 20 reviewers in a set (exit 2 too_many_reviewers) stop the call; the head's go to invalid.
#                                     --store without --snapshot store= and --reviewed-head store= is exit 2; an unreadable snapshot exits 2.
#                                     A pr.reviewers that is not a mapping (a string, a list) reads as no reviewers, so it authorizes
#                                     nothing, and is listed in invalid [{side, key, value}]
#   delete-remote --repo o/n --branch b --head sha
#                                     delete the remote branch only when it is still at the full 40-hex merged head and no open PR is
#                                     based on it: deleted | gone (404, or 422 gone meanwhile) | moved (sha) | based_on (prs) |
#                                     kept (DELETE refused, GitHub's message; exit 1); a failed read is unknown (exit 3), nothing deleted
#   discover --repo o/n --branch b [--base main] [--state all|open|closed|merged[,..]]
#                                     every PR from o/n's own branch b, paginated; failure = unknown (exit 3)
#   expected --code <dir> --store <dir> --branch b
#                                     the expected PR set: store (GitHub origin) and code (PR in any state, or commits)
#   ensure-pr --repo o/n --branch b --base main --title t --body-file f
#                                     find the open PR or create it; stops on a wrong base; never edits a description
#   closing-check --repo o/n --pr N   the issues the description's closing lines name vs what GitHub will close
#                                     status match | mismatch | not_default_base (one GraphQL read, then GitHub's rendering of the description read as lines; a failure = unknown, exit 3)
#   closed-check --repo o/n --pr N --repos o/n[,o/n] [--login o/n=L ...]
#                                     at cleanup: which issues the merged PR's closing lines name are still open (lines read from GitHub's rendering)
#                                     status merged | not_merged | not_default_base; open, reopened, closed, outside (a failed read = unknown, exit 3)
#                                     --login: the login that reads o/n when it is not the one the call runs as
#   link --repo o/n --pr N --kind store|code --peer-url URL [--login L]
#                                     one marker comment <!-- specwright:link KIND URL -->; edits its own on a new peer
#   pair-state --code d --store d --branch b [--snapshot code=f] [--snapshot store=f] [--dropped id@rev]...
#              [--carry-over code|store]...
#                                     watch action: ship | wait | ready | split_hand_off | cleanup | no_watch;
#                                     --carry-over: that side is an archive head whose reviewers' reports carry over
#   rounds --code d [--store d] --branch b
#                                     highest Feedback-Round across both branches (+ legacy subject count, unpushed)
#   pass write --code d [--store d] --code-repo o/n --change c --intent file [--store-prefix openspec]
#   pass plan --code d [--store d] --code-repo o/n --change c --snapshot code=f [--snapshot store=f] [--owner id]
#   pass done --code d [--store d] --code-repo o/n --change c --snapshot code=f [--snapshot store=f] --owner id
#   pass adopt --code d [--store d] --code-repo o/n --change c --owner new-id --from shown-id|none
#                                     the intent record of a feedback pass (write returns the owner id); the evidence-based
#                                     resume plan (owned: true|false|null); delete, by its owner; hand over, naming the owner shown
#                                     (no --store: a repo-local change, code repo only)
#                                     plan's rerequest row counts a request done when it was posted at or after the cutoff:
#                                     the head's push time (cutoff_source push), else the time a snapshot first saw the head
#                                     (first_seen), else, only with no such record, when the record was written (pass_written;
#                                     written_at, or the owner's at in an older record); none = no cutoff, the row stays todo
#   cleanup-plan --code d --store d --branch b
#                                     post-merge commands per repo whose expected PR is MERGED: checkout, a pull fenced as
#                                     that repo's login (bash <as.sh> <login> git pull --ff-only), then
#                                     branch-check (--head: the merged PR's head); `delete` (git branch -D) runs only on delete: true
#   branch-check --dir d --branch b --main m [--head sha]
#                                     delete true when the branch tip is on main (on_main) or is the merged head or an ancestor of
#                                     it (pr_head); else false with reason lacking | head_unknown and the commits "lacking" (sha,
#                                     subject). Read-only, no network; a git error stops (ok false, exit 1)
# Exit: 0 answered, 1 stop (the JSON has "error" and "message"; an unexpected failure is
#       error "internal_error"), 2 usage or missing input,
#       3 GitHub state unknown (a lookup failed; never read it as "no PR").
# Every gh call names its repository (--repo or repos/<o>/<n>/...) and runs with GH_REPO unset, so an
# inherited override cannot redirect a store lookup to the code repo. Wrap with as.sh to pin the
# GitHub identity, started inside the repository it acts on (its header scrub is per working directory).
# Needs bash, git, gh 2.40+ and Python 3.8+.
set -euo pipefail

py=
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1; then py=$c; break; fi
done
[ -n "$py" ] || { echo '{"ok":false,"error":"no_python","message":"pr-pair.sh needs python 3.8+"}'; exit 2; }
unset GH_REPO
# native Windows python cannot run an MSYS path; hand it a Windows path to this bash for its gh calls
PR_PAIR_BASH=${BASH:-}
if [ -n "$PR_PAIR_BASH" ] && command -v cygpath >/dev/null 2>&1; then PR_PAIR_BASH=$(cygpath -w "$PR_PAIR_BASH"); fi
export PR_PAIR_BASH
# absolute, so the python below can hand as.sh to bash from any working directory (-m: forward slashes bash accepts)
PR_PAIR_DIR=$(cd "$(dirname "$0")" && pwd -P)
if command -v cygpath >/dev/null 2>&1; then PR_PAIR_DIR=$(cygpath -m "$PR_PAIR_DIR"); fi
export PR_PAIR_DIR

exec "$py" -I -X utf8 - "$@" <<'PYSRC'
import base64
import contextlib
import datetime
import errno
import hashlib
import json
import os
import re
import secrets
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import importlib.util
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import quote


class _Bounded:
    """The bounded runner, loaded by path on first use: -I keeps this script's directory off sys.path."""
    mod = None

    def __getattr__(self, name):
        if _Bounded.mod is None:
            sys.dont_write_bytecode = True  # no __pycache__ in an installed skill (#157)
            spec = importlib.util.spec_from_file_location("bounded", os.path.join(os.environ["PR_PAIR_DIR"], "bounded.py"))
            _Bounded.mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(_Bounded.mod)
        return getattr(_Bounded.mod, name)


bounded = _Bounded()

ENV = {k: v for k, v in os.environ.items() if k != "GH_REPO"}
BASH = os.environ.get("PR_PAIR_BASH") or shutil.which("bash")
TRAILER = re.compile(r"^Feedback-Round:[ \t]*(\d+)[ \t]*$", re.M)
LEGACY_SUBJECT = re.compile(r"address review feedback", re.I)
MARK = re.compile(r"<!--\s*specwright:link\s+(store|code)\s+(\S+)\s*-->")
GH_URL = re.compile(
    r"^(?:(?:https?|ssh|git)://(?:[^@/\s]+@)?(?:ssh\.)?github\.com\.?(?::\d+)?/|(?:[^@/\s]+@)?(?:ssh\.)?github\.com\.?:)"
    r"([^/\s]+)/([^/\s]+?)(?:\.git)?/?$", re.I)


class Stop(Exception):
    def __init__(self, error, message="", code=1, **extra):
        super().__init__(message or error)
        self.error, self.message, self.code, self.extra = error, message or error, code, extra

    def obj(self):
        return {"ok": False, "error": self.error, "message": self.message, **self.extra}


class Refused(Stop):
    """as.sh refused a fenced read (exit 3 with an `as.sh:` message): never an ordinary network failure."""


def usage(msg):
    raise Stop("usage", msg, code=2)


def emit(obj, code=0):
    # U+2028/U+2029 stay escaped: line splitters treat them as line ends, and every subcommand prints ONE JSON line
    print(json.dumps(obj, ensure_ascii=False).replace("\u2028", "\\u2028").replace("\u2029", "\\u2029"))
    sys.exit(code)


def run(cmd, cwd=None, env=None):
    try:
        return subprocess.run(cmd, cwd=cwd, env=env or ENV, capture_output=True, text=True, encoding="utf-8", errors="replace")
    except OSError as e:
        return subprocess.CompletedProcess(cmd, 127, "", str(e))


def git(d, *args, env=None):
    return run(["git", *args], cwd=d, env=env)


def net(cmd, name, env=None, cwd=None, paged=False, secret=False, limit_ok=False):
    """Run one network command under the runner's deadline and byte bound. A limit stops the command and its processes and
    raises Stop(<limit>, code 3, unknown) naming `name`; `limit_ok` returns a failed (exit 1) result instead, for a caller
    that reads the state back before it decides (merge)."""
    r = bounded.run_bounded(cmd, env=env or ENV, cwd=cwd, paged=paged, secret=secret)
    if r.limit:
        msg = f"GitHub state unknown: {r.limit}: {name}"
        if limit_ok:
            return subprocess.CompletedProcess(cmd, 1, "", msg)
        raise Stop(r.limit, msg, code=3, unknown=True)
    return subprocess.CompletedProcess(cmd, r.rc, r.stdout, r.stderr)


FENCE_VAR = re.compile(r"GH_TOKEN|GIT_SSH_COMMAND|GIT_TERMINAL_PROMPT|GCM_INTERACTIVE|GIT_ASKPASS|SSH_ASKPASS|GIT_CONFIG_COUNT"
                       r"|GIT_CONFIG_(?:KEY|VALUE)_\d+|AS_SH_ORIG_\w+")


def unfenced_env():
    """ENV without an outer as.sh's git fence (and its token), with the values it kept restored: a non-GitHub remote
    authenticates as the user's own git would. Outside as.sh, ENV unchanged."""
    if "AS_SH_ORIG_SET" not in ENV:
        return ENV
    env = {k: v for k, v in ENV.items() if not FENCE_VAR.fullmatch(k)}
    env.update({v: ENV.get(f"AS_SH_ORIG_{v}", "") for v in ENV["AS_SH_ORIG_SET"].split()})
    return env


IDENT = {}
HOST_VARS = ("GH_HOST", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN")  # gh must target github.com only (as.sh unsets them too)
_START = []


def started_in(d):
    """True when `d` is the work tree this process started in: the outer as.sh checked that repo, and only that one."""
    if not _START:
        _START.append(toplevel_path(os.getcwd()))
    return bool(_START[0]) and _START[0] == toplevel_path(d)


def toplevel_path(d):
    r = git(d, "rev-parse", "--show-toplevel")
    return os.path.normcase(os.path.realpath(r.stdout.strip())) if r.returncode == 0 and r.stdout.strip() else ""


def fetch_repo(d):
    """`owner/name` of origin's GitHub fetch URL, whatever its push URLs; None when it does not fetch from GitHub."""
    try:
        return identity(d)["repo"]
    except Stop:
        r = git(d, "remote", "get-url", "origin")
        return parse_repo(r.stdout.strip()) if r.returncode == 0 else None


def git_net(d, *args):
    """git ls-remote / fetch in `d`. A GitHub repo other than the one this process started in is read through as.sh from
    inside it, as its own login, else as the code run login (the ambient, fenced one): the URL check and header scrub of
    the outer as.sh cover only the repo it started in. Non-GitHub remotes stay plain git, outside the outer fence."""
    if d not in IDENT:  # the fetch URL alone decides: a GitHub fetch is fenced, anything else is plain git
        fetch = fetch_repo(d)
        IDENT[d] = fetch.lower() if fetch else None
    name = f"git {args[0]}" if args else "git"
    if IDENT[d] is None:
        return net(["git", *args], name, cwd=d, env=unfenced_env())
    login = REPO_LOGIN.get(IDENT[d])
    if not login:
        if started_in(d):
            return net(["git", *args], name, cwd=d)
        login = ambient_login()
    token_for(login)  # no credential / wrong identity stops here, before any git network command
    r = net([BASH, f"{os.environ['PR_PAIR_DIR']}/as.sh", login, "git", *args], name, cwd=d)
    if r.returncode == 3 and r.stderr.lstrip().startswith("as.sh:"):
        raise Refused("fence_refused", f"as.sh refused the read in {d}: {r.stderr.strip()}", code=3, repo_dir=norm(d))
    return r


REPO_LOGIN, TOKENS = {}, {}  # repo slug (lower) -> login that reads it; login -> its verified token


def gh(*args, repo=None, limit_ok=False):
    # through bash so a `gh` that is a shell script (or a shim) resolves like it does for the caller
    # `repo` names whose login to use when the arguments carry no repo (a GraphQL node id)
    # a paginated read gets the longer deadline; `limit_ok`: a limit is a failed result, not a stop (merge reads back)
    cmd = [BASH, "-c", 'exec gh "$@"', "gh", *args] if BASH else ["gh", *args]
    login = REPO_LOGIN.get((repo or repo_of(args) or "").lower())
    name, paged = f"gh {args[0]}" if args else "gh", "--paginate" in args
    if not login:
        return net(cmd, name, paged=paged, limit_ok=limit_ok)
    env = {**{k: v for k, v in ENV.items() if k not in HOST_VARS}, "GH_TOKEN": token_for(login)}
    return net(cmd, name, env=env, paged=paged, limit_ok=limit_ok)


def repo_of(args):
    for i, x in enumerate(args):
        m = re.match(r"/?repos/([^/]+/[^/?]+)", x)
        if m:
            return m.group(1)
        if x == "--repo" and i + 1 < len(args):
            return args[i + 1]
    return None


def token_for(login):
    """`login`'s gh token, pinned and verified the way as.sh pins one (never `gh auth switch`)."""
    if login not in TOKENS:
        bare = {k: v for k, v in ENV.items() if k not in ("GH_TOKEN", "GITHUB_TOKEN", *HOST_VARS)}
        base = [BASH, "-c", 'exec gh "$@"', "gh"] if BASH else ["gh"]
        r = net(base + ["auth", "token", "--hostname", "github.com", "--user", login], "gh auth", env=bare, secret=True)
        tok = r.stdout.strip() if r.returncode == 0 else ""
        if not tok:
            raise Stop("no_credential", f"no gh credential for '{login}' (planning_store.login); run gh auth login", code=3, login=login)
        v = net(base + ["api", "--hostname", "github.com", "user", "--jq", ".login"], "gh api", env={**bare, "GH_TOKEN": tok})
        if v.stdout.strip() != login:
            raise Stop("identity_mismatch", f"the token for '{login}' resolves to '{v.stdout.strip()}'; refusing", code=3, login=login)
        TOKENS[login] = tok
    return TOKENS[login]


def read_store_as(ctx, store_repo):
    """Store reads use planning_store.login when it differs from the code login the pair-wide call runs as."""
    s, c = (ctx.get("store") or {}).get("login") or "", ctx["code"].get("login") or ""
    if store_repo and s and s.lower() != c.lower():
        REPO_LOGIN[store_repo.lower()] = s


def norm(p):
    return str(p).replace("\\", "/")


def parse_args(argv, spec):
    """spec maps a flag to a destination; '+dest' collects repeats."""
    a, pos, i = {}, [], 0
    while i < len(argv):
        t = argv[i]
        if t in spec:
            dest = spec[t]
            if i + 1 >= len(argv):
                usage(f"{t} needs a value")
            v, i = argv[i + 1], i + 2
            if dest.startswith("+"):
                a.setdefault(dest[1:], []).append(v)
            else:
                a[dest] = v
        elif t.startswith("--"):
            usage(f"unknown option {t}")
        else:
            pos.append(t)
            i += 1
    return a, pos


def need(a, *names):
    for n in names:
        if not a.get(n):
            usage(f"missing --{n.replace('_', '-')}")


# ---- a small YAML reader: maps, scalars, flow maps/lists, comments (all specwright.yaml uses) ------------------
def strip_comment(s):
    q, esc = None, False
    for i, ch in enumerate(s):
        if esc:
            esc = False
        elif q:
            if q == '"' and ch == "\\":
                esc = True
            elif ch == q:
                q = None
        elif ch in "\"'":
            q = ch
        elif ch == "#" and (i == 0 or s[i - 1] in " \t"):
            return s[:i]
    return s


def split_top(s, sep=","):
    parts, depth, q, esc, cur = [], 0, None, False, ""
    for ch in s:
        if esc:
            esc = False
        elif q:
            if q == '"' and ch == "\\":
                esc = True
            elif ch == q:
                q = None
        elif ch in "\"'":
            q = ch
        elif ch in "{[":
            depth += 1
        elif ch in "}]":
            depth -= 1
        elif ch == sep and depth == 0:
            parts.append(cur)
            cur = ""
            continue
        cur += ch
    if cur.strip():
        parts.append(cur)
    return parts


def scalar(v):
    v = v.strip()
    if v == "":
        return None
    if v[0] == "{" and v[-1] == "}":
        out = {}
        for part in split_top(v[1:-1]):
            k, _, val = part.partition(":")
            out[unquote(k.strip())] = scalar(val)
        return out
    if v[0] == "[" and v[-1] == "]":
        return [scalar(p) for p in split_top(v[1:-1])]
    if v[0] in "\"'" and v[-1] == v[0] and len(v) >= 2:
        return unquote(v)
    if v.lower() in ("true", "yes"):
        return True
    if v.lower() in ("false", "no"):
        return False
    if v in ("null", "~"):
        return None
    if re.fullmatch(r"-?\d+", v):
        return int(v)
    return v


YAML_ESCAPES = {"0": "\0", "a": "\a", "b": "\b", "t": "\t", "\t": "\t", "n": "\n", "v": "\v", "f": "\f", "r": "\r",
                "e": "\x1b", " ": " ", '"': '"', "/": "/", "\\": "\\", "N": "\x85", "_": "\xa0", "L": "\u2028", "P": "\u2029"}


def unquote(k):
    """Strip a scalar's quotes and decode them as YAML does: `''` in single quotes, backslash escapes in double."""
    if len(k) < 2 or k[0] not in "\"'" or k[-1] != k[0]:
        return k
    body = k[1:-1]
    if k[0] == "'":
        return body.replace("''", "'")

    def esc(m):
        e = m.group(1)
        return chr(int(e[1:], 16)) if len(e) > 1 else YAML_ESCAPES.get(e, m.group(0))
    return re.sub(r"\\(x[0-9a-fA-F]{2}|u[0-9a-fA-F]{4}|U[0-9a-fA-F]{8}|.)", esc, body)


BLOCK_HEADER = re.compile(r"^([|>])([+-]?)\d*$")


def block_scalar(raw, start, indent, style, chomp):
    """Read a `|` or `>` block scalar from raw lines after a key at `indent`; returns (value, next raw index)."""
    end = start
    while end < len(raw) and (not raw[end].strip() or len(raw[end]) - len(raw[end].lstrip(" ")) > indent):
        end += 1
    body = [l.rstrip("\r") for l in raw[start:end]]
    filled = [l for l in body if l.strip()]
    pad = len(filled[0]) - len(filled[0].lstrip(" ")) if filled else 0
    lines = [l[pad:] if l.strip() else "" for l in body]
    trailing = 0
    while lines and lines[-1] == "":
        lines.pop()
        trailing += 1
    if style == "|":
        text = "\n".join(lines)
    else:
        text, prev = "", None
        for l in lines:
            text += "\n" if l == "" else (" " + l if prev else l)
            prev = l != ""
    if not lines or chomp == "-":
        return text, end
    return text + "\n" + ("\n" * trailing if chomp == "+" else ""), end


class Map(dict):
    """A YAML mapping that also keeps each plain scalar's text as written (`yes` stays `yes` in messages)."""
    def __init__(self):
        super().__init__()
        self.text = {}


def parse_yaml(text):
    raw = text.splitlines()
    lines = []
    for n, r in enumerate(raw):
        s = strip_comment(r).rstrip()
        if s.strip():
            lines.append((len(s) - len(s.lstrip(" ")), s.strip(), n))

    def block(i, indent):
        d = Map()
        while i < len(lines) and lines[i][0] == indent:
            body = lines[i][1]
            m = re.match(r"^((?:\"(?:[^\"\\]|\\.)*\"|'(?:[^']|'')*'|[^:\s][^:]*?)):(?:\s+(.*))?$", body)
            if not m:
                i += 1
                continue
            key, val = unquote(m.group(1).strip()), m.group(2)
            row = lines[i][2]
            i += 1
            header = BLOCK_HEADER.match(val.strip()) if val else None
            if header:
                d[key], end = block_scalar(raw, row + 1, indent, header.group(1), header.group(2))
                while i < len(lines) and lines[i][2] < end:
                    i += 1
            elif val is None or val.strip() == "":
                if i < len(lines) and lines[i][0] > indent:
                    d[key], i = block(i, lines[i][0])
                else:
                    d[key] = None
            else:
                d[key] = scalar(val)
                d.text[key] = val.strip()
        return d, i

    return block(0, lines[0][0])[0] if lines else {}


def escape_len(s, i):
    """Length of the double-quoted escape at s[i] (a backslash) as YAML defines it, or 0 when YAML has no such escape."""
    c = s[i + 1:i + 2]
    if c in ("x", "u", "U"):
        n = {"x": 2, "u": 4, "U": 8}[c]
        h = s[i + 2:i + 2 + n]
        if not re.fullmatch(r"[0-9a-fA-F]{%d}" % n, h):
            return 0
        v = int(h, 16)  # YAML rejects a surrogate (a pair too) and a code point past U+10FFFF
        return 0 if 0xD800 <= v <= 0xDFFF or v > 0x10FFFF else 2 + n
    return 2 if c and c in YAML_ESCAPES else 0


class YamlBad(ValueError):
    pass


PLAIN_START_BAD = set("[]{},#&*!|>'\"%@`")
FLOW_CHARS = set(",[]{}")


def plain_ok(v, flow, key=False):
    """Raise YamlBad unless v is a plain scalar that parse_yaml reads as YAML does."""
    if not v:
        raise YamlBad("an empty entry")
    if v[0] in PLAIN_START_BAD or (v[0] in "-?:" and (len(v) == 1 or v[1] in " \t" or (flow and v[1] in FLOW_CHARS))) \
            or (flow and v[0] in "?:"):  # in a flow collection YAML 1.1 parsers (Psych) read a leading `?` or `:` as an indicator
        raise YamlBad(f"`{v[0]}` cannot start a plain value (anchors, tags, aliases and directives are not read)")
    if " #" in v or "\t#" in v:
        raise YamlBad("a comment the reader would keep as text")
    if re.search(r":[ \t]", v) or v.endswith(":"):
        raise YamlBad("a plain value holds `:` before a space or tab")
    if flow and (set(v) & (FLOW_CHARS | {"'", '"'})):
        raise YamlBad("a flow entry holds `,`, a bracket or a quote outside quotes")
    if key and ":" in v:
        raise YamlBad("a flow key holds `:` (the reader splits at the first one)")


def quoted_end(v, i):
    """Index after the quoted scalar starting at v[i]; raises YamlBad on an unknown escape or a missing closing quote."""
    q, j = v[i], i + 1
    while j < len(v):
        if q == '"' and v[j] == "\\":
            n = escape_len(v, j)
            if not n:
                raise YamlBad(f"unknown escape `{v[j:j + 2]}`")
            j += n
            continue
        if v[j] == q:
            if q == "'" and v[j + 1:j + 2] == "'":
                j += 2
                continue
            return j + 1
        j += 1
    raise YamlBad("unterminated quote")


def key_too_long(k):
    """YAML ends a simple (implicit) key within 1024 characters; the reader has no limit."""
    return "a key of 1024 characters or more (YAML's simple-key limit)" if len(k.strip()) >= 1024 else None


MAX_DEPTH = 32  # nesting the validator accepts; deeper would exhaust Python's recursion limit here or in parse_yaml


def flow_node(v, i, key=False, depth=0):
    """Index after one flow node at v[i] (i already past spaces): a collection, a quoted or a plain scalar."""
    if i >= len(v):
        raise YamlBad("an empty entry")
    c = v[i]
    if key and c in "[{":
        raise YamlBad("a flow key that is a collection")
    if c == "[" or c == "{":
        if depth >= MAX_DEPTH:
            raise YamlBad(f"flow collections nested more than {MAX_DEPTH} deep")
        close, j, keys = ("]" if c == "[" else "}"), i + 1, set()
        while True:
            j = skip_ws(v, j)
            if j >= len(v):
                raise YamlBad(f"unterminated `{c}`")
            if v[j] == close:
                return j + 1
            if v[j] == ",":
                raise YamlBad("an empty entry")
            start = j
            j = flow_node(v, j, key=c == "{", depth=depth + 1)
            j = skip_ws(v, j)
            if c == "{":
                why = key_too_long(v[start:j].strip())
                if why:
                    raise YamlBad(why)
                key = unquote(v[start:j].strip())
                if v[start:j].strip() == "<<":
                    raise YamlBad("a `<<` merge key (YAML merges it in, the reader does not)")
                if key in keys:
                    raise YamlBad(f"duplicate key `{key}`")
                keys.add(key)
                if j < len(v) and v[j] == ":":
                    if v[j + 1:j + 2] not in (" ", "\t"):  # `{a:[]}`, `{"a":1}`, `{a:}`: YAML 1.1 parsers want the space
                        raise YamlBad("a flow key's `:` not followed by a space")
                    j = skip_ws(v, j + 1)
                    if j < len(v) and v[j] not in ",}":
                        j = skip_ws(v, flow_node(v, j, depth=depth + 1))
            elif j < len(v) and v[j] == ":":
                raise YamlBad("a `key: value` pair inside `[...]` is read as text")
            if j >= len(v):
                raise YamlBad(f"unterminated `{c}`")
            if v[j] == ",":
                j = skip_ws(v, j + 1)
                if j < len(v) and v[j] == close:
                    raise YamlBad("a trailing comma (the reader keeps it as an empty entry)")
            elif v[j] != close:
                raise YamlBad(f"`{v[j]}` where `,` or `{close}` belongs")
    if c in "]}":
        raise YamlBad(f"unbalanced `{c}`")
    if c in "\"'":
        return quoted_end(v, i)
    j = i
    # libyaml ends a flow plain scalar at `:` before a space or any of `,?[]{}`
    while j < len(v) and v[j] not in FLOW_CHARS and not (v[j] == ":" and (j + 1 == len(v) or v[j + 1] in " \t,?[]{}")):
        j += 1
    plain_ok(v[i:j].rstrip(), True, key)
    return j


def skip_ws(v, i):
    while i < len(v) and v[i] in " \t":
        i += 1
    return i


def value_problem(v):
    """Why a value (or a quoted key) is not YAML that parse_yaml reads as written, or None."""
    v = v.strip()
    try:
        if v[0] in "[{\"'":
            j = flow_node(v, 0) if v[0] in "[{" else quoted_end(v, 0)
            if v[j:].strip():
                raise YamlBad("text after the closing " + ("bracket" if v[0] in "[{" else "quote"))
        else:
            plain_ok(v, False)
    except YamlBad as e:
        return str(e)
    return None


def yaml_problem(text):
    """The first line parse_yaml would skip, drop or misread, as `line N: why`, or None.

    parse_yaml is lenient for local settings; `policy` authorizes a merge from a remote file, so a file it cannot read whole
    is unknown there (ADR 0020 D4). This checks the YAML subset the reader reads as YAML does: block mappings, flow
    collections, quoted and plain scalars, `|`/`>` blocks. What it would read otherwise (block sequences, anchors, tags,
    aliases, tabs in indentation, duplicate keys, explicit indentation indicators) is a problem too, so it fails closed."""
    # YAML allows tab, LF, CR and printable characters; U+0085, U+2028, U+2029 and U+FEFF are excluded too
    odd = re.search("[^\t\n\r\x20-\x7e\xa0-\ud7ff\ue000-\ufffd\U00010000-\U0010ffff]|[\u2028\u2029\ufeff]", text)
    if odd:  # str.splitlines breaks at some of these where YAML does not, and YAML forbids the controls
        row = len(re.split(r"\r\n|\r|\n", text[:odd.start()]))
        return f"line {row}: a control character or line separator (U+{ord(odd.group()):04X})"
    odd = re.search(r"[^\S \t\r\n]", text)  # Python's \s and strip() take these as space, YAML takes them as text
    if odd:
        row = len(re.split(r"\r\n|\r|\n", text[:odd.start()]))
        return f"line {row}: a space character YAML does not separate with (U+{ord(odd.group()):04X})"
    raw = text.splitlines()
    key_re = re.compile(r"^((?:\"(?:[^\"\\]|\\.)*\"|'(?:[^']|'')*'|[^:\s][^:]*?)):(?:\s+(.*))?$")
    lines = []
    marker = False  # the one `---` allowed, before any key
    block = None  # the key's indentation while inside a `|`/`>` block, whose text mapping() checks from the raw lines
    for n, r in enumerate(raw):
        if not r.strip() and "\t" in r:  # blank lines too, in a block or not: YAML rejects or keeps them, the reader drops them
            return f"line {n + 1}: a tab in the indentation"
        if block is not None and (not r.strip() or len(r) - len(r.lstrip(" ")) > block):
            continue  # block text: a tab after its space indentation is text
        block = None
        if "\t" in r[:len(r) - len(r.lstrip())]:
            return f"line {n + 1}: a tab in the indentation"
        s = strip_comment(r).rstrip()
        if s.strip():
            lead = s[:len(s) - len(s.lstrip())]
            if not lead and re.match(r"(---|\.\.\.)(\s|$)", s):  # indented: block text, or not a `key: value` line below
                if marker or lines or s != "---":
                    return f"line {n + 1}: a document marker the reader does not read (only `---` alone, first, at column 0)"
                marker = True
                continue
            lines.append((len(lead), s.strip(), n))
            m = key_re.match(s.strip())
            if m and m.group(2) and m.group(2).strip()[0] in "|>":
                block = len(lead)

    def bad(i, why):
        raise YamlBad(f"line {lines[i][2] + 1}: {why}")

    def mapping(i, indent, depth=0):
        if depth >= MAX_DEPTH:
            bad(i, f"mappings nested more than {MAX_DEPTH} deep")
        keys = set()
        while i < len(lines) and lines[i][0] == indent:
            body, row = lines[i][1], lines[i][2]
            if body == "-" or body.startswith("- "):
                bad(i, "a block sequence (`- item`) is not read; write it as `[a, b]`")
            m = key_re.match(body)
            if not m:
                bad(i, "not a `key: value` line")
            k = m.group(1)
            why = value_problem(k) or key_too_long(k)
            if why:
                bad(i, why)
            key = unquote(k.strip())
            if k.strip() == "<<":
                bad(i, "a `<<` merge key (YAML merges it in, the reader does not)")
            if key in keys:
                bad(i, f"duplicate key `{key}`")
            keys.add(key)
            val = m.group(2)
            if val and val.strip()[0] in "|>":
                if not BLOCK_HEADER.match(val.strip()) or re.search(r"\d", val):
                    bad(i, "a block scalar header the reader does not read (only |, >, with + or -)")
                end = block_scalar(raw, row + 1, indent, "|", "")[1]
                body_rows = [r for r in raw[row + 1:end] if r.strip()]
                if body_rows:
                    pad = len(body_rows[0]) - len(body_rows[0].lstrip(" "))
                    for r in raw[row + 1:end]:
                        if r.strip():
                            break
                        if len(r) > pad:
                            bad(i, "a blank line before a block scalar's text with more spaces than the text")
                    if any(len(r) - len(r.lstrip(" ")) < pad for r in body_rows):
                        bad(i, "a block scalar line indented less than its first line")
                    if val.strip()[0] == ">" and any(len(r) - len(r.lstrip(" ")) > pad or r[pad] == "\t" for r in body_rows):
                        bad(i, "a more-indented or tab-led line in a `>` block (YAML keeps its line breaks, the reader folds them)")
                i += 1
                while i < len(lines) and lines[i][2] < end:
                    i += 1
            elif val is None or val.strip() == "":
                i += 1
                if i < len(lines) and lines[i][0] > indent:
                    i = mapping(i, lines[i][0], depth + 1)
            else:
                why = value_problem(val)
                if why:
                    bad(i, why)
                i += 1
        return i

    if not lines:
        return None
    try:
        i = mapping(0, lines[0][0])
        if i < len(lines):
            bad(i, "unexpected indentation")
    except YamlBad as e:
        return str(e)
    return None


def duration(v, default):
    if v is None or v == "":
        return default
    if isinstance(v, int):
        return v
    m = re.fullmatch(r"(\d+)\s*([smh]?)", str(v).strip())
    if not m:
        return default
    return int(m.group(1)) * {"": 1, "s": 1, "m": 60, "h": 3600}[m.group(2)]


# ---- repositories ----------------------------------------------------------------------------------------------
def parse_repo(url):
    m = GH_URL.match(url.strip())
    return f"{m.group(1)}/{m.group(2)}" if m else None


def identity(d):
    if not d or not Path(d).is_dir() or git(d, "rev-parse", "--git-dir").returncode != 0:
        raise Stop("not-a-repo", f"{d} is not a git work tree")
    r = git(d, "remote", "get-url", "origin")
    if r.returncode != 0:
        raise Stop("no-origin", f"{d} has no origin remote")
    fetch_url = r.stdout.strip()
    push_urls = [u for u in git(d, "remote", "get-url", "--push", "--all", "origin").stdout.split("\n") if u.strip()] or [fetch_url]
    fetch, push = parse_repo(fetch_url), [parse_repo(u) for u in push_urls]
    if fetch is None or any(p is None for p in push):
        raise Stop("not-github", f"origin of {d} is not a GitHub repository: fetch {fetch_url}, push {', '.join(push_urls)}",
                   fetch_url=fetch_url, push_urls=push_urls)
    if any(p.lower() != fetch.lower() for p in push):
        raise Stop("mismatch", f"origin of {d} fetches from {fetch} but pushes to {', '.join(push)}; "
                   "forks and mirrors as push targets are not supported", fetch=fetch, push=push)
    return {"ok": True, "repo": fetch, "owner": fetch.split("/")[0], "name": fetch.split("/")[1], "fetch": fetch, "push": push}


def has_ref(d, ref):
    return git(d, "show-ref", "--verify", "--quiet", ref).returncode == 0


def detect_main(d):
    for name in ("main", "master"):
        if has_ref(d, f"refs/heads/{name}") or has_ref(d, f"refs/remotes/origin/{name}"):
            return name
    return "main"


def main_ref(d, main):
    for ref in (f"refs/heads/{main}", f"refs/remotes/origin/{main}"):
        if has_ref(d, ref):
            return ref
    return None


def toplevel(d):
    r = git(d, "rev-parse", "--show-toplevel")
    return r.stdout.strip() if r.returncode == 0 and r.stdout.strip() else d


# ---- settings --------------------------------------------------------------------------------------------------
def settings_text(code_dir):
    """The text of openspec/specwright.yaml in the work tree (the directory, else its top level), or None when there is none."""
    for base in (code_dir, toplevel(code_dir)):
        p = Path(base) / "openspec" / "specwright.yaml"
        if p.is_file():
            return p.read_text(encoding="utf-8", errors="replace")
    return None


def load_settings(code_dir):
    text = settings_text(code_dir)
    return (parse_yaml(text) or {}) if text is not None else {}


MAX_REVIEWERS = 20  # per set: a bigger set is too_many_reviewers
MAX_CONFIG_BYTES = 64 * 1024  # a reviewer-config file stays under this


def problem(key, why, error="bad_setting"):
    return {"error": error, "key": key, "why": why}


def problem_text(p):
    return f"{p['key']}: {p['why']}"


def report_of(v):
    """A reviewer's `report` normalized: (dict of each key to its string value, None), or ({}, why) when it is not a mapping of
    strings. Unknown keys stay as read: the snapshot's evaluator validates keys and patterns and names an unknown key."""
    if v is None or v == "":
        return {}, None
    if not isinstance(v, dict):
        return {}, "must be a mapping of keys to strings"
    for k, x in v.items():
        if not isinstance(x, str):
            return {}, f"{k} must be a string (quote it if it looks like a number or a boolean)"
    return {str(k): x for k, x in v.items()}, None


def reviewers_of(raw, problems=None, where="pr.reviewers"):
    """The reviewer set of a settings map. A set or a `report` the settings get wrong is appended to `problems` (when given)."""
    out = {}
    if problems is not None and isinstance(raw, dict) and len(raw) > MAX_REVIEWERS:
        problems.append(problem(where, f"{len(raw)} reviewers is too_many_reviewers (at most {MAX_REVIEWERS})", "too_many_reviewers"))
    for login, cfg in (raw or {}).items():
        cfg = cfg if isinstance(cfg, dict) else {}
        name = re.sub(r"\[bot\]$", "", str(login))
        report, why = report_of(cfg.get("report"))
        if why and problems is not None:
            problems.append(problem(f"{where}.{name}.report", why))
        out[name] = {
            "role": str(cfg.get("role") or "required"), "timeout": duration(cfg.get("timeout"), 1200),
            "request": str(cfg.get("request") or ""), "report": report}
    return out


def settle_of(pr):
    """pr.settle as (seconds, None); strictly <int><s|m|h>, 1m to 1h. Unset is 300. A bad value is (300, problem)."""
    v = pr.get("settle")
    if v is None or v == "":
        return 300, None
    m = re.fullmatch(r"([0-9]+)([smh])", v) if isinstance(v, str) else None
    seconds = int(m.group(1)) * {"s": 1, "m": 60, "h": 3600}[m.group(2)] if m else None
    if seconds is None or not 60 <= seconds <= 3600:
        return 300, problem("pr.settle", f"{setting_text(pr, 'settle')} must be a duration of 1m to 1h written as <number>s, <number>m or <number>h")
    return seconds, None


def reviewer_config_bytes(reviewers):
    """The canonical bytes of a reviewer-config file: sorted keys, compact, UTF-8, reviewers by login, no `request`."""
    entries = [{"login": l, "role": r["role"], "timeout": r["timeout"], "report": r["report"]} for l, r in sorted(reviewers.items())]
    obj = {"format": 1, "reviewers": entries}
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8", errors="replace")


def write_reviewer_config(reviewers):
    """Write the set as a content-addressed file: (path or None, sha256 hex of its bytes, problem or None). The file lives in
    <state dir>/reviewers/<digest>.json, else under the system temp dir; an existing file of that name with the same bytes is
    reused. The location never stops the caller: with no writable place the path is None."""
    data = reviewer_config_bytes(reviewers)
    digest = hashlib.sha256(data).hexdigest()
    why = problem("reviewer config", f"{len(data)} bytes is over the {MAX_CONFIG_BYTES // 1024} KB limit") if len(data) >= MAX_CONFIG_BYTES else None
    state = Path(os.environ.get("SPECWRIGHT_STATE_DIR") or str(Path.home() / ".cache" / "specwright"))
    for base in (state, Path(tempfile.gettempdir()) / "specwright"):
        target = base / "reviewers" / f"{digest}.json"
        tmp = None
        try:
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.is_file() and target.read_bytes() == data:
                return norm(target), digest, why
            fd, tmp = tempfile.mkstemp(dir=str(target.parent), prefix=".tmp-", suffix=".json")
            with os.fdopen(fd, "wb") as f:
                f.write(data)
            os.replace(tmp, target)
            return norm(target), digest, why
        except OSError:
            if tmp:
                with contextlib.suppress(OSError):
                    os.unlink(tmp)
            with contextlib.suppress(OSError):  # a concurrent writer of the same rules may have won the rename
                if target.read_bytes() == data:
                    return norm(target), digest, why
    return None, digest, why


def repo_ctx(s, d, which, problems=None):
    g, pr, ps = s.get("github") or {}, s.get("pr") or {}, s.get("planning_store") or {}
    rr = g.get("review_request") or {}
    c = {"dir": norm(d), "review_request": {"body": str(rr.get("body") or ""), "login": str(rr.get("login") or ""),
                                              "after_fixes": bool(rr.get("after_fixes"))},
         "request_as": str(pr.get("request_as") or "")}
    if which == "store":
        c["login"] = str(ps.get("login") or g.get("login") or "")
        c["main"] = str(ps.get("main_branch") or detect_main(d))
        c["validate"] = str(ps.get("validate") or "")
        own = ps.get("reviewers")
        if isinstance(own, dict):
            c["reviewers"] = reviewers_of(own, problems, "planning_store.reviewers")
        else:
            c["reviewers"] = reviewers_of(pr.get("reviewers"), problems)
        c["requests_disabled"] = isinstance(own, dict) and not own
    else:
        c["login"] = str(g.get("login") or "")
        c["main"] = str(s.get("main_branch") or detect_main(d))
        c["validate"] = str(pr.get("validate") or "")
        c["reviewers"] = reviewers_of(pr.get("reviewers"), problems)
        c["requests_disabled"] = False
    ready = any(r["role"] == "required" for r in c["reviewers"].values())
    c["merge_ready"], c["merge_reason"] = ready, None if ready else "no_required_reviewer"
    return c


def setting_text(m, key):
    """The setting as the user wrote it, for messages; the parsed value when the text is not kept."""
    text = m.text.get(key) if isinstance(m, Map) else None
    if text is not None:
        return text
    v = m.get(key)
    return str(v).lower() if isinstance(v, bool) else str(v)


def merge_mode(pr):
    """pr.merge as the policy reads it: (user|agent, note). Anything else is user, with a note naming the value as written."""
    merge = pr.get("merge")
    note = None
    if merge not in (None, "") and merge not in ("user", "agent"):
        note = f"pr.merge: {setting_text(pr, 'merge')} is not user or agent; treated as user"
    return (merge if merge in ("user", "agent") else "user"), note


def merge_options(pr):
    """pr.merge_method and pr.delete_branch with their defaults; a bad value is exit 2 bad_setting."""
    method = pr.get("merge_method")
    method = "merge" if method is None else method
    if method not in ("merge", "squash", "rebase"):
        raise Stop("bad_setting", f"pr.merge_method: {setting_text(pr, 'merge_method')} must be merge, squash or rebase", code=2)
    delete = pr.get("delete_branch")
    delete = True if delete is None else delete
    if not isinstance(delete, bool):
        raise Stop("bad_setting", f"pr.delete_branch: {setting_text(pr, 'delete_branch')} must be true or false", code=2)
    return method, delete


def contexts(code, store, check_merge=True, problems=None):
    """Both repos' contexts. `problems` (a list) collects what the settings get wrong in the reviewer sets and pr.settle."""
    s = load_settings(code)
    pr = s.get("pr") or {}
    settle, bad = settle_of(pr)
    if bad and problems is not None:
        problems.append(bad)
    out = {"code": repo_ctx(s, code, "code", problems), "store": repo_ctx(s, store, "store", problems) if store else None,
           "finish": str(s.get("finish") or ""), "max_fix_rounds": int(pr.get("max_fix_rounds") if isinstance(pr.get("max_fix_rounds"), int) else 2),
           "after_limit": str(pr.get("after_limit") or "ask"), "react": bool(pr.get("react")),
           "poll_interval": duration(pr.get("poll_interval"), 300), "settle": settle}
    out["merge"], note = merge_mode(pr)
    if note:
        out["merge_note"] = note
    out["merge_method"], out["delete_branch"] = "merge", True
    if out["merge"] != "agent" or not check_merge:  # only the agent merge reads them: user mode keeps today's behaviour
        return out
    out["merge_method"], out["delete_branch"] = merge_options(pr)
    return out


def review_requests(c):
    """The re-requests this repo's settings call for after a push (SKILL: Re-request review)."""
    if c["requests_disabled"]:
        return []
    if c["reviewers"]:
        poster = c["request_as"] or c["review_request"]["login"] or c["login"]
        return [{"body": r["request"], "poster": poster} for r in c["reviewers"].values() if r["request"]]
    rr = c["review_request"]
    if rr["body"] and rr["after_fixes"]:
        return [{"body": rr["body"], "poster": rr["login"] or c["login"]}]
    return []


# ---- GitHub ----------------------------------------------------------------------------------------------------
def unknown(msg):
    raise Stop("lookup_failed", f"GitHub state unknown: {msg}", code=3, unknown=True)


def decode_pages(text):
    dec, i, pages = json.JSONDecoder(), 0, []
    while True:
        while i < len(text) and text[i].isspace():
            i += 1
        if i >= len(text):
            return pages
        obj, i = dec.raw_decode(text, i)
        pages.append(obj)


def gh_list(endpoint):
    r = gh("api", "--paginate", endpoint)
    if r.returncode != 0:
        unknown((r.stderr or r.stdout).strip() or f"gh exited {r.returncode}")
    try:
        pages = decode_pages(r.stdout)
    except ValueError as e:
        unknown(f"unreadable response: {e}")
    items = []
    for p in pages:
        if not isinstance(p, list):
            unknown("unexpected response shape")
        items.extend(p)
    if not pages:
        unknown("empty response")
    return items


def gh_obj(endpoint, *extra):
    r = gh("api", *extra, endpoint)
    if r.returncode != 0:
        unknown((r.stderr or r.stdout).strip() or f"gh exited {r.returncode}")
    try:
        return json.loads(r.stdout)
    except ValueError as e:
        unknown(f"unreadable response: {e}")


_AMBIENT = []


def ambient_login():
    """The active gh login, read once per run: a later `gh auth switch` cannot change it mid-run."""
    if not _AMBIENT:
        r = gh("api", "user", "--jq", ".login")
        if r.returncode != 0 or not r.stdout.strip():
            unknown("cannot read the ambient gh login")
        _AMBIENT.append(r.stdout.strip())
    return _AMBIENT[0]


def norm_pr(p):
    state = "MERGED" if p.get("merged_at") else ("OPEN" if p.get("state") == "open" else "CLOSED")
    return {"number": p["number"], "url": p["html_url"], "state": state, "base": (p.get("base") or {}).get("ref"),
            "head_sha": (p.get("head") or {}).get("sha"), "merged_at": p.get("merged_at"),
            "merge_commit_sha": p.get("merge_commit_sha"), "title": p.get("title", "")}


def discover(repo, branch, base=None, states=None):
    owner = repo.split("/")[0]
    items = gh_list(f"repos/{repo}/pulls?state=all&head={owner}:{branch}&per_page=100")
    own = {}
    for p in items:  # a same-named PR from a fork is not the change's PR
        head = p.get("head") or {}
        if ((head.get("repo") or {}).get("full_name") or "").lower() == repo.lower() and head.get("ref") == branch:
            own[p["number"]] = norm_pr(p)
    prs = sorted(own.values(), key=lambda p: -p["number"])
    other = []
    if base:
        other = [p for p in prs if p["base"] != base]
        prs = [p for p in prs if p["base"] == base]
    if states and "all" not in states:
        prs = [p for p in prs if p["state"].lower() in states]
    return {"ok": True, "repo": repo, "branch": branch, "base": base, "prs": prs, "other_base": other,
            "newest": prs[0] if prs else None}


def pr_of(prs):
    return next((p for p in prs if p["state"] == "OPEN"), prs[0] if prs else None)


# ---- subcommands -----------------------------------------------------------------------------------------------
def cmd_identity(argv):
    _, pos = parse_args(argv, {})
    if len(pos) != 1:
        usage("identity <dir>")
    return identity(pos[0])


def settings_path(code):
    """The settings file load_settings reads, or None."""
    for base in (code, toplevel(code)):
        p = Path(base) / "openspec" / "specwright.yaml"
        if p.is_file():
            return p.resolve()  # absolute: git runs with cwd=toplevel, so a path relative to the caller would miss
    return None


def settings_pinned(code, ref, branch, after_merge=False):
    """GitButler: the work-tree settings file must equal the one at `ref` (hash-object applies the repo's clean and eol
    filters, so a CRLF checkout compares equal). Raises settings_not_pinned (a difference, or a file on one side only) or git_error."""
    top = toplevel(code)
    path = settings_path(code)
    rel = "openspec/specwright.yaml"
    if path is not None:
        try:
            rel = path.resolve().relative_to(Path(top).resolve()).as_posix()
        except ValueError:
            pass
    work = None
    if path is not None:
        r = git(top, "hash-object", f"--path={rel}", str(path))
        if r.returncode != 0:
            raise Stop("git_error", f"git hash-object {rel} failed: {r.stderr.strip()}")
        work = r.stdout.strip()
    r = git(top, "ls-tree", ref, "--", rel)
    if r.returncode != 0:
        raise Stop("git_error", f"git ls-tree {ref} -- {rel} failed: {r.stderr.strip()}")
    parts = r.stdout.split()
    tip = parts[2] if len(parts) >= 3 else None
    if work == tip:
        return
    if after_merge:
        how = f"run `but pull` or undo the edit of {rel} in the work tree before acting on it"
    else:
        how = f"commit the edit on {branch}, or undo it, before this step"
    if work is None:
        state = f"{rel} is missing from the work tree but present at {ref}"
    elif tip is None:
        state = f"{rel} exists in the work tree but not at {ref}"
    else:
        state = f"{rel} in the work tree differs from the copy at {ref}"
    raise Stop("settings_not_pinned", f"{state}; with vcs: gitbutler the settings are those the change branch committed: {how}",
               file=rel, ref=ref)


def gitbutler_pins(code):
    """Whether `context` pins the settings: `vcs: gitbutler` in the work-tree file, or a GitButler-managed repo as vcs.sh
    `gitbutler_managed` sees it (`gitbutler/` in the common git dir and gitbutler.project.targetRef set). The second does not
    come from the file being checked, so an unpinned edit of the `vcs:` line cannot turn the check off; a leftover target ref
    without the metadata dir is a Git or jj checkout and does not pin."""
    if load_settings(code).get("vcs") == "gitbutler":
        return True
    # no --path-format (git 2.31+): on an older git it would fail and turn the check off; a relative answer is
    # relative to `code`, as vcs.sh gitbutler_managed resolves it
    r = git(code, "rev-parse", "--git-common-dir")
    common = r.stdout.strip()
    if r.returncode != 0 or not common:
        return False
    common_dir = Path(common) if Path(common).is_absolute() else Path(code) / common
    if not (common_dir / "gitbutler").is_dir():
        return False
    r = git(code, "config", "--get", "gitbutler.project.targetRef")
    return r.returncode == 0 and bool(r.stdout.strip())


def pin_ref(code, branch, after_merge):
    if not after_merge:
        return f"refs/heads/{branch}"
    if has_ref(code, f"refs/heads/{branch}"):
        return f"refs/heads/{branch}"
    r = git(code, "config", "--get", "gitbutler.project.targetRef")
    target = r.stdout.strip() if r.returncode == 0 else ""
    if not target:
        raise Stop("git_error", "gitbutler.project.targetRef is not set, so there is no target to compare the settings with")
    return target


def cmd_context(argv):
    after_merge = "--after-merge" in argv
    argv = [t for t in argv if t != "--after-merge"]
    a, _ = parse_args(argv, {"--code": "code", "--store": "store", "--only": "only", "--branch": "branch"})
    need(a, "code")
    if a.get("only") not in (None, "repos"):
        usage("--only takes repos")
    if after_merge and not a.get("branch"):
        usage("--after-merge needs --branch")
    if gitbutler_pins(a["code"]):
        if a.get("only") != "repos" and not a.get("branch"):
            usage("with vcs: gitbutler, context for the merge settings needs --branch <branch>")
        if a.get("branch"):
            settings_pinned(a["code"], pin_ref(a["code"], a["branch"], after_merge), a["branch"], after_merge)
    text = settings_text(a["code"])
    problems = []
    strict = yaml_problem(text) if text is not None else None
    c = contexts(a["code"], a.get("store"), check_merge=a.get("only") != "repos", problems=problems)
    for k, d in (("code", a["code"]), ("store", a.get("store"))):
        if c[k] is not None:
            try:
                c[k]["repo"] = identity(d)["repo"]
            except Stop:
                c[k]["repo"] = None
            c[k]["reviewer_config"], _, big = write_reviewer_config(c[k]["reviewers"])
            if big:
                problems.append(big)
    out = {"ok": True, **c}
    first = strict or (problem_text(problems[0]) if problems else None)  # the first problem found, not exit 1: the lenient read went on
    if first:
        out["settings_problem"] = first
    return out


def cmd_tier(argv):
    a, _ = parse_args(argv, {"--code": "code"})
    need(a, "code")
    section = load_settings(a["code"]).get("cheap_tier")
    out = {"ok": True, "cheap_tier": False}
    if section is None:
        return out
    if not isinstance(section, dict):
        out["note"] = "cheap_tier must hold enabled: true|false; treated as false"
        return out
    v = section.get("enabled")
    if v is True:
        out["cheap_tier"] = True
    elif v is not False and v is not None:
        out["note"] = f"cheap_tier.enabled: {setting_text(section, 'enabled')} is not true or false; treated as false"
    return out
def cmd_vcs(argv):
    a, _ = parse_args(argv, {"--code": "code"})
    need(a, "code")
    raw = load_settings(a["code"])
    planning_store = raw.get("planning_store")
    if not isinstance(planning_store, dict):
        planning_store = {}

    def selected(section, name, accepted):
        value = section.get("vcs")
        if value is None:
            return "git"
        if value not in accepted:
            raise Stop("unknown_vcs", f"unknown {name} VCS {value!r}; accepted values: {', '.join(accepted)}")
        return value

    code = selected(raw, "code", ("git", "jj", "gitbutler"))
    if planning_store.get("vcs") == "gitbutler":
        raise Stop("unsupported_vcs", "planning_store.vcs: gitbutler is not supported; a store accepts git or jj")
    store = selected(planning_store, "planning_store", ("git", "jj"))
    if code == "gitbutler" and raw.get("finish") != "pr":
        raise Stop("unsupported_combination", "vcs: gitbutler runs only with finish: pr (finish is "
                   f"{setting_text(raw, 'finish') if raw.get('finish') is not None else 'absent, which counts as local'})")
    return {"ok": True, "code": code, "store": store}




def cmd_discover(argv):
    a, _ = parse_args(argv, {"--repo": "repo", "--branch": "branch", "--base": "base", "--state": "state"})
    need(a, "repo", "branch")
    states = [s.strip().lower() for s in a["state"].split(",")] if a.get("state") else None
    return discover(a["repo"], a["branch"], a.get("base"), states)


def count_commits(d, main, branch):
    mref = main_ref(d, main)
    if not mref or not has_ref(d, f"refs/heads/{branch}"):
        return 0
    r = git(d, "rev-list", "--count", f"{mref}..refs/heads/{branch}")
    return int(r.stdout.strip() or 0) if r.returncode == 0 else 0


def expected_set(code, store, branch):
    ctx = contexts(code, store)
    cid = identity(code)
    cmain, smain = ctx["code"]["main"], ctx["store"]["main"]
    cd = discover(cid["repo"], branch, base=cmain)
    commits = count_commits(code, cmain, branch)
    code_exp = bool(cd["prs"]) or commits > 0
    code_side = {"expected": code_exp, "repo": cid["repo"], "main": cmain, "commits": commits,
                 "reason": "pr_exists" if cd["prs"] else ("commits" if commits > 0 else "none"),
                 "pr": pr_of(cd["prs"]), "other_base": cd["other_base"]}
    try:
        sid = identity(store)
    except Stop as e:
        if e.error not in ("not-github", "no-origin"):
            raise
        sid = None
    store_side = {"expected": sid is not None, "repo": sid["repo"] if sid else None, "main": smain,
                  "reason": "github_origin" if sid else "no_github_origin", "pr": None, "other_base": []}
    if sid:
        read_store_as(ctx, sid["repo"])
        sd = discover(sid["repo"], branch, base=smain)
        store_side["pr"], store_side["other_base"] = pr_of(sd["prs"]), sd["other_base"]
    members = [k for k, side in (("store", store_side), ("code", code_side)) if side["expected"]]
    report = {("store", "code"): ("both", "Both PR URLs."),
              ("code",): ("code_only", "Code PR only; the store branch is shared by hand."),
              ("store",): ("store_only", "Store PR only; the change has no code changes."),
              (): ("none", "No PR to open: the store branch is shared by hand and nothing is watched.")}[tuple(members)]
    return {"ok": True, "branch": branch, "set": members, "code": code_side, "store": store_side,
            "ship": {"report": report[0], "note": report[1]}, "contexts": ctx}


def public(e):
    return {k: v for k, v in e.items() if k != "contexts"}


def cmd_expected(argv):
    a, _ = parse_args(argv, {"--code": "code", "--store": "store", "--branch": "branch"})
    need(a, "code", "store", "branch")
    return public(expected_set(a["code"], a["store"], a["branch"]))


def temp_file(text):
    f = tempfile.NamedTemporaryFile("w", delete=False, suffix=".json", encoding="utf-8", newline="\n")
    f.write(text)
    f.close()
    return f.name


def cmd_ensure_pr(argv):
    a, _ = parse_args(argv, {"--repo": "repo", "--branch": "branch", "--base": "base", "--title": "title", "--body-file": "body_file"})
    need(a, "repo", "branch", "base", "title", "body_file")
    repo, branch, base = a["repo"], a["branch"], a["base"]
    d = discover(repo, branch)["prs"]
    opens = [p for p in d if p["state"] == "OPEN"]
    for p in opens:
        if p["base"] != base:
            raise Stop("wrong_base", f"PR #{p['number']} {p['url']} targets {p['base']}, not {base}; nothing was opened or linked",
                       pr=p, base=p["base"])
    if opens:
        return {"ok": True, "action": "found", "pr": opens[0]}
    based = [p for p in d if p["base"] == base]
    if based and based[0]["state"] == "MERGED":
        raise Stop("already_merged", f"PR #{based[0]['number']} {based[0]['url']} from {branch} is already merged; not opening another",
                   pr=based[0])
    r = gh("pr", "create", "--repo", repo, "--head", branch, "--base", base, "--title", a["title"], "--body-file", a["body_file"])
    if r.returncode != 0:
        raise Stop("create_failed", (r.stderr or r.stdout).strip() or "gh pr create failed")
    m = re.search(r"(https://\S+/pull/(\d+))", r.stdout)
    if not m:
        raise Stop("create_failed", f"gh pr create printed no PR URL: {r.stdout.strip()}")
    return {"ok": True, "action": "created", "pr": {"number": int(m.group(2)), "url": m.group(1), "state": "OPEN", "base": base}}


CLOSING_QUERY = ("query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) "
                 "{ defaultBranchRef { name } pullRequest(number: $number) { body baseRefName "
                 "closingIssuesReferences(first: 100) { nodes { number repository { nameWithOwner } } "
                 "pageInfo { hasNextPage } } } } }")
CLOSE_KW = r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b:?"
ISSUE_REF = (r"https?://github\.com/([\w.-]+/[\w.-]+)/issues/(\d+)\b|(?<![\w/.-])([\w.-]+/[\w.-]+)#(\d+)\b"
             r"|(?<![\w/&])#(\d+)\b")


BLOCK_TAGS = frozenset(("p", "pre", "ul", "ol", "li", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "div", "table", "tr", "td",
                        "th", "dl", "dt", "dd", "details", "summary", "hr", "br"))
CODE_TAGS = frozenset(("pre", "code"))
CODE_MARK = "\ufffc"  # not whitespace, a word character or part of any closing-list gap


class RenderedLines(HTMLParser):
    """GitHub's HTML rendering of a description as lines of prose: text inside `pre` and `code` is dropped and replaced by one
    U+FFFC (so the text around ``Fi`x`xes`` never joins into a keyword, and no gap of a closing list accepts the marker, so a
    code span ends the list), comments are dropped, a block element ends a line at its
    start and its end, a newline in text ends a line (a soft break never joins two source lines into one closing list), entities
    are decoded, and link text stays as shown (`#N`, `owner/repo#N` or the URL, which ISSUE_REF reads)."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.lines, self.code = [""], 0

    def newline(self):
        if self.lines[-1]:
            self.lines.append("")

    def handle_starttag(self, tag, attrs):
        if tag in BLOCK_TAGS:
            self.newline()
        if tag in CODE_TAGS:
            if not self.code:
                self.lines[-1] += CODE_MARK
            self.code += 1

    def handle_endtag(self, tag):
        if tag in CODE_TAGS and self.code:
            self.code -= 1
        if tag in BLOCK_TAGS:
            self.newline()

    def handle_data(self, data):
        if self.code:
            return
        first, *rest = data.split("\n")
        self.lines[-1] += first
        for part in rest:
            self.newline()
            self.lines[-1] += part


def rendered_lines(body, repo):
    """The lines of `body` as GitHub renders it (GFM, with `repo` as context), read through `repo`'s login. The request goes in a
    temp file (a PR body can be longer than a Windows command line) that is removed on every exit. A failed or limited render is
    unknown (exit 3)."""
    if not body.strip():
        return []
    req = temp_file(json.dumps({"text": body, "mode": "gfm", "context": repo}))
    try:
        r = gh("api", "-X", "POST", "markdown", "--input", req, repo=repo)
    finally:
        with contextlib.suppress(OSError):
            os.remove(req)
    if r.returncode != 0:
        unknown((r.stderr or r.stdout).strip() or f"gh exited {r.returncode} rendering the description")
    parser = RenderedLines()
    parser.feed(r.stdout)
    parser.close()
    return parser.lines


def issue_key(m, repo):
    """(owner/name, number) of an ISSUE_REF match; a bare #N takes the PR's own repository."""
    if m.group(1):
        return m.group(1), int(m.group(2))
    if m.group(3):
        return m.group(3), int(m.group(4))
    return repo, int(m.group(5))


LIST_GAP = re.compile(r"(?:[\s,;]|\band\b|" + CLOSE_KW + r")*", re.I)
FIRST_GAP = re.compile(r"\s*")  # the keyword's own optional colon is part of CLOSE_KW


def intended_issues(body, repo):
    """Issues a description's closing lines name, read from GitHub's rendering of it (`rendered_lines`, so code is never read): every ref directly after a closing keyword, and the closing list of a line that
    starts with one: the ref after that keyword (only white space between; a `,`, `;`, `and` or a code span there means no
    list; a code span is the marker U+FFFC, which no gap accepts, wherever the keyword stands) and each next ref separated from
    the one before by only `,`, `;`, `and`, white space or another closing keyword. Any other text, a code span included, ends the list; a line whose first ref does not directly follow the
    keyword has none."""
    found = []
    for line in rendered_lines(body, repo):
        refs = [(m.start(), m.end(), issue_key(m, repo)) for m in re.finditer(ISSUE_REF, line)]
        lead = re.match(r"(?:[\s>*+-]|\d{1,9}[.)](?=\s))*" + CLOSE_KW, line, re.I)
        if lead:
            prev, first = lead.end(), True
            for at, end, k in refs:
                if at < lead.end():
                    continue
                gap = FIRST_GAP if first else LIST_GAP  # the first ref follows the keyword with only white space between
                if gap.match(line, prev).end() != at:
                    break
                first = False
                found.append(k)
                prev = end
        for kw in re.finditer(CLOSE_KW, line, re.I):
            nxt = next((k for at, _, k in refs if at >= kw.end() and not line[kw.end():at].strip()), None)
            if nxt:
                found.append(nxt)
    seen, out = set(), []
    for slug, n in found:
        if (slug.lower(), n) not in seen:
            seen.add((slug.lower(), n))
            out.append((slug, n))
    return out


def cmd_closing_check(argv):
    a, _ = parse_args(argv, {"--repo": "repo", "--pr": "pr"})
    need(a, "repo", "pr")
    repo = a["repo"]
    if not re.match(r"^[^/\s]+/[^/\s]+$", repo) or not str(a["pr"]).isdigit():
        usage("--repo is owner/name and --pr a number")
    owner, name = repo.split("/")
    r = gh("api", "graphql", "-f", f"query={CLOSING_QUERY}", "-f", f"owner={owner}", "-f", f"name={name}", "-F", f"number={a['pr']}",
           repo=repo)
    if r.returncode != 0:
        unknown((r.stderr or r.stdout).strip() or f"gh exited {r.returncode}")
    try:
        data = json.loads(r.stdout)
    except ValueError as e:
        unknown(f"unreadable response: {e}")
    try:
        if data.get("errors"):
            unknown(f"GraphQL errors: {data['errors']}")
        rep = data["data"]["repository"]
        pr = rep["pullRequest"]
        default = rep["defaultBranchRef"]["name"]
        base = pr["baseRefName"]
        refs = pr["closingIssuesReferences"]
        nodes, more = refs["nodes"], refs["pageInfo"]["hasNextPage"]
        linked = [(n["repository"]["nameWithOwner"], int(n["number"])) for n in nodes]
        body = pr["body"] or ""
    except (KeyError, TypeError, AttributeError, ValueError):
        unknown("unexpected GraphQL response shape (PR, default branch or closing list missing)")
    if more:
        unknown("the PR closes more than 100 issues; the closing list is cut off")
    intended = intended_issues(body, repo)
    fmt = lambda ks: [f"{s}#{n}" for s, n in ks]
    low = lambda ks: {(s.lower(), n) for s, n in ks}
    out = {"ok": True, "intended": fmt(intended), "linked": fmt(linked), "base": base, "default_branch": default}
    if base != default:  # GitHub applies closing keywords only on PRs into the default branch
        return {**out, "status": "not_default_base", "missing": [], "extra": []}
    missing = [k for k in intended if (k[0].lower(), k[1]) not in low(linked)]
    extra = [k for k in linked if (k[0].lower(), k[1]) not in low(intended)]
    return {**out, "status": "mismatch" if missing else "match", "missing": fmt(missing), "extra": fmt(extra)}


CLOSED_PR_QUERY = ("query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) "
                   "{ defaultBranchRef { name } pullRequest(number: $number) { state url body baseRefName mergedAt } } }")
CLOSED_ISSUE_QUERY = ("query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) "
                      "{ issue(number: $number) { state timelineItems(last: 1, itemTypes: [CLOSED_EVENT]) "
                      "{ nodes { ... on ClosedEvent { createdAt } } } } } }")


def graphql_read(query, slug, number):
    """The `data` of one GraphQL read through `slug`'s login; any failure or GraphQL error is unknown (exit 3)."""
    owner, name = slug.split("/")
    r = gh("api", "graphql", "-f", f"query={query}", "-f", f"owner={owner}", "-f", f"name={name}", "-F", f"number={number}", repo=slug)
    if r.returncode != 0:
        unknown((r.stderr or r.stdout).strip() or f"gh exited {r.returncode}")
    try:
        data = json.loads(r.stdout)
    except ValueError as e:
        unknown(f"unreadable response: {e}")
    if not isinstance(data, dict) or data.get("errors"):
        unknown(f"GraphQL errors: {data.get('errors') if isinstance(data, dict) else data}")
    return data


def cmd_closed_check(argv):
    a, _ = parse_args(argv, {"--repo": "repo", "--pr": "pr", "--repos": "repos", "--login": "+login"})
    need(a, "repo", "pr", "repos")
    repo, scope = a["repo"], [s for s in a["repos"].split(",") if s]
    slug_ok = lambda s: re.match(r"^[^/\s]+/[^/\s]+$", s)
    if not slug_ok(repo) or not str(a["pr"]).isdigit() or not scope or not all(slug_ok(s) for s in scope):
        usage("--repo is owner/name, --pr a number and --repos a comma-separated list of owner/name")
    for pair in a.get("login", []):  # a repository read through a login other than the ambient one
        slug, _, login = pair.partition("=")
        if not slug_ok(slug) or not login:
            usage("--login is owner/name=login")
        REPO_LOGIN[slug.lower()] = login
    data = graphql_read(CLOSED_PR_QUERY, repo, a["pr"])
    try:
        rep = data["data"]["repository"]
        pr = rep["pullRequest"]
        default, base, state = rep["defaultBranchRef"]["name"], pr["baseRefName"], pr["state"]
        url, body, merged_at = pr["url"], pr["body"] or "", pr["mergedAt"]
    except (KeyError, TypeError, AttributeError):
        unknown("unexpected GraphQL response shape (PR, state or default branch missing)")
    intended = intended_issues(body, repo)
    fmt = lambda ks: [f"{s}#{n}" for s, n in ks]
    out = {"ok": True, "status": "merged", "pr_url": url, "base": base, "default_branch": default, "intended": fmt(intended),
           "open": [], "reopened": [], "closed": [], "outside": []}
    if state != "MERGED":
        return {**out, "status": "not_merged"}
    if not isinstance(merged_at, str) or not merged_at:
        unknown("the merged PR has no mergedAt")
    if base != default:  # GitHub closed nothing from this PR, and the fix has not reached the default branch
        return {**out, "status": "not_default_base"}
    inside = {s.lower() for s in scope}
    for slug, n in intended:
        if slug.lower() not in inside:
            out["outside"].append(f"{slug}#{n}")  # never read
            continue
        try:
            issue = graphql_read(CLOSED_ISSUE_QUERY, slug, n)["data"]["repository"]["issue"]
            st, events = issue["state"], issue["timelineItems"]["nodes"]
            last_close = events[-1]["createdAt"] if events else None
        except (KeyError, TypeError, AttributeError, IndexError):
            unknown(f"unexpected GraphQL response shape for {slug}#{n}")
        if last_close is not None and not isinstance(last_close, str):
            unknown(f"unexpected close time for {slug}#{n}")
        if st == "CLOSED":
            out["closed"].append(f"{slug}#{n}")
        elif st == "OPEN":  # closed at or after the merge and open now: a person reopened it; an older close does not count
            out["reopened" if last_close and last_close >= merged_at else "open"].append(f"{slug}#{n}")
        else:
            unknown(f"{slug}#{n} has unexpected state {st!r}")
    return out


def link_state(repo, n, kind, peer):
    """Does PR `n` of `repo` already name `peer` (the `kind` PR's URL)? In its description, or in a `specwright:link <kind>` marker.
    The one test `link` skips on and the feedback pass's `link` row reports. Returns (reason, comment id, the kind's markers)."""
    pr = gh_obj(f"repos/{repo}/pulls/{n}")
    if peer in (pr.get("body") or ""):
        return "description", None, []
    found = []
    for c in gh_list(f"repos/{repo}/issues/{n}/comments?per_page=100"):
        m = MARK.search(c.get("body") or "")
        if m and m.group(1) == kind:
            found.append((c, m.group(2)))
    for c, url in found:
        if url == peer:
            return "marker", c["id"], found
    return None, None, found


def cmd_link(argv):
    a, _ = parse_args(argv, {"--repo": "repo", "--pr": "pr", "--kind": "kind", "--peer-url": "peer", "--login": "login"})
    need(a, "repo", "pr", "kind", "peer")
    repo, n, kind, peer = a["repo"], a["pr"], a["kind"], a["peer"]
    if kind not in ("store", "code"):
        usage("--kind is store or code")
    reason, cid0, found = link_state(repo, n, kind, peer)
    if reason == "description":
        return {"ok": True, "action": "skipped", "reason": "description"}
    if reason:
        return {"ok": True, "action": "skipped", "reason": "marker", "comment_id": cid0}
    login = (a.get("login") or ambient_login()).lower()
    mine = [c for c, _ in found if ((c.get("user") or {}).get("login") or "").lower() == login]
    label = "Store" if kind == "store" else "Code"
    body = json.dumps({"body": f"{label} PR for this change: {peer}\n\n<!-- specwright:link {kind} {peer} -->\n"})
    f = temp_file(body)
    try:
        if mine:  # only Specwright's own comment is ever edited
            r = gh("api", "-X", "PATCH", f"repos/{repo}/issues/comments/{mine[-1]['id']}", "--input", f)
            action, cid = "updated", mine[-1]["id"]
        else:
            r = gh("api", "-X", "POST", f"repos/{repo}/issues/{n}/comments", "--input", f)
            action, cid = "created", None
    finally:
        os.unlink(f)
    if r.returncode != 0:
        raise Stop("link_failed", (r.stderr or r.stdout).strip() or "gh api failed")
    try:
        cid = cid or json.loads(r.stdout).get("id")
    except ValueError:
        pass
    return {"ok": True, "action": action, "comment_id": cid}


def readiness(s, dropped, carry_over=False):
    """The readiness test of SKILL.md watch step 3, minus 'no new activity for one full wait'. `merge_state` UNSTABLE
    passes when no check fails and `checks.ci_pending` is 0 (a reviewer's own check may still run). `carry_over` is an
    archive head whose reviewers' reports carry over from the ready head before it (watch, archive_only true): its
    reviewers' states and their checks do not count, only CI (`ci_pending`), mergeability and feedback."""
    if s is None:
        return False, ["no_snapshot"], False
    b = []
    if not s.get("complete", True):
        b.append("incomplete")
    if s.get("pending_review"):
        b.append("pending_review")
    if s.get("state", "OPEN") != "OPEN":
        b.append("not_open")
    if s.get("mergeable") != "MERGEABLE":
        b.append("not_mergeable")
    ck = s.get("checks") or {}
    ci_done = ck.get("ci_pending") == 0 and not ck.get("failing")
    if not (s.get("merge_state") == "CLEAN" or (s.get("merge_state") == "UNSTABLE" and ci_done)):
        b.append(f"merge_state:{s.get('merge_state')}")
    if (ck.get("ci_pending") if carry_over else ck.get("pending")):
        b.append("checks_pending")
    if ck.get("failing"):
        b.append("checks_failing")
    for kind in ("threads", "comments", "reviews"):
        if [i for i in s.get(kind) or [] if f"{i.get('id')}@{i.get('rev')}" not in dropped]:
            b.append(kind)
    for r in ([] if carry_over else s.get("reviewers") or []):
        if r.get("role", "required") == "required" and r.get("state") != "reported":
            b.append(f"reviewer:{r.get('login')}:{r.get('state')}")
        elif r.get("role") == "advisory" and r.get("state") == "waiting":
            b.append(f"reviewer:{r.get('login')}:waiting")
    stale_only = b == ["merge_state:BLOCKED"] and bool(s.get("stale_verdicts"))
    return not b, b, stale_only


def read_snapshots(a):
    out = {}
    for spec in a.get("snapshot", []):
        name, _, path = spec.partition("=")
        if name not in ("code", "store") or not path:
            usage("--snapshot is code=<file> or store=<file>")
        try:
            out[name] = json.loads(Path(path).read_text(encoding="utf-8"))
        except (OSError, ValueError) as e:
            raise Stop("snapshot_unreadable", f"{path}: {e}", code=2)
    return out


def snapshot_refresh(s, pr):
    """The refresh blocker when snapshot s is not of the discovered PR (repo, number, head commit), else None."""
    m = re.match(r"https?://[^/]+/([^/]+/[^/]+)/pull/(\d+)", (s.get("url") or "") if isinstance(s.get("url"), str) else "")
    want_m = re.match(r"https?://[^/]+/([^/]+/[^/]+)/pull/(\d+)", pr.get("url") or "")
    number = s.get("number")
    same_repo = bool(m and want_m and m.group(1).lower() == want_m.group(1).lower())
    if number != pr["number"] or not same_repo:
        got = "?" if number is None else str(number)
        if number == pr["number"] and m:
            got = f"{m.group(1)}#{number}"
        return f"refresh:pr:{got}!={pr['number']}"
    got, want = s.get("head_oid") or "", pr.get("head_sha") or ""
    if not got or got != want:
        return f"refresh:head:{got[:7] or '?'}!={want[:7]}"
    return None


def cmd_pair_state(argv):
    a, _ = parse_args(argv, {"--code": "code", "--store": "store", "--branch": "branch", "--snapshot": "+snapshot", "--dropped": "+dropped",
                             "--carry-over": "+carry"})
    need(a, "code", "store", "branch")
    carry = set(a.get("carry", []))
    if carry - {"code", "store"}:
        usage("--carry-over is code or store: the side whose archive head carries its reviewers' reports over")
    e = expected_set(a["code"], a["store"], a["branch"])
    snaps, dropped = read_snapshots(a), set(a.get("dropped", []))
    members = e["set"]
    states = {k: (e[k]["pr"]["state"] if e[k]["pr"] else None) for k in members}
    r = {"ok": True, "set": members, "states": states, "waits": [], "ready": {}, "waiting_on": [], "blocking": {}, "missing": [], "refresh": [],
         "merged": [], "closed": [], "open": [], "stop_waits": False, "archive": False, "rerequest": False,
         "share_store_by_hand": "code" in members and "store" not in members,
         "prs": {k: e[k]["pr"] for k in members}, "ship": e["ship"]}
    if not members:
        return {**r, "action": "no_watch"}
    r["missing"] = [k for k in members if states[k] is None]
    r["merged"] = [k for k in members if states[k] == "MERGED"]
    r["closed"] = [k for k in members if states[k] == "CLOSED"]
    r["open"] = [k for k in members if states[k] == "OPEN"]
    if r["missing"]:
        return {**r, "action": "ship"}
    ended = r["merged"] + r["closed"]
    if ended and r["open"]:
        return {**r, "action": "split_hand_off", "stop_waits": True}
    if ended:
        return {**r, "action": "cleanup", "stop_waits": True}
    for k in members:
        ok, blockers, stale_only = readiness(snaps.get(k), dropped, k in carry)
        stale = snapshot_refresh(snaps[k], e[k]["pr"]) if snaps.get(k) is not None else None
        if stale:
            ok, blockers, stale_only = False, [stale] + blockers, False
            r["refresh"].append(k)
        r["ready"][k] = ok
        if not ok:
            r["blocking"][k] = blockers
            r["waiting_on"].append(k)
            if stale_only:
                r.setdefault("ready_except_stale_verdicts", []).append(k)
    r["waits"] = list(members)
    return {**r, "action": "ready" if not r["waiting_on"] else "wait"}


def is_jj(d):
    """A jj repo: it has .jj/ at its toplevel (colocated)."""
    return os.path.isdir(os.path.join(toplevel(d), ".jj"))


def is_gitbutler(d):
    """A repo GitButler manages: it has .git/gitbutler/."""
    r = git(d, "rev-parse", "--git-path", "gitbutler")
    return r.returncode == 0 and bool(r.stdout.strip()) and os.path.isdir(os.path.join(d, r.stdout.strip()))


def remote_contains(d, branch, sha):
    r = git_net(d, "ls-remote", "origin", f"refs/heads/{branch}")
    if r.returncode != 0:
        raise Stop("remote_unreadable", f"git ls-remote origin failed in {d}: {r.stderr.strip()}", code=3, unknown=True)
    line = r.stdout.strip().split("\n")[0].strip()
    if not line:
        return False
    remote = line.split()[0]
    if remote == sha:
        return True
    if git(d, "cat-file", "-e", remote + "^{commit}").returncode != 0:
        # another checkout pushed a tip this repo lacks: fetch it (FETCH_HEAD only, no local ref moves) before the ancestry test
        # --refmap= on a jj or GitButler repo: jj imports a remote-tracking move into a tracked bookmark, and a Git ref write is
        # outside GitButler's workspace, so only FETCH_HEAD may change
        git_net(d, "fetch", "-q", *(["--refmap="] if is_jj(d) or is_gitbutler(d) else []), "origin", f"refs/heads/{branch}")
    r = git(d, "merge-base", "--is-ancestor", sha, remote)
    if r.returncode in (0, 1):
        return r.returncode == 0
    raise Stop("remote_unreadable", f"cannot tell whether origin/{branch} contains {sha} in {d}: {r.stderr.strip()}", code=3, unknown=True)


def branch_log(d, rng, branch_ref):
    """[(sha, subject, body)] for `git log rng`, newest first; None when git cannot resolve the range."""
    r = git(d, "log", rng, "--format=%H%x1f%s%x1f%B%x1e")
    if r.returncode != 0:
        return None
    out = []
    for rec in r.stdout.split("\x1e"):
        if rec.strip():
            sha, subj, body = (rec.strip("\n").split("\x1f") + ["", ""])[:3]
            out.append((sha.strip(), subj, body))
    return out


def cmd_rounds(argv):
    a, _ = parse_args(argv, {"--code": "code", "--store": "store", "--branch": "branch"})
    need(a, "code", "branch")  # no --store: a repo-local change, whose only branch is the code branch
    ctx = contexts(a["code"], a.get("store"))
    repos = pass_repos(a)
    per, rounds_all = {}, {}
    for k, d in repos:
        mref = main_ref(d, ctx[k]["main"])
        commits = branch_log(d, f"{mref}..refs/heads/{a['branch']}", None) if mref and has_ref(d, f"refs/heads/{a['branch']}") else []
        commits = commits or []
        trailers = {sha: max([int(x) for x in TRAILER.findall(body)] or [0]) for sha, _, body in commits}
        per[k] = {"max_trailer": max(trailers.values(), default=0), "trailers": trailers,
                  "subject_count": sum(1 for _, s, _ in commits if LEGACY_SUBJECT.search(s))}
    top = max(p["max_trailer"] for p in per.values())
    # trailers are exact; the legacy subject count only stands in on a branch that has none in either repo
    rounds = top or max(p["subject_count"] for p in per.values())
    unpushed, unreadable = {}, []
    if top:
        shas_of = {k: [s for s, n in per[k]["trailers"].items() if n == top] for k, _ in repos}
        if a.get("store") and shas_of.get("store"):
            # the store may need its own login: stop on a missing credential before the per-repo loop, but only when
            # the store has top-round commits to look for on its remote
            slug = fetch_repo(a["store"])  # by the fetch URL, as git_net reads it, whatever the push URLs
            read_store_as(ctx, slug)
            if slug and REPO_LOGIN.get(slug.lower()):
                token_for(REPO_LOGIN[slug.lower()])
        for k, d in repos:
            shas = shas_of[k]
            try:
                missing = [s for s in shas if not remote_contains(d, a["branch"], s)]
            except Refused:  # as.sh refused (a credential in a URL, no credential): a stop, not an unreadable remote
                raise
            except Stop:  # the count does not depend on the remote; say which side could not be checked
                unreadable.append(k)
                continue
            if missing:
                unpushed[k] = missing
    limit = ctx["max_fix_rounds"]
    for k in per:
        del per[k]["trailers"]
    return {"ok": True, "rounds": rounds, "code": per["code"], "store": per.get("store"), "max_fix_rounds": limit,
            "limit_reached": rounds >= limit, "after_limit": ctx["after_limit"], "unpushed": unpushed,
            "remote_unreadable": unreadable}


# ---- the feedback pass record ----------------------------------------------------------------------------------
def record_dir():
    return Path(os.environ.get("SPECWRIGHT_STATE_DIR") or str(Path.home() / ".cache" / "specwright")) / "feedback"


def _safe(s):
    return re.sub(r"[^A-Za-z0-9._-]", "_", s)


def record_path(code_repo, change):
    """<owner>.<name>.<change>-<32 hex of sha256(lower(owner), lower(name), change)>.json: the hash keeps hyphenated
    identities apart (0.1.9 joined the parts with '-', so acme-tools/widget and acme/tools-widget shared a file). The readable
    part is cut to 120 characters so the file and its `.lock` stay under the 255-character name limit; the hash covers it all."""
    owner, _, name = code_repo.partition("/")
    h = hashlib.sha256(f"{owner.lower()}\n{name.lower()}\n{change}".encode("utf-8")).hexdigest()[:32]
    return record_dir() / (f"{_safe(owner)}.{_safe(name)}.{_safe(change)}"[:120].lower() + f"-{h}.json")


def legacy_record_path(code_repo, change):
    owner, _, name = code_repo.partition("/")
    return record_dir() / f"{_safe(owner)}-{_safe(name)}-{_safe(change)}.json"


def publish(src, dst):
    """Create dst from src's content, failing with FileExistsError if dst exists: a hard link, so dst is complete the moment it
    appears; where links are unsupported, an O_EXCL create and write (a crash mid-write leaves a record_unreadable file)."""
    try:
        os.link(src, dst)
        return
    except FileExistsError:
        raise
    except OSError:
        pass
    data = Path(src).read_bytes()
    fd = os.open(dst, os.O_CREAT | os.O_EXCL | os.O_WRONLY | getattr(os, "O_BINARY", 0))
    try:  # the destination is ours from here: a failed write or close must not leave a file a later call reads as record_unreadable
        try:
            f = os.fdopen(fd, "wb")
        except BaseException:
            os.close(fd)
            raise
        with f:
            f.write(data)
    except BaseException:
        try:
            os.unlink(dst)
        except OSError:
            pass
        raise


def exists_here(p):
    """Path.exists(), except that a path the OS rejects as too long is absent: no file can have that name."""
    try:
        return p.exists()
    except OSError as e:
        if e.errno == errno.ENAMETOOLONG or getattr(e, "winerror", None) == 206:
            return False
        raise


def locate_record(code_repo, change):
    """(path, ignored legacy path or None). A 0.1.9-key record of this repository and change is moved to the new key on first
    use; one of another identity stays where it is, and one beside an existing new-key record is left and reported. A legacy
    file byte-identical to the new-key record is the leftover of an interrupted move and is removed. With no new-key record, an
    unreadable legacy file stops (record_unreadable): it may be the pass in progress, and a new pass must not start beside it;
    beside a new-key record it is reported as ignored."""
    path, old = record_path(code_repo, change), legacy_record_path(code_repo, change)
    if not exists_here(old):
        return path, None
    if path.exists():
        try:
            if old.read_bytes() == path.read_bytes():
                old.unlink()
                return path, None
        except OSError:
            pass
    try:
        rec = load_record(old)
    except Stop:
        if path.exists():
            return path, norm(old)
        raise
    if (not isinstance(rec, dict) or str(rec.get("code_repo") or "").lower() != code_repo.lower() or rec.get("change") != change):
        return path, None
    if path.exists():
        return path, norm(old)
    try:
        publish(old, path)
    except FileExistsError:
        return path, norm(old)
    try:
        old.unlink()
    except FileNotFoundError:  # another call finished the move first
        pass
    return path, None


def new_owner(oid, checkout):
    return {"id": oid, "at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "checkout": norm(os.path.abspath(checkout)),
            "host": socket.gethostname()}


LEFT_LOCKS = []  # locks this call could not remove; the output names them, and later calls stop with record_busy


@contextlib.contextmanager
def record_lock(path):
    """The `<record>.lock` directory, held only by the call that created it; a lock already there is never removed. A failed removal
    never replaces the outcome of the work under the lock: it is recorded in LEFT_LOCKS and reported as `lock_left`."""
    lock = Path(str(path) + ".lock")
    try:
        os.mkdir(lock)
    except FileExistsError:
        raise Stop("record_busy", f"{lock} exists: another call, or an interrupted one, holds the record; it is not removed automatically",
                   path=norm(path), lock=norm(lock))
    try:
        yield
    finally:
        try:
            os.rmdir(lock)
        except OSError:
            LEFT_LOCKS.append(norm(lock))


def temp_beside(path):
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".tmp-", suffix=".json")
    return os.fdopen(fd, "w", encoding="utf-8", newline="\n"), tmp


def load_record(p):
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except (ValueError, OSError) as e:  # cut off, not JSON, or not readable at all (a denied permission): identity unknown
        raise Stop("record_unreadable", f"{p}: {e}")


def find_marker(store, branch, change, prefix, main=None):
    """The planning-only marker of this change's own archive, under the selected root only: another root's marker is not
    ours, and neither is an earlier archive of a reused change name - that one is already on the store's main."""
    archive = f"{prefix}/changes/archive"
    r = git(store, "ls-tree", "-d", "--name-only", f"refs/heads/{branch}", "--", archive + "/")
    if r.returncode != 0:
        return None
    rx = re.compile("^" + re.escape(archive) + r"/(\d{4}-\d{2}-\d{2}-)?" + re.escape(change) + "$")
    dirs = [d for d in r.stdout.split("\n") if rx.search(d)]
    mref = main_ref(store, main) if main else None
    if mref:
        dirs = [d for d in dirs if git(store, "cat-file", "-e", f"{mref}:{d}").returncode != 0]
    if len(dirs) > 1:
        raise Stop("marker_ambiguous", f"more than one archive of {change} on {branch} is not on the store's main: {', '.join(dirs)}",
                   paths=dirs)
    for d in dirs:
        path = f"{d}/specwright-change.yaml"
        body = git(store, "show", f"refs/heads/{branch}:{path}")
        if body.returncode == 0 and re.search(r"^code_changes:\s*none\s*$", body.stdout, re.M):
            return path
    return None


def edit_repo(f, e):
    """The repo an edit lands in: its own `repo` (required when the finding's destination is `both`), else the finding's."""
    return e.get("repo") or f["destination"]


def edits_for(f, k):
    return [e for e in f["edits"] if edit_repo(f, e) == k]


def pass_args(argv, extra=None):
    spec = {"--code": "code", "--store": "store", "--code-repo": "code_repo", "--change": "change", "--snapshot": "+snapshot"}
    spec.update(extra or {})
    a, _ = parse_args(argv, spec)
    need(a, "code", "code_repo", "change")  # no --store: a repo-local change (code only)
    return a


def pass_repos(a):
    """[(name, dir)] the call reads: the code repo, and the store when --store is given."""
    return [("code", a["code"])] + ([("store", a["store"])] if a.get("store") else [])


def is_pos_int(v):
    return isinstance(v, int) and not isinstance(v, bool) and v >= 1


def check_intent_header(intent, local=False):
    """branch, round and prs, before anything is written; a repo-local change (local) has no store PR."""
    if not isinstance(intent["branch"], str) or not intent["branch"].strip():
        raise Stop("invalid_intent", "'branch' must be a non-empty string", code=2)
    if not is_pos_int(intent["round"]):
        raise Stop("invalid_intent", "'round' must be a positive integer", code=2)
    prs = intent["prs"]
    if not isinstance(prs, dict) or set(prs) - {"code", "store"}:
        raise Stop("invalid_intent", "'prs' must be an object with only 'code' and 'store' entries", code=2)
    if local and prs.get("store") is not None:
        raise Stop("invalid_intent", "'prs.store' must be absent or null: this change is repo-local (no --store)", code=2)
    for k, v in prs.items():
        if v is None:
            continue
        if (not isinstance(v, dict) or not isinstance(v.get("repo"), str) or not re.match(r"^[^/\s]+/[^/\s]+$", v["repo"])
                or not is_pos_int(v.get("number"))):
            raise Stop("invalid_intent", f"'prs.{k}' must be null or an object with 'repo' as <owner>/<name> and 'number' as a positive integer", code=2)


def pass_write(argv):
    a = pass_args(argv, {"--intent": "intent", "--store-prefix": "prefix"})
    need(a, "intent")
    prefix = (a.get("prefix") or "openspec").strip("/")
    try:
        intent = json.loads(Path(a["intent"]).read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        raise Stop("invalid_intent", f"{a['intent']}: {e}", code=2)
    for key in ("branch", "round", "prs", "findings"):
        if key not in intent:
            raise Stop("invalid_intent", f"intent lacks '{key}'", code=2)
    local = not a.get("store")
    check_intent_header(intent, local)
    path, _ = locate_record(a["code_repo"], a["change"])
    if path.exists():
        raise Stop("record_exists", f"a feedback pass record exists at {path}; resume that pass before starting another", path=str(path))
    seen = set()
    if not isinstance(intent["findings"], list) or not all(isinstance(f, dict) for f in intent["findings"]):
        raise Stop("invalid_intent", "findings must be a list of objects", code=2)
    for f in intent["findings"]:
        # everything `pass plan` reads from a finding is checked here: a record it cannot read would block every later pass
        for key in ("id", "item", "source", "destination", "edits", "disposition", "revision"):
            if key not in f:
                raise Stop("invalid_intent", f"finding {f.get('id')} lacks '{key}'", code=2)
        if (f["id"] in seen or f["destination"] not in ("code", "store", "both") or f["source"] not in ("code", "store")
                or not isinstance(f["item"], str) or not f["item"] or f.get("kind", "thread") not in ("thread", "comment", "review")
                or not isinstance(f["disposition"], dict) or not isinstance(f["revision"], dict)
                or not isinstance(f["edits"], list) or not f["edits"]
                or not all(isinstance(e, dict) and isinstance(e.get("file"), str) and e["file"] for e in f["edits"])):
            raise Stop("invalid_intent", f"finding {f['id']} is duplicated or malformed", code=2)
        seen.add(f["id"])
        if local and (f["source"] != "code" or f["destination"] != "code"):
            raise Stop("misrouted", f"finding {f['id']}: a repo-local change has only the code repo, so source and destination must be code",
                       finding=f["id"])
        if f.get("kind", "thread") == "thread":
            if not is_pos_int(f.get("root_id")):
                raise Stop("invalid_intent", f"finding {f['id']}: thread finding needs 'root_id' as a positive integer", code=2)
        elif not isinstance(f["item"], str) or not f["item"]:
            raise Stop("invalid_intent", f"finding {f['id']}: {f['kind']} finding needs 'item' as a non-empty string", code=2)
        for e in f["edits"]:
            r = e.get("repo")
            if (f["destination"] == "both" and r not in ("code", "store")) or (f["destination"] != "both" and r not in (None, f["destination"])):
                raise Stop("invalid_intent", f"finding {f['id']}: edit {e.get('file')} needs repo code|store matching the destination", code=2)
        for e in edits_for(f, "store"):
            if not norm(e["file"]).startswith(prefix + "/"):
                raise Stop("misrouted", f"finding {f['id']}: {e['file']} is not under {prefix}/, so it does not belong to the store branch",
                           finding=f["id"], file=e["file"])
    heads = {}
    for k, d in pass_repos(a):
        r = git(d, "rev-parse", f"refs/heads/{intent['branch']}")
        if r.returncode != 0:
            raise Stop("branch_missing", f"{k} has no branch {intent['branch']}")
        heads[k] = r.stdout.strip()
    marker = (find_marker(a["store"], intent["branch"], a["change"], prefix, (contexts(a["code"], a["store"])["store"] or {}).get("main"))
              if not local and any(edits_for(f, "code") for f in intent["findings"]) else None)
    owner = new_owner(secrets.token_hex(16), a["code"])
    rec = {**intent, "version": 2, "owner": owner, "change": a["change"], "code_repo": a["code_repo"], "heads": heads, "marker": marker,
           "written_at": owner["at"]}
    if cmd_vcs(["--code", a["code"]])["code"] == "gitbutler":  # D13: unassigned paths already there are not this pass's to ask about
        rec["preexisting"] = sorted(vcs_state(a["code"], "code", a["code"], intent["branch"])["unassigned_paths"])  # when the pass began: the last-resort re-request cutoff (adopt keeps it; nothing rewrites it)
    path.parent.mkdir(parents=True, exist_ok=True)
    f, tmp = temp_beside(path)  # a uniquely named file: two writers never share one
    try:
        with f:
            f.write(json.dumps(rec, indent=2))
        try:
            publish(tmp, path)  # exclusive: fails if any record exists, and the record is complete when it appears
        except FileExistsError:
            raise Stop("record_exists", f"a feedback pass record exists at {path}; resume that pass before starting another", path=str(path))
    finally:
        os.unlink(tmp)
    return {"ok": True, "path": norm(path), "round": rec["round"], "heads": heads, "marker": marker, "owner": owner["id"]}


def listify(v):
    return [] if v is None else (v if isinstance(v, list) else [v])


def judge(d, e):
    p = Path(d) / e["file"]
    if e.get("deleted"):
        return "pending" if p.exists() else "done"
    contains, absent = listify(e.get("contains")), listify(e.get("absent"))
    if not contains and not absent:
        return "unjudgeable"
    if not p.is_file():
        return "pending"
    t = p.read_text(encoding="utf-8", errors="replace")
    return "done" if all(c in t for c in contains) and not any(x in t for x in absent) else "pending"


def judge_at(d, e, rev):
    """judge() on the file as commit `rev` has it."""
    r = git(d, "cat-file", "blob", f"{rev}:{e['file']}")
    if e.get("deleted"):
        return "pending" if r.returncode == 0 else "done"
    contains, absent = listify(e.get("contains")), listify(e.get("absent"))
    if not contains and not absent:
        return "unjudgeable"
    if r.returncode != 0:
        return "pending"
    t = r.stdout
    return "done" if all(c in t for c in contains) and not any(x in t for x in absent) else "pending"


def dirty_paths(d):
    r = git(d, "status", "--porcelain", "-z", "-uall")
    parts, out, i = r.stdout.split("\0"), set(), 0
    while i < len(parts):
        s = parts[i]
        i += 1
        if len(s) > 3:
            out.add(s[3:])
            if s[0] in "RC" or s[1] in "RC":
                i += 1  # the old name follows a rename
    return out


def fix_commit(d, head0, branch, n):
    # a reset, rebase or force-update can drop the recorded head while `head0..branch` still resolves
    if git(d, "merge-base", "--is-ancestor", head0, f"refs/heads/{branch}").returncode != 0:
        return None, False
    commits = branch_log(d, f"{head0}..refs/heads/{branch}", None)
    if commits is None:
        return None, False
    for sha, _, body in commits:  # newest first
        if n in [int(x) for x in TRAILER.findall(body)]:
            return sha, True
    return None, True


def first_seen_at(repo, num, oid):
    """The earliest GitHub time a snapshot on this machine saw head `oid` of the PR, as an ISO time, or None when the record
    cannot be read. The record is pr-snapshot.sh's: <state>/heads/<owner/name/pr, lowercased>/<oid>, one HTTP-date line."""
    base = Path(os.environ.get("SPECWRIGHT_STATE_DIR") or str(Path.home() / ".cache" / "specwright"))
    try:
        lines = (base / "heads" / f"{repo}/{num}".lower() / oid).read_text(encoding="utf-8").splitlines()
        m = re.match(r"^[A-Za-z]{3}, ([0-9]{2} [A-Za-z]{3} [0-9]{4} [0-9:]{8}) GMT$", lines[0].strip())
        return datetime.datetime.strptime(m.group(1), "%d %b %Y %H:%M:%S").strftime("%Y-%m-%dT%H:%M:%SZ")
    except (OSError, IndexError, AttributeError, ValueError):
        return None


def request_state(repo, num, branch, tip, reqs, written=None):
    """Which re-requests exist after the cutoff for `tip`: the push time, else the time a snapshot first saw the head, else (only
    when no such record can be read) `written`, the time the pass record was written. GitHub timestamps otherwise.
    Returns (states, push time, cutoff, cutoff source)."""
    acts = gh_list(f"repos/{repo}/activity?ref=refs/heads/{branch}&per_page=100")
    pushed = next((x.get("timestamp") for x in acts if x.get("after") == tip), None)
    cutoff, source = pushed, "push"
    if not cutoff:
        cutoff, source = first_seen_at(repo, num, tip), "first_seen"
    if not cutoff:
        cutoff, source = written, "pass_written"
    if not cutoff:
        source = "none"
    comments = gh_list(f"repos/{repo}/issues/{num}/comments?per_page=100")
    out = []
    for r in reqs:
        poster = (r["poster"] or ambient_login()).lower()
        done = bool(cutoff) and any(((c.get("user") or {}).get("login") or "").lower() == poster
                                    and (c.get("body") or "").strip() == r["body"].strip()
                                    and (c.get("created_at") or "") >= cutoff for c in comments)
        out.append({"body": r["body"], "poster": r["poster"], "done": done})
    return out, pushed, cutoff, source


REACTION_GQL = ("query($id: ID!, $cursor: String) { node(id: $id) { ... on Reactable { reactions(first: 100, content: %s, after: $cursor) "
                "{ nodes { user { login } } pageInfo { hasNextPage endCursor } } } } }")


def has_reaction(repo, kind, target, reaction, viewer):
    """Has `viewer` put `reaction` (+1 or -1) on the recorded target? A thread's root is a numeric review-comment id (REST);
    a comment or review is a node id (GraphQL). Any failed read exits 3."""
    who = (viewer or "").lower()
    if kind == "thread":
        content = "%2B1" if reaction == "+1" else "-1"
        return any(((r.get("user") or {}).get("login") or "").lower() == who and r.get("content") == reaction
                   for r in gh_list(f"repos/{repo}/pulls/comments/{target}/reactions?content={content}&per_page=100"))
    query, cursor, pages = REACTION_GQL % ("THUMBS_UP" if reaction == "+1" else "THUMBS_DOWN"), None, 0
    while True:
        pages += 1
        r = gh("api", "graphql", "-f", f"query={query}", "-f", f"id={target}", *(["-f", f"cursor={cursor}"] if cursor else []), repo=repo)
        if r.returncode != 0:
            unknown((r.stderr or r.stdout).strip() or f"gh exited {r.returncode}")
        try:
            node = (json.loads(r.stdout).get("data") or {}).get("node")
            rx = node["reactions"]
            if any(((n.get("user") or {}).get("login") or "").lower() == who for n in rx["nodes"]):
                return True
            more, cursor = rx["pageInfo"]["hasNextPage"], rx["pageInfo"]["endCursor"]
        except (ValueError, TypeError, KeyError, AttributeError):
            unknown(f"unreadable reactions of {target}")
        if not more or not cursor:
            return False
        if pages >= bounded.MAX_PAGES:  # never "absent" from a loop that was cut short
            raise Stop(bounded.RESPONSE_TOO_LARGE,
                       f"GitHub state unknown: {bounded.RESPONSE_TOO_LARGE}: gh api graphql (reactions of {target}, over {pages} pages)",
                       code=3, unknown=True)


def pass_plan(argv):
    a = pass_args(argv, {"--owner": "owner"})
    path, ignored = locate_record(a["code_repo"], a["change"])
    rec = load_record(path)
    if rec is None:
        return {"ok": True, "record": False, "new_pass_allowed": True, "status": "none", "rows": [], "stops": [],
                "delete_record": False, "needs_user": False}
    held = rec.get("owner")
    owned = None if not held else a.get("owner") == held.get("id")
    snaps = read_snapshots(a)
    findings, n, branch, prs = rec["findings"], rec["round"], rec["branch"], rec.get("prs") or {}
    for src in sorted({f["source"] for f in findings}):
        if src not in snaps:
            raise Stop("snapshot_required", f"pass plan needs --snapshot {src}=<file> (a fresh pr-snapshot.sh of that PR)", code=2, source=src)
    ctx = contexts(a["code"], a.get("store"))
    dirs = {"code": a["code"], "store": a.get("store")}
    marker = rec.get("marker")
    code_gitbutler = cmd_vcs(["--code", a["code"]])["code"] == "gitbutler"
    dests = [k for k in ("store", "code") if any(edits_for(f, k) for f in findings) or (k == "store" and marker)]
    if not a.get("store") and ("store" in dests or prs.get("store") or any(f["source"] == "store" for f in findings)):
        raise Stop("store_required", "this record names the store repo; pass plan needs --store <dir>", code=2)
    rows, stops = [], []
    fix, tip, pushed, slug = {}, {}, {}, {}
    for k in ("code", "store"):
        slug[k] = (prs.get(k) or {}).get("repo") or (rec["code_repo"] if k == "code" else None)
    read_store_as(ctx, slug["store"])

    for k in dests:  # 1. fix commits
        d = dirs[k]
        r = git(d, "rev-parse", f"refs/heads/{branch}")
        if r.returncode != 0:
            raise Stop("branch_missing", f"{k} has no branch {branch}")
        tip[k] = r.stdout.strip()
        sha, ok = fix_commit(d, rec["heads"][k], branch, n)
        if not ok:
            stops.append({"reason": "head_unreachable", "repo": k, "detail": f"{rec['heads'][k]} is not reachable from {branch}"})
        edits = [{**e, "finding": f["id"]} for f in findings for e in edits_for(f, k)]
        if k == "store" and marker:
            edits.append({"file": marker, "deleted": True, "finding": "marker"})
        files = sorted({norm(e["file"]) for e in edits})
        row = {"step": "fix_commit", "repo": k, "state": "done" if sha else "todo", "sha": sha, "trailer": f"Feedback-Round: {n}",
               "files": files}
        st = vcs_state(d, "code", a["code"], branch) if k == "code" and code_gitbutler else None
        # judged even when a trailer commit exists: an interrupted pass can commit and push only part of its edits.
        # GitButler: the working tree holds every applied branch, so a file the change has no uncommitted edit in is
        # judged at the branch tip; another branch's assigned edit is never evidence
        mine = set(st["change_paths"]) | set(st["unassigned_paths"]) if st else None
        verdicts = [(e, judge(d, e) if mine is None or norm(e["file"]) in mine else judge_at(d, e, tip[k])) for e in edits]
        pending = [{"file": norm(e["file"]), "finding": e["finding"], "reason": "not_made"} for e, v in verdicts if v == "pending"]
        for e, v in verdicts:
            if v == "unjudgeable":
                stops.append({"reason": "edit_unjudgeable", "repo": k, "finding": e["finding"], "file": norm(e["file"]),
                              "detail": "the recorded edit has no contains/absent/deleted check, so it cannot be judged done"})
        if k == "code" and code_gitbutler:
            # D13: the change's paths and the unassigned ones; another branch's never count, nor do the unassigned paths that
            # `pass write` recorded as preexisting (unless the pass itself edits one of them)
            dirty = (set(st["change_paths"]) | set(st["unassigned_paths"])) - (set(rec.get("preexisting") or []) - set(files))
        else:
            dirty = dirty_paths(d)
        extra = sorted(dirty - set(files))
        if extra:
            stops.append({"reason": "unrecorded_change", "repo": k, "files": extra,
                          "detail": "the working tree has changes outside the files this pass recorded"})
        uncommitted = sorted(dirty & set(files))
        blocked = bool(pending) or any(v == "unjudgeable" for _, v in verdicts) or bool(extra)
        if sha and (blocked or uncommitted):  # the trailer commit holds only part of the pass: commit the rest under it
            sha = None
            row.update(state="todo", sha=None, partial_commit=row["sha"])
        if not sha:
            row.update({"pending_edits": pending, "committable": not blocked,
                        "action": "finish_edits" if pending else ("ask" if blocked else "validate_and_commit")})
        fix[k] = sha
        rows.append(row)

    def unmet(*ids):
        return [i for i in ids if not any(r["step"] + ":" + r["repo"] == i and r["state"] in ("done", "not_applicable") for r in rows if "repo" in r)]

    adopted = None
    if "code" in dests and not prs.get("code"):  # a code fix on a store-only change: the code PR is now expected
        opened = [p for p in discover(slug["code"], branch, base=ctx["code"]["main"])["prs"] if p["state"] == "OPEN"]
        if opened:
            prs = {**prs, "code": {"repo": slug["code"], "number": opened[0]["number"]}}
            adopted = prs["code"]

    for k in dests:  # 2. push
        pr = prs.get(k)
        row = {"step": "push", "repo": k, "branch": branch, "after": [], "blocked": False}
        if not pr and k == "code":
            after = unmet("fix_commit:code") + (unmet("fix_commit:store") if marker else [])
            row.update(state="todo", action="ship", after=after, blocked=bool(after),
                       detail="the code repo now has commits but no open code PR: ship it (push, ensure-pr, review request), then plan again")
        elif not pr:
            row.update(state="not_applicable", share_by_hand=True)
        else:
            after = unmet(f"fix_commit:{k}")
            if k == "code" and marker:
                after += unmet("fix_commit:store")
            row["after"], row["blocked"] = after, bool(after)
            row["state"] = "todo" if after or not fix[k] else ("done" if remote_contains(dirs[k], branch, fix[k]) else "todo")
        pushed[k] = row["state"] in ("done", "not_applicable")
        rows.append(row)

    for k in dests:  # 3. re-request review
        pr = prs.get(k)
        reqs = review_requests(ctx[k]) if pr else []
        row = {"step": "rerequest", "repo": k, "pr": ({"repo": pr["repo"], "number": pr["number"]} if pr else None),
               "requests": [{"body": r["body"], "poster": r["poster"], "done": False} for r in reqs]}
        if not reqs:
            row["state"] = "not_applicable"
        else:
            row["after"] = unmet(f"push:{k}")
            row["blocked"] = bool(row["after"])
            row["state"] = "todo"
            if not row["after"]:
                states, pushed_at, cutoff, source = request_state(pr["repo"], pr["number"], branch, tip[k], reqs,
                                                                  rec.get("written_at") or (held or {}).get("at"))
                row["requests"], row["push_time"], row["cutoff"], row["cutoff_source"] = states, pushed_at, cutoff, source
                row["state"] = "done" if all(s["done"] for s in states) else "todo"
        rows.append(row)

    if adopted and prs.get("store"):  # 3b. a code PR adopted after the pair was linked (or not): the link is evidence too
        urls = {k: gh_obj(f"repos/{prs[k]['repo']}/pulls/{prs[k]['number']}")["html_url"] for k in ("code", "store")}  # canonical, never built
        linked = (link_state(prs["code"]["repo"], prs["code"]["number"], "store", urls["store"])[0]
                  and link_state(prs["store"]["repo"], prs["store"]["number"], "code", urls["code"])[0])
        rows.append({"step": "link", "state": "done" if linked else "todo",
                     **{k: {"repo": prs[k]["repo"], "number": prs[k]["number"], "url": urls[k]} for k in ("code", "store")}})

    react_on = ctx["react"]
    for f in findings:  # 4-6. reply, resolution, reaction
        src, kind = f["source"], f.get("kind", "thread")
        ks = [k for k in ("store", "code") if edits_for(f, k)]
        s = snaps[src]
        items = s.get({"thread": "threads", "comment": "comments", "review": "reviews"}[kind]) or []
        item = next((i for i in items if i.get("id") == f["item"]), None)
        rev0, last0 = f["revision"].get("rev"), f["revision"].get("last_reviewer_comment") or {}
        viewer, disp = s.get("viewer"), f["disposition"]
        want_resolve = bool(disp.get("resolve")) and kind == "thread"
        reaction = disp.get("react") if react_on and disp.get("react") in ("+1", "-1") else None
        answered, stale, activity = item is None, False, []
        if item is not None:
            cs = item.get("comments") or []
            if kind == "thread" and (item.get("awaiting_reviewer") or any(
                    c.get("author") == viewer and (c.get("at") or "") > (last0.get("at") or "") for c in cs)):
                answered = True
            elif item.get("rev") != rev0:
                stale = True
                if kind == "thread":
                    activity = [{"id": c.get("id"), "author": c.get("author"), "at": c.get("at"), "edited": c.get("edited")} for c in cs
                                if c.get("author") != viewer and max(c.get("at") or "", c.get("edited") or "") > (last0.get("at") or "")]
                else:
                    activity = [{"id": item.get("id"), "author": item.get("author"), "at": item.get("at"), "edited": None}]
        base = {"finding": f["id"]}
        if stale:
            stops.append({"reason": "stale_disposition", "finding": f["id"], "item": f["item"], "new_activity": activity,
                          "detail": "the reviewer added to or edited this item since the disposition was judged; post nothing, list the activity and ask"})
            rows.append({**base, "step": "reply", "state": "stopped"})
            rows.append({**base, "step": "resolve", "state": "stopped"})
            rows.append({**base, "step": "react", "state": "stopped"})
            continue
        pr = prs.get(src) or {}
        after = [i for k in ks for i in unmet(f"fix_commit:{k}", f"push:{k}")]
        links = [{"repo": slug[k], "sha": fix.get(k)} for k in ks]
        reply = {**base, "step": "reply", "state": "done" if answered else "todo", "kind": kind, "item": f["item"], "root_id": f.get("root_id"),
                 "pr": {"repo": pr.get("repo"), "number": pr.get("number")}, "resolve": want_resolve and not answered,
                 "react": reaction if not answered else None, "link_commit": links[0], "link_commits": links,
                 "after": [] if answered else after, "blocked": bool(after) and not answered}
        rows.append(reply)
        if not want_resolve:
            res = {**base, "step": "resolve", "state": "not_applicable"}
        elif item is None or item.get("resolved"):
            res = {**base, "step": "resolve", "state": "done"}
        elif not answered:
            res = {**base, "step": "resolve", "state": "todo", "after": [f"reply:{f['id']}"]}
        else:
            res = {**base, "step": "resolve", "state": "ask", "thread": f["item"], "resolve_pending": bool(item.get("resolve_pending")),
                   "detail": "the reply is posted but the thread is unresolved: list it and ask; never re-resolve silently"}
        rows.append(res)
        target = f.get("root_id") if kind == "thread" else f["item"]
        if not reaction:
            rows.append({**base, "step": "react", "state": "not_applicable"})
        else:
            # a reaction counts once GitHub shows it: read it with the viewer's login, after the reply is posted
            seen = answered and has_reaction(pr.get("repo") or slug[src], kind, target, reaction, viewer)
            rows.append({**base, "step": "react", "state": "done" if seen else "todo", "react": reaction, "comment": target,
                         "pr": {"repo": pr.get("repo"), "number": pr.get("number")}, "idempotent": True})

    done_states = ("done", "not_applicable")
    complete = not stops and all(r["state"] in done_states for r in rows)
    status = "stop" if stops else ("complete" if complete else "resume")
    return {"ok": True, "record": True, "round": n, "branch": branch, "new_pass_allowed": False, "status": status, "stops": stops,
            "rows": rows, "delete_record": complete, "needs_user": bool(stops) or any(r["state"] == "ask" for r in rows),
            "share_by_hand": [r["repo"] for r in rows if r["step"] == "push" and r.get("share_by_hand")], "path": norm(path),
            "owner": held, "owned": owned, **({"legacy_record_ignored": ignored} if ignored else {})}


def owner_id(rec):
    return (rec.get("owner") or {}).get("id")


def pass_done(argv):
    a = pass_args(argv, {"--owner": "owner"})
    need(a, "owner")
    path, _ = locate_record(a["code_repo"], a["change"])
    if not path.exists():
        return {"ok": True, "deleted": False, "record": False}
    with record_lock(path):
        rec = load_record(path)
        if rec is None:
            return {"ok": True, "deleted": False, "record": False}
        if owner_id(rec) != a["owner"]:
            raise Stop("not_owner", f"the record at {norm(path)} is owned by {owner_id(rec) or 'no session'}, not {a['owner']}; "
                       "show its owner and ask the user", owner=rec.get("owner"))
        p = pass_plan(argv)
        if not p["delete_record"]:
            raise Stop("not_complete", "the pass still has steps to do; run pass plan", status=p["status"])
        path.unlink()
    return {"ok": True, "deleted": True}


def pass_adopt(argv):
    a = pass_args(argv, {"--owner": "owner", "--from": "frm"})
    need(a, "owner", "frm")
    path, _ = locate_record(a["code_repo"], a["change"])
    if not path.exists():
        raise Stop("no_record", f"no feedback pass record at {norm(path)}")
    with record_lock(path):
        rec = load_record(path)
        if rec is None:
            raise Stop("no_record", f"no feedback pass record at {norm(path)}")
        cur = owner_id(rec)
        if cur != (None if a["frm"] == "none" else a["frm"]):
            raise Stop("not_owner", f"the record at {norm(path)} is owned by {cur or 'no session'}, not {a['frm']}; nothing changed",
                       owner=rec.get("owner"))
        # an older record has no written_at and falls back to the owner's at: keep that pass start before the owner changes
        rec = {**rec, "version": 2, "written_at": rec.get("written_at") or (rec.get("owner") or {}).get("at"),
               "owner": new_owner(a["owner"], a["code"])}
        if rec["written_at"] is None:
            rec.pop("written_at")
        f, tmp = temp_beside(path)
        try:
            with f:
                f.write(json.dumps(rec, indent=2))
            os.replace(tmp, path)
        except BaseException:
            if os.path.exists(tmp):
                os.unlink(tmp)
            raise
    return {"ok": True, "path": norm(path), "owner": a["owner"], "previous": cur}


def cmd_pass(argv):
    if not argv or argv[0] not in ("write", "plan", "done", "adopt"):
        usage("pass write|plan|done|adopt ...")
    return {"write": pass_write, "plan": pass_plan, "done": pass_done, "adopt": pass_adopt}[argv[0]](argv[1:])


def cmd_branch_check(argv):
    """May a change branch be deleted once its PR merged and main is updated? Local refs only; changes nothing."""
    a, _ = parse_args(argv, {"--dir": "dir", "--branch": "branch", "--main": "main", "--head": "head", "--code": "code",
                             "--role": "role", "--login": "login"})
    need(a, "dir", "branch", "main")
    d, b, m, head = a["dir"], a["branch"], a["main"], a.get("head")
    backend = "git"
    if a.get("code"):  # a non-Git backend reads the fetched main through vcs.sh: its local main may lag a skipped pull
        role = a.get("role") or "code"
        if role not in ("code", "store"):
            usage("--role must be code or store")
        backend = cmd_vcs(["--code", a["code"]])[role]
        if backend != "git":
            m = vcs_json("fetch-main", "--repo", d, "--role", role, "--code", a["code"],
                         *(["--login", a["login"]] if a.get("login") else []))["commit"]
    if head is not None and not re.match(r"^[0-9a-fA-F]{4,64}$", head):
        raise Stop("usage", f"--head must be a commit id, got {head!r}", code=2)

    def fail(what, r):
        raise Stop("git_error", f"{what} in {d}: {(r.stderr or r.stdout).strip()}")

    if not has_ref(d, f"refs/heads/{b}"):
        # without --code (the repo-local call) <dir> is the code repo; a store is never on GitButler
        if not a.get("code"):
            backend = cmd_vcs(["--code", d])["code"]
        if backend == "gitbutler":  # `but pull` removed the integrated branch: delete-branch reports already_deleted
            return {"ok": True, "delete": True, "reason": "already_deleted", "lacking": []}

    # --main may be a commit id (the fetched main on GitButler) when no branch has that name
    by_commit = re.fullmatch(r"[0-9a-fA-F]{7,40}", m) and not has_ref(d, f"refs/heads/{m}")
    for ref in (f"refs/heads/{b}",) + (() if by_commit else (f"refs/heads/{m}",)):
        r = git(d, "rev-parse", "--verify", "-q", ref + "^{commit}")
        if r.returncode != 0:
            fail(f"cannot resolve {ref}", r)
    if by_commit:
        r = git(d, "rev-parse", "--verify", "-q", m + "^{commit}")
        if r.returncode != 0:
            fail(f"cannot resolve commit {m}", r)

    def ancestor(x, y, what):
        r = git(d, "merge-base", "--is-ancestor", x, y)
        if r.returncode not in (0, 1):
            fail(what, r)
        return r.returncode == 0

    def lacking(*rng):
        r = git(d, "log", "--format=%H%x1f%s%x1e", *rng)
        if r.returncode != 0:
            fail("git log failed", r)
        rows = [(rec.strip("\n").split("\x1f") + [""])[:2] for rec in r.stdout.split("\x1e") if rec.strip()]
        return [{"sha": sha.strip(), "subject": subject} for sha, subject in rows]

    tip, mref = f"refs/heads/{b}", (m if by_commit else f"refs/heads/{m}")
    if ancestor(tip, mref, f"cannot compare {b} with {m}"):
        return {"ok": True, "delete": True, "reason": "on_main", "lacking": []}
    known = bool(head) and git(d, "cat-file", "-e", head + "^{commit}").returncode == 0
    if not known:
        return {"ok": True, "delete": False, "reason": "head_unknown", "lacking": lacking(f"{mref}..{tip}")}
    if ancestor(tip, head, f"cannot compare {b} with {head}"):
        return {"ok": True, "delete": True, "reason": "pr_head", "lacking": []}
    return {"ok": True, "delete": False, "reason": "lacking", "lacking": lacking(f"{mref}..{tip}", "--not", head)}


def vcs_sh(*args):
    return run([BASH, f"{os.environ['PR_PAIR_DIR']}/vcs.sh", *args])


def vcs_plan(cwd, role, code, operation, branch, *extra):
    """The commands vcs.sh plan prints for one operation in a jj repo, as {cmd: argv, cwd}."""
    r = vcs_sh("plan", "--repo", cwd, "--role", role, "--code", code, "--operation", operation, "--branch", branch, *extra)
    try:
        doc = json.loads(r.stdout)
    except ValueError:
        doc = {}
    if not doc.get("ok"):
        raise Stop(doc.get("error") or "vcs_error", doc.get("message") or f"vcs.sh plan failed in {cwd}: {r.stderr.strip()}")
    return [[x.replace("\\", "/") if re.match(r"^[A-Za-z]:\\", x) else x for x in shlex.split(c)] for c in doc["commands"]]  # drive paths: forward slashes


def vcs_json(command, *args):
    r = vcs_sh(command, *args)
    try:
        doc = json.loads(r.stdout)
    except ValueError:
        doc = {}
    if not doc.get("ok"):
        raise Stop(doc.get("error") or "vcs_error", doc.get("message") or f"vcs.sh {command} failed: {r.stderr.strip()}",
                   code=3 if r.returncode == 3 else 1)
    return doc


def vcs_state(cwd, role, code, branch):
    """vcs.sh state for the named change branch (GitButler: the change's, unassigned and other branches' paths)."""
    return vcs_json("state", "--repo", cwd, "--role", role, "--code", code, "--branch", branch)


def vcs_branch(cwd, role, code):
    """The current branch of a repo, read through vcs.sh state."""
    r = vcs_sh("state", "--repo", cwd, "--role", role, "--code", code)
    try:
        doc = json.loads(r.stdout)
    except ValueError:
        doc = {}
    if not doc.get("ok"):
        raise Stop(doc.get("error") or "vcs_error", doc.get("message") or f"vcs.sh state failed in {cwd}: {r.stderr.strip()}")
    return doc["branch"]


def cmd_cleanup(argv):
    a, _ = parse_args(argv, {"--code": "code", "--store": "store", "--branch": "branch"})
    need(a, "code", "store", "branch")
    branch = a["branch"]
    e = expected_set(a["code"], a["store"], branch)
    ctx = contexts(a["code"], a["store"])
    as_sh = f"{os.environ['PR_PAIR_DIR']}/as.sh"
    members, keep, out = e["set"], [], {}
    backends = cmd_vcs(["--code", a["code"]])
    all_merged = bool(members) and all(e[k]["pr"] and e[k]["pr"]["state"] == "MERGED" for k in members)
    for k, d in (("code", a["code"]), ("store", a["store"])):
        side, main = e[k], e[k]["main"]
        pr, cwd = side["pr"], norm(d)
        exists = has_ref(d, f"refs/heads/{branch}")
        ent = {"expected": side["expected"], "repo": side["repo"], "dir": cwd, "merged": False, "branch_exists": exists, "pr": pr, "commands": []}
        cmd = lambda *c: {"cmd": list(c), "cwd": cwd}
        jj = backends[k] != "git"  # a jj or GitButler repo gets vcs.sh plan's commands; a Git repo keeps the Git commands below
        gb = backends[k] == "gitbutler"
        if side["expected"] and pr and pr["state"] == "MERGED":
            ent["merged"] = True
            if exists:
                # after the pull, branch-check decides: the skill runs `delete` only when it answers delete: true
                check = ["pr-pair.sh", "branch-check", "--dir", cwd, "--branch", branch, "--main", main] + (["--head", pr["head_sha"]] if pr.get("head_sha") else [])
                if jj:
                    login = ctx[k]["login"] or ambient_login()
                    merged_sha = pr.get("merge_commit_sha")
                    if gb:  # the pull names the branch being cleaned up; the check reads the fetched main; the delete carries the squash proof
                        check += ["--code", a["code"], "--role", k, "--login", login]
                    ent["commands"] = ([cmd(*c) for c in vcs_plan(cwd, k, a["code"], "switch", main)] +
                                       [cmd(*c) for c in vcs_plan(cwd, k, a["code"], "pull", branch if gb else main, "--login", login)] +
                                       [cmd(*check)])
                    ent["delete"] = vcs_plan(cwd, k, a["code"], "delete-branch", branch, "--force",
                                             *(["--merged-commit", merged_sha] if gb and merged_sha else []))[0]
                else:
                    ent["commands"] = [cmd("git", "checkout", main), cmd("bash", as_sh, ctx[k]["login"] or ambient_login(), "git", "pull", "--ff-only"), cmd(*check)]
                    ent["delete"] = ["git", "branch", "-D", branch]
        elif side["expected"]:
            keep.append({"repo": k, "slug": side["repo"], "state": pr["state"] if pr else "NONE", "branch": branch,
                         "url": pr["url"] if pr else None})
        elif k == "store" and exists and side["reason"] == "no_github_origin":  # no PR can merge it: the user shares it by hand
            keep.append({"repo": k, "slug": None, "state": "SHARE_BY_HAND", "branch": branch, "url": None})
        elif k == "code" and exists and all_merged:  # the empty code branch, kept until now
            cur = vcs_branch(cwd, k, a["code"])
            if jj:
                ent["commands"] = (([cmd(*c) for c in vcs_plan(cwd, k, a["code"], "switch", main)] if cur == branch else []) +
                                   [cmd(*c) for c in vcs_plan(cwd, k, a["code"], "delete-branch", branch)])
            else:
                ent["commands"] = ([cmd("git", "checkout", main)] if cur == branch else []) + [cmd("git", "branch", "-d", branch)]
        out[k] = ent
    return {"ok": True, "branch": branch, "set": members, "code": out["code"], "store": out["store"], "keep": keep}


def cmd_merge(argv):
    """Merge PR n at the ready head with the configured method, once, and decide from a read-back (never from the PUT alone)."""
    a, _ = parse_args(argv, {"--repo": "repo", "--pr": "pr", "--method": "method", "--head": "head"})
    need(a, "repo", "pr", "method", "head")
    repo, n, method, head = a["repo"], a["pr"], a["method"], a["head"]
    if not re.fullmatch(r"[1-9][0-9]*", n):
        usage("--pr must be a positive integer")
    if method not in ("merge", "squash", "rebase"):
        usage(f"--method must be merge, squash or rebase, got {method!r}")
    if not re.fullmatch(r"[0-9a-fA-F]{7,40}", head):
        usage(f"--head must be a commit id of 7 to 40 hex digits, got {head!r}")
    n = int(n)
    r = gh("api", "-X", "PUT", f"repos/{repo}/pulls/{n}/merge", "-f", f"merge_method={method}", "-f", f"sha={head}",
           limit_ok=True)  # a limit leaves the merge undecided: the read-back below decides
    m = re.search(r"\(HTTP (\d{3})\)", r.stderr or "")
    status = int(m.group(1)) if m else None
    message = ""
    try:
        body = json.loads(r.stdout)
        message = body.get("message") or "" if isinstance(body, dict) else ""
    except ValueError:
        pass
    message = message or (r.stderr or r.stdout).strip() or f"gh exited {r.returncode}"
    try:
        pr = gh_obj(f"repos/{repo}/pulls/{n}")  # unreadable = unknown (exit 3): the merge may have happened
    except Stop as e:
        e.extra.setdefault("status", "unknown")
        raise
    if pr.get("merged_at"):
        return {"ok": True, "status": "merged", "repo": repo, "pr": n, "head_sha": (pr.get("head") or {}).get("sha"),
                "merge_commit_sha": pr.get("merge_commit_sha")}
    if r.returncode == 0 or status is None or status >= 500:  # a server error may still complete the merge
        raise Stop("lookup_failed", f"GitHub state unknown: merge of {repo}#{n} is not confirmed: {message}", code=3,
                   unknown=True, status="unknown")
    raise Stop("refused", message, status="refused", reason="head_changed" if status == 409 else "refused",
               http_status=status, repo=repo, pr=n)


def http_status(r):
    m = re.search(r"\(HTTP (\d{3})\)", r.stderr or "")
    return int(m.group(1)) if m else None


def reply_message(r):
    try:
        body = json.loads(r.stdout)
        message = body.get("message") or "" if isinstance(body, dict) else ""
    except ValueError:
        message = ""
    return message or (r.stderr or r.stdout).strip() or f"gh exited {r.returncode}"


def policy_unknown(reason):
    raise Stop("lookup_failed", f"merge policy unknown: {reason}", code=3, unknown=True)


def policy_gh(*args):
    """One fenced, bounded gh read for `policy`; a failure or a limit is unknown with the policy wording; a 404 is None."""
    try:
        r = gh(*args)
    except Stop as e:
        if e.extra.get("unknown"):
            policy_unknown(re.sub(r"^GitHub state unknown: ", "", e.message))
        raise
    if r.returncode != 0:
        if http_status(r) == 404:
            return None
        policy_unknown(reply_message(r))
    return r.stdout


def policy_file(repo, ref):
    """The parsed specwright.yaml at `ref` from GitHub's contents API: a mapping, or None when the file is not there (404)."""
    out = policy_gh("api", f"repos/{repo}/contents/openspec/specwright.yaml?ref={quote(ref, safe='')}")
    if out is None:
        return None
    try:
        body = json.loads(out)
        if not isinstance(body, dict) or body.get("type") != "file" or body.get("encoding") != "base64":
            raise ValueError("not a base64 file")
        text = base64.b64decode("".join(str(body.get("content", "")).split()), validate=True).decode("utf-8-sig")
        why = yaml_problem(text)
        if why:
            raise ValueError(why)
        s = parse_yaml(text) or {}
        if not isinstance(s, dict):
            raise ValueError("not a mapping")
    except (ValueError, TypeError) as e:  # binascii.Error and UnicodeDecodeError are ValueErrors
        policy_unknown(f"unreadable openspec/specwright.yaml at {ref}: {e}")
    return s


def policy_side(s, with_store):
    """The policy keys of one settings file, normalized so only a real difference compares unequal. Keys are the setting names."""
    def sect(src, name):
        v = src.get(name)
        return v if isinstance(v, dict) else {}
    pr = sect(s, "pr")
    merge, note = merge_mode(pr)
    method, delete = pr.get("merge_method"), pr.get("delete_branch")
    raw, invalid, probs = pr.get("reviewers"), [], []
    if raw is not None and not isinstance(raw, dict):  # a string or a list: no reviewers, so it authorizes nothing
        invalid.append({"key": "pr.reviewers", "value": setting_text(pr, "reviewers")})
        raw = None
    side = {"pr.merge": merge, "pr.merge_method": "merge" if method is None else method,
            "pr.delete_branch": True if delete is None else delete, "pr.reviewers": reviewers_of(raw, probs),
            "pr.settle": settle_of(pr)[0]}  # seconds; a bad value counts as the default, and main's stops `policy`
    if with_store:
        own = sect(s, "planning_store").get("reviewers")
        side["planning_store.reviewers"] = (  # None: the store inherits pr.reviewers
            reviewers_of(own, probs, "planning_store.reviewers") if isinstance(own, dict) else None)
    return side, note, pr, invalid, probs


def same_setting(a, b):
    """Equal by type as well as value: Python has 1 == True and 0 == False, but `delete_branch: 1` is not `true`."""
    return json.dumps(a, sort_keys=True, default=str) == json.dumps(b, sort_keys=True, default=str)


def has_required(reviewers):
    return any(r["role"] == "required" for r in reviewers.values())


def same_commit(a, b):
    """Two commit ids are the same when equal, or when one (7 to 40 hex digits) is a prefix of the other."""
    a, b = str(a or "").lower(), str(b or "").lower()
    return bool(re.fullmatch(r"[0-9a-f]{7,40}", a) and re.fullmatch(r"[0-9a-f]{7,40}", b)) and (a.startswith(b) or b.startswith(a))


def reported_check(snapshot, reviewed, reviewers, digest):
    """Whether the snapshot is of the reviewed head, ran with the rules of this set (its `reviewer_config` digest equals the
    set's) and every required reviewer of the set reported in it. A set with no required reviewer authorizes nothing: not ok."""
    got = snapshot.get("head_oid") if isinstance(snapshot, dict) else None
    mismatch = not same_commit(got, reviewed)
    state = {}
    for r in (snapshot.get("reviewers") if isinstance(snapshot, dict) else None) or []:
        if isinstance(r, dict) and isinstance(r.get("login"), str):
            login = re.sub(r"\[bot\]$", "", r["login"]).lower()
            state[login] = state.get(login, False) or r.get("state") == "reported"
    required = [l for l, r in reviewers.items() if r["role"] == "required"]
    missing = [l for l in required if not state.get(l.lower())]
    rules = not (isinstance(snapshot, dict) and snapshot.get("reviewer_config") == digest)
    return {"ok": bool(required) and not missing and not mismatch and not rules, "missing": missing, "head_mismatch": mismatch,
            "rules_mismatch": rules, "snapshot_head": got, "reviewed_head": reviewed}


def cmd_policy(argv):
    """The merge policy as the default branch holds it, and where the PR head's copy differs (trust-main-merge-policy D1-D3)."""
    with_store = "--store" in argv
    a, _ = parse_args([t for t in argv if t != "--store"], {"--repo": "repo", "--head": "head", "--snapshot": "+snapshot",
                                                            "--reviewed-head": "+reviewed"})
    need(a, "repo", "head")
    repo, head = a["repo"], a["head"]
    if not re.fullmatch(r"[0-9a-fA-F]{7,40}", head):
        usage(f"--head must be a commit id of 7 to 40 hex digits, got {head!r}")
    reviewed = {}
    for spec in a.get("reviewed", []):
        name, _, sha = spec.partition("=")
        if name not in ("code", "store") or not re.fullmatch(r"[0-9a-fA-F]{7,40}", sha):
            usage("--reviewed-head is code=<sha> or store=<sha> (7 to 40 hex digits)")
        reviewed[name] = sha
    reviewed.setdefault("code", head)
    sides = ["code", "store"] if with_store else ["code"]
    snaps = read_snapshots(a)
    for side in sides:
        if side not in snaps:
            usage(f"missing --snapshot {side}=<file>")
    if with_store and "store" not in reviewed:
        usage("--store needs --reviewed-head store=<sha>")
    if not with_store and ("store" in snaps or "store" in reviewed):
        usage("--snapshot store= and --reviewed-head store= need --store")
    body = policy_gh("api", f"repos/{repo}")
    try:
        default = json.loads(body or "")["default_branch"]
        if not isinstance(default, str) or not default:
            raise ValueError("no default branch")
    except (ValueError, KeyError, TypeError):
        policy_unknown(f"cannot read the default branch of {repo}")
    main_s = policy_file(repo, default)
    if main_s is None:
        main_s = {}  # no settings file on the default branch: user mode
    head_s = policy_file(repo, head)
    if head_s is None:
        policy_unknown(f"no openspec/specwright.yaml readable at {head}")
    main, note, main_pr, main_bad, main_probs = policy_side(main_s, with_store)
    head_side, _, _, head_bad, head_probs = policy_side(head_s, with_store)
    settle_bad = settle_of(main_pr)[1]  # main's policy: a bad value stops here, a bad head value is only the head's
    for bad in ([settle_bad] if settle_bad else []) + main_probs:
        raise Stop(bad["error"], problem_text(bad), code=2)
    drift = [{"key": k, "main": main[k], "head": head_side[k]} for k in main if not same_setting(main[k], head_side[k])]
    out = {"ok": True, "repo": repo, "default_branch": default, "main": main, "head": head_side, "drift": drift,
           "invalid": [dict(side=w, **b) for w, bad in (("main", main_bad), ("head", head_bad)) for b in bad]
           + [{"side": "head", "key": b["key"], "value": b["error"] if b["error"] == "too_many_reviewers" else b["why"]}
              for b in head_probs],
           "merge": main["pr.merge"], "merge_method": "merge", "delete_branch": True, "settle": main["pr.settle"]}
    if out["merge"] == "agent":  # only the agent merge reads them, as context does; a bad value on main stops here
        out["merge_method"], out["delete_branch"] = merge_options(main_pr)
    ready = {"code": has_required(main["pr.reviewers"])}
    if with_store:
        own = main["planning_store.reviewers"]
        ready["store"] = ready["code"] if own is None else has_required(own)
    out["merge_ready"] = ready
    out["reported"], out["reviewer_config"] = {}, {}
    for which, side in (("main", main), ("head", head_side)):
        sets = {"code": side["pr.reviewers"]}
        if with_store:
            own = side["planning_store.reviewers"]
            sets["store"] = side["pr.reviewers"] if own is None else own
        out["reported"][which], out["reviewer_config"][which] = {}, {}
        for k, v in sets.items():
            path, digest, big = write_reviewer_config(v)
            if big and which == "main":
                raise Stop("bad_setting", problem_text(big), code=2)
            if big:
                out["invalid"].append({"side": "head", "key": big["key"], "value": big["why"]})
            out["reviewer_config"][which][k] = path
            out["reported"][which][k] = reported_check(snaps[k], reviewed[k], v, digest)
    out["merge_reason"] = {k: None if v else "no_required_reviewer" for k, v in ready.items()}
    if note:
        out["merge_note"] = note
    return out


def cmd_delete_remote(argv):
    """Delete the remote branch only at the merged head with no open PR based on it; a failed read is unknown, never a delete."""
    a, _ = parse_args(argv, {"--repo": "repo", "--branch": "branch", "--head": "head"})
    need(a, "repo", "branch", "head")
    repo, branch, head = a["repo"], a["branch"], a["head"]
    if not re.fullmatch(r"[0-9a-fA-F]{40}", head):  # GitHub reports the full id: no prefix matching
        usage(f"--head must be a full 40-digit commit id, got {head!r}")
    path = quote(branch, safe="/")
    base = {"repo": repo, "branch": branch}
    r = gh("api", f"repos/{repo}/git/ref/heads/{path}")
    if r.returncode != 0:
        if http_status(r) == 404:
            return {"ok": True, "status": "gone", **base}
        unknown(reply_message(r))
    try:
        sha = json.loads(r.stdout)["object"]["sha"]
    except (ValueError, KeyError, TypeError):
        unknown("unreadable ref response")
    if not isinstance(sha, str) or sha.lower() != head.lower():
        return {"ok": True, "status": "moved", **base, "sha": sha}
    based = gh_list(f"repos/{repo}/pulls?state=open&base={quote(branch, safe='')}&per_page=100")
    if based:
        return {"ok": True, "status": "based_on", **base, "prs": [p["number"] for p in based]}
    r = gh("api", "-X", "DELETE", f"repos/{repo}/git/refs/heads/{path}")
    if r.returncode == 0:
        return {"ok": True, "status": "deleted", **base}
    status, message = http_status(r), reply_message(r)
    if status is None:
        unknown(message)
    if status == 422 and "does not exist" in message.lower():  # gone between the read and the delete
        return {"ok": True, "status": "gone", **base}
    raise Stop("kept", message, status="kept", http_status=status, **base)


ITEM_JQ = '.[] | select(.pull_request == null and ((.body // "") | contains("specwright:pr-item "))) | {number, body}'


def cmd_item_issues(argv):
    """The existing PR-item issues of one repository in one paged read; gh's --jq keeps only marked issues. An item is matched
    by a whole `specwright:pr-item <id>` line, the lowest issue number winning. A failed or limited read exits 3, never a guess."""
    a, _ = parse_args(argv, {"--repo": "repo", "--item": "+items"})
    need(a, "repo", "items")
    repo, items = a["repo"], a["items"]
    r = gh("api", "--paginate", f"repos/{repo}/issues?state=all&per_page=100", "--jq", ITEM_JQ, repo=repo)
    if r.returncode != 0:
        unknown((r.stderr or r.stdout).strip() or f"gh exited {r.returncode}")
    lines = {}  # marker line -> lowest issue number
    for raw in r.stdout.splitlines():
        if not raw.strip():
            continue
        try:
            issue = json.loads(raw)
            number, body = issue["number"], issue.get("body") or ""
        except (ValueError, KeyError, TypeError, AttributeError):
            unknown("unreadable response")
        for line in body.splitlines():
            line = line.strip()
            if line.startswith("specwright:pr-item "):
                lines[line] = min(number, lines.get(line, number))
    found = {i: lines[f"specwright:pr-item {i}"] for i in items if f"specwright:pr-item {i}" in lines}
    return {"ok": True, "found": found, "missing": [i for i in items if i not in found]}


COMMANDS = {"identity": cmd_identity, "context": cmd_context, "tier": cmd_tier, "vcs": cmd_vcs, "discover": cmd_discover, "expected": cmd_expected,
            "ensure-pr": cmd_ensure_pr, "closing-check": cmd_closing_check,
            "closed-check": cmd_closed_check, "link": cmd_link, "pair-state": cmd_pair_state, "rounds": cmd_rounds,
            "pass": cmd_pass, "cleanup-plan": cmd_cleanup, "branch-check": cmd_branch_check, "merge": cmd_merge,
            "delete-remote": cmd_delete_remote, "policy": cmd_policy, "item-issues": cmd_item_issues}

args = sys.argv[1:]
try:
    if not args or args[0] not in COMMANDS:
        usage("subcommand: " + " | ".join(COMMANDS))
    out = COMMANDS[args[0]](args[1:])
    emit({**out, "lock_left": LEFT_LOCKS} if LEFT_LOCKS else out)
except Stop as e:
    emit({**e.obj(), "lock_left": LEFT_LOCKS} if LEFT_LOCKS else e.obj(), e.code)
except Exception as e:
    err = {"ok": False, "error": "internal_error", "message": f"{type(e).__name__}: {e}"}
    emit({**err, "lock_left": LEFT_LOCKS} if LEFT_LOCKS else err, 1)
PYSRC
