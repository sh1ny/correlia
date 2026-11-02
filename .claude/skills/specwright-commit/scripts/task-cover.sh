#!/usr/bin/env bash
# Which tasks of tasks.md are covered by commits on a change branch. Read-only: it only reads
# tasks.md and runs `git log` and `git rev-list --count`. Prints ONE JSON document.
#
# Usage: bash task-cover.sh --repo <dir> --range <a>..<b> --tasks <tasks.md> --change <name>
# Evidence (a task X.Y is covered by a commit when):
#   subject  the subject starts `<type>(<change>): task X.Y ` (<type> is any token; nothing else in a
#            subject counts, so `task 1.1` inside other text, or in a `group N` subject, is not evidence);
#   trailer  a `Specwright-Task` trailer has the value exactly X.Y (read by Git's own trailer parser).
# A commit naming a task by both forms counts once (form subject).
# Membership: task X.Y belongs to group X, compared as an integer (1 is not 10). A group's heading is the
# text of `## X. <text>`. A commit's group is the group of its `task X.Y` subject, or N of a
# `<type>(<change>): group N ` subject; a commit with neither subject has no group, so its trailers are
# never cross-group.
# JSON keys:
#   ok, change, range
#   tasks[]         {id, group, ticked, commits:[{sha, form: subject|trailer}]}  (file order; read from
#                   `- [<box>] X.Y ` lines, ticked when the box holds only x, any case and spacing; CRLF tolerated)
#   groups[]        {group, heading}  heading is null when `## N.` is missing
#   pending_groups[] {group, tasks:[ids]}  groups with ticked tasks that have no evidence
#   uncovered[]     ids of ticked tasks with no evidence
#   duplicates[]    {task, commits:[sha,...]}  tasks covered by more than one commit
#   cross_group[]   {sha, task, group}  a trailer naming a task outside the commit's group
#   missing_headings[]  groups that have tasks but no `## N.` heading
# Exit: 0 answered (even with uncovered tasks or gaps: the caller decides), 1 stop (JSON "error"): range_too_large,
#       2 usage or bad input (usage, no_tasks, tasks_too_large, no_python, duplicate_task_ids: a task id on
#       more than one `- [<box>] X.Y ` line; the message names every repeated id), 3 git failed (git_failed).
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
    want = {"--repo": None, "--range": None, "--tasks": None, "--change": None}
    i = 0
    while i < len(argv):
        if argv[i] in want and i + 1 < len(argv):
            want[argv[i]] = argv[i + 1]
            i += 2
        else:
            stop("usage", "task-cover.sh --repo <dir> --range <a>..<b> --tasks <tasks.md> --change <name>", 2)
    if not all(want.values()):
        stop("usage", "task-cover.sh --repo <dir> --range <a>..<b> --tasks <tasks.md> --change <name>", 2)
    return want


def git(repo, *args):
    try:
        # log.showSignature would print signature checks into the machine-readable log
        r = subprocess.run(["git", "-c", "log.showSignature=false", "-C", repo, *args], capture_output=True)
    except OSError as e:
        stop("git_failed", "cannot run git: %s" % e, 3)
    if r.returncode != 0:
        stop("git_failed", "git %s failed: %s" % (args[0], r.stderr.decode("utf-8", "replace").strip()), 3)
    return r.stdout


a = parse_args(sys.argv[1:])
repo, rng, tasks_path, change = a["--repo"], a["--range"], a["--tasks"], a["--change"]

if not os.path.isfile(tasks_path):
    stop("no_tasks", "no tasks file: %s" % tasks_path, 2)
if os.path.getsize(tasks_path) > MAX_TASKS_BYTES:
    stop("tasks_too_large", "tasks.md is over 1 MiB", 2)
with open(tasks_path, "rb") as f:
    text = f.read().decode("utf-8", "replace")

def box_done(box):
    # the apply schema: a box holding only x (any case, any spacing) is done; every other marker is not
    return box.strip() in ("x", "X")


HEADING = re.compile(r"^##[ \t]+(\d+)\.[ \t]+(\S.*?)[ \t]*$")
TASK = re.compile(r"^[ \t]*-[ \t]+\[([^\]\r\n]*)\][ \t]+(\d+)\.(\d+)(?=\s|$)")
tasks, headings = [], {}
for line in text.splitlines():
    m = HEADING.match(line)
    if m:
        headings.setdefault(int(m.group(1)), m.group(2))
        continue
    m = TASK.match(line)
    if m:
        tasks.append({"id": "%s.%s" % (m.group(2), m.group(3)), "group": int(m.group(2)),
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

raw = git(repo, "log", "-z", "--format=%H%x00%s%x00%(trailers:key=Specwright-Task,valueonly,separator=%x1F)", rng)
tok = raw.decode("utf-8", "replace").split("\0")
# a trailing empty token after the last record terminator
if tok and tok[-1] == "":
    tok.pop()
if len(tok) % 3:
    stop("git_failed", "unexpected git log output", 3)
commits = [(tok[i].strip(), tok[i + 1][:MAX_FIELD], tok[i + 2][:MAX_FIELD]) for i in range(0, len(tok), 3)]

ct = re.escape(change)
SUBJ_TASK = re.compile(r"^\S+\(%s\): task (\d+\.\d+) " % ct)
SUBJ_GROUP = re.compile(r"^\S+\(%s\): group (\d+) " % ct)
by_id = {t["id"]: t for t in tasks}
cross = []
for sha, subject, trailers in commits:
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
    for tid, form in forms.items():
        if tid in by_id:
            by_id[tid]["commits"].append({"sha": sha, "form": form})

group_ids = sorted({t["group"] for t in tasks} | set(headings))
uncovered = [t["id"] for t in tasks if t["ticked"] and not t["commits"]]
pending = []
for g in group_ids:
    ids = [t["id"] for t in tasks if t["group"] == g and t["ticked"] and not t["commits"]]
    if ids:
        pending.append({"group": g, "tasks": ids})
out({
    "ok": True, "change": change, "range": rng,
    "tasks": tasks,
    "groups": [{"group": g, "heading": headings.get(g)} for g in group_ids],
    "pending_groups": pending,
    "uncovered": uncovered,
    "duplicates": [{"task": t["id"], "commits": [c["sha"] for c in t["commits"]]} for t in tasks if len(t["commits"]) > 1],
    "cross_group": cross,
    "missing_headings": [g for g in sorted({t["group"] for t in tasks}) if g not in headings],
}, 0)
PYSRC
