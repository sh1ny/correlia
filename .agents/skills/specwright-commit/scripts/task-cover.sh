#!/usr/bin/env bash
# Which tasks of tasks.md are covered by commits on a change branch. Read-only: it only reads
# tasks.md and runs `git log`, `git rev-list --count`, `git ls-files -s` and `git cat-file -s` and, with --rev,
# `git rev-parse`, `git ls-tree` and `git cat-file blob`. Prints ONE JSON document. An evidence file counts only as a
# regular, non-empty blob under the change folder in the index of the repo holding tasks.md (with --rev, in that
# revision's tree); it is never read through the working tree.
#
# Usage: bash task-cover.sh --repo <dir> --range <a>..<b> --tasks <tasks.md> --change <name> [--rev <sha>]
#   --rev <sha>  read --tasks as committed at <sha> (the regular-file blob at <path>, the path taken relative to
#                the repo; the working tree is ignored) and check evidence files at <sha> too. The tasks file
#                absent at <sha>, or a symlink or directory there = exit 2 no_tasks.
# Evidence (a task X.Y is covered by a commit when):
#   subject  the subject starts `<type>(<change>): task X.Y ` (<type> is any token; nothing else in a
#            subject counts, so `task 1.1` inside other text, or in a `group N` subject, is not evidence);
#   trailer  a `Specwright-Task` trailer has the value exactly X.Y (read by Git's own trailer parser).
# A commit naming a task by both forms counts once (form subject).
# A `Specwright-User-Task` trailer with the value exactly X.Y covers X.Y when it is a user task (form user_trailer);
# it never covers an agent or evidence task and is never cross-group.
# Kind: the first token after the id is exactly `[user]` (a user task) or `[evidence]` (an evidence task), lowercase;
# a marker elsewhere, glued to text or in another case leaves the task an agent task.
# Membership: task X.Y belongs to group X, compared as an integer (1 is not 10). A group's heading is the
# text of `## X. <text>`. A commit's group is the group of its `task X.Y` subject, or N of a
# `<type>(<change>): group N ` subject; a commit with neither subject has no group, so its trailers are
# never cross-group.
# JSON keys:
#   ok, change, range
#   tasks[]         {id, group, kind: agent|user|evidence, ticked, commits:[{sha, form: subject|trailer|user_trailer}]}
#                   (file order; read from `- [<box>] X.Y ` lines, ticked when the box holds only x, any case and spacing; CRLF tolerated)
#   groups[]        {group, heading}  heading is null when `## N.` is missing
#   pending_groups[] {group, tasks:[ids]}  groups with ticked agent or evidence tasks that have no evidence
#   uncovered[]     ids of ticked agent or evidence tasks with no evidence (user tasks are never counted)
#   waiting_on_user[]    ids of unticked user tasks, file order
#   user_uncommitted[]   ids of ticked user tasks that no commit's `Specwright-User-Task` trailer covers
#   evidence_missing[]   ids of ticked evidence tasks whose text names no `evidence/` path, or whose file (relative
#                        to the change folder = the directory of --tasks) is missing or empty
#   duplicates[]    {task, commits:[sha,...]}  tasks covered by more than one commit
#   cross_group[]   {sha, task, group}  a trailer naming a task outside the commit's group
#   missing_headings[]  groups that have tasks but no `## N.` heading
# Exit: 0 answered (even with uncovered tasks or gaps: the caller decides), 1 stop (JSON "error"): range_too_large,
#       2 usage or bad input (usage, no_tasks (also the tasks file absent at --rev), tasks_too_large, no_python,
#       duplicate_task_ids: a task id on more than one `- [<box>] X.Y ` line; the message names every repeated id), 3 git failed (git_failed).
# Bounds: tasks.md over 1 MiB = exit 2 tasks_too_large; more than 10000 commits in the range = exit 1
# range_too_large (the test lowers it with TASK_COVER_MAX_COMMITS); a subject or trailer value is cut at 64 KiB.
# Needs bash, git (trailers) and Python 3.8+.
set -euo pipefail

