#!/usr/bin/env bash
# Release decisions for a project that opted in (release.enabled in openspec/specwright.yaml): do the version
# files agree, bump them to a target, and which release commit carries a version. Every subcommand prints ONE
# JSON document.
#
# Usage: bash release.sh [--dir <repo>] <subcommand> [options]
#   check [--main <ref>] [--branch <name>]
#                                     read the version files in the working tree (with --branch: at the tip of refs/heads/<name>,
#                                     resolved now, through git; the range below is then <ref>..<tip> and the merge base is the
#                                     tip's: no other branch's commit counts): exactly one match per file, one shared
#                                     version -> version + the files read. With --main, then refuse (exit 1,
#                                     version_not_ahead_of_main) a branch that bumped to a version not greater than <ref>'s. It
#                                     bumped when its version differs from the merge base's with <ref>, or the newest non-merge
#                                     commit in <ref>..HEAD (<ref>..<tip>) that changed the primary file's version raised it; no readable version
#                                     at <ref> passes. A primary file that exists but does not read exactly one version is
#                                     unreadable, not absent: an unreadable merge base or parent counts as a bump only when the
#                                     version is not among the versions it matched (and, for a commit, is greater than all of them);
#                                     a commit whose parent is unreadable and on the branch changed it when it matched a version
#                                     the parent did not; otherwise a commit whose own version is unreadable changed it only when
#                                     the version it is judged against is not among those it matched; a change raised it only
#                                     when it matched a version and all of them are greater than that version
#                                     check: when the code repo's backend is gitbutler (read as vcs.sh reads it, through pr-pair.sh vcs)
#                                     --branch is required: exit 2, usage. HEAD is the workspace commit there. An unknown branch is
#                                     exit 1, branch_not_found
#   bump --to MAJOR.MINOR.PATCH       rewrite only the captured version in every version file (temp file + rename each);
#                                     the target must be greater than the current version. Never commits. Rerunning an
#                                     interrupted bump to the same target completes it
#   status --version V [--main <ref>] [--base <branch>] [--store <dir> [--store-main <ref>] [--store-prefix <path>]]
#                                     V's release commit: the first commit on <ref>'s first-parent history whose primary file
#                                     reads V (default: the local main; the skill passes origin/<main>). It must be a merge
#                                     commit or a commit whose subject ends in (#<n>), and its version files must all read V.
#                                     JSON: version, tag, release_commit, main, files, previous {commit, version, basis:
#                                     tag|history|null}, range {from, to, commits}, changes [{name, why, pr}], warnings [{change, error}] (a change whose
#                                     `## Release Notes` section is invalid, or whose proposal is over 64 KB, falls back to its Why
#                                     line; the first error), notes (text for the tag annotation and the release body: with a
#                                     valid section in the range, the release summary, then Added:/Changed:/Fixed:/Removed: groups
#                                     of the sections' items (150 at most) and Changes: for the changes without one; else
#                                     `Changes in <tag>:` and one line per change; the summary is the bumping change's (its
#                                     archived tasks.md ticks `release.sh bump --to V`), else the last valid section's), tag_local (sha the local tag points at, or
#                                     null), tag_remote (the commit the tag points at on origin, from one read-only
#                                     `git ls-remote --tags origin`, or null; also null with no origin remote; an unreadable
#                                     origin is exit 3, remote_tags_unreadable), previous (from tags locally or on origin:
#                                     one more `git ls-remote --tags --refs origin`, also exit 3 when unreadable),
#                                     tag_object {local, remote} (each side's tag
#                                     object id, or null), repo and tag_repo (the code repo: the only one
#                                     ever tagged), github_release (existing|absent from a read-only `gh release view <tag>
#                                     --repo o/n`; disabled when release.github_release is false, not_github when origin is not
#                                     on github.com; any other gh failure is exit 3, release_view_failed), store (with --store).
#                                     Notes: repo-local = archive dirs added in (previous release commit, release commit];
#                                     with --store = the store main's archive dirs (not code_changes: none) whose code-merge
#                                     proof is in that range: `merge: <name>` subject (finish: local) or a merged PR from the
#                                     code repo's own <prefix>/<name> branch (one `gh api --paginate .../pulls` call; a failure
#                                     is exit 3, pr_discovery_failed). --store-prefix defaults to openspec. --base is the GitHub
#                                     base branch that call lists PRs of (a jj run passes the fetched commit as --main, which
#                                     names no branch); without it the branch is --main's name after `origin/`, or the main name.
#   notes --proposal <file>           parse one proposal's `## Release Notes` section: no repo, no git or network call, and no
#                                     release.enabled needed. Exit 0: summary, items {added|changed|fixed|removed: [{text, line}]}
#                                     (line = the notes line, an unreferenced item ending in the literal ` (#<pr>)`). Exit 1:
#                                     release_notes_invalid (errors [{line, message}]; a file over 64 KB too) or no_release_notes.
#                                     Exit 2: the file does not exist
#   untagged [--main <ref>] [--local] versions in main's history of the primary file after the latest tagged one (with no tag:
#                                     only the current version) that are not published, oldest first (published = tag on origin;
#                                     --local, or no origin remote: a local tag, with no network call):
#                                     {latest_tagged, tags: local|origin, untagged: [{version, tag, release_commit}]}
#   publish --version V [--main ref] [--base <branch>] [--store ...]
#                                     after the opt-in, merge-method, release-commit, agreement and older-untagged gates, reads
#                                     the tag locally and on origin (ls-remote) and does only what is missing: annotated tag on
#                                     the release commit (notes = its message), `git push origin refs/tags/<tag>:refs/tags/<tag>`
#                                     (never --tags, --force or a branch), then `gh release create --verify-tag` (body = the
#                                     tag's message) when release.github_release is on and origin is on github.com. A tag at
#                                     another commit, locally or on origin, is exit 1 tag_conflict before any write; a push URL
#                                     naming another repository than the fetch URL is exit 1 push_url_mismatch; local and
#                                     origin tags at the release commit as different tag objects (a lost push race) are exit 1
#                                     tag_mismatch before any write, so the release body is always origin's tag. Unreadable
#                                     origin tags: exit 3 remote_tags_unreadable before any tag. A failed push: exit 3
#                                     tag_push_failed (the local tag stays; a re-run pushes it, or stops with tag_mismatch when
#                                     another clone's tag reached origin first; no release is created). A failed
#                                     release: exit 3 release_create_failed (the tag stays on origin; a re-run creates only the
#                                     release). JSON: ok, version, tag, release_commit, tag_local created|existing|fetched,
#                                     tag_remote pushed|existing, github_release created|existing|disabled|not_github,
#                                     release_url (when created), notes, warnings (as in status, only when this run created the
#                                     tag; [] when the tag existed), repo, tag_repo, store (with --store).
# Settings (openspec/specwright.yaml): release.enabled (default false), release.version_files (path or glob ->
# regex with one capture group; the first entry is the primary file), release.tag (v{version}),
# release.github_release (true), release.auto (false), pr.merge_method (rebase is refused with releases on).
# Exit: 0 done, 1 stop (the JSON has "ok": false, "error" and "message"), 2 usage, 3 a git or gh network call failed.
# Every network command (git ls-remote, fetch, push, every gh) runs under bounded.py (next to this script): 120 s (300 s for the
# paginated closed-PR read) and 32 MiB per command. A bound stops the command's whole process tree and ends the run as exit 3,
# "error": "deadline_exceeded" or "response_too_large", naming the command; nothing is retried. After a cut-off tag push publish
# reads origin's tag back (done only when it is the local tag object at the release commit; another commit is tag_conflict,
# another tag object tag_mismatch); after a cut-off `gh release create` it reads the release back (found = done). A failed
# read-back is exit 3 with "state": "unknown".
# Needs bash, git and Python 3.8+.
set -euo pipefail

py=
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1; then py=$c; break; fi
done
[ -n "$py" ] || { echo '{"ok":false,"error":"no_python","message":"release.sh needs python 3.8+"}'; exit 2; }

RELEASE_DIR=$(cd "$(dirname "$0")" && pwd -P)
if command -v cygpath >/dev/null 2>&1; then RELEASE_DIR=$(cygpath -m "$RELEASE_DIR"); fi
export RELEASE_DIR

exec "$py" -I -X utf8 - "$@" <<'PYSRC'
import bisect
import importlib.util
import glob as globmod
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ENV = dict(os.environ)
ENV.setdefault("GIT_TERMINAL_PROMPT", "0")


class Stop(Exception):
    def __init__(self, error, message="", code=1, **extra):
        super().__init__(message or error)
        self.error, self.message, self.code, self.extra = error, message or error, code, extra

    def obj(self):
        return {"ok": False, "error": self.error, "message": self.message, **self.extra}


def usage(msg):
    raise Stop("usage", msg, code=2)


def emit(obj, code=0):
    print(json.dumps(obj, ensure_ascii=False).replace("\u2028", "\\u2028").replace("\u2029", "\\u2029"))
    sys.exit(code)


class _Bounded:
    """The bounded runner (bounded.py next to this script), loaded by path on first use: -I keeps this script's directory off
    sys.path."""
    mod = None

    def __getattr__(self, name):
        if _Bounded.mod is None:
            sys.dont_write_bytecode = True  # no __pycache__ in an installed skill (#157)
            spec = importlib.util.spec_from_file_location("bounded", os.path.join(os.environ["RELEASE_DIR"], "bounded.py"))
            _Bounded.mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(_Bounded.mod)
        return getattr(_Bounded.mod, name)


bounded = _Bounded()


class Cut(Exception):
    """A network command stopped by a bound: .limit is deadline_exceeded or response_too_large, .call the command shown."""

    def __init__(self, limit, call):
        super().__init__(f"{limit}: {call}")
        self.limit, self.call = limit, call


def run(cmd, cwd=None, data=None, env=None):
    try:
        return subprocess.run(cmd, cwd=cwd, env=env or ENV, input=data, capture_output=True)
    except OSError as e:
        return subprocess.CompletedProcess(cmd, 127, b"", str(e).encode())


def net(cmd, shown, cwd=None, env=None, paged=False):
    """A network command under the deadline and the byte bound (bounded.py). Returns a CompletedProcess with bytes; raises Cut
    when a bound stopped it: never a partial answer. `shown` names the command in the message."""
    try:
        r = bounded.run_bounded(cmd, cwd=cwd, env=env or ENV, paged=paged)
    except OSError as e:
        return subprocess.CompletedProcess(cmd, 127, b"", str(e).encode())
    if r.limit:
        raise Cut(r.limit, shown)
    return subprocess.CompletedProcess(cmd, r.rc, r.stdout.encode("utf-8"), r.stderr.encode("utf-8"))


