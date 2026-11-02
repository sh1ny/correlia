#!/usr/bin/env bash
# Decisions for finishing a change that were prose before: how to undo an archive of a DEFERRED change. The script only READS
# the repo (rev-parse, status, log, show, diff-tree, ls-tree, ls-files, cat-file). It never checks out, moves, restores or
# commits; the user runs the scripts it prints. Every run prints ONE JSON document.
#
# Usage: bash finish.sh [--dir <planning toplevel>] undo-archive-plan --change <name> --archived-name <archived>
#                       --prefix <P> --main <main> [--branch <branch>] [--type <commit type>] [--code <code toplevel>]
#   undo-archive-plan   the plan to undo the archive of <name> (its directory <P>/changes/archive/<archived>/) and of every
#                       change archived with it. <P> is the openspec root inside the planning repo ("openspec"). --dir is the
#                       planning repo (default: the current directory; store-backed: the store's toplevel). --branch is the
#                       branch that holds a committed archive (default: the current branch). --type is the commit type of the
#                       undo commit's subject `<type>(<name>): undo archive of <member names>`; default: the branch prefix
#                       (`bugfix` -> `fix`, any other prefix as it is, no prefix -> `chore`).
#                       Uncommitted archive (the archive directory is in the working tree and not in HEAD): the members are
#                       every untracked directory under <P>/changes/archive/ whose <P>/changes/<name>/ is tracked at HEAD and
#                       missing from the working tree. Committed archive: A is the NEWEST commit in <main>..<branch> that added
#                       the archive directory's review.md; the members are the archive directories A added. A member's name
#                       is its directory name without the date, unless the change was itself named with a date (that
#                       <P>/changes/<dated name>/ is the one the archive moved). Main specs include nested capabilities
#                       (<P>/specs/<area>/<id>/spec.md).
#                       JSON: ok, mode (uncommitted|committed), archive_commit (A, null when uncommitted), branch, head,
#                       members [{name, archived_name, deferred}], main_specs {modified[], created[]} (a spec deleted on the
#                       branch after the archive is left deleted, with a warning), amended[] (main specs whose working copy
#                       differs from A's synced content), carried_edits[] (archive-copy files with edits
#                       that are not committed or differ from the change directory), backup_dir
#                       (<git-dir>/specwright-undo/<archived>/), script, after_rerun (for a bulk archive, a script that
#                       archives the non-deferred members again and merges back amendments to the main specs they sync;
#                       null otherwise), warnings[].
#                       `script` and `after_rerun` are bash texts that begin with `set -euo pipefail`: save each to a file and
#                       run it with `bash <file>`. `script` guards the branch, HEAD and index first (a resume from another
#                       branch checks the tree is clean and the branch tip is the planned head BEFORE the checkout, then
#                       guards again), saves backups, builds ONE undo commit in the index (committed mode only), and fixes
#                       the working tree. Nothing here ever resets, force-pushes or reverts a later commit.
#                       Refusals (exit 1, ok false, error, message): no_archive (nothing to undo; `commits` lists the add
#                       commits when the newest add was reverted), dirty_tree (a resume on another branch with a dirty tree,
#                       or a synced main spec or member archive directory deleted from the working tree; `files` names
#                       them), staged_changes, target_exists (<P>/changes/<name>/ already exists), duplicate_member (two
#                       archive directories restore to one <P>/changes/<name>/), member_missing (a later commit deleted a
#                       member's archive directory; `paths` names them), backup_exists (the backup directory exists),
#                       bad_ref, not_a_repo.
#                       On GitButler (the code repo's backend, read through vcs.sh) --branch is required (exit 2, usage) and the
#                       head every guard checks is the tip of refs/heads/<branch>, resolved now: HEAD is the workspace commit
#                       there. On Git and jj the head is HEAD, as before.
#                       The current branch is read through ../../specwright-pr/scripts/vcs.sh `state` (exit 2, error
#                       vcs_script_missing, naming the path when that script is absent). --code is the code repo's toplevel; give
#                       it with `--dir <store>` so the store's own backend is probed. On a jj repo `script` works the working copy
#                       and commits only the touched paths with `jj commit`, then sets the branch's bookmark; it runs no Git write.
#                       It guards with `vcs.sh state`, `git rev-parse HEAD` (the colocated Git HEAD is `@-`) and
#                       `jj diff -r @ --name-only` over the touched paths. An archive committed on another branch needs `@` empty
#                       (else dirty_tree) and the script starts with `jj new <branch>`.
# Exit: 0 done, 1 stop (the JSON has "ok": false, "error" and "message"), 2 usage.
# Needs bash, git and Python 3.8+ (and jj for a jj repo).
set -euo pipefail