py=
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1; then py=$c; break; fi
done
[ -n "$py" ] || { echo '{"ok":false,"error":"no_python","message":"task-cover.sh needs python 3.8+"}'; exit 2; }

exec "$py" -I -X utf8 - "$@" <<'PYSRC'
import json
import os
import re
import subprocess
import sys

MAX_TASKS_BYTES = 1024 * 1024
MAX_COMMITS = int(os.environ.get("TASK_COVER_MAX_COMMITS") or 10000)
MAX_FIELD = 64 * 1024


def out(doc, code):
    sys.stdout.write(json.dumps(doc, ensure_ascii=False) + "\n")
    sys.exit(code)


def stop(error, message, code):
    out({"ok": False, "error": error, "message": message}, code)


def parse_args(argv):
    want = {"--repo": None, "--range": None, "--tasks": None, "--change": None, "--rev": None}
    usage = "task-cover.sh --repo <dir> --range <a>..<b> --tasks <tasks.md> --change <name> [--rev <sha>]"
    i = 0
    while i < len(argv):
        if argv[i] in want and i + 1 < len(argv):
            want[argv[i]] = argv[i + 1]
            i += 2
        else:
            stop("usage", usage, 2)
    if not all(v for k, v in want.items() if k != "--rev"):
        stop("usage", usage, 2)
    return want


def git(repo, *args, soft=False):
    try:
        # log.showSignature would print signature checks into the machine-readable log; a local refs/replace
        # entry must not change what a commit (the ready head above all) holds
        r = subprocess.run(["git", "--no-replace-objects", "-c", "log.showSignature=false", "-C", repo, *args],
                           capture_output=True)
    except OSError as e:
        stop("git_failed", "cannot run git: %s" % e, 3)
    if r.returncode != 0:
        if soft:
            return None
        stop("git_failed", "git %s failed: %s" % (args[0], r.stderr.decode("utf-8", "replace").strip()), 3)
    return r.stdout


a = parse_args(sys.argv[1:])
repo, rng, tasks_path, change = a["--repo"], a["--range"], a["--tasks"], a["--change"]

rev = a["--rev"]
rel_dir = None  # the change folder relative to the repo top, only with --rev
if rev:
    top = git(repo, "rev-parse", "--show-toplevel").decode("utf-8", "replace").strip()
    # The path inside the repo is taken lexically: following a working-tree symlink would let the checkout pick
    # which committed file is read. Only the repo's own location may be resolved (macOS /var -> /private/var).
    tasks_rel = None
    for base in (os.path.abspath(repo), os.path.abspath(top), os.path.realpath(repo)):
        try:
            r = os.path.relpath(os.path.abspath(tasks_path), base).replace(os.sep, "/")
        except ValueError:  # Windows: another drive
            continue
        if r not in (".", "..") and not r.startswith("../"):
            tasks_rel = r
            break
    if tasks_rel is None:
        stop("no_tasks", "tasks file %s is outside the repo" % tasks_path, 2)
    # only a regular file is a task list: a committed symlink or directory would parse as one with no tasks
    entry = git(repo, "ls-tree", "-z", rev, "--", tasks_rel, soft=True) or b""
    meta, _, name = entry.rstrip(b"\0").partition(b"\t")
    meta = meta.split()
    if len(meta) != 3 or meta[0] not in (b"100644", b"100755") or meta[1] != b"blob" \
            or name != tasks_rel.encode("utf-8") or b"\0" in entry.rstrip(b"\0"):
        stop("no_tasks", "no tasks file %s at %s" % (tasks_rel, rev), 2)
    raw_tasks = git(repo, "cat-file", "blob", meta[2].decode("ascii"), soft=True)
    if raw_tasks is None:
        stop("no_tasks", "no tasks file %s at %s" % (tasks_rel, rev), 2)
    rel_dir = os.path.dirname(tasks_rel)
