#!/usr/bin/env python3
"""Reviewer detection for the pr snapshot.

  python -I reviewers.py --config FILE --material FILE --head OID
      Read the material pr-snapshot.sh built, decide for each configured reviewer
      whether it reported on the head, and print the finished snapshot as one line.
      --config is optional: without it there are no reviewers.
  python -I reviewers.py --check-config FILE
      Validate the config only; print {"ok":true,"digest":...,"logins":[...]}.

Exit 0 ok; 1 the material is unreadable or malformed, or --head is not its head;
2 a usage or config problem (one stderr line, nothing on stdout).
Pure standard library; imports nothing from its own directory.
"""
import argparse
import base64
import calendar
import hashlib
import json
import re
import sys

NAME = "reviewers.py"
MAX_REVIEWERS = 20
MAX_TEXT = 500
MAX_EVIDENCE = 10
MAX_EXCERPT = 300
LOGIN_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]*$")
REVIEWER_KEYS = {"login", "role", "timeout", "report"}
REPORT_KEYS = ("sha_pattern", "check", "marker", "ignore")
RULE_KEYS = ("sha_pattern", "check", "marker")
HEX_RE = re.compile(r"^[0-9a-fA-F]{7,40}$")
ISO_RE = re.compile(r"^(\d{4})-(\d\d)-(\d\d)[Tt ](\d\d):(\d\d):(\d\d)(?:\.(\d+))?(Z|z|[+-]\d\d:?\d\d)?$")
REMOVED = ("material", "checks_all", "cfg", "sig_base", "attn_base")


class ConfigError(Exception):
    pass


class MaterialError(Exception):
    pass


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise ConfigError("%s: %s" % ("usage", message))


def parse_iso(s):
    """Epoch seconds (float) of an ISO 8601 string, or None."""
    if not isinstance(s, str):
        return None
    m = ISO_RE.match(s.strip())
    if not m:
        return None
    y, mo, d, h, mi, se, frac, tz = m.groups()
    try:
        t = calendar.timegm((int(y), int(mo), int(d), int(h), int(mi), int(se), 0, 0, 0))
    except (ValueError, OverflowError):
        return None
    if frac:
        t += float("0." + frac)
    if tz and tz not in ("Z", "z"):
        sign = 1 if tz[0] == "+" else -1
        digits = tz[1:].replace(":", "")
        t -= sign * (int(digits[:2]) * 3600 + int(digits[2:]) * 60)
    return t


def format_iso(epoch):
    import time
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


# ---------------------------------------------------------------- config

def bad(login, key, why):
    return ConfigError("%s: %s: %s" % (login, key, why) if key else "%s: %s" % (login, why))


def validate_report(login, report):
    if not isinstance(report, dict):
        raise bad(login, "report", "must be an object")
    out = {}
    for key, val in report.items():
        if key not in REPORT_KEYS:
            raise bad(login, "report.%s" % key, "unknown key")
        if not isinstance(val, str) or not val:
            raise bad(login, "report.%s" % key, "must be a non-empty string")
        if len(val) > MAX_TEXT:
            raise bad(login, "report.%s" % key, "longer than %d characters" % MAX_TEXT)
        if key in ("sha_pattern", "ignore"):
            try:
                rx = re.compile(val)
            except (re.error, RecursionError, OverflowError) as e:
                raise bad(login, "report.%s" % key, "does not compile: %s" % e)
            if key == "sha_pattern" and rx.groups < 1:
                raise bad(login, "report.%s" % key, "needs a capture group for the commit SHA")
        out[key] = val
    return out


