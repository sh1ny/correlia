"""Run one command under a deadline and a byte bound on its stdout and its stderr. Stdlib only, Python 3.8+.

The pr scripts run every network command (gh, git fetch/push/ls-remote) through here, so a stuck network or a huge
response ends as a named limit instead of a hang or an out-of-memory.

Limits (defaults live here only; the environment can lower them, for tests, but never raise them):
  120 s            per command                         SPECWRIGHT_NET_DEADLINE
  300 s            per paginated read (paged=True)     SPECWRIGHT_NET_PAGED_DEADLINE
  32 MiB           of stdout, and of stderr, per command  SPECWRIGHT_NET_MAX_BYTES
  50 pages         in a cursor loop a script drives    MAX_PAGES (constant)
  SPECWRIGHT_NET_DEADLINE_AT (epoch seconds) caps each deadline to the time left until then.
Test overrides (read from the run's environment, only when set; never needed in production):
  SPECWRIGHT_TEST_POLL     the wait interval of the loop, in seconds (default POLL)
  SPECWRIGHT_TEST_NO_JOB   1 makes the Windows job object fail, to test the fallback (read only by spawn)
  SPECWRIGHT_TEST_SPAWN_DIR  a directory; on POSIX each successful spawn creates an empty file named after the child's pid in
                           it (from this process's environment, and from the child's env= when that names another), so a
                           test runner can stop sessions nested spawns started. Unset: nothing is written. Windows: never.

Use as a library:  run_bounded(cmd, deadline, max_bytes, env, cwd, paged=False, secret=False) -> Result(rc, stdout, stderr, limit)
  limit is None, "deadline_exceeded" or "response_too_large" (rc is None then); deadline and max_bytes default (None) to the
  values above. stdout and stderr are text (UTF-8, undecodable bytes replaced).
Use as a CLI:      python bounded.py [--paged] [--secret] -- cmd...
                   python bounded.py --deadline-at   (prints time.time() + the deadline resolve() gives, for a caller's poll)
  Copies the command's stdout and stderr through after it ends and exits with its status. On a limit it prints
  `bounded: <limit>: <cmd[0]> <cmd[1]>` on stderr
  (for `sh -c script name args...`, the wrapped command: `name args[0]`) and exits 124 (deadline) or 125 (too large).

Windows argument transport: a native command line cuts an argument with spaces at 8186 characters when bash.exe parses it, so
for `bash -c script $0 args...` the arguments after $0 are not put on the command line. They go to the child's stdin as UTF-8,
each followed by a NUL, then an end marker; a prelude in front of the script reads them back into "$@" and empties stdin. Nothing
reaches disk. A missing marker (a runner that died mid-write, a bash older than 4.4) exits 126 without running the script.

Output is read from pipes as the command writes it and kept in memory, never on disk: a stream stops being read once it passes
the byte bound, so neither memory nor disk can grow past it between two checks, and the tree is stopped at once. Secret mode
(--secret, secret=True), for commands that print a credential, runs the same way. After a limit a survivor holding a pipe is
let go after 5 s. A command that exits while a process it started still holds a pipe gets 2 s for its readers, then that
tree is stopped and the command's own status and output are returned. The process tree is stopped by PID only, never by name.

Process interface for callers with their own capture loop (review-run.sh, release.sh), all stdlib, all public:
  spawn(cmd, data=None, hook_env=None, **popen_kw) -> Popen   starts the command in its own process group (POSIX: new session;
      Windows: suspended, assigned to a job object, then resumed, so nothing it starts escapes). The job handle is p.job (None
      when there is none); stdin is DEVNULL, or the bytes in `data` written by a daemon thread. Raises OSError when the command
      cannot start. On Windows without a job object it writes `bounded: no job object: <reason>` to stderr and goes on without.
  kill(p)             stops every process the command started, also when the command itself has already exited. Windows:
      TerminateJobObject, or `taskkill /T /F /PID` for a run without a job; POSIX: killpg. By PID or job only, never by name.
  close_job(p)        closes the job handle (the job has no kill-on-close: a finished command's detached helpers live on).
  watch_exit(p, wake) -> ExitWatcher   a daemon thread blocked in p.wait(); on exit it records time.monotonic() and sets the
      `wake` event the caller passes in. watcher.exit_time() is that time, or None while the command runs (it polls p.poll()
      if the thread could not start); watcher.wait(timeout) waits for the exit.
"""
import os
import signal
import subprocess
import sys
import threading
import time
from collections import namedtuple