else:
    if not os.path.isfile(tasks_path):
        stop("no_tasks", "no tasks file: %s" % tasks_path, 2)
    if os.path.getsize(tasks_path) > MAX_TASKS_BYTES:
        stop("tasks_too_large", "tasks.md is over 1 MiB", 2)
    with open(tasks_path, "rb") as f:
        raw_tasks = f.read()
if len(raw_tasks) > MAX_TASKS_BYTES:
    stop("tasks_too_large", "tasks.md is over 1 MiB", 2)
text = raw_tasks.decode("utf-8", "replace")

def box_done(box):
    # the apply schema: a box holding only x (any case, any spacing) is done; every other marker is not
    return box.strip() in ("x", "X")


HEADING = re.compile(r"^##[ \t]+(\d+)\.[ \t]+(\S.*?)[ \t]*$")
TASK = re.compile(r"^[ \t]*-[ \t]+\[([^\]\r\n]*)\][ \t]+(\d+)\.(\d+)(?=\s|$)(.*)$")
MARKER = re.compile(r"^[ \t]*\[(user|evidence)\](?=[ \t]|$)")
EVIDENCE = re.compile(r"(?:^|[\s(`'\"*_])(evidence/[^\s)`'\",;]+)")
tasks, headings, texts = [], {}, {}
for line in text.splitlines():
    m = HEADING.match(line)
    if m:
        headings.setdefault(int(m.group(1)), m.group(2))
        continue
    m = TASK.match(line)
    if m:
        tid = "%s.%s" % (m.group(2), m.group(3))
        mk = MARKER.match(m.group(4))
        texts[tid] = m.group(4)
        tasks.append({"id": tid, "group": int(m.group(2)), "kind": mk.group(1) if mk else "agent",
                      "ticked": box_done(m.group(1)), "commits": []})

# a repeated id would let one line's evidence hide the other's: tasks.md is invalid, report no coverage
seen, repeated = set(), []
for t in tasks:
    if t["id"] in seen and t["id"] not in repeated:
        repeated.append(t["id"])
    seen.add(t["id"])
if repeated:
    stop("duplicate_task_ids", "%s repeats task ids: %s" % (tasks_path, ", ".join(repeated)), 2)

count =int(git(repo, "rev-list", "--count", rng).decode().strip() or 0)
if count > MAX_COMMITS:
    stop("range_too_large", "range %s has %d commits, over the bound of %d" % (rng, count, MAX_COMMITS), 1)

raw = git(repo, "log", "-z", "--format=%H%x00%s%x00%(trailers:key=Specwright-Task,valueonly,separator=%x1F)%x00"
          "%(trailers:key=Specwright-User-Task,valueonly,separator=%x1F)", rng)
tok = raw.decode("utf-8", "replace").split("\0")
# a trailing empty token after the last record terminator
if tok and tok[-1] == "":
    tok.pop()
if len(tok) % 4:
    stop("git_failed", "unexpected git log output", 3)
commits = [(tok[i].strip(), tok[i + 1][:MAX_FIELD], tok[i + 2][:MAX_FIELD], tok[i + 3][:MAX_FIELD])
           for i in range(0, len(tok), 4)]

ct = re.escape(change)
SUBJ_TASK = re.compile(r"^\S+\(%s\): task (\d+\.\d+) " % ct)
SUBJ_GROUP = re.compile(r"^\S+\(%s\): group (\d+) " % ct)
by_id = {t["id"]: t for t in tasks}
cross = []
for sha, subject, trailers, user_trailers in commits:
    forms = {}
    grp = None
    m = SUBJ_TASK.match(subject)
    if m:
        forms[m.group(1)] = "subject"
        grp = int(m.group(1).split(".")[0])
    else:
        m = SUBJ_GROUP.match(subject)
        if m:
            grp = int(m.group(1))
    for v in [v.strip() for v in trailers.split("\x1f")] if trailers else []:
        if not re.fullmatch(r"\d+\.\d+", v):
            continue
        forms.setdefault(v, "trailer")
        if grp is not None and int(v.split(".")[0]) != grp:
            cross.append({"sha": sha, "task": v, "group": grp})
    # a Specwright-User-Task trailer covers a user task only and is never cross-group
    for v in [v.strip() for v in user_trailers.split("\x1f")] if user_trailers else []:
        t = by_id.get(v)
        if t and t["kind"] == "user":
            forms[v] = "user_trailer"
    for tid, form in forms.items():
        if tid in by_id:
            by_id[tid]["commits"].append({"sha": sha, "form": form})