def cut_stop(c, what="a re-run of publish resumes", **extra):
    """The Stop for a bound: error is the limit, exit 3, naming the command."""
    return Stop(c.limit, f"{c.limit}: {c.call} was stopped by its bound; {what}", code=3, call=c.call, **extra)


def git(d, *args, data=None):
    return run(["git", *args], cwd=d, data=data)


def git_net(d, *args):
    """A git command that reaches origin (ls-remote, fetch, push)."""
    return net(["git", *args], "git " + " ".join(args[:2]), cwd=d)


def text_of(r):
    return r.stdout.decode("utf-8", "replace").strip()


def err_of(r):
    return r.stderr.decode("utf-8", "replace").strip()


class Flag(str):
    """An option that takes no value: its spec entry is Flag(<name>)."""


def parse_args(argv, spec):
    a, pos, i = {}, [], 0
    while i < len(argv):
        t = argv[i]
        if isinstance(spec.get(t), Flag):
            a[spec[t]] = True
            i += 1
        elif t in spec:
            if i + 1 >= len(argv):
                usage(f"{t} needs a value")
            a[spec[t]] = argv[i + 1]
            i += 2
        elif t.startswith("--"):
            usage(f"unknown option {t}")
        else:
            pos.append(t)
            i += 1
    return a, pos


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


# ---- settings ---------------------------------------------------------------------------------------------------
class Settings:
    def __init__(self, root):
        self.root = root
        p = os.path.join(root, "openspec", "specwright.yaml")
        try:
            with open(p, encoding="utf-8") as f:
                doc = parse_yaml(f.read())
        except FileNotFoundError:
            doc = {}
        rel = doc.get("release") if isinstance(doc.get("release"), dict) else {}
        pr = doc.get("pr") if isinstance(doc.get("pr"), dict) else {}
        self.enabled = rel.get("enabled") is True
        self.version_files = rel.get("version_files")
        self.tag = rel.get("tag") if isinstance(rel.get("tag"), str) and rel.get("tag") else "v{version}"
        self.github_release = rel.get("github_release") is not False
        self.auto = rel.get("auto") is True
        self.merge_method = str(pr.get("merge_method") or "").strip().lower()
        self.finish = doc.get("finish") if isinstance(doc.get("finish"), str) else None
        self.main_branch = doc.get("main_branch") if isinstance(doc.get("main_branch"), str) else None

    def gate(self, rebase=False):
        """Stop before any write unless releases are enabled (and, for bump and publish, not with rebase merges)."""
        if not self.enabled:
            raise Stop("release_disabled", "releases are off: set release.enabled: true in openspec/specwright.yaml")
        if "{version}" not in self.tag:
            raise Stop("bad_tag_template", f"release.tag '{self.tag}' has no {{version}} placeholder: every version would map "
                       "to one tag, and later versions would read as published; use a template such as v{version}")
        if rebase and self.merge_method == "rebase":
            raise Stop("rebase_merge", "release.enabled cannot be used with pr.merge_method: rebase: a rebase merge "
                       "leaves no single release commit; change pr.merge_method or set release.enabled to false")

    def entries(self):
        vf = self.version_files
        if not isinstance(vf, dict) or not vf:
            raise Stop("no_version_files", "release.version_files must map each path or glob to a regular expression")
        out = []
        for path, rx in vf.items():
            parts = str(path).replace("\\", "/").split("/")
            if os.path.isabs(str(path)) or parts[0] == "" or re.match(r"^[A-Za-z]:", str(path)) or ".." in parts:
                raise Stop("bad_version_files", f"release.version_files entry '{path}' must be a relative path inside the "
                           "repository (not absolute, no '..')")
            if not isinstance(rx, str) or not rx:
                raise Stop("bad_version_files", f"release.version_files entry '{path}' needs a regular expression")
            try:
                c = re.compile(rx, re.M)
            except re.error as e:
                raise Stop("bad_version_files", f"release.version_files entry '{path}': invalid pattern '{rx}': {e}")
            if c.groups != 1:
                raise Stop("bad_version_files", f"release.version_files entry '{path}': pattern '{rx}' must have exactly one "
                           f"capture group (has {c.groups})")
            out.append((str(path), rx, c))
        return out


# ---- version files: the working tree and a commit ---------------------------------------------------------------
def glob_regex(pat):
    """A git-path glob as a regex: `*` and `?` stop at `/`, `**/` spans directories."""
    out, i = "", 0
    while i < len(pat):
        c = pat[i]
        if pat.startswith("**/", i):
            out += "(?:.*/)?"
            i += 3
            continue
        if c == "*":
            out += "[^/]*"
        elif c == "?":
            out += "[^/]"
        elif c == "[" and pat.find("]", i + 2) > 0:
            j = pat.find("]", i + 2)
            body = pat[i + 1:j]
            neg = body[:1] in ("!", "^")
            out += "[" + ("^" if neg else "") + (body[1:] if neg else body).replace("\\", "\\\\") + "]"
            i = j
        else:
            out += re.escape(c)
        i += 1
    return re.compile(out + r"\Z")


def has_glob(p):
    return any(ch in p for ch in "*?[")


def inside(root, path):
    """True when the resolved `path` lies under the resolved `root` (another drive is outside)."""
    try:
        return os.path.commonpath([root, path]) == root
    except ValueError:
        return False


class WorkTree:
    label = "the working tree"

    def __init__(self, root):
        self.root = root

    def files(self, pattern):
        if has_glob(pattern):
            hits = globmod.glob(os.path.join(globmod.escape(self.root), pattern), recursive=True)
        else:
            hits = [os.path.join(self.root, pattern)]
        real = os.path.realpath(self.root)
        for h in hits:
            if not os.path.isfile(h):
                continue
            rel = os.path.relpath(h, self.root).replace(os.sep, "/")
            target = os.path.realpath(h)
            if not inside(real, target):
                raise Stop("bad_version_files", f"release.version_files entry '{pattern}' reaches {rel} through a symlink "
                           "outside the repository")
            if os.path.normcase(target) != os.path.normcase(os.path.join(real, os.path.normpath(rel))):
                raise Stop("bad_version_files", f"release.version_files entry '{pattern}' reaches {rel} through a symlink; "
                           "git stores a link as its text, so status and publish could not read the version at a commit. "
                           "List the file the link points to instead")
        return sorted({os.path.relpath(h, self.root).replace(os.sep, "/") for h in hits if os.path.isfile(h)})

    def read_all(self, paths):
        out = {}
        for p in paths:
            with open(os.path.join(self.root, p), "rb") as f:
                out[p] = f.read()
        return out


def cat_batch(root, specs):
    """Contents for `<commit>:<path>` specs through one `git cat-file --batch`; None for a missing object."""
    if not specs:
        return []
    r = git(root, "cat-file", "--batch", data=("\n".join(specs) + "\n").encode("utf-8", "surrogateescape"))
    if r.returncode != 0:
        raise Stop("git_failed", f"git cat-file failed: {err_of(r)}", code=3)
    buf, pos, out = r.stdout, 0, []
    for _ in specs:
        nl = buf.index(b"\n", pos)
        head = buf[pos:nl].decode("utf-8", "replace").split(" ")
        pos = nl + 1
        if head[-1] == "missing" or len(head) < 3:
            out.append(None)
            continue
        size = int(head[2])
        out.append(buf[pos:pos + size])
        pos += size + 1
    return out


class CommitTree:
    def __init__(self, root, commit):
        self.root, self.commit = root, commit
        self.label = f"commit {commit[:12]}"
        self._names = self._links = None

    def names(self):
        if self._names is None:
            r = git(self.root, "ls-tree", "-r", "-z", self.commit)
            if r.returncode != 0:
                raise Stop("git_failed", f"git ls-tree failed at {self.commit}: {err_of(r)}", code=3)
            self._names, self._links = [], set()
            for row in r.stdout.decode("utf-8", "surrogateescape").split("\0"):
                meta, tab, name = row.partition("\t")
                if tab:
                    self._names.append(name)
                    if meta.startswith("120000 "):
                        self._links.add(name)
        return self._names

    def files(self, pattern):
        if not has_glob(pattern):
            hits = [pattern] if pattern in self.names() else []
        else:
            rx = glob_regex(pattern)
            hits = sorted(n for n in self.names() if rx.match(n))
        for n in hits:
            if n in self._links:
                raise Stop("bad_version_files", f"release.version_files entry '{pattern}' matches {n}, a symlink at "
                           f"{self.label}; git stores a link as its text, so no version can be read there. List the file "
                           "the link points to instead")
        return hits

    def read_all(self, paths):
        paths = list(paths)
        got = cat_batch(self.root, [f"{self.commit}:{p}" for p in paths])
        return {p: (b if b is not None else b"") for p, b in zip(paths, got)}


def decode(raw):
    return raw.decode("utf-8", "surrogateescape")


class Hit:
    """One version match: the captured value and its span in the original text."""
    def __init__(self, value, start, end):
        self.value, self.span1 = value, (start, end)

    def group(self, _=1):
        return self.value

    def start(self, _=1):
        return self.span1[0]

    def end(self, _=1):
        return self.span1[1]

    def span(self, _=1):
        return self.span1


def find_versions(c, text):
    """Every match of `c` in `text` as Hit, reading CRLF line ends as LF so `$` matches before CRLF (a Windows
    checkout with core.autocrlf); the spans index the original text, so bump keeps the CRLF."""
    if "\r\n" not in text:
        return [Hit(m.group(1), m.start(1), m.end(1)) for m in c.finditer(text)]
    norm = text.replace("\r\n", "\n")
    crlf, k = [], 0  # positions in norm of the LFs that were CRLF
    for i, ch in enumerate(norm):
        if ch == "\n" and text[i + k] == "\r":
            crlf.append(i)
            k += 1
    orig = lambda pos: pos + bisect.bisect_left(crlf, pos)
    return [Hit(m.group(1), orig(m.start(1)), orig(m.end(1))) for m in c.finditer(norm)]