DEADLINE = 120
PAGED_DEADLINE = 300
MAX_BYTES = 32 * 1024 * 1024
MAX_PAGES = 50
GRACE = 2  # seconds the readers get to reach EOF after the command exits
POLL = 0.02  # seconds the loop waits between two checks

DEADLINE_EXCEEDED = "deadline_exceeded"
RESPONSE_TOO_LARGE = "response_too_large"

Result = namedtuple("Result", "rc stdout stderr limit")


def kill_tree(pid):
    """Stop a process and everything it started, BY PID. Never by name or pattern. Use kill(p) for a spawned command: on
    Windows only its job object reaches the children of a command that has already exited."""
    if os.name == "nt":
        subprocess.run(["taskkill", "/T", "/F", "/PID", str(pid)], capture_output=True)
        return
    try:
        os.killpg(pid, signal.SIGKILL)  # the command is its own session and group leader
    except OSError:
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass


CREATE_SUSPENDED = 0x00000004
_K32 = _NT = None


def _win_api():
    """kernel32 and ntdll with typed signatures (handles are pointer-sized; a bare int would be cut to 32 bits)."""
    global _K32, _NT
    if _K32 is None:
        import ctypes
        from ctypes import wintypes
        k, nt = ctypes.WinDLL("kernel32", use_last_error=True), ctypes.WinDLL("ntdll")
        k.CreateJobObjectW.argtypes, k.CreateJobObjectW.restype = [ctypes.c_void_p, wintypes.LPCWSTR], ctypes.c_void_p
        k.AssignProcessToJobObject.argtypes, k.AssignProcessToJobObject.restype = [ctypes.c_void_p, ctypes.c_void_p], wintypes.BOOL
        k.TerminateJobObject.argtypes, k.TerminateJobObject.restype = [ctypes.c_void_p, wintypes.UINT], wintypes.BOOL
        k.CloseHandle.argtypes, k.CloseHandle.restype = [ctypes.c_void_p], wintypes.BOOL
        nt.NtResumeProcess.argtypes, nt.NtResumeProcess.restype = [ctypes.c_void_p], ctypes.c_long
        _K32, _NT = k, nt
    return _K32, _NT


def _hook(env, name):
    """A test override from the run's environment (the one the command gets), else this process's; None when unset."""
    return (env if env is not None else os.environ).get(name)


def _make_job(p, env):
    """A job object holding process p, or OSError. No kill-on-close limit: a command that finished normally keeps the
    detached helpers it left (git's background maintenance), as it does on POSIX."""
    import ctypes
    if _hook(env, "SPECWRIGHT_TEST_NO_JOB") == "1":
        raise OSError("SPECWRIGHT_TEST_NO_JOB is set")
    k, _ = _win_api()
    job = k.CreateJobObjectW(None, None)
    if not job:
        raise ctypes.WinError(ctypes.get_last_error())
    if not k.AssignProcessToJobObject(job, int(p._handle)):
        err = ctypes.WinError(ctypes.get_last_error())
        k.CloseHandle(job)
        raise err
    return job


def _resume(p):
    status = _win_api()[1].NtResumeProcess(int(p._handle))
    if status != 0:
        raise OSError("NtResumeProcess failed: NTSTATUS 0x%08x" % (status & 0xFFFFFFFF))


def _record_spawn(pid, child_env):
    """Test hook SPECWRIGHT_TEST_SPAWN_DIR (POSIX): create an empty file named `pid` in the directory this process's
    environment names, and in the one the child's env names when that is another. A failed write is ignored."""
    dirs = []
    for env in (os.environ, child_env):
        d = (env or {}).get("SPECWRIGHT_TEST_SPAWN_DIR")
        if d and d not in dirs:
            dirs.append(d)
    for d in dirs:
        try:
            open(os.path.join(d, str(pid)), "w").close()
        except OSError:
            pass


def spawn(cmd, data=None, hook_env=None, **kw):
    """Popen with a stopping handle on the whole tree (see the module header). `hook_env` is the environment that carries the
    test overrides when it is not the command's own (default: kw["env"], else this process's). Returns p with p.stdin None
    (only the writer thread owns it), and p.job."""
    hook_env = kw.get("env") if hook_env is None else hook_env
    if os.name == "nt":
        kw["creationflags"] = kw.get("creationflags", 0) | CREATE_SUSPENDED
    else:
        kw.setdefault("start_new_session", True)
    p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL if data is None else subprocess.PIPE, bufsize=0, **kw)
    p.job = None
    if os.name != "nt":
        _record_spawn(p.pid, kw.get("env"))
    if os.name == "nt":
        try:
            p.job = _make_job(p, hook_env)
        except OSError as e:
            sys.stderr.write("bounded: no job object: %s\n" % (str(e).strip() or e.__class__.__name__))
            sys.stderr.flush()
        try:
            _resume(p)
        except OSError:
            kill(p)
            p.wait()
            close_job(p)
            for s in (p.stdin, p.stdout, p.stderr):
                if s:
                    s.close()
            raise
    if data is not None:
        stream, p.stdin = p.stdin, None

        def write():
            try:
                stream.write(data)
            except (OSError, ValueError):
                pass
            finally:
                try:
                    stream.close()
                except (OSError, ValueError):
                    pass
        threading.Thread(target=write, daemon=True).start()
    return p