py=
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1; then py=$c; break; fi
done
[ -n "$py" ] || { echo '{"ok":false,"error":"no_python","message":"finish.sh needs python 3.8+"}'; exit 2; }
FIN_DIR=$(cd "$(dirname "$0")" && pwd -P)
FIN_BASH=${BASH:-bash}
if command -v cygpath >/dev/null 2>&1; then FIN_DIR=$(cygpath -m "$FIN_DIR"); FIN_BASH=$(cygpath -w "$FIN_BASH"); fi
export FIN_DIR FIN_BASH

exec "$py" -I -X utf8 - "$@" <<'PYSRC'
import json
import os
import re
import shlex
import subprocess
import sys

ENV = dict(os.environ)
ENV.setdefault("GIT_TERMINAL_PROMPT", "0")
VCS_SH = os.path.normpath(os.path.join(os.environ["FIN_DIR"], "..", "..", "specwright-pr", "scripts", "vcs.sh")).replace("\\", "/")
BASH = os.environ.get("FIN_BASH") or "bash"
DATE_RX = re.compile(r"^\d{4}-\d{2}-\d{2}-")
DEFERRED_RX = re.compile(r"(?m)^VERDICT: DEFERRED[ \t]*\r?$")


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


def git(d, *args):
    try:
        return subprocess.run(["git", *args], cwd=d, env=ENV, capture_output=True)
    except OSError as e:
        return subprocess.CompletedProcess(args, 127, b"", str(e).encode())


def text_of(r):
    return r.stdout.decode("utf-8", "replace").strip()


def nul_list(r):
    return [x.decode("utf-8", "replace") for x in r.stdout.split(b"\0") if x]


def vcs_state(top, code, branch=None):
    """The branch and the working-copy changes, read through vcs.sh state (the repo's own backend). --branch is passed along:
    on GitButler `branch` is empty unless that branch is applied."""
    if not os.path.isfile(VCS_SH):
        raise Stop("vcs_script_missing", f"{VCS_SH} is missing; finish.sh reads the branch through it", code=2, path=VCS_SH)
    role = ["--role", "store", "--code", code] if code else ["--role", "code"]
    if branch:
        role += ["--branch", branch]
    try:
        r = subprocess.run([BASH, VCS_SH, "state", "--repo", top, *role], cwd=top, env=ENV, capture_output=True)
    except OSError as e:
        raise Stop("vcs_error", f"could not run {VCS_SH}: {e}")
    try:
        doc = json.loads(r.stdout.decode("utf-8", "replace"))
    except ValueError:
        raise Stop("vcs_error", f"{VCS_SH} state printed no JSON: " + r.stderr.decode("utf-8", "replace").strip())
    if not doc.get("ok"):
        raise Stop(str(doc.get("error") or "vcs_error"), str(doc.get("message") or "vcs.sh state failed"))
    return doc


def parse_args(argv, spec):
    a, i = {}, 0
    while i < len(argv):
        t = argv[i]
        if t in spec:
            if i + 1 >= len(argv):
                usage(f"{t} needs a value")
            a[spec[t]] = argv[i + 1]
            i += 2
        elif t.startswith("--"):
            usage(f"unknown option {t}")
        else:
            usage(f"unexpected argument {t}")
    return a


q = shlex.quote


def dq(text):
    """A jj string literal: fileset `root:"<path>"` and revset `"<name>"`."""
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def join(*parts):
    return "/".join(p for p in parts if p)