def read_versions(tree, entries):
    """Apply every entry to `tree`. Returns (matches, problems); matches: [(file, [re.Match], raw bytes)]."""
    problems, per_entry = [], []
    for path, rx, c in entries:
        fs = tree.files(path)
        if not fs:
            problems.append({"kind": "no_file", "entry": path,
                             "text": f"version_files entry '{path}' matches no file in {tree.label}"})
        per_entry.append((path, rx, c, fs))
    data = tree.read_all(sorted({f for _, _, _, fs in per_entry for f in fs}))
    matches = []
    for path, rx, c, fs in per_entry:
        for f in fs:
            ms = find_versions(c, decode(data[f]))
            matches.append((f, ms, data[f]))
            if len(ms) != 1:
                problems.append({"kind": "match_count", "file": f, "entry": path, "pattern": rx, "count": len(ms),
                                 "text": f"{f}: pattern '{rx}' (entry '{path}') matches {len(ms)} times, expected exactly 1"})
    return matches, problems


def invalid(tree, matches, problems):
    return Stop("version_files_invalid", f"version files are not readable in {tree.label}: " + "; ".join(p["text"] for p in problems),
                problems=[{k: v for k, v in p.items() if k != "text"} for p in problems],
                files=sorted({m[0] for m in matches}))


def disagree(tree, by, files):
    split = "; ".join(f"{v} in {', '.join(fs)}" for v, fs in by.items())
    return Stop("version_files_disagree", f"version files disagree in {tree.label}: {split}", versions=by, files=files)


def group(matches):
    by = {}
    for f, ms, _ in matches:
        by.setdefault(ms[0].group(1), []).append(f)
    return by


def agree(tree, entries):
    """Exactly one match per file and one shared version, else stop naming each offending file.
    Returns (version, files read)."""
    matches, problems = read_versions(tree, entries)
    if problems:
        raise invalid(tree, matches, problems)
    by, files = group(matches), sorted({m[0] for m in matches})
    if len(by) > 1:
        raise disagree(tree, by, files)
    return next(iter(by)), files


# ---- semver -----------------------------------------------------------------------------------------------------
def sv(v):
    m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", v)
    return tuple(int(x) for x in m.groups()) if m else None


# ---- subcommands ------------------------------------------------------------------------------------------------
class Unreadable:
    """A primary file that exists but does not read exactly one version (or the files disagree). It proves nothing on its
    own, but a version outside `versions` (what the file did match, possibly nothing) is still a change (D5)."""
    def __init__(self, versions):
        self.versions = versions


def primary_at(st, entries, commit):
    """The one version the primary file reads at `commit`; None when the file is absent there; an Unreadable carrying the
    versions it matched when a file matches other than once or the files disagree."""
    path, _, c = entries[0]
    tree = CommitTree(st.root, commit)
    blobs = tree.read_all(tree.files(path))
    if not blobs:
        return None
    vals, once = set(), True
    for b in blobs.values():  # exactly one match per file, as read_versions requires; the files must then agree
        ms = find_versions(c, decode(b))
        once = once and len(ms) == 1
        vals.update(m.group(1) for m in ms)
    return next(iter(vals)) if once and len(vals) == 1 else Unreadable(vals)


def judged_parent(st, entries, commit, ref):
    """D5: the version `commit` is judged against: its parent's, or, while that is unreadable and not on `ref`, the version
    of the nearest first-parent ancestor that is readable or on `ref` (PR #108 review, round 5)."""
    at = f"{commit}^"
    parent = primary_at(st, entries, at) if ref_exists(st.root, at) else None
    while isinstance(parent, Unreadable):
        sha = text_of(git(st.root, "rev-parse", at))
        if git(st.root, "merge-base", "--is-ancestor", sha, ref).returncode == 0 or not ref_exists(st.root, f"{sha}^"):
            break
        at = f"{sha}^"
        parent = primary_at(st, entries, at)
    return parent


def own_bump(st, entries, commits, ref):
    """D3/D5: whether the newest of `commits` (newest first) that changed the primary version raised it. An edit that keeps
    the version (a manifest's dependencies) is skipped, and a bump reverted later on the branch is no bump. Each commit is
    judged against judged_parent: an unreadable parent on the branch is looked past, so a bump made through an unreadable
    version counts and a stray line added and then removed does not. D9: a commit whose immediate parent is unreadable and on
    the branch is a change when it matched a version that parent did not; it is a bump when each version it matched is
    greater than the version it is judged against (than each semver of it, when that is unreadable too), else no bump, and
    the walk stops. Any other commit: one whose own version is unreadable is no change
    when that version is among those it matched (or it is unreadable too), else a bump only when it matched at least one
    version and every one is greater. One judged against an unreadable version (on `ref`) is no change when its version is
    the greatest semver among those matched, no bump when it is a lower one of them, else a bump when greater than every
    semver among them (or none)."""
    for c in commits:
        mine = primary_at(st, entries, c)
        parent = judged_parent(st, entries, c, ref)
        if ref_exists(st.root, f"{c}^"):
            direct = primary_at(st, entries, f"{c}^")
            if isinstance(direct, Unreadable) and git(st.root, "merge-base", "--is-ancestor", text_of(git(st.root, "rev-parse", f"{c}^")), ref).returncode != 0:
                matched = mine.versions if isinstance(mine, Unreadable) else ({mine} if mine is not None else set())
                if matched - direct.versions:  # D9: a version its unreadable parent on the branch did not match is a change
                    seen = [sv(v) for v in parent.versions if sv(v)] if isinstance(parent, Unreadable) else (
                        [sv(parent)] if parent is not None and sv(parent) else [])
                    return all(sv(v) and all(sv(v) > s for s in seen) for v in matched)
        if isinstance(mine, Unreadable):
            if isinstance(parent, Unreadable) or (parent is not None and parent in mine.versions):
                continue
            if not mine.versions:
                return False
            if parent is None or not sv(parent):
                return True
            return all(sv(v) and sv(v) > sv(parent) for v in mine.versions)
        if mine == parent:
            continue
        if mine is None:
            return False
        if isinstance(parent, Unreadable):
            seen = [sv(v) for v in parent.versions if sv(v)]
            if mine in parent.versions:
                if sv(mine) and seen and sv(mine) < max(seen):
                    return False  # it kept a lower one of its parent's versions: the higher one, a bump, is dropped
                continue  # it kept the highest of its parent's versions, which is on ref: no change
            return not seen or not sv(mine) or all(sv(mine) > s for s in seen)
        return parent is None or not (sv(mine) and sv(parent)) or sv(mine) > sv(parent)
    return False


def check_ahead_of(st, entries, ref, version, tip="HEAD"):
    """D3/D5: a branch that bumped must be greater than `ref`'s version. An unreadable version at `ref` passes, as an absent
    one does; an unreadable merge base counts as bumped only when the branch's version is not among those it matched."""
    if not ref_exists(st.root, ref):
        raise Stop("no_main", f"main ref '{ref}' does not exist")
    theirs = primary_at(st, entries, ref)
    if theirs is None or isinstance(theirs, Unreadable):
        return
    base = git(st.root, "merge-base", tip, ref)
    base_version = primary_at(st, entries, text_of(base)) if base.returncode == 0 and text_of(base) else None
    bumped = version not in base_version.versions if isinstance(base_version, Unreadable) else base_version != version
    if not bumped:
        r = git(st.root, "log", "--no-merges", "--topo-order", "--format=%H", f"{ref}..{tip}", "--",
                f":(glob){entries[0][0]}" if has_glob(entries[0][0]) else f":(literal){entries[0][0]}")
        if r.returncode != 0:
            raise Stop("git_failed", f"git log failed: {err_of(r)}", code=3)
        bumped = own_bump(st, entries, text_of(r).split(), ref)
    if bumped and not (sv(version) and sv(theirs) and sv(version) > sv(theirs)):
        raise Stop("version_not_ahead_of_main", f"this branch bumped to {version}, which is not greater than {ref}'s {theirs}: "
                   f"another change reached {ref} first. Rerun bump --to with a version greater than {theirs}",
                   version=version, main_version=theirs, main=ref)


PR_PAIR = os.path.join(os.path.dirname(os.environ["RELEASE_DIR"]), "..", "specwright-pr", "scripts", "pr-pair.sh")


def code_backend(st):
    """The code repo's VCS backend, read the way vcs.sh reads it (`pr-pair.sh vcs --code <repo>`). Settings that do not
    mention gitbutler cannot select it, so that case skips the process; settings that mention it with pr-pair.sh missing stop
    rather than guess. A settings error stops, as it does for vcs.sh."""
    try:
        with open(os.path.join(st.root, "openspec", "specwright.yaml"), encoding="utf-8", errors="replace") as f:
            if "gitbutler" not in f.read():
                return "git"
    except OSError:
        return "git"
    script = os.path.normpath(PR_PAIR)
    if not os.path.isfile(script):  # the settings may select gitbutler: fail closed rather than read HEAD
        raise Stop("vcs_error", f"{script} is missing, so the code repo's backend cannot be read")
    r = run([shutil.which("bash") or "bash", script, "vcs", "--code", st.root], cwd=st.root)
    try:
        doc = json.loads(r.stdout.decode("utf-8", "replace"))
    except ValueError:
        raise Stop("vcs_error", f"{script} vcs printed no JSON: {err_of(r)}")
    if not doc.get("ok"):
        raise Stop(str(doc.get("error") or "vcs_error"), str(doc.get("message") or "pr-pair.sh vcs failed"))
    return str(doc.get("code") or "git")


def cmd_check(st, a):
    branch = a.get("branch")
    # --main compares the change branch with main: on GitButler HEAD is the workspace commit, so it needs the branch.
    # A plain check (the bump task's verification) reads the working tree, as on Git.
    if not branch and a.get("main") and code_backend(st) == "gitbutler":
        usage("vcs: gitbutler needs --branch <prefix>/<change-name> with --main: HEAD is the workspace commit, not the change branch")
    entries = st.entries()
    tip = "HEAD"
    if branch:  # resolved now, on every call: never a SHA from the caller, never HEAD
        r = git(st.root, "rev-parse", "--verify", "--quiet", f"refs/heads/{branch}^{{commit}}")
        if r.returncode != 0 or not text_of(r):
            raise Stop("branch_not_found", f"{st.root} has no local branch {branch}")
        tip = text_of(r)
    version, files = agree(CommitTree(st.root, tip) if branch else WorkTree(st.root), entries)
    if a.get("main"):
        check_ahead_of(st, entries, a["main"], version, tip)
    return {"ok": True, "version": version, "files": files}