def kill(p):
    """Stop every process the spawned command started, also when the command itself has already exited."""
    job = getattr(p, "job", None)
    if job is not None and os.name == "nt":
        if _win_api()[0].TerminateJobObject(job, 1):
            try:
                p.kill()  # the job holds it too; this only makes sure a failed assignment race cannot leave it
            except OSError:
                pass
            return
    kill_tree(p.pid)


def close_job(p):
    job, p.job = getattr(p, "job", None), None
    if job is not None and os.name == "nt":
        _win_api()[0].CloseHandle(job)


class ExitWatcher:
    """Records when a process exited, as the thread that blocks on it sees it, not at a later poll."""

    def __init__(self, p, wake):
        self.p, self.at, self.wake = p, None, wake
        try:
            self.thread = threading.Thread(target=self._run, daemon=True)
            self.thread.start()
        except RuntimeError:  # no thread: exit_time() polls instead and keeps the old window
            self.thread = None

    def _run(self):
        try:
            self.p.wait()
        except Exception:
            return
        self.at = time.monotonic()
        self.wake.set()

    def exit_time(self):
        """time.monotonic() at which the process exited, or None while it runs."""
        if self.at is None and self.thread is None and self.p.poll() is not None:
            self.at = time.monotonic()
        return self.at

    def wait(self, timeout):
        if self.thread is not None:
            self.thread.join(timeout)
        else:
            try:
                self.p.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                pass


def watch_exit(p, wake):
    return ExitWatcher(p, wake)


def _number(env, name, default, cast=float):
    try:
        v = cast((env if env is not None else os.environ).get(name, ""))
        return v if v >= 0 else default
    except (TypeError, ValueError):
        return default


def _poll(env):
    """The loop's wait interval: POLL, or SPECWRIGHT_TEST_POLL when the run's environment sets it."""
    return _number(env, "SPECWRIGHT_TEST_POLL", POLL)


def resolve(deadline, max_bytes, env, paged):
    """The deadline in seconds and the byte bound: arguments first, then the environment, then the defaults. The environment
    only lowers a default, never raises it. A deadline is capped to the time left until SPECWRIGHT_NET_DEADLINE_AT."""
    if deadline is None:
        default = PAGED_DEADLINE if paged else DEADLINE
        deadline = min(_number(env, "SPECWRIGHT_NET_PAGED_DEADLINE" if paged else "SPECWRIGHT_NET_DEADLINE", default), default)
    if max_bytes is None:
        max_bytes = min(_number(env, "SPECWRIGHT_NET_MAX_BYTES", MAX_BYTES, int), MAX_BYTES)
    at = _number(env, "SPECWRIGHT_NET_DEADLINE_AT", None)
    if at is not None:
        deadline = min(deadline, max(0.0, at - time.time()))
    return deadline, max_bytes


ARGV_END = "__SW_ARGV_END__"
ARGV_PRELUDE = (
    'mapfile -d "" -t __sw_argv; '
    '[ ${#__sw_argv[@]} -gt 0 ] && [ "${__sw_argv[${#__sw_argv[@]}-1]}" = %s ] || '
    '{ echo "bounded: argument transport failed" >&2; exit 126; }; '
    'unset "__sw_argv[${#__sw_argv[@]}-1]"; set -- "${__sw_argv[@]}"; unset __sw_argv; exec </dev/null' % ARGV_END)


def _transport(cmd):
    """(cmd, stdin bytes or None). On Windows a `bash -c script $0 args...` keeps its script and $0 on the command line and
    sends the arguments after $0 on stdin."""
    if os.name != "nt" or len(cmd) < 4 or cmd[1] != "-c" or os.path.basename(cmd[0]).lower().split(".")[0] != "bash":
        return cmd, None
    data = b"".join(a.encode("utf-8") + b"\0" for a in cmd[4:]) + ARGV_END.encode("ascii") + b"\0"
    return [cmd[0], "-c", ARGV_PRELUDE + "; " + cmd[2], cmd[3]], data