group_ids = sorted({t["group"] for t in tasks} | set(headings))


def work(t):
    # user tasks are never counted as pending agent work
    return t["kind"] != "user" and t["ticked"] and not t["commits"]


def evidence_ok(t):
    m = EVIDENCE.search(texts[t["id"]])
    if not m:
        return False
    rel = m.group(1).rstrip(".:*!?")  # sentence or markdown punctuation after the path is not part of it
    # `\` and `:` would let Windows read a segment as a UNC or drive path outside the change: reject before any
    # filesystem access, as are empty, `.` and `..` segments.
    if "\\" in rel or ":" in rel or any(s in ("", ".", "..") for s in rel.split("/")):
        return False
    if rev:
        # only a regular file entry counts: a tree, symlink (120000) or submodule entry does not
        path = "/".join(p for p in (rel_dir, rel) if p)
        entry = git(repo, "ls-tree", "-z", rev, "--", path, soft=True)
        if not entry:
            return False
        meta, _, name = entry.rstrip(b"\0").partition(b"\t")
        fields = meta.split()
        if len(fields) != 3 or fields[0] not in (b"100644", b"100755") or name.decode("utf-8", "replace") != path:
            return False
        size = git(repo, "cat-file", "-s", fields[2].decode("ascii"), soft=True)
        return size is not None and size.strip() not in (b"", b"0")
    # The index of the repo holding tasks.md (the planning repo, whatever --repo names), never the working tree:
    # no path is opened, so no symlink, UNC or drive path, or swap during the check can make another file count.
    change_dir = os.path.dirname(os.path.abspath(tasks_path))
    entry = git(change_dir, "ls-files", "-s", "-z", "--", ":(literal)" + rel, soft=True)
    if not entry:
        return False
    entries = [e for e in entry.split(b"\0") if e]
    if len(entries) != 1:
        return False
    meta, _, name = entries[0].partition(b"\t")
    fields = meta.split()  # mode, object, stage
    if len(fields) != 3 or fields[0] not in (b"100644", b"100755") or fields[2] != b"0" \
            or name.decode("utf-8", "replace") != rel:
        return False
    size = git(change_dir, "cat-file", "-s", fields[1].decode("ascii"), soft=True)
    return size is not None and size.strip() not in (b"", b"0")


uncovered = [t["id"] for t in tasks if work(t)]
pending = []
for g in group_ids:
    ids = [t["id"] for t in tasks if t["group"] == g and work(t)]
    if ids:
        pending.append({"group": g, "tasks": ids})
waiting = [t["id"] for t in tasks if t["kind"] == "user" and not t["ticked"]]
user_uncommitted = [t["id"] for t in tasks
                    if t["kind"] == "user" and t["ticked"] and not any(c["form"] == "user_trailer" for c in t["commits"])]
evidence_missing = [t["id"] for t in tasks if t["kind"] == "evidence" and t["ticked"] and not evidence_ok(t)]
out({
    "ok": True, "change": change, "range": rng,
    "tasks": tasks,
    "groups": [{"group": g, "heading": headings.get(g)} for g in group_ids],
    "pending_groups": pending,
    "uncovered": uncovered,
    "waiting_on_user": waiting,
    "user_uncommitted": user_uncommitted,
    "evidence_missing": evidence_missing,
    "duplicates": [{"task": t["id"], "commits": [c["sha"] for c in t["commits"]]} for t in tasks if len(t["commits"]) > 1],
    "cross_group": cross,
    "missing_headings": [g for g in sorted({t["group"] for t in tasks}) if g not in headings],
}, 0)
PYSRC