def validate_config(cfg, fname):
    def top(why):
        return ConfigError("%s: %s" % (fname, why))

    if not isinstance(cfg, dict):
        raise top("config must be a JSON object")
    for key in cfg:
        if key not in ("format", "reviewers"):
            raise top("unknown key %s" % key)
    fmt = cfg.get("format")
    if isinstance(fmt, bool) or fmt != 1:
        raise top("format must be 1")
    revs = cfg.get("reviewers")
    if not isinstance(revs, list):
        raise top("reviewers must be a list")
    if len(revs) > MAX_REVIEWERS:
        raise top("reviewers: more than %d reviewers" % MAX_REVIEWERS)
    out, seen = [], set()
    for r in revs:
        if not isinstance(r, dict):
            raise top("reviewers: each reviewer must be an object")
        login = r.get("login")
        if not isinstance(login, str) or not LOGIN_RE.match(login):
            raise bad(login if isinstance(login, str) else "?", "login", "must match %s" % LOGIN_RE.pattern)
        for key in r:
            if key not in REVIEWER_KEYS:
                raise bad(login, key, "unknown key")
        if login.lower() in seen:
            raise bad(login, "login", "listed twice")
        seen.add(login.lower())
        if r.get("role") not in ("required", "advisory"):
            raise bad(login, "role", "must be required or advisory")
        timeout = r.get("timeout")
        if isinstance(timeout, bool) or not isinstance(timeout, int) or timeout < 0:
            raise bad(login, "timeout", "must be a non-negative integer")
        out.append({"login": login, "role": r["role"], "timeout": timeout,
                    "report": validate_report(login, r["report"]) if "report" in r else {}})
    return out


def load_config(path):
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError as e:
        raise ConfigError("%s: cannot read: %s" % (path, e.strerror or e))
    try:
        cfg = json.loads(raw.decode("utf-8"))
    except (ValueError, RecursionError) as e:
        raise ConfigError("%s: not valid JSON: %s" % (path, e))
    return validate_config(cfg, path), hashlib.sha256(raw).hexdigest()


# ------------------------------------------------------------- evaluation

def item_time(it):
    return parse_iso(it.get("edited") or it.get("created"))


def excerpt(s):
    return (s or "")[:MAX_EXCERPT]


def evaluate_reviewer(rev, items, checks_all, head, cutoff, now):
    report = rev["report"]
    ignore = re.compile(report["ignore"]) if "ignore" in report else None
    sha_rx = re.compile(report["sha_pattern"]) if "sha_pattern" in report else None
    check_name = report.get("check")
    marker = report.get("marker")
    has_rule = any(k in report for k in RULE_KEYS)
    head_l = head.lower()

    items = [i for i in items if not (i.get("kind") == "review" and i.get("state") == "PENDING")]
    for i in items:
        i["_t"] = item_time(i)
        body = i.get("body") or ""
        i["_ignored"] = bool(ignore and ignore.search(body))

    def after_cutoff(i):
        return cutoff is not None and i["_t"] is not None and i["_t"] >= cutoff

    def on_head(i):
        return i.get("kind") == "review" and i.get("commit") == head

    live = [i for i in items if not i["_ignored"]]
    own_checks = [c for c in checks_all if check_name is not None and owns(rev, c)]

    by = None
    if any(on_head(i) for i in live):
        by = "review"
    elif not has_rule:
        if any(after_cutoff(i) for i in live):
            by = "output"
    else:
        if sha_rx and any(sha_matches(sha_rx, i.get("body") or "", head_l) for i in live):
            by = "sha_pattern"
        elif check_name is not None and any(c.get("state") != "pending" for c in own_checks):
            by = "check"
        elif marker and any(marker in (i.get("body") or "") and after_cutoff(i) for i in live):
            by = "marker"

    if by:
        state = "reported"
    elif cutoff is not None and now - cutoff >= rev["timeout"]:
        state = "timed_out"
    else:
        state = "waiting"

    ev = [(i["_t"], {"kind": i.get("kind"), "at": i.get("edited") or i.get("created"), "state": i.get("state"),
                     "excerpt": excerpt(i.get("body"))})
          for i in items if on_head(i) or after_cutoff(i)]
    for c in own_checks:
        ev.append((parse_iso(c.get("at")), {"kind": "check", "at": c.get("at"), "state": c.get("state"),
                                            "excerpt": excerpt(c.get("name"))}))
    ev.sort(key=lambda p: float("-inf") if p[0] is None else p[0], reverse=True)
    return {"login": rev["login"], "role": rev["role"], "timeout": rev["timeout"], "state": state, "by": by,
            "evidence": [e for _, e in ev[:MAX_EVIDENCE]]}