def cmd_bump(st, a):
    st.gate(rebase=True)
    target = a.get("to")
    if not target:
        usage("bump needs --to MAJOR.MINOR.PATCH")
    if not re.fullmatch(r"\d+\.\d+\.\d+", target):
        raise Stop("bad_target", f"the target version must be MAJOR.MINOR.PATCH (digits only, e.g. 0.5.0), got '{target}'")
    tree = WorkTree(st.root)
    matches, problems = read_versions(tree, st.entries())
    if problems:
        raise invalid(tree, matches, problems)
    by, files = group(matches), sorted({m[0] for m in matches})
    present = sorted(by, key=lambda v: (sv(v) is None, sv(v) or (0, 0, 0), v))
    if len(present) == 1:
        current = present[0]
        if sv(current) is None:
            raise Stop("bad_current", f"the current version '{current}' is not MAJOR.MINOR.PATCH, so {target} cannot be compared")
        if sv(target) <= sv(current):
            raise Stop("target_not_greater", f"the target {target} must be greater than the current version {current}")
    elif len(present) == 2 and present[1] == target and sv(present[0]) is not None and sv(present[0]) < sv(target):
        current = present[0]  # an interrupted bump to this same target: complete it (D7)
    else:
        raise disagree(tree, by, files)
    # every replacement in memory first, then one temp file + rename per file
    # entries that match the same file each contribute their capture: compose them, so none is lost
    spans, raws = {}, {}
    for f, ms, raw in matches:
        m = ms[0]
        raws[f] = raw
        if m.group(1) != target:
            spans.setdefault(f, set()).add(m.span(1))
    plan = {}
    for f, ss in spans.items():
        text, end = decode(raws[f]), None
        for a, b in sorted(ss, reverse=True):
            if end is not None and b > end:
                raise Stop("bad_version_files", f"{f}: two version_files entries capture overlapping text; make their "
                           "patterns capture the same version or separate ones", file=f)
            text, end = text[:a] + target + text[b:], a
        plan[f] = text.encode("utf-8", "surrogateescape")
    changed, pending = [], sorted(plan)
    for f in sorted(plan):
        full = os.path.join(st.root, f)
        tmp = None
        try:
            fd, tmp = tempfile.mkstemp(prefix=".release-", dir=os.path.dirname(full))
            with os.fdopen(fd, "wb") as out:
                out.write(plan[f])
            try:
                os.chmod(tmp, os.stat(full).st_mode & 0o7777)
            except OSError:
                pass
            os.replace(tmp, full)
            tmp = None
            changed.append(f)
            pending.remove(f)
        except OSError as e:
            raise Stop("write_failed", f"writing {f} failed: {e}; written: {', '.join(changed) or 'none'}; not written: "
                       f"{', '.join(pending)}. Rerun bump --to {target} to complete it", written=changed, pending=pending)
        finally:
            if tmp and os.path.exists(tmp):
                try:
                    os.remove(tmp)
                except OSError:
                    pass
    return {"ok": True, "from": current, "to": target, "changed": changed, "files": files}


def detect_main(st):
    names = [st.main_branch] if st.main_branch else ["main", "master"]
    for n in names:
        if git(st.root, "show-ref", "--verify", "--quiet", f"refs/heads/{n}").returncode == 0:
            return n
    return names[0]


def ref_exists(root, ref):
    return git(root, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}").returncode == 0


def primary_history(st, entries, ref):
    """The commits on `ref`'s first-parent history that touch the primary file, oldest first, as [(sha, value)]. The value is
    the one version the primary file reads there (every match of every file the entry names), None when it reads none or
    several. One `git log` and one `cat-file --batch`; for a glob the log's first-parent name-status tracks which matching
    files exist at each commit."""
    path, _, c = entries[0]
    spec = f":(glob){path}" if has_glob(path) else f":(literal){path}"
    r = git(st.root, "log", "--first-parent", "--format=%H", "--reverse", ref, "--", spec)
    if r.returncode != 0:
        raise Stop("git_failed", f"git log failed: {err_of(r)}", code=3)
    shas = text_of(r).split()
    texts = []
    if has_glob(path):
        # -m with --first-parent diffs a merge against its first parent on any git (the diff-merges option needs 2.31); the -c
        # pins that on 2.31+, where -m follows log.diffMerges (older git ignores the key)
        r = git(st.root, "-c", "log.diffMerges=first-parent", "log", "-z", "--first-parent", "-m", "--no-renames",
                "--name-status", "--format=%x01%H", "--reverse", ref, "--", spec)
        if r.returncode != 0:
            raise Stop("git_failed", f"git log failed: {err_of(r)}", code=3)
        rx, present, per_sha, sha = glob_regex(path), set(), {}, None
        tokens = iter(r.stdout.decode("utf-8", "surrogateescape").split("\0"))
        for tok in tokens:
            if tok.startswith("\x01"):
                if sha is not None:
                    per_sha[sha] = sorted(present)
                sha = tok[1:]
            elif tok.strip():
                name = next(tokens, "")
                if rx.match(name):
                    (present.discard if tok.strip() == "D" else present.add)(name)
        if sha is not None:
            per_sha[sha] = sorted(present)
        files = [per_sha.get(s, []) for s in shas]
        got = iter(cat_batch(st.root, [f"{s}:{f}" for s, fs in zip(shas, files) for f in fs]))
        texts = [[decode(b) for b in (next(got) for _ in fs) if b is not None] for fs in files]
    else:
        texts = [[decode(b)] if b is not None else [] for b in cat_batch(st.root, [f"{s}:{path}" for s in shas])]
    out = []
    for sha, blobs in zip(shas, texts):
        vals = {m.group(1) for t in blobs for m in find_versions(c, t)}
        out.append((sha, next(iter(vals)) if len(vals) == 1 else None))
    return out


class Releases:
    """What the primary file's first-parent history says: each distinct value's first appearance (its release commit, D3)
    and the value that preceded it."""
    def __init__(self, hist):
        self.hist = hist
        self.first = {}   # version -> sha of its first appearance
        self.order = []   # versions by first appearance
        self.before = {}  # version -> the value read just before its first appearance (None for the first)
        last = None
        for sha, v in hist:
            if v is None:
                continue
            if v not in self.first:
                self.first[v] = sha
                self.order.append(v)
                self.before[v] = last
            last = v
        self.current = last


def release_commit(st, entries, ref, version):
    """First commit on ref's first-parent history whose primary file reads `version`, or None."""
    return Releases(primary_history(st, entries, ref)).first.get(version)


def local_tags(st):
    r = git(st.root, "tag", "-l")
    return set(text_of(r).split()) if r.returncode == 0 else set()


def published_tags(st):
    """The tags that count as published: the ones on origin, or with no origin remote the local ones. A local tag whose push
    failed is not published, so `untagged` still lists it and publish of a newer version waits for it. Exit 3 when origin
    cannot be read. Read once per run: publish asks twice (the older-untagged gate and the notes range)."""
    if origin_url(st) is None:
        return local_tags(st)
    if getattr(st, "_published", None) is not None:
        return st._published
    r = git_net(st.root, "ls-remote", "--tags", "--refs", "origin")
    if r.returncode != 0:
        shown = "git ls-remote --tags --refs origin"
        raise Stop("remote_tags_unreadable", f"{shown} failed: {err_of(r) or 'exit ' + str(r.returncode)}; no tag was written",
                   code=3, call=shown)
    st._published = {name[len("refs/tags/"):] for name in (l.partition("\t")[2] for l in text_of(r).splitlines())
                     if name.startswith("refs/tags/")}
    return st._published


def tag_for(st, version):
    return st.tag.replace("{version}", version)


def previous_release(st, rel, version, tags):
    """(version, sha, basis) of the previous release for `version`, or None. D4: the highest lower version with a tag, else
    the value read just before `version` first appeared."""
    me = sv(version)
    lower = [v for v in rel.order if me and sv(v) and sv(v) < me and tag_for(st, v) in tags]
    if lower:
        v = max(lower, key=sv)
        return v, rel.first[v], "tag"
    b = rel.before.get(version)
    return (b, rel.first[b], "history") if b is not None else None


def untagged_since_latest(st, rel, tags, local=frozenset()):
    """Versions after the latest tagged one (highest semver with a tag) in first-appearance order that have no tag; with no tag
    at all, only the current version. Every version whose tag is in `local` but not in `tags` (a tag push that failed) is
    listed too, whatever the anchor. Returns (versions, latest tagged version or None)."""
    latest = max((v for v in rel.order if sv(v) and tag_for(st, v) in tags), key=sv, default=None)
    if latest is None:
        want = {rel.current} if rel.current is not None else set()
    else:
        want = {v for v in rel.order[rel.order.index(latest) + 1:] if sv(v)}
    want |= {v for v in rel.order if sv(v) and tag_for(st, v) in local}
    return [v for v in rel.order if v in want and tag_for(st, v) not in tags], latest


SUBJECT_PR = re.compile(r"\(#(\d+)\)\s*$|^Merge pull request #(\d+)\b")


def subject_pr(subject):
    m = SUBJECT_PR.search(subject)
    return int(m.group(1) or m.group(2)) if m else None


def require_release_shape(st, sha):
    """D3: the release commit must be a merge commit or a squash commit (subject ends `(#n)`); a replayed bump is refused."""
    r = git(st.root, "log", "-1", "--format=%P%x00%s", sha)
    if r.returncode != 0:
        raise Stop("git_failed", f"git log failed at {sha}: {err_of(r)}", code=3)
    parents, _, subject = r.stdout.decode("utf-8", "replace").rstrip("\n").partition("\0")
    if len(parents.split()) >= 2 or re.search(r"\(#\d+\)\s*$", subject):
        return
    raise Stop("rebase_release_commit", f"the release commit {sha[:12]} ('{subject}') is neither a merge commit nor a commit whose "
               "subject ends in (#<n>): the release commit must be a merge or squash commit (a rebase merge or a direct push "
               "replays the bump as its own commit)", commit=sha)


# ---- notes ------------------------------------------------------------------------------------------------------
MAX_PROPOSAL = 64 * 1024
MAX_WHY = 300
MAX_LISTED = 100
WHY_HEAD = re.compile(r"^#{2}[ \t]+Why[ \t]*$", re.I | re.M)
ABBREV = re.compile(r"(?:^|[\s(])(?:e\.g|i\.e|vs|cf)$", re.I)