def cmd_undo(d, a):
    for k in ("change", "archived", "prefix", "main"):
        if k not in a:
            usage(f"undo-archive-plan needs --{'archived-name' if k == 'archived' else k}")
    change, archived, main = a["change"], a["archived"], a["main"]
    P = a["prefix"].strip("/")
    if P == ".":
        P = ""
    r = git(d, "rev-parse", "--show-toplevel")
    if r.returncode != 0 or not text_of(r):
        raise Stop("not_a_repo", f"{d} is not inside a git work tree")
    top = text_of(r)
    gitdir = text_of(git(top, "rev-parse", "--absolute-git-dir"))
    r = git(top, "rev-parse", "--verify", "-q", "HEAD^{commit}")
    if r.returncode != 0:
        raise Stop("not_a_repo", "the repository has no commit")
    head = text_of(r)
    vs = vcs_state(top, a.get("code"), a.get("branch"))
    jj = vs["backend"] == "jj"
    gb = vs["backend"] == "gitbutler"
    headref = "HEAD"
    if gb:  # HEAD is the workspace commit: the head every guard checks is the branch's tip
        if not a.get("branch"):
            usage("--branch is required on GitButler: HEAD is the workspace commit, not the change branch")
        if not vs.get("applied"):
            raise Stop("branch_not_applied", f"{a['branch']} is not applied in the GitButler workspace; Specwright never applies one "
                       "(it can conflict with the other branches): apply it yourself, then plan again", branch=a["branch"])
        headref = "refs/heads/" + a["branch"]
        r = git(top, "rev-parse", "--verify", "-q", headref + "^{commit}")
        if r.returncode != 0:
            raise Stop("bad_ref", f"{a['branch']} is not a local branch")
        head = text_of(r)
    cb = vs["branch"]
    branch = a.get("branch") or cb
    if not branch:
        usage("--branch is required on a detached HEAD")
    if git(top, "rev-parse", "--verify", "-q", main + "^{commit}").returncode != 0:
        raise Stop("bad_ref", f"{main} is not a commit")

    ad = join(P, "changes", "archive", archived)
    ad_in_wd = os.path.isdir(os.path.join(top, ad))
    ad_in_head = bool(git(top, "ls-tree", "-r", "--name-only", head, "--", ad).stdout.strip())
    uncommitted = ad_in_wd and not ad_in_head
    typ = a.get("type") or _type_of(branch)
    backup_dir = f"{gitdir}/specwright-undo/{archived}"

    def has(tree, path):
        return git(top, "cat-file", "-e", f"{tree}:{path}").returncode == 0

    def blob(tree, path):
        r = git(top, "cat-file", "blob", f"{tree}:{path}")
        return r.stdout if r.returncode == 0 else None

    def blob_wd(tree, path):
        """The blob as a checkout writes it (eol and filter attributes, core.autocrlf), to compare with working-tree bytes."""
        r = git(top, "cat-file", "--filters", f"{tree}:{path}")
        return r.stdout if r.returncode == 0 else None

    def wd_bytes(path):
        try:
            with open(os.path.join(top, path), "rb") as f:
                return f.read()
        except OSError:
            return None

    def staged():
        return [] if jj or gb else nul_list(git(top, "diff", "--cached", "--name-only", "-z"))  # no index on jj; GitButler never stages

    def unique_members(order):
        """Two archive directories that restore to one changes/<name>/ would nest one inside the other."""
        seen = {}
        for dname, nm in order:
            if nm in seen:
                tgt = join(P, "changes", nm)
                raise Stop("duplicate_member", f"{seen[nm]} and {dname} both restore to {tgt}; move one out of "
                           f"{join(P, 'changes', 'archive')}/, then plan again", path=tgt, archived_names=[seen[nm], dname])
            seen[nm] = dname

    def missing_in_wd(paths):
        """The script copies each synced main spec and moves each archive directory: one deleted from the working tree
        would stop it halfway."""
        gone = [p for p in paths if not os.path.exists(os.path.join(top, p))]
        if gone:
            raise Stop("dirty_tree", "Deleted in the working tree: " + ", ".join(gone) + ". Restore them with `git restore -- "
                       + " ".join(gone) + "` (or commit the deletion), then plan again.", files=gone)

    warnings = []
    members = []          # dicts: name, archived_name, deferred, dir
    main_mod, main_new, gone_specs = [], [], []

    if uncommitted:
        mode, A, T, plan_branch = "uncommitted", None, head, cb
        names = {}
        if jj:  # Git's index does not follow the jj working copy: the added files are @'s changes
            others = [e["path"] for e in vs["dirty"] if e["status"] == "A" and e["path"].startswith(join(P, "changes", "archive") + "/")]
        else:
            others = nul_list(git(top, "ls-files", "-z", "--others", "--exclude-standard", "--", join(P, "changes", "archive") + "/"))
        base = join(P, "changes", "archive") + "/"
        for path in others:
            rest = path[len(base):] if path.startswith(base) else ""
            dname = rest.split("/", 1)[0]
            if not dname or "/" not in rest:
                continue
            if dname == archived:
                continue
            for nm in (dname, DATE_RX.sub("", dname)):  # a change named with a date is archived under that name
                if has(head, join(P, "changes", nm)) and not os.path.exists(os.path.join(top, join(P, "changes", nm))):
                    names[dname] = nm
                    break
        order = [(archived, change)] + sorted(names.items())
        unique_members(order)
        for dname, nm in order:
            mdir = join(P, "changes", "archive", dname)
            rv = wd_bytes(join(mdir, "review.md")) or b""
            members.append({"name": nm, "archived_name": dname, "deferred": bool(DEFERRED_RX.search(rv.decode("utf-8", "replace"))), "dir": mdir})
        if cb != branch:
            warnings.append(f"The archive is uncommitted, so the plan guards the current branch {cb or '(detached)'}, not {branch}.")
        if staged():
            raise Stop("staged_changes", "The index differs from HEAD: " + ", ".join(staged()) + ". Unstage or commit them first.")
        # main specs: the capabilities each member's delta names
        caps = []
        for m in members:
            sp = join(m["dir"], "specs")
            for root, _dirs, files in os.walk(os.path.join(top, sp)):  # nested capabilities: specs/<area>/<id>/spec.md
                rel = os.path.relpath(root, os.path.join(top, sp)).replace(os.sep, "/")
                if "spec.md" in files and rel != "." and join(P, "specs", rel, "spec.md") not in caps:
                    caps.append(join(P, "specs", rel, "spec.md"))
        for f in sorted(caps):
            if has(head, f):
                main_mod.append(f)
            elif os.path.isfile(os.path.join(top, f)):
                main_new.append(f)
        missing_in_wd(main_mod)
        for m in members:
            tgt = join(P, "changes", m["name"])
            if os.path.exists(os.path.join(top, tgt)):
                raise Stop("target_exists", f"{tgt} already exists; merge or move it first", path=tgt)
        # carried edits: archive-copy files that differ from the change directory at HEAD
        carried = []
        for m in members:
            for root, _dirs, files in os.walk(os.path.join(top, m["dir"])):
                for fn in files:
                    full = os.path.join(root, fn)
                    rel = os.path.relpath(full, os.path.join(top, m["dir"])).replace(os.sep, "/")
                    old = blob_wd(head, join(P, "changes", m["name"], rel))
                    with open(full, "rb") as fh:
                        if old is None or fh.read() != old:
                            carried.append(join(m["dir"], rel))
        marker_dirs = {}
        for m in members:
            mk = join(m["dir"], "specwright-change.yaml")
            marker_dirs[m["name"]] = os.path.isfile(os.path.join(top, mk)) and not has(head, join(P, "changes", m["name"], "specwright-change.yaml"))
        if os.path.exists(backup_dir):
            raise Stop("backup_exists", f"{backup_dir} exists; move or delete it, then plan again", path=backup_dir)
        amended = []
        backup_files = main_mod + main_new
        if backup_files:
            warnings.append(f"The synced main specs are copied to {backup_dir}/amended/ before they are restored or removed; "
                            "a sync and your own edit in one file cannot be told apart, so that copy is the only one of your edit.")
    else:
        mode, plan_branch = "committed", branch
        r = git(top, "rev-parse", "--verify", "-q", f"refs/heads/{branch}")
        T = text_of(r) if r.returncode == 0 else ""
        adds = []
        if T:
            r = git(top, "log", "--no-renames", "--diff-filter=A", "--format=%H", f"{main}..{branch}", "--", join(ad, "review.md"))
            adds = text_of(r).split()
        if not adds:
            raise Stop("no_archive", f"No archive of {change} ({ad}) found in the working tree or on {branch}", commits=[])
        A = adds[0]
        if not has(T, ad):
            raise Stop("no_archive", f"The archive commit(s) {', '.join(x[:9] for x in adds)} of {change} were reverted: {ad} is not on {branch}", commits=adds)
        if branch != cb and jj:
            if vs["dirty_paths"]:
                raise Stop("dirty_tree", f"The working copy @ is not empty, so it cannot move onto {branch} with jj new: "
                           + ", ".join(vs["dirty_paths"]), files=vs["dirty_paths"])
        elif branch != cb:
            dirty = text_of(git(top, "status", "--porcelain")).splitlines()
            if dirty:
                raise Stop("dirty_tree", "The working tree is dirty, so the branch cannot be checked out: " + "; ".join(x.strip() for x in dirty), files=[x[3:] for x in dirty])
        else:
            if staged():
                raise Stop("staged_changes", "The index differs from HEAD: " + ", ".join(staged()) + ". Unstage or commit them first.")
        changes = git(top, "diff-tree", "-r", "--no-renames", "--root", "--no-commit-id", "--name-status", "-z", A).stdout.split(b"\0")
        changes = [x.decode("utf-8", "replace") for x in changes if x]
        added, mod, new, deleted = [], [], [], []
        for i in range(0, len(changes) - 1, 2):
            st, path = changes[i], changes[i + 1]
            if st == "A":
                added.append(path)
            elif st == "D":
                deleted.append(path)
            if path.startswith(join(P, "specs") + "/"):
                if st == "M":
                    mod.append(path)
                elif st == "A":
                    new.append(path)
        abase = join(P, "changes", "archive") + "/"
        dnames = []
        for path in added:
            if path.startswith(abase):
                rest = path[len(abase):]
                dn = rest.split("/", 1)[0]
                if dn and "/" in rest and dn not in dnames:  # a plain file under archive/ is no member
                    dnames.append(dn)
        if archived in dnames:
            dnames.remove(archived)
        cbase = join(P, "changes") + "/"
        moved = {p[len(cbase):].split("/", 1)[0] for p in deleted if p.startswith(cbase) and not p.startswith(abase)}
        gone = [join(P, "changes", "archive", dn) for dn in dnames if not has(T, join(P, "changes", "archive", dn))]
        if gone:  # restoring the synced specs would drop those members' requirements with nothing to rerun
            raise Stop("member_missing", "Archive directories of this archive were deleted on " + branch + " after it: "
                       + ", ".join(gone) + ". Restore them (or undo the archive by hand), then plan again.", paths=gone)
        for dn in [archived] + dnames:
            mdir = join(P, "changes", "archive", dn)
            nm = change if dn == archived else dn if dn in moved else DATE_RX.sub("", dn)  # a dated name is archived as it is
            rv = blob(T, join(mdir, "review.md")) or b""
            members.append({"name": nm, "archived_name": dn, "deferred": bool(DEFERRED_RX.search(rv.decode("utf-8", "replace"))), "dir": mdir})
        unique_members([(m["archived_name"], m["name"]) for m in members])
        for m in members:
            tgt = join(P, "changes", m["name"])
            if has(T, tgt) or (branch == cb and os.path.exists(os.path.join(top, tgt))):
                raise Stop("target_exists", f"{tgt} already exists; merge or move it first", path=tgt)
        if os.path.exists(backup_dir):
            raise Stop("backup_exists", f"{backup_dir} exists; move or delete it, then plan again", path=backup_dir)
        main_mod = [f for f in mod if has(T, f)]
        main_new = [f for f in new if has(T, f)]
        gone_specs = [f for f in mod + new if not has(T, f)]  # a later deletion is an amendment: keep it
        marker_dirs = {m["name"]: join(m["dir"], "specwright-change.yaml") in added and has(T, join(m["dir"], "specwright-change.yaml")) for m in members}
        carried = []
        if branch == cb and jj:
            carried = [p for p in vs["dirty_paths"] if any(p.startswith(m["dir"] + "/") for m in members)]
        elif branch == cb:
            pathspecs = [m["dir"] for m in members]
            out = git(top, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--", *pathspecs).stdout.split(b"\0")
            carried = [x.decode("utf-8", "replace")[3:] for x in out if len(x) > 3]
        amended = []
        backup_files = [f for f in main_mod + main_new if has(T, f)]
        if branch == cb:  # a resume from another branch checks out a clean tree, where nothing is missing
            missing = [m["dir"] for m in members] + backup_files
            missing_in_wd(missing)
        for f in backup_files:
            cur = wd_bytes(f) if branch == cb else None
            if cur is None:
                cur, synced = blob(T, f), blob(A, f)
            else:
                synced = blob_wd(A, f)
            if cur != synced:
                amended.append(f)

    names_all = [m["name"] for m in members]
    if len(members) > 1:
        warnings.append("This archive holds " + ", ".join(names_all) + ". The whole archive is undone, never only the deferred "
                        "change's files; run the archive again without the deferred change.")
    warnings.append("Do not edit files while the script runs.")

    # ---- the guard ---------------------------------------------------------------------------------------------
    sq = q
    touched_all = [m["dir"] for m in members] + [join(P, "changes", m["name"]) for m in members] + main_mod + main_new
    if gb:  # the guard reads: the branch is applied at the planned tip and the touched paths have no uncommitted change
        state_cmd = f'bash {sq(VCS_SH)} state --repo {sq(top)} --role code --branch {sq(branch)}'
        lines = ["set -euo pipefail", f"cd {sq(top)}",
                 f'case "$({state_cmd})" in *{sq(chr(34) + "branch" + chr(34) + ": " + json.dumps(plan_branch, ensure_ascii=False))}*) ;; *) echo "wrong branch" >&2; exit 1 ;; esac',
                 f'test "$(git rev-parse {sq(headref)})" = {sq(T)}',
                 # HEAD is the workspace commit: a touched path that differs from the tip there is another applied branch's,
                 # and restoring the file would undo that branch's committed change
                 f'git diff --quiet {sq(T)} HEAD -- ' + " ".join(sq(f) for f in touched_all)
                 + ' || { echo "another applied branch changes a path the undo restores" >&2; exit 1; }']
        if mode == "committed":
            lines.append(f'test -z "$(git --no-optional-locks status --porcelain --untracked-files=all -- '
                         + " ".join(sq(f) for f in touched_all) + ')"')
        lines.append(f"test ! -e {sq(backup_dir)}")
    elif jj:
        rev = branch if re.fullmatch(r"[A-Za-z0-9._/]+(-[A-Za-z0-9._/]+)*", branch) else dq(branch)  # a revset symbol or string
        fsets = " ".join(sq("root:" + dq(f)) for f in touched_all)
        state_cmd = f'bash {sq(VCS_SH)} state --repo {sq(top)} ' + (f"--role store --code {sq(a['code'])}" if a.get("code") else "--role code")
        lines = ["set -euo pipefail", f"cd {sq(top)}"]
        if mode == "committed" and branch != cb:
            lines += ['test -z "$(jj diff -r @ --name-only)"', f'test "$(git rev-parse {sq("refs/heads/" + branch)})" = {sq(T)}',
                      f"jj new {sq(rev)}"]
        lines += [f'case "$({state_cmd})" in *{sq(chr(34) + "branch" + chr(34) + ": " + json.dumps(plan_branch, ensure_ascii=False))}*) ;; *) echo "wrong branch" >&2; exit 1 ;; esac',
                  f'test "$(git rev-parse {sq(headref)})" = {sq(T)}']
        if mode == "committed":
            lines.append(f'test -z "$(jj diff -r @ --name-only {fsets})"')
        lines.append(f"test ! -e {sq(backup_dir)}")
    else:
        lines = ["set -euo pipefail", f"cd {sq(top)}"]
    guard = [f'test "$(git branch --show-current)" = {sq(plan_branch)}', f'test "$(git rev-parse {sq(headref)})" = {sq(T)}',
             "git diff --cached --quiet", f"test ! -e {sq(backup_dir)}"]
    if not jj and not gb:
        if mode == "committed" and branch != cb:
            lines += ['test -z "$(git status --porcelain)"', f'test "$(git rev-parse {sq("refs/heads/" + branch)})" = {sq(T)}',
                      f"git checkout -q {sq(branch)} --"]
        lines += guard

    # ---- the backups -------------------------------------------------------------------------------------------
    dirs = sorted({backup_dir + "/amended/" + os.path.dirname(f) for f in backup_files} |
                  ({backup_dir + "/base/" + os.path.dirname(f) for f in backup_files} if mode == "committed" else set()))
    if backup_files:
        lines += ["mkdir -p -- " + " ".join(sq(x) for x in dirs)]
    for f in backup_files:
        if mode == "committed":
            lines.append(f"git cat-file --filters {sq(A + ':' + f)} > {sq(backup_dir + '/base/' + f)}")
        lines.append(f"cp -- {sq(f)} {sq(backup_dir + '/amended/' + f)}")
    if not backup_files:
        lines.append(f"mkdir -p -- {sq(backup_dir)}")

    if mode == "committed" and not jj and not gb:
        for m in members:
            lines.append(f"git rm -r -q --cached -- {sq(m['dir'])}")
            lines.append(f"git read-tree --prefix={sq(join(P, 'changes', m['name']) + '/')} {sq(T + ':' + m['dir'])}")
            if marker_dirs[m["name"]]:
                lines.append(f"git rm -q --cached -- {sq(join(P, 'changes', m['name'], 'specwright-change.yaml'))}")
        if main_mod:
            lines.append(f"git restore --source={sq(A + '^')} --staged -- " + " ".join(sq(f) for f in main_mod))
        if main_new:
            lines.append("git rm -q --cached -- " + " ".join(sq(f) for f in main_new))
        subject = f"{typ}({change}): undo archive of {', '.join(names_all)}"
        lines.append(f"git commit -q -m {sq(subject)}")
    for m in members:
        lines.append(f"mv -- {sq(m['dir'])} {sq(join(P, 'changes', m['name']))}")
        if marker_dirs[m["name"]]:
            lines.append(f"rm -f -- {sq(join(P, 'changes', m['name'], 'specwright-change.yaml'))}")
    src = f"--source={sq(A + '^')}" if mode == "committed" else f"--source={sq(T)}"
    if main_mod and jj:
        lines.append(f"jj restore --from {sq(A + '-' if mode == 'committed' else T)} " + " ".join(sq("root:" + dq(f)) for f in main_mod))
    elif main_mod and gb:  # a file write from a Git read: `git restore` would be a Git write to the shared work tree
        base_rev = A + "^" if mode == "committed" else T
        for f in main_mod:
            lines.append(f"git cat-file --filters {sq(base_rev + ':' + f)} > {sq(f)}")
    elif main_mod:
        lines.append(f"git restore {src} --worktree -- " + " ".join(sq(f) for f in main_mod))
    if main_new:
        lines.append("rm -f -- " + " ".join(sq(f) for f in main_new))
        for dn in sorted({os.path.dirname(f) for f in main_new}):
            lines.append(f"rmdir {sq(dn)} 2>/dev/null || true")
    if jj and mode == "committed":
        subject = f"{typ}({change}): undo archive of {', '.join(names_all)}"
        lines.append(f"jj commit -m {sq(subject)} {fsets}")
        lines.append(f"jj bookmark set {sq(rev)} -r @-")
    if gb and mode == "committed":
        subject = f"{typ}({change}): undo archive of {', '.join(names_all)}"
        msgfile = backup_dir + "/commit-message.txt"
        lines.append(f"printf '%s\\n' {sq(subject)} > {sq(msgfile)}")
        # a directory ends in `/` so the commit covers the files that left it
        cpaths = [d + "/" for d in [m["dir"] for m in members] + [join(P, "changes", m["name"]) for m in members]] + main_mod + main_new
        lines.append(f"bash {sq(VCS_SH)} commit --repo {sq(top)} --role code --branch {sq(branch)} --message-file {sq(msgfile)} -- "
                     + " ".join(sq(f) for f in cpaths))
    lines.append(f"echo {sq('Undo done. Saved copies are in ' + backup_dir)}")
    script = "\n".join(lines) + "\n"

    if mode == "committed" and jj:
        warnings.append("If the script fails after it began changing the working copy and before it commits, run "
                        f"`jj restore {fsets}` and plan again. Unlike the Git script, the working tree is NOT untouched "
                        "until the commit on jj: the moves and restores happen in @ first.")
        if vs["dirty_paths"] and branch == cb and any(p.startswith(tuple(f + "/" for f in touched_all)) or p in touched_all for p in vs["dirty_paths"]):
            warnings.append("@ already holds changes under the touched paths, so the script's guard stops before it moves anything. "
                            "Commit them elsewhere or set them aside, then plan again.")
    elif mode == "committed" and gb:
        warnings.append("The script moves and rewrites files in the shared GitButler work tree first and commits them last, with "
                        f"`vcs.sh commit` (`but commit -b {branch}`), naming only the touched paths; no Git write runs. If it fails "
                        "before the commit, those files are uncommitted changes: move the archived directories back by hand, write "
                        "each main spec again with `git cat-file --filters <archive commit>^:<path>`, and plan again.")
    elif mode == "committed":
        touched = [m["dir"] for m in members] + [join(P, "changes", m["name"]) for m in members] + main_mod + main_new
        warnings.append("If the script fails after it began changing the index and before it commits, run "
                        "`git restore --staged -- " + " ".join(touched) + "` and plan again; the working tree is untouched until the commit.")
    if backup_files and mode == "committed":
        warnings.append(f"Base and amended copies of the synced main specs are saved in {backup_dir}; no step reads or deletes them.")

    # ---- after_rerun -------------------------------------------------------------------------------------------
    after = None
    rerun = [m for m in members if not m["deferred"]]  # every bulk member but the deferred ones, the named one included
    merge, left, redelete = [], list(amended) if mode == "committed" else [], []
    if mode == "committed" and rerun:
        synced_by_rerun = set()
        for m in rerun:
            for p in nul_list(git(top, "ls-tree", "-r", "--name-only", "-z", T, "--", join(m["dir"], "specs"))):
                rel = p[len(m["dir"]) + 1:]
                if rel.endswith("/spec.md"):
                    synced_by_rerun.add(join(P, rel))
        merge = [f for f in amended if f in synced_by_rerun]
        left = [f for f in amended if f not in synced_by_rerun]
        redelete = [f for f in gone_specs if f in synced_by_rerun]  # the rerun archive would bring them back
    if rerun:
        names = ", ".join(m["name"] for m in rerun)
        al = ["set -euo pipefail", f"cd {sq(top)}"]
        for f in redelete:  # stop before any archive when the user made a new spec of the same name
            al.append(f"test ! -e {sq(f)} || {{ echo {sq(f + ' exists; the after-rerun script would delete it. Move it away, then run again.')} >&2; exit 1; }}")
        for m in rerun:
            al.append(f"openspec archive {sq(m['name'])} --yes")
        for f in merge:
            al.append(f"git merge-file -L rerun -L archived -L amended {sq(f)} {sq(backup_dir + '/base/' + f)} {sq(backup_dir + '/amended/' + f)}")
        for f in redelete:
            al.append(f"rm -f -- {sq(f)}")
        done = "Amendments merged." if merge else "Archived again by after_rerun."
        al.append(f"echo {sq(done + ' Now start finish for: ' + names)}")
        after = "\n".join(al) + "\n"
        warnings.append("Run after_rerun after script: it archives " + names + " again" +
                        (" and merges the saved amendments into " + ", ".join(merge) + ". On a conflict it stops with markers "
                         "in the file; both copies stay in " + backup_dir + "." if merge else "."))
    for f in gone_specs:
        if f in redelete:
            warnings.append(f"{f} was deleted on {branch} after the archive; the undo leaves it deleted, and after_rerun deletes it again "
                            f"after it archives {names}.")
        else:
            warnings.append(f"{f} was deleted on {branch} after the archive; the undo leaves it deleted.")
    if left:
        warnings.append("Amendments to " + ", ".join(left) + " were made on top of the deferred change's synced content, so they "
                        f"are saved in {backup_dir}/amended/ and never merged automatically; review them by hand.")

    return {"ok": True, "mode": mode, "archive_commit": A, "branch": plan_branch, "head": T,
            "members": [{"name": m["name"], "archived_name": m["archived_name"], "deferred": m["deferred"]} for m in members],
            "main_specs": {"modified": main_mod, "created": main_new}, "amended": amended,
            "carried_edits": carried, "backup_dir": backup_dir, "script": script, "after_rerun": after, "warnings": warnings}


def _type_of(branch):
    if "/" not in branch:
        return "chore"
    pre = branch.split("/", 1)[0]
    return "fix" if pre == "bugfix" else pre


COMMANDS = {
    "undo-archive-plan": (cmd_undo, {"--change": "change", "--archived-name": "archived", "--prefix": "prefix",
                                     "--main": "main", "--branch": "branch", "--type": "type", "--code": "code"}),
}


def main(argv):
    rest, d = list(argv), None
    if rest[:1] == ["--dir"]:
        if len(rest) < 2:
            usage("--dir needs a value")
        d, rest = rest[1], rest[2:]
    if not rest or rest[0] not in COMMANDS:
        usage("usage: finish.sh [--dir <planning toplevel>] undo-archive-plan --change <name> --archived-name <archived> "
              "--prefix <P> --main <main> [--branch <branch>] [--type <type>] [--code <code toplevel>]")
    fn, spec = COMMANDS[rest[0]]
    a = parse_args(rest[1:], spec)
    emit(fn(d or os.getcwd(), a))


try:
    main(sys.argv[1:])
except Stop as e:
    emit(e.obj(), e.code)
except SystemExit:
    raise
except Exception as e:  # a bug must still answer with one JSON document
    emit({"ok": False, "error": "internal_error", "message": f"{type(e).__name__}: {e}"}, 1)
PYSRC