def owns(rev, c):
    """Whether check `c` is reviewer `rev`'s `report.check`: the exact name, from a check run of the reviewer's own GitHub
    App (its slug equals the login, case-insensitively). A same-named check from another app, or a commit status (no
    app), can be posted by anyone with access to the head, so it never stands for the reviewer."""
    name = rev["report"].get("check")
    app = c.get("app")
    return (name is not None and c.get("name") == name and isinstance(app, str)
            and app.lower() == rev["login"].lower())


def sha_matches(rx, body, head_l):
    for m in rx.finditer(body):
        g = m.group(1) if m.re.groups >= 1 else None
        if g and HEX_RE.match(g) and head_l.startswith(g.lower()):
            return True
    return False


def evaluate(mat, reviewers, digest, head):
    if not isinstance(mat, dict) or mat.get("head_oid") != head:
        raise MaterialError("--head does not match the material's head_oid")
    cfg = mat.get("cfg") or {}
    cutoff = parse_iso(cfg.get("since"))
    now = cfg.get("now")
    if isinstance(now, bool) or not isinstance(now, (int, float)):
        raise MaterialError("cfg.now missing")
    checks_all = mat.get("checks_all") or []
    material = mat.get("material") or {}

    results = [evaluate_reviewer(r, list(material.get(r["login"]) or []), checks_all, head, cutoff, now)
               for r in reviewers]
    state_of = {r["login"]: x for r, x in zip(reviewers, results)}

    pending = [c for c in checks_all if c.get("state") == "pending"]
    advisory = ci = 0
    for c in pending:
        own = [r for r in reviewers if owns(r, c)]
        if not own:
            ci += 1
        elif all(r["role"] == "advisory" and state_of[r["login"]]["state"] in ("reported", "timed_out") for r in own):
            advisory += 1

    out = {}
    for k, v in mat.items():
        if k in REMOVED:
            continue
        if k == "checks" and isinstance(v, dict):
            checks = {}
            base = {kk: vv for kk, vv in v.items() if kk not in ("pending", "advisory_pending", "ci_pending")}
            counts = {"pending": len(pending) - advisory, "advisory_pending": advisory, "ci_pending": ci}
            if "total" not in base:
                checks.update(counts)
            for kk, vv in base.items():
                checks[kk] = vv
                if kk == "total":
                    checks.update(counts)
            v = checks
        out[k] = v
    if "checks" not in out:
        out["checks"] = {"pending": len(pending) - advisory, "advisory_pending": advisory, "ci_pending": ci}
    out["reviewers"] = results
    out["now"] = format_iso(now)
    out["reviewer_config"] = digest
    r = ",".join("%s:%s" % (x["login"], x["state"]) for x in results)
    for name in ("sig", "attn"):
        base = mat.get(name + "_base") or ""
        out[name] = base64.b64encode(("%s|%s" % (base, r)).encode("utf-8")).decode("ascii")
    return out


def emit(text):
    sys.stdout.buffer.write((text + "\n").encode("utf-8", "replace"))
    sys.stdout.buffer.flush()


def main(argv):
    ap = Parser(prog=NAME, add_help=False)
    ap.add_argument("--config")
    ap.add_argument("--material")
    ap.add_argument("--head")
    ap.add_argument("--check-config", dest="check_config")
    try:
        args = ap.parse_args(argv)
        if args.check_config:
            if args.config or args.material or args.head:
                raise ConfigError("usage: --check-config takes no other option")
            revs, digest = load_config(args.check_config)
            emit(json.dumps({"ok": True, "digest": digest, "logins": [r["login"] for r in revs]},
                            separators=(",", ":"), ensure_ascii=False))
            return 0
        if not args.material or not args.head:
            raise ConfigError("usage: --material and --head are required")
        revs, digest = load_config(args.config) if args.config else ([], None)
    except ConfigError as e:
        sys.stderr.write("%s: %s\n" % (NAME, e))
        return 2
    try:
        with open(args.material, "rb") as f:
            mat = json.loads(f.read().decode("utf-8"))
        out = evaluate(mat, revs, digest, args.head)
    except (OSError, ValueError, MaterialError, KeyError, TypeError, AttributeError, RecursionError) as e:
        sys.stderr.write("%s: %s: %s\n" % (NAME, args.material, e))
        return 1
    emit(json.dumps(out, separators=(",", ":"), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