def first_sentence(proposal):
    """The first sentence of the first paragraph under `## Why`, or None. Rules: the paragraph runs from the first non-blank
    line after the heading to a blank line, a heading, or (after a list item's first line) the next list marker; a leading
    list marker (`-`, `*`, `+`, `1.`) is dropped; whitespace collapses to single spaces; the sentence ends at the first
    `.`, `!` or `?` that is followed by whitespace or the end, is outside a backtick code span, and does not close
    `e.g`, `i.e`, `vs` or `cf`; with no end the whole paragraph is the sentence. Over 300 characters it is cut to 299
    plus an ellipsis."""
    m = WHY_HEAD.search(proposal)
    if not m:
        return None
    lines, para, marker = proposal[m.end():].splitlines(), [], re.compile(r"^\s*(?:[-*+]|\d+[.)])\s+")
    for line in lines:
        if not line.strip():
            if para:
                break
            continue
        if line.lstrip().startswith("#"):
            break
        if not para:
            line = marker.sub("", line, count=1)
        elif marker.match(line):
            break
        para.append(line.strip())
    text = re.sub(r"\s+", " ", " ".join(para)).strip()
    if not text:
        return None
    end, i, n = len(text), 0, len(text)
    while i < n:
        ch = text[i]
        if ch == "`":
            j = i
            while j < n and text[j] == "`":
                j += 1
            close = text.find(text[i:j], j)
            i = (close + (j - i)) if close >= 0 else j
            continue
        if ch in ".!?" and (i + 1 == n or text[i + 1].isspace()) and not (ch == "." and ABBREV.search(text[:i])):
            end = i + 1
            break
        i += 1
    s = text[:end]
    return s if len(s) <= MAX_WHY else s[:MAX_WHY - 1] + "…"


MAX_SUMMARY = 600
MAX_ITEM = 500
MAX_ITEMS = 150
MAX_PARSED = 1000
HEADINGS = ("added", "changed", "fixed", "removed")
NOTES_HEAD = re.compile(r"^##[ \t]+Release Notes[ \t]*$", re.I)
SUB_HEAD = re.compile(r"^###(?!#)[ \t]*(.*?)[ \t]*$")
ITEM_START = re.compile(r"^[-*+][ \t]+(.*)$")
CODE_SPAN = re.compile(r"(?<!`)(`+)(?!`)(.+?)(?<!`)\1(?!`)", re.S)
REFERENCE = re.compile(r"#\d+(?!\w)")