def _piped(cmd, data, deadline, max_bytes, env, cwd):
    try:
        p = spawn(cmd, data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=cwd, env=env)
    except OSError as e:
        return 127, b"", str(e).encode("utf-8", "replace"), None
    bufs, over, wake = (bytearray(), bytearray()), threading.Event(), threading.Event()
    # over: a stream passed its bound. wake: the loop should look again (a bound, an EOF, or the command's exit).

    def drain(stream, buf):  # reads as the command writes, so the bound holds in memory while it runs
        try:
            fd = stream.fileno()
            while True:
                chunk = os.read(fd, 65536)
                if not chunk:
                    return
                buf += chunk
                if len(buf) > max_bytes:
                    over.set()
                    return
        except (OSError, ValueError):
            pass
        finally:
            wake.set()

    readers = [threading.Thread(target=drain, args=(s, b), daemon=True) for s, b in zip((p.stdout, p.stderr), bufs)]
    for t in readers:
        t.start()
    watcher = watch_exit(p, wake)
    poll = _poll(env)
    try:
        end, limit = time.monotonic() + deadline, None  # monotonic: a stepped clock cannot move a deadline
        while True:
            wake.clear()  # before the checks, so a set that follows them is not lost
            if over.is_set():
                limit = RESPONSE_TOO_LARGE
                break
            exited, now = watcher.exit_time(), time.monotonic()
            if (exited is None or exited >= end) and now >= end:
                limit = DEADLINE_EXCEEDED  # still running when the deadline passed, even if its exit is seen only now
                break
            if exited is not None and (not any(t.is_alive() for t in readers) or now - exited >= GRACE):
                break  # an exit recorded before the deadline is never reported as a deadline
            left = end - now
            if left <= 0:
                break
            wake.wait(min(poll, left, GRACE - (now - exited) if exited is not None else poll))
        if limit is None and any(t.is_alive() for t in readers):
            kill(p)  # a process the command started still holds a pipe: stop it; the command's own result stands
            for t in readers:
                t.join(1)
        if limit is None and over.is_set():  # a bound passed between the loop's checks, just before the exit
            limit = RESPONSE_TOO_LARGE
        if limit:
            kill(p)
            stop = time.monotonic() + 5  # collect what the killed tree left; a survivor holding a pipe is let go after 5 s
            watcher.wait(5)
            for t in readers:
                t.join(max(0, stop - time.monotonic()))
            return None, b"", b"", limit
        return p.returncode, bytes(bufs[0]), bytes(bufs[1]), None
    finally:
        if p.poll() is None:
            kill(p)
        close_job(p)
        for s, t in zip((p.stdout, p.stderr), readers):
            if s and not t.is_alive():  # a reader still blocked on a survivor's pipe keeps its end
                try:
                    s.close()
                except (OSError, ValueError):
                    pass


def _run(cmd, deadline, max_bytes, env, cwd, paged, secret):
    deadline, max_bytes = resolve(deadline, max_bytes, env, paged)
    cmd, data = _transport(list(cmd))
    return _piped(cmd, data, deadline, max_bytes, env, cwd)  # secret mode reads the same way; the flag stays for callers


def run_bounded(cmd, deadline=None, max_bytes=None, env=None, cwd=None, paged=False, secret=False):
    rc, out, err, limit = _run(cmd, deadline, max_bytes, env, cwd, paged, secret)
    return Result(rc, out.decode("utf-8", "replace"), err.decode("utf-8", "replace"), limit)


def main(argv):
    if argv == ["--deadline-at"]:
        sys.stdout.write("%.6f\n" % (time.time() + resolve(None, None, None, False)[0]))
        return 0
    flags = []
    while argv and argv[0] != "--":
        flags.append(argv.pop(0))
    cmd = argv[1:]
    if not cmd or any(f not in ("--paged", "--secret") for f in flags):
        sys.stderr.write("usage: bounded.py [--paged] [--secret] -- cmd...\n")
        return 2
    rc, out, err, limit = _run(cmd, None, None, None, None, "--paged" in flags, "--secret" in flags)
    if limit:
        shell = os.path.basename(cmd[0]).lower().split(".")[0] in ("sh", "bash")
        named = cmd[3:5] if shell and len(cmd) > 3 and cmd[1] == "-c" else cmd[:2]  # sh -c 'exec gh "$@"' gh api: name gh api
        sys.stderr.write("bounded: %s: %s\n" % (limit, " ".join(named)))
        return 124 if limit == DEADLINE_EXCEEDED else 125
    sys.stdout.buffer.write(out)
    sys.stdout.buffer.flush()
    sys.stderr.buffer.write(err)
    sys.stderr.buffer.flush()
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