def parse_release_notes(text):
    """The `## Release Notes` section of a proposal: None when there is no such heading, else {"summary", "items": {heading:
    [(text, line)]}, "errors": [(line, message)]}, valid when errors is empty. HTML comments go first (their newlines stay, so
    lines still count the file's). The section runs to the next `##` heading or the end. The summary is the text before the first
    `###`, whitespace collapsed, at most 600 characters. The headings are Added, Changed, Fixed and Removed (any case), each at
    most once, followed only by items: a line starting `-`, `*` or `+` and a space, joined with the indented lines after it, at
    most 500 characters collapsed. Every error is collected with its line."""
    text = re.sub(r"<!--.*?-->", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    lines = [l.rstrip("\r") for l in text.split("\n")]
    start = next((i for i, l in enumerate(lines) if NOTES_HEAD.match(l)), None)
    if start is None:
        return None
    end = next((i for i in range(start + 1, len(lines)) if re.match(r"##(?!#)", lines[i])), len(lines))
    errors, items, summary, seen = [], {}, [], set()
    cur, item = None, None  # the heading being read (None under an invalid one), the open item [parts, line]

    def close():
        nonlocal item
        if item is not None and cur is not None:
            t = re.sub(r"\s+", " ", " ".join(item[0])).strip()
            if not t:
                errors.append((item[1], "empty list item"))
            elif len(t) > MAX_ITEM:
                errors.append((item[1], f"item is {len(t)} characters, over the {MAX_ITEM} limit"))
            else:
                items[cur].append((t, item[1]))
        item = None

    for i in range(start + 1, end):
        line, n = lines[i], i + 1
        h = SUB_HEAD.match(line)
        if h:
            close()
            name = h.group(1)
            if name.lower() not in HEADINGS:
                errors.append((n, f"unknown heading '{name}' (use Added, Changed, Fixed or Removed)"))
                cur = None
            elif name.lower() in seen:
                errors.append((n, f"heading '{name}' appears twice"))
                cur = None
            else:
                cur = name.lower()
                items[cur] = []
            seen.add(name.lower())
            continue
        if not line.strip():
            continue
        if not seen:
            summary.append(line.strip())
            continue
        if cur is None:
            continue  # under an invalid heading: that heading's error covers it
        m = ITEM_START.match(line)
        if m:
            close()
            item = [[m.group(1)], n]
        elif line[0] in " \t" and item is not None:
            item[0].append(line.strip())
        else:
            close()
            errors.append((n, f"line is neither a list item nor an indented continuation: {line.strip()[:60]}"))
    close()
    body_errors = len(errors)
    summary = re.sub(r"\s+", " ", " ".join(summary)).strip()
    if not summary:
        errors.append((start + 1, "the summary is missing (text before the first ### heading)"))
    elif len(summary) > MAX_SUMMARY:
        errors.append((start + 1, f"summary is {len(summary)} characters, over the {MAX_SUMMARY} limit"))
    if not any(items.values()) and not body_errors:
        errors.append((start + 1, "no list item under Added, Changed, Fixed or Removed"))
    errors.sort(key=lambda e: e[0])
    return {"summary": summary, "items": {k: v for k, v in items.items() if v}, "errors": errors}


def item_line(text, pr):
    """The notes line of one item: ` (#<pr>)` appended when the item names no issue or PR outside a code span and `pr` is known."""
    if pr is not None and not REFERENCE.search(CODE_SPAN.sub(" ", text)):
        return f"- {text} (#{pr})"
    return f"- {text}"


def cmd_notes(a):
    """`notes --proposal <file>`: parse one proposal's section. No git, no network, no opt-in (design D5)."""
    path = a.get("proposal")
    if not path:
        usage("notes needs --proposal <file>")
    if not os.path.isfile(path):
        usage(f"--proposal file not found: {path}")
    limit = f"{MAX_PROPOSAL // 1024} KB"
    size = os.path.getsize(path)
    if size > MAX_PROPOSAL:
        raise Stop("release_notes_invalid", f"{path} is {size} bytes, over the {limit} limit",
                   errors=[{"line": None, "message": f"the proposal is over the {limit} limit"}])
    with open(path, "rb") as f:
        parsed = parse_release_notes(f.read().decode("utf-8", "replace"))
    if parsed is None:
        raise Stop("no_release_notes", f"{path} has no '## Release Notes' section")
    if parsed["errors"]:
        errs = [{"line": n, "message": m} for n, m in parsed["errors"]]
        raise Stop("release_notes_invalid", f"{path}: " + "; ".join(f"line {e['line']}: {e['message']}" for e in errs), errors=errs)
    return {"ok": True, "summary": parsed["summary"],
            "items": {h: [{"text": t, "line": item_line(t, "<pr>")} for t, _ in parsed["items"][h]] for h in HEADINGS if h in parsed["items"]}}


def blob_sizes(root, specs):
    """Byte sizes for `<commit>:<path>` specs through one `git cat-file --batch-check`; None for a missing object."""
    if not specs:
        return []
    r = git(root, "cat-file", "--batch-check", data=("\n".join(specs) + "\n").encode("utf-8", "surrogateescape"))
    if r.returncode != 0:
        raise Stop("git_failed", f"git cat-file failed: {err_of(r)}", code=3)
    out = []
    for line in r.stdout.decode("utf-8", "replace").splitlines()[:len(specs)]:
        head = line.split(" ")
        out.append(None if head[-1] == "missing" or len(head) < 3 else int(head[2]))
    return out


def read_sections(root, commit, prefix, rows, version):
    """{dirname: {"section", "warning", "bump"}} for the last MAX_PARSED archive directories of `rows`. One size pass over every
    proposal.md and tasks.md, then one read of the blobs within MAX_PROPOSAL. A proposal over the bound is never read for its
    section (a warning); a tasks.md over it counts as having no bump task. `section` is the parsed section when valid, `bump`
    is True when tasks.md has a ticked `release.sh bump --to <version>` task."""
    dirs = [d for d, _ in rows[-MAX_PARSED:]]
    base = f"{commit}:{prefix}/changes/archive/"
    specs = [f"{base}{d}/{f}" for d in dirs for f in ("proposal.md", "tasks.md")]
    sizes = blob_sizes(root, specs)
    want = [s for s, z in zip(specs, sizes) if z is not None and z <= MAX_PROPOSAL]
    blobs = dict(zip(want, cat_batch(root, want)))
    bump = re.compile(r"^[ \t]*[-*+][ \t]+\[[ \t]*x[ \t]*\][ \t]+.*release\.sh[ \t]+bump[ \t]+--to[ \t]+" + re.escape(version) + r"(?!\.?\d)",
                      re.I | re.M)
    out = {}
    for i, d in enumerate(dirs):
        (ps, ts), (psz, tsz) = specs[2 * i:2 * i + 2], sizes[2 * i:2 * i + 2]
        row = {"section": None, "warning": None, "bump": False}
        if psz is not None and psz > MAX_PROPOSAL:
            row["warning"] = f"the proposal is {psz} bytes, over the {MAX_PROPOSAL // 1024} KB limit"
        elif psz is not None and blobs.get(ps) is not None:
            parsed = parse_release_notes(decode(blobs[ps]))
            if parsed and parsed["errors"]:
                n, msg = parsed["errors"][0]
                row["warning"] = f"line {n}: {msg}"
            elif parsed:
                row["section"] = parsed
        if tsz is not None and tsz <= MAX_PROPOSAL and blobs.get(ts) is not None:
            row["bump"] = bool(bump.search(decode(blobs[ts])))
        out[d] = row
    return out


def archive_dirs(root, commit, prefix):
    """Names of the archive directories under `<prefix>/changes/archive/` at `commit`."""
    base = f"{prefix}/changes/archive/"
    r = git(root, "-c", "core.quotepath=off", "ls-tree", "-d", "--name-only", commit, base)
    if r.returncode != 0:
        raise Stop("git_failed", f"git ls-tree failed at {commit}: {err_of(r)}", code=3)
    return {l[len(base):] for l in text_of(r).splitlines() if l.startswith(base)}


DATE_PREFIX = re.compile(r"^\d{4}-\d{2}-\d{2}-")


def change_name(dirname):
    return DATE_PREFIX.sub("", dirname, count=1)


def whys(root, commit, prefix, dirs):
    """First Why sentence per archive directory, read from `commit` (at most 64 KB of each proposal)."""
    got = cat_batch(root, [f"{commit}:{prefix}/changes/archive/{d}/proposal.md" for d in dirs])
    return {d: (first_sentence(decode(b[:MAX_PROPOSAL])) if b is not None else None) for d, b in zip(dirs, got)}


def range_commits(st, prev, rel):
    """[(sha, subject)] of the first-parent commits in (prev, rel], oldest first."""
    spec = f"{prev}..{rel}" if prev else rel
    r = git(st.root, "log", "--first-parent", "--reverse", "--format=%H%x02%s", spec)
    if r.returncode != 0:
        raise Stop("git_failed", f"git log failed: {err_of(r)}", code=3)
    return [tuple(l.split("\x02", 1)) for l in r.stdout.decode("utf-8", "replace").splitlines() if "\x02" in l]


def archive_adders(st, prev, rel, prefix):
    """{archive dir: (sha, subject)} of the first first-parent commit in (prev, rel] that adds a file under the archive."""
    spec = f"{prev}..{rel}" if prev else rel
    r = git(st.root, "-c", "core.quotepath=off", "log", "--first-parent", "-m", "--no-renames", "--name-only", "--diff-filter=A",
            "--reverse", "--format=%x01%H%x02%s", spec, "--", f":(literal){prefix}/changes/archive")
    if r.returncode != 0:
        raise Stop("git_failed", f"git log failed: {err_of(r)}", code=3)
    out, base = {}, f"{prefix}/changes/archive/"
    for chunk in r.stdout.decode("utf-8", "replace").split("\x01")[1:]:
        head, *files = chunk.splitlines()
        sha, _, subject = head.partition("\x02")
        for f in files:
            if f.startswith(base) and "/" in f[len(base):]:
                out.setdefault(f[len(base):].split("/", 1)[0], (sha, subject))
    return out


def local_changes(st, prev, rel, rng):
    """D4: archive directories present at `rel` and absent at `prev`, oldest first by the commit that first holds them.
    Returns ([(dirname, pr)], commit the proposals are read at, archive prefix)."""
    prefix = "openspec"
    new = archive_dirs(st.root, rel, prefix) - (archive_dirs(st.root, prev, prefix) if prev else set())
    adders = archive_adders(st, prev, rel, prefix)
    pos = {sha: i for i, (sha, _) in enumerate(rng)}
    subjects = dict(rng)
    rows = []
    for d in new:
        sha = adders.get(d, (rel, ""))[0]
        rows.append((pos.get(sha, len(pos)), d, subject_pr(subjects.get(sha, ""))))
    rows.sort(key=lambda r: (r[0], r[1]))
    entries = [(d, pr) for _, d, pr in rows]
    return entries, rel, prefix


def store_setup(a):
    d = a["store"]
    r = git(d, "rev-parse", "--show-toplevel")
    if r.returncode != 0 or not text_of(r):
        raise Stop("store_not_a_repo", f"--store {d} is not inside a git work tree")
    top = os.path.normpath(text_of(r))
    sst = Settings(top)
    ref = a.get("store-main")
    if not ref:
        names = [sst.main_branch] if sst.main_branch else ["main", "master"]
        for n in names:
            if ref_exists(top, f"refs/remotes/origin/{n}"):
                ref = f"origin/{n}"
                break
            if ref_exists(top, f"refs/heads/{n}"):
                ref = n
                break
    if not ref or not ref_exists(top, ref):
        raise Stop("no_store_main", f"the store's main ref '{ref or 'main'}' does not exist in {top}")
    return top, ref, a.get("store-prefix") or "openspec"


PLANNING_ONLY = re.compile(r"^code_changes:\s*none\s*$", re.M)

GH_URL = re.compile(
    r"^(?:(?:https?|ssh|git)://(?:[^@/\s]+@)?(?:ssh\.)?github\.com\.?(?::\d+)?/|(?:[^@/\s]+@)?(?:ssh\.)?github\.com\.?:)"
    r"([^/\s]+)/([^/\s]+?)(?:\.git)?/?$", re.I)
BASH = os.environ.get("RELEASE_BASH") or shutil.which("bash")


def code_slug(st):
    slug = release_slug(st)  # the same repository the release names, so a shorthand origin rewritten to github.com works
    if not slug:
        raise Stop("no_github_origin", "store-backed notes in pr mode need origin to be a github.com repository (to find the "
                   "merged code PRs)")
    return slug


def gh_run(st, *args, paged=False):
    """`gh <args>` in the code repo with GH_REPO unset (the repo is always named by the call), under the network bounds. Through
    bash, so a shell-script gh (a shim) runs on Windows too. Raises Cut when a bound stopped it."""
    env = {k: v for k, v in ENV.items() if k != "GH_REPO"}
    return net([BASH, "-c", 'exec gh "$@"', "gh", *args] if BASH else ["gh", *args], "gh " + " ".join(args[:2]), cwd=st.root,
               env=env, paged=paged)


def merged_pulls(st, ref, base=None):
    """One paginated gh call for the closed PRs into the code main; exit 3 when it fails. `base` (--base) names the GitHub
    base branch when given; else it is taken from an origin/<name> ref (a bare commit, as a jj run reads, names no branch)."""
    slug = code_slug(st)
    branch = base or (ref[len("origin/"):] if ref.startswith("origin/") else ref)
    url = f"repos/{slug}/pulls?state=closed&base={branch}&per_page=100"
    r = gh_run(st, "api", "--paginate", url, paged=True)
    shown = f"gh api --paginate {url}"
    if r.returncode != 0:
        raise Stop("pr_discovery_failed", f"{shown} failed: {err_of(r) or 'exit ' + str(r.returncode)}", code=3, call=shown)
    text, pos, pulls, dec = r.stdout.decode("utf-8", "replace"), 0, [], json.JSONDecoder()
    try:
        while True:
            while pos < len(text) and text[pos].isspace():
                pos += 1
            if pos >= len(text):
                break
            page, pos = dec.raw_decode(text, pos)
            if not isinstance(page, list):
                raise ValueError("not a list")
            pulls.extend(page)
    except ValueError as e:
        raise Stop("pr_discovery_failed", f"{shown} returned unreadable output: {e}", code=3, call=shown)
    return slug, pulls


def is_ancestor(root, sha, tip):
    return git(root, "merge-base", "--is-ancestor", sha, tip).returncode == 0


BRANCH_PREFIXES = {"feat": ("add", "feat", "feature", "implement", "introduce"),
                   "bugfix": ("fix", "bugfix", "hotfix", "patch", "resolve"),
                   "refactor": ("refactor", "restructure", "cleanup"), "docs": ("docs", "doc", "document"),
                   "chore": ("chore", "bump", "deps", "ci", "build")}


def branch_prefix(change):
    """The change branch's prefix from the name's first token, as specwright-branch derives it (anything else: feat)."""
    first = change.split("-", 1)[0].lower()
    return next((p for p, words in BRANCH_PREFIXES.items() if first in words), "feat")


def store_changes(st, a, prev, rel, rng):
    """D5: archive directories on the store's main (not planning-only) whose code-merge proof lies in the code range.
    Returns (entries [(dirname, pr)], store commit, prefix, info)."""
    top, sref, prefix = store_setup(a)
    dirs = sorted(archive_dirs(top, sref, prefix))
    marks = cat_batch(top, [f"{sref}:{prefix}/changes/archive/{d}/specwright-change.yaml" for d in dirs])
    cands = {change_name(d): d for d, m in zip(dirs, marks) if not (m is not None and PLANNING_ONLY.search(decode(m)))}
    mode = "local" if st.finish == "local" else "pr"
    found = []  # (order, dirname, pr)
    if mode == "local":
        for i, (sha, subject) in enumerate(rng):
            m = re.fullmatch(r"merge: (\S+)", subject.strip())
            if m and m.group(1) in cands:
                found.append((i, cands[m.group(1)], None))
    elif cands:
        main_name = detect_main(st) if not a.get("main") else a["main"]
        slug, pulls = merged_pulls(st, main_name, a.get("base"))
        pos = {sha: i for i, (sha, _) in enumerate(rng)}
        for p in sorted(pulls, key=lambda p: p.get("number") or 0):
            head, sha = p.get("head") or {}, p.get("merge_commit_sha")
            ref, repo = head.get("ref") or "", ((head.get("repo") or {}).get("full_name") or "")
            if not p.get("merged_at") or not sha or repo.lower() != slug.lower() or "/" not in ref:
                continue
            name = ref.rsplit("/", 1)[1]
            if name not in cands or ref != f"{branch_prefix(name)}/{name}" or any(f[1] == cands[name] for f in found):
                continue
            if is_ancestor(st.root, sha, rel) and not (prev and is_ancestor(st.root, sha, prev)):
                found.append((pos.get(sha, len(pos)), cands[name], p.get("number")))
    found.sort(key=lambda f: (f[0], f[1]))
    info = {"dir": top, "main": sref, "prefix": prefix, "mode": mode, "candidates": len(cands)}
    return [(d, pr) for _, d, pr in found], sref, prefix, info, top


def change_lines(changes):
    """`- <name> (#<pr>): <why>` per change; names only, then `…and <n> more`, past MAX_LISTED."""
    lines = []
    for c in changes[:MAX_LISTED]:
        if len(changes) > MAX_LISTED:
            lines.append(f"- {c['name']}")
        else:
            lines.append(f"- {c['name']}" + (f" (#{c['pr']})" if c["pr"] is not None else "") + (f": {c['why']}" if c["why"] else ""))
    if len(changes) > MAX_LISTED:
        lines.append(f"…and {len(changes) - MAX_LISTED} more")
    return lines


def build_notes(tag, changes, sections=None, summary=None):
    """`sections` is parallel to `changes`: a change's valid parsed section or None. With no valid section the text is
    `Changes in <tag>:` and one line per change; else the summary, the Added/Changed/Fixed/Removed groups (at most MAX_ITEMS
    items, then `…and <n> more items`) and `Changes:` for the changes without a section, one blank line between blocks."""
    if not changes:
        return f"No change was archived in this release ({tag})."
    sections = sections or [None] * len(changes)
    if not any(sections):
        return "\n".join([f"Changes in {tag}:", "", *change_lines(changes)])
    flat = [(h, item_line(t, c["pr"])) for h in HEADINGS for c, s in zip(changes, sections) if s for t, _ in s["items"].get(h, [])]
    listed, blocks = flat[:MAX_ITEMS], [summary]
    for h in HEADINGS:
        group = [l for g, l in listed if g == h]
        if group:
            blocks.append("\n".join([f"{h.capitalize()}:", *group]))
    if len(flat) > MAX_ITEMS:
        blocks[-1] += f"\n…and {len(flat) - MAX_ITEMS} more items"
    plain = [c for c, s in zip(changes, sections) if not s]
    if plain:
        blocks.append("\n".join(["Changes:", *change_lines(plain)]))
    return "\n\n".join(blocks)


def load_main(st, a):
    """(entries, ref, Releases) for `--main` (default: the local main)."""
    entries = st.entries()
    ref = a.get("main") or detect_main(st)
    if not ref_exists(st.root, ref):
        raise Stop("no_main", f"main ref '{ref}' does not exist")
    return entries, ref, Releases(primary_history(st, entries, ref))


def release_commit_of(st, entries, ref, rel, v):
    sha = rel.first.get(v)
    if not sha:
        raise Stop("no_release_commit", f"no commit on {ref}'s first-parent history carries {v} in the primary file "
                   f"'{entries[0][0]}': the release commit must be on main (merged), not only on a branch")
    require_release_shape(st, sha)
    return sha


def refuse_older_untagged(st, rel, tags, v):
    older = [u for u in untagged_since_latest(st, rel, tags, local_tags(st))[0] if sv(v) and sv(u) and sv(u) < sv(v)]
    if older:
        names = ", ".join(older)
        raise Stop("older_untagged", f"older version(s) not published (no tag on origin): {names}; publish {older[0]} "
                   f"(tag {tag_for(st, older[0])}) before {v}", versions=older)


def origin_url(st):
    r = git(st.root, "config", "--get", "remote.origin.url")
    return text_of(r) if r.returncode == 0 and text_of(r) else None


def same_remote(a, b):
    """True when two remote URLs name the same repository: the same owner/name on github.com (any URL form, any case),
    else the same URL apart from a trailing .git or slash."""
    ma, mb = GH_URL.match(a), GH_URL.match(b)
    if ma and mb:
        return (ma.group(1).lower(), ma.group(2).lower()) == (mb.group(1).lower(), mb.group(2).lower())
    norm = lambda u: re.sub(r"(?:\.git)?/*$", "", u.strip())
    return norm(a) == norm(b)


def check_push_destination(st):
    """Publish reads origin's tags from the fetch URL, pushes the tag to the push URL(s) and names the GitHub release's
    repository from the configured remote.origin.url. Stop unless they all name one repository, so the tag lands where it
    was checked and released. A rewrite (insteadOf) to a mirror that is not on github.com is fine. Local reads only."""
    if origin_url(st) is None:
        return
    f = git(st.root, "remote", "get-url", "origin")
    p = git(st.root, "remote", "get-url", "--push", "--all", "origin")
    if f.returncode != 0 or p.returncode != 0:
        raise Stop("git_failed", f"git remote get-url origin failed: {err_of(f) or err_of(p)}", code=3)
    mask = lambda u: re.sub(r"//[^@/\s]+@", "//***@", u)
    fetch, pushes = text_of(f), text_of(p).splitlines()
    raw = origin_url(st)
    if GH_URL.match(raw) and GH_URL.match(fetch) and not same_remote(raw, fetch):
        raise Stop("push_url_mismatch", f"origin is configured as {mask(raw)} but a URL rewrite (insteadOf) makes git reach "
                   f"{mask(fetch)}; the GitHub release would go to the first, the tag to the second. Nothing was written",
                   fetch_url=mask(fetch), configured_url=mask(raw))
    bad = [u for u in pushes if not same_remote(fetch, u)]
    if bad:
        raise Stop("push_url_mismatch", f"origin fetches from {mask(fetch)} but pushes to {', '.join(mask(u) for u in bad)}; "
                   "publish checks the tag and creates the release on the fetch URL, so the tag would land elsewhere. "
                   "Nothing was written. Publish from a remote whose push and fetch URLs name the same repository",
                   fetch_url=mask(fetch), push_urls=[mask(u) for u in pushes])


def remote_tag(st, tag):
    """(commit, annotated, object) for `tag` on origin: the peeled commit of an annotated tag (annotated True), or the commit
    of a lightweight one (False), and the ref's object id; (None, None, None) when absent or with no origin remote. Exit 3
    when origin cannot be read."""
    if origin_url(st) is None:
        return None, None, None
    r = git_net(st.root, "ls-remote", "--tags", "origin", f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}")
    if r.returncode != 0:
        shown = f"git ls-remote --tags origin refs/tags/{tag}"
        raise Stop("remote_tags_unreadable", f"{shown} failed: {err_of(r) or 'exit ' + str(r.returncode)}; no tag was written",
                   code=3, call=shown)
    obj = peeled = None
    for line in text_of(r).splitlines():
        sha, _, name = line.partition("\t")
        if name == f"refs/tags/{tag}":
            obj = sha
        elif name == f"refs/tags/{tag}^{{}}":
            peeled = sha
    return ((peeled or obj), peeled is not None, obj) if obj else (None, None, None)


def status_doc(st, a, loaded=None, release=True):
    """Everything status reports, for one version: the release commit, notes, previous release, local and remote tag."""
    v = a.get("version")
    if not v:
        usage(f"{a.get('_cmd', 'status')} needs --version")
    entries, ref, rel = loaded or load_main(st, a)
    sha = release_commit_of(st, entries, ref, rel, v)
    shared, files = agree(CommitTree(st.root, sha), entries)
    if shared != v:
        raise Stop("version_mismatch", f"version files at release commit {sha[:12]} read {shared}, not {v}")
    tags = local_tags(st) | published_tags(st)  # a clone that never fetched tags still sees origin's (D4)
    prev = previous_release(st, rel, v, tags)
    prev_sha = prev[1] if prev else None
    rng = range_commits(st, prev_sha, sha)
    info = None
    if a.get("store"):
        rows, wcommit, prefix, info, wroot = store_changes(st, a, prev_sha, sha, rng)
    else:
        rows, wcommit, prefix = local_changes(st, prev_sha, sha, rng)
        wroot = st.root
    secs = read_sections(wroot, wcommit, prefix, rows, v)
    ok = [d for d, _ in rows if d in secs and secs[d]["section"]]
    bumpers = [d for d in ok if secs[d]["bump"]]
    summary_of = bumpers[0] if len(bumpers) == 1 else (ok[-1] if ok else None)
    why = whys(wroot, wcommit, prefix, [d for d, _ in rows if d not in ok][:MAX_LISTED])  # Why lines of the listed no-section changes
    changes = [{"name": change_name(d), "why": why.get(d), "pr": pr} for d, pr in rows]
    warnings = [{"change": change_name(d), "error": secs[d]["warning"]} for d, _ in rows if d in secs and secs[d]["warning"]]
    tag = tag_for(st, v)
    tl = git(st.root, "rev-parse", "--verify", "--quiet", f"refs/tags/{tag}^{{commit}}")
    remote, remote_annotated, remote_obj = remote_tag(st, tag)
    lo = git(st.root, "rev-parse", "--verify", "--quiet", f"refs/tags/{tag}") if tl.returncode == 0 else None
    lightweight = []
    if tl.returncode == 0 and text_of(git(st.root, "cat-file", "-t", f"refs/tags/{tag}")) != "tag":
        lightweight.append("locally")
    if remote and not remote_annotated:
        lightweight.append("on origin")
    return {"ok": True, "version": v, "tag": tag, "release_commit": sha, "main": ref, "files": files,
            "previous": {"commit": prev_sha, "version": prev[0] if prev else None, "basis": prev[2] if prev else None},
            "range": {"from": prev_sha, "to": sha, "commits": len(rng)},
            "changes": changes, "warnings": warnings,
            "notes": build_notes(tag, changes, [secs[d]["section"] if d in ok else None for d, _ in rows],
                                 secs[summary_of]["section"]["summary"] if summary_of else None),
            "tag_local": text_of(tl) if tl.returncode == 0 else None, "tag_remote": remote, "tag_lightweight": lightweight,
            "tag_object": {"local": text_of(lo) if lo is not None and lo.returncode == 0 else None, "remote": remote_obj},
            **({"github_release": release_state(st, tag)[0]} if release else {}), "repo": st.root, "tag_repo": st.root, **({"store": info} if info else {})}


def cmd_status(st, a):
    return status_doc(st, a)


def cmd_untagged(st, a):
    entries, ref, rel = load_main(st, a)
    local = "local" in a or origin_url(st) is None
    tags = local_tags(st) if local else published_tags(st)
    versions, latest = untagged_since_latest(st, rel, tags, local_tags(st))
    return {"ok": True, "main": ref, "tags": "local" if local else "origin", "latest_tagged": latest,
            "untagged": [{"version": u, "tag": tag_for(st, u), "release_commit": rel.first[u]} for u in versions]}


def tag_message(st, tag):
    r = git(st.root, "tag", "-l", "--format=%(contents)", tag)
    if r.returncode != 0:
        raise Stop("git_failed", f"git tag -l {tag} failed: {err_of(r)}", code=3)
    return r.stdout.decode("utf-8", "surrogateescape").rstrip("\n") + "\n"


def with_file(text, fn):
    """Run fn(path) with `text` in a temp file that is removed afterwards."""
    fd, path = tempfile.mkstemp(prefix=".release-notes-")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(text.encode("utf-8", "surrogateescape"))
        return fn(path)
    finally:
        try:
            os.remove(path)
        except OSError:
            pass


def release_slug(st):
    """owner/name of the GitHub release: the configured remote.origin.url when it is a github.com URL, else the fetch URL
    after insteadOf rewriting (a shorthand such as `corp:acme/app` that git expands to github.com), else None (not_github).
    check_push_destination has already stopped when both are github.com URLs naming different repositories."""
    m = GH_URL.match(origin_url(st) or "")
    if not m:
        r = git(st.root, "remote", "get-url", "origin")
        m = GH_URL.match(text_of(r)) if r.returncode == 0 else None
    return f"{m.group(1)}/{m.group(2)}" if m else None


def release_state(st, tag):
    """The GitHub release of `tag`: (state, slug) with state existing | absent | disabled | not_github. A read-only
    `gh release view`; "release not found" is absent, any other failure is exit 3 (release_view_failed)."""
    if not st.github_release:
        return "disabled", None
    slug = release_slug(st)
    if not slug:
        return "not_github", None
    try:
        r = gh_run(st, "release", "view", tag, "--repo", slug)
    except Cut as c:
        raise cut_stop(c)
    if r.returncode == 0:
        return "existing", slug
    if "release not found" in err_of(r).lower():
        return "absent", slug
    shown = f"gh release view {tag} --repo {slug}"
    raise Stop("release_view_failed", f"{shown} failed: {err_of(r) or 'exit ' + str(r.returncode)}; a re-run of publish resumes",
               code=3, call=shown)


def release_read_back(st, tag, slug, c):
    """D5: `gh release create` was stopped by a bound. Read the release back (one `gh release view`, never retried): found counts
    as done; not found stops with the limit; a failed read-back leaves the state unknown."""
    try:
        state, _ = release_state(st, tag)
    except (Stop, Cut):
        raise Stop(c.limit, f"{c.limit}: {c.call} was stopped by its bound and reading the release back failed too: the state "
                   f"of the GitHub release is unknown. The tag {tag} is on origin and a re-run reads the release again",
                   code=3, call=c.call, state="unknown")
    if state == "existing":
        return "created", f"https://github.com/{slug}/releases/tag/{tag}"
    raise cut_stop(c, f"the release was not created (read back). The tag {tag} is on origin and a re-run creates only the release")


def github_release(st, tag):
    """D6 step 4. Returns (state, url): created | existing | disabled | not_github."""
    state, slug = release_state(st, tag)
    if state == "absent":
        shown = f"gh release create {tag} --repo {slug} --verify-tag"
        try:
            r = with_file(tag_message(st, tag), lambda path: gh_run(st, "release", "create", tag, "--repo", slug, "--verify-tag",
                                                                   "--title", tag, "--notes-file", path))
        except Cut as c:
            return release_read_back(st, tag, slug, Cut(c.limit, f"gh release create {tag}"))
        if r.returncode == 0:
            out = text_of(r).splitlines()
            return "created", out[-1] if out else None
        if "already exists" in err_of(r).lower() and release_state(st, tag)[0] == "existing":  # another session won the race
            return "existing", None
        raise Stop("release_create_failed", f"{shown} failed: {err_of(r) or 'exit ' + str(r.returncode)}; the tag {tag} is on "
                   "origin, a re-run creates only the release", code=3, call=shown)
    return state, None


def conflict_stop(tag, v, sha, at, where, written):
    return Stop("tag_conflict", f"tag {tag} already points at {at} {where}, but the release commit for {v} is {sha}; "
                f"{written}. Fix the tag by hand: publish never moves, deletes or forces a tag",
                tag=tag, tag_commit=at, release_commit=sha, where=where)


def mismatch_stop(tag, local_obj, remote_obj, written):
    return Stop("tag_mismatch", f"tag {tag} is at the release commit both locally and on origin, but as different tag "
                f"objects (local {local_obj[:12]}, origin {remote_obj[:12]}): a lost push race. The release body "
                f"must be origin's tag message, and {written}. Delete the local tag by hand "
                f"(git tag -d {tag}); a re-run then fetches origin's: publish never moves, deletes or forces a tag",
                tag=tag, local_object=local_obj, remote_object=remote_obj)


def push_read_back(st, tag, v, sha, c):
    """D5: the tag push was stopped by a bound, so it may or may not have landed. Read origin's tag back (one ls-remote, never
    retried): done only when it is the local tag object at the release commit; another commit is tag_conflict, the same commit
    as another tag object is tag_mismatch; absent stops with the limit; an unreadable origin leaves the state unknown."""
    try:
        commit, _, obj = remote_tag(st, tag)
    except (Stop, Cut):
        raise Stop(c.limit, f"{c.limit}: {c.call} was stopped by its bound and reading origin's {tag} back failed too: the state "
                   f"of the tag on origin is unknown; no GitHub release was created. The local tag {tag} stays, and a re-run "
                   "reads origin again before it pushes", code=3, call=c.call, state="unknown")
    if commit is None:
        raise cut_stop(c, f"the tag {tag} is not on origin (read back), so nothing landed. The local tag stays and a re-run "
                          "pushes it; no GitHub release was created")
    if commit != sha:
        raise conflict_stop(tag, v, sha, commit, "on origin", f"the push was stopped by {c.limit} and another clone's tag won; "
                            "no GitHub release was created")
    local_obj = text_of(git(st.root, "rev-parse", f"refs/tags/{tag}"))
    if obj != local_obj:
        raise mismatch_stop(tag, local_obj, obj, f"the push was stopped by {c.limit} and another clone's tag won; no GitHub "
                            "release was created")


def cmd_publish(st, a):
    st.gate(rebase=True)
    v = a.get("version")
    if not v:
        usage("publish needs --version")
    check_push_destination(st)  # before any network read: every URL must name one repository
    loaded = load_main(st, a)
    entries, ref, rel = loaded
    release_commit_of(st, entries, ref, rel, v)
    refuse_older_untagged(st, rel, published_tags(st), v)
    doc = status_doc(st, {**a, "_cmd": "publish"}, loaded, release=False)  # agreement at the release commit, notes, local and remote tag
    tag, sha, notes = doc["tag"], doc["release_commit"], doc["notes"]
    if origin_url(st) is None:
        raise Stop("no_origin", "publish needs an origin remote to push the tag to")
    local, remote = doc["tag_local"], doc["tag_remote"]
    for where, at in (("locally", local), ("on origin", remote)):
        if at and at != sha:
            raise conflict_stop(tag, v, sha, at, where, "nothing was written")
    if doc["tag_lightweight"]:
        where = " and ".join(doc["tag_lightweight"])
        raise Stop("lightweight_tag", f"tag {tag} exists {where} as a lightweight tag at the release commit; a release is an "
                   "annotated tag, and nothing was written. Replace it by hand: publish never moves, deletes or forces a tag",
                   tag=tag, where=doc["tag_lightweight"])
    objs = doc["tag_object"]
    if local and remote and objs["local"] != objs["remote"]:
        raise mismatch_stop(tag, objs["local"], objs["remote"], "nothing was written")
    # D6: read each step's state, do only what is missing
    if local:
        tag_local = "existing"
    elif remote:
        r = git_net(st.root, "fetch", "origin", f"refs/tags/{tag}:refs/tags/{tag}")
        if r.returncode != 0:
            raise Stop("tag_fetch_failed", f"git fetch origin refs/tags/{tag}:refs/tags/{tag} failed: {err_of(r)}; a re-run retries",
                       code=3, call=f"git fetch origin refs/tags/{tag}")
        tag_local = "fetched"
    else:
        def create(path):
            return git(st.root, "tag", "-a", "--cleanup=verbatim", "-F", path, tag, sha)
        r = with_file(notes + "\n", create)
        if r.returncode != 0:
            raise Stop("tag_create_failed", f"git tag -a {tag} failed: {err_of(r)} (the tagger is git's committer identity)", code=3,
                       call=f"git tag -a {tag}")
        tag_local = "created"
    if remote:
        tag_remote = "existing"
    else:
        try:
            r = git_net(st.root, "push", "origin", f"refs/tags/{tag}:refs/tags/{tag}")
        except Cut as c:
            push_read_back(st, tag, v, sha, Cut(c.limit, f"git push origin refs/tags/{tag}"))  # returns only when it landed
            r = subprocess.CompletedProcess([], 0, b"", b"")
        if r.returncode != 0:
            raise Stop("tag_push_failed", f"git push origin refs/tags/{tag}:refs/tags/{tag} failed: {err_of(r) or 'exit ' + str(r.returncode)}; "
                       f"the local tag {tag} exists and a re-run pushes it (or stops with tag_mismatch if another clone's {tag} "
                       "reached origin first); no GitHub release was created", code=3,
                       call=f"git push origin refs/tags/{tag}")
        tag_remote = "pushed"
    gh_state, url = github_release(st, tag)
    out = {"ok": True, "version": v, "tag": tag, "release_commit": sha, "tag_local": tag_local, "tag_remote": tag_remote,
           "github_release": gh_state, "notes": tag_message(st, tag).rstrip("\n"), "repo": st.root, "tag_repo": st.root}
    out["warnings"] = doc["warnings"] if tag_local == "created" else []  # they describe notes derived now, not the tag's
    if url:
        out["release_url"] = url
    if "store" in doc:
        out["store"] = doc["store"]
    return out


STORE_OPTS = {"--store": "store", "--store-main": "store-main", "--store-prefix": "store-prefix"}
COMMANDS = {
    "check": (cmd_check, {"--main": "main", "--branch": "branch"}),
    "bump": (cmd_bump, {"--to": "to"}),
    "status": (cmd_status, {"--version": "version", "--main": "main", "--base": "base", **STORE_OPTS}),
    "untagged": (cmd_untagged, {"--main": "main", "--local": Flag("local")}),
    "publish": (cmd_publish, {"--version": "version", "--main": "main", "--base": "base", **STORE_OPTS}),
}


def main(argv):
    rest, d = list(argv), None
    if rest[:1] == ["--dir"]:
        if len(rest) < 2:
            usage("--dir needs a value")
        d, rest = rest[1], rest[2:]
    if rest[:1] == ["notes"]:  # before the repo and the opt-in gate: one file, no git, no network (design D5)
        a, pos = parse_args(rest[1:], {"--proposal": "proposal"})
        if pos:
            usage(f"unexpected argument {pos[0]}")
        emit(cmd_notes(a))
    if not rest or rest[0] not in COMMANDS:
        usage("usage: release.sh [--dir <repo>] check [--main ref] [--branch name] | bump --to V | status --version V [--main ref] [--store dir] | untagged [--main ref] [--local] | publish --version V | notes --proposal <file>")
    fn, spec = COMMANDS[rest[0]]
    a, pos = parse_args(rest[1:], spec)
    if pos:
        usage(f"unexpected argument {pos[0]}")
    d = d or os.getcwd()
    r = git(d, "rev-parse", "--show-toplevel")
    if r.returncode != 0 or not text_of(r):
        raise Stop("not_a_repo", f"{d} is not inside a git work tree")
    st = Settings(os.path.normpath(text_of(r)))
    st.gate()
    emit(fn(st, a))


try:
    main(sys.argv[1:])
except Stop as e:
    emit(e.obj(), e.code)
except Cut as e:  # a bound stopped a network command nobody handles by name
    emit(cut_stop(e).obj(), 3)
except SystemExit:
    raise
except Exception as e:  # a bug must still answer with one JSON document
    emit({"ok": False, "error": "internal_error", "message": f"{type(e).__name__}: {e}"}, 1)
PYSRC
