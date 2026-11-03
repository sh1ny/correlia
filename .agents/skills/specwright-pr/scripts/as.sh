#!/usr/bin/env bash
# Run a command as one specific GitHub login, fenced against concurrent
# `gh auth switch`: the token is resolved per process, its identity is
# verified, and both gh (GH_TOKEN) and git push (credential helper) use it.
#
# Usage: bash as.sh <login> <command> [args...]
#        bash as.sh --resolve
#   bash as.sh KintsugiBot gh pr create ...
#   bash as.sh KintsugiBot git push -u origin HEAD
#   bash as.sh KintsugiBot bash pr-snapshot.sh 12
# --resolve: no login is configured, so read the active github.com account once,
# check gh has its token, and print the login (nothing else on stdout). A run keeps
# that login and passes it to every later as.sh call; GH_TOKEN/GITHUB_TOKEN never
# pick it.
# Needs bash, gh 2.40+ and Python 3.8+ (exit 2 `no_python` without it). Each gh lookup here has a deadline: a hung one exits 3
# naming `deadline_exceeded` (or `response_too_large`) and the command, and the fenced command is not run.
# Exit 3: no credential for <login> (or no active account for --resolve), the token
# resolves to someone else, gh is older than 2.40 (no per-account token lookup), or
# the command could use a github.com URL with userinfo (below). Exit 2: usage.
# Inside, gh targets github.com only: GH_HOST, GH_ENTERPRISE_TOKEN and
# GITHUB_ENTERPRISE_TOKEN are unset along with GH_TOKEN and GITHUB_TOKEN. The three
# enterprise variables are saved first (AS_SH_ORIG_*, listed in AS_SH_ORIG_SET) so an
# unfenced non-GitHub git can get them back; the token variables are never saved.
# Inside, git cannot use SSH or prompt; HTTPS credentials go to github.com only.
# A github.com URL with userinfo (a token, a password or a bare username) is
# refused before the command runs: in a git work tree, any remote's fetch or push
# URL, any url.<base>.insteadOf / pushInsteadOf rule that adds it, and any argument
# (including a `git -c key=value`). The fence supplies the credential; the message
# names the remote and kind with the userinfo masked, and no config is changed.
# A trailing dot (github.com., any letter case) is github.com; github.com.example.org
# is not. URLs for other hosts are ignored.
# Run git from inside the target repo: the URL check and the http extraHeader
# scrub cover the current repository only, so a git command that selects
# another one (-C, --git-dir, --work-tree) is refused (exit 3).
# but: only `but pull` runs (it runs the system `git fetch`, so the same transport rules
# apply); -C/--current-dir and every other but subcommand are refused (exit 3).
# jj: only `jj git push` and `jj git fetch` run (they use a Git child process, so the
# same transport rules apply); -R/--repository, --config/--config-file and every other
# jj subcommand are refused (exit 3).
set -euo pipefail

resolve=
if [ "${1:-}" = --resolve ]; then
  [ $# -eq 1 ] || { echo "as.sh: --resolve takes no other arguments" >&2; exit 2; }
  resolve=1
else
  login=${1:?usage: as.sh <login> <command> [args...] | as.sh --resolve}
  shift
  [ $# -gt 0 ] || { echo "as.sh: no command given" >&2; exit 2; }
fi

# Keep the caller's values of what the fence below overrides, once: an as.sh started
# inside another keeps the outer originals. A fenced script that runs plain git for
# a non-GitHub remote (pr-pair.sh) restores them, so that remote keeps the user's own
# SSH, prompts, credential helpers and enterprise host settings (GH_HOST,
# GH_ENTERPRISE_TOKEN, GITHUB_ENTERPRISE_TOKEN). GH_TOKEN and GITHUB_TOKEN are never
# kept. Only variables that were set are recorded. This runs before the unset below.
if [ -z "${AS_SH_ORIG_SET+x}" ]; then
  AS_SH_ORIG_SET=
  for v in GH_HOST GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN \
           GIT_SSH_COMMAND GIT_TERMINAL_PROMPT GCM_INTERACTIVE GIT_ASKPASS SSH_ASKPASS GIT_CONFIG_COUNT \
           $(compgen -e | grep -E '^GIT_CONFIG_(KEY|VALUE)_[0-9]+$' || true); do
    [ -n "${!v+x}" ] || continue
    export "AS_SH_ORIG_$v=${!v}"
    AS_SH_ORIG_SET="$AS_SH_ORIG_SET $v"
  done
  export AS_SH_ORIG_SET
fi

# gh must target github.com with a token this script picked, whatever the
# environment says (an empty GH_HOST counts as set, so unset it too).
unset GH_TOKEN GITHUB_TOKEN GH_HOST GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN

# Every gh call here runs through bounded.py (a deadline and a byte bound on stdout and stderr; see its header): a stuck
# network ends as exit 3 naming the limit, never a hang. SW_SECRET=1 keeps what the lookups print (the token)
# off disk. Python 3.8+ runs it. Only these lookups are bounded: the fenced command at the end is not.
py=
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1; then py=$c; break; fi
done
[ -n "$py" ] || { echo "as.sh: no_python: needs python 3.8+ for its bounded gh calls" >&2; exit 2; }
# native Windows python cannot run an MSYS path: hand it Windows paths (-m: forward slashes bash accepts)
SW_DIR=$(cd "$(dirname "$0")" && pwd -P)
SW_BASH=${BASH:-bash}
if command -v cygpath >/dev/null 2>&1; then SW_DIR=$(cygpath -m "$SW_DIR"); SW_BASH=$(cygpath -w "$SW_BASH"); fi
SW_SECRET=1
gh() { "$py" -I "$SW_DIR/bounded.py" ${SW_PAGED:+--paged} ${SW_SECRET:+--secret} -- "$SW_BASH" -c 'exec gh "$@"' gh "$@"; }
# a lookup that hit a limit (bounded.py exits 124 deadline, 125 too large, 126 argument transport failed) stops here, before the message for "no credential"
limit_stop() {  # <status> <command>
  case $1 in
    124) echo "as.sh: deadline_exceeded: $2" >&2; exit 3 ;;
    125) echo "as.sh: response_too_large: $2" >&2; exit 3 ;;
    126) echo "as.sh: argument transport failed: $2" >&2; exit 3 ;;
  esac
}

# Without `gh auth token --user` the only per-account lookup is a shared
# `gh auth switch`, which other agents race on - so refuse rather than fall back.
rc=0; help=$(gh auth token --help 2>&1) || rc=$?
limit_stop "$rc" "gh auth token --help"
case $help in
  *--user*) ;;
  *) echo "as.sh: $(gh --version 2>/dev/null | head -n 1 || echo 'gh not found') cannot look up a token per account (gh auth token --user, gh 2.40+); upgrade gh" >&2; exit 3 ;;
esac

if [ -n "$resolve" ]; then
  rc=0; login=$(gh api --hostname github.com user --jq .login 2>/dev/null) || rc=$?
  limit_stop "$rc" "gh api user"
  [ "$rc" -eq 0 ] || login=
  [ -n "$login" ] || { echo "as.sh: no active gh account for github.com; run 'gh auth login' or set github.login in openspec/specwright.yaml (GH_TOKEN and GITHUB_TOKEN are not used to pick the login)" >&2; exit 3; }
  rc=0; gh auth token --hostname github.com --user "$login" >/dev/null 2>&1 || rc=$?
  limit_stop "$rc" "gh auth token --user $login"
  [ "$rc" -eq 0 ] || { echo "as.sh: no gh credential for the active account '$login'; run 'gh auth login' or set github.login in openspec/specwright.yaml (GH_TOKEN and GITHUB_TOKEN are not used to pick the login)" >&2; exit 3; }
  printf '%s\n' "$login"
  exit 0
fi

rc=0; token=$(gh auth token --hostname github.com --user "$login" 2>/dev/null) || rc=$?
limit_stop "$rc" "gh auth token --user $login"
[ "$rc" -eq 0 ] || token=
[ -n "$token" ] || { echo "as.sh: no gh credential for '$login' (gh auth login)" >&2; exit 3; }
export GH_TOKEN=$token

rc=0; actual=$(gh api --hostname github.com user --jq .login 2>/dev/null) || rc=$?
limit_stop "$rc" "gh api user"
[ "$rc" -eq 0 ] || actual=
[ "$actual" = "$login" ] || { echo "as.sh: token resolves to '$actual', expected '$login'; refusing" >&2; exit 3; }

# URL check: the helper below answers github.com with the verified token, so a
# github.com URL that carries its own userinfo would authenticate as someone
# else (or as a bare username the fence cannot tell from a token). Refuse it
# before anything runs; never print or change the secret.
lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }
gh_url() { [[ $(lower "$1") =~ ^[a-z][a-z0-9+.-]*://([^/]*@)?github\.com\.?([:/]|$) ]]; }
gh_userinfo() { [[ $(lower "$1") =~ ^[a-z][a-z0-9+.-]*://[^/]*@github\.com\.?([:/]|$) ]]; }
has_userinfo() { [[ $1 =~ ^[A-Za-z][A-Za-z0-9+.-]*://[^/]*@ ]]; }
mask() { printf '%s' "$1" | sed 's#^\([A-Za-z][A-Za-z0-9+.-]*://\)[^/]*@#\1***@#'; }
refuse() { # <what names it> <masked url>
  echo "as.sh: $1 has credentials in a github.com URL ($2); remove the userinfo, the fence supplies the credential; refusing" >&2
  exit 3
}
check_rule() { # <base> <rewritten prefix> <what names it>
  local base=$1 prefix=$2
  has_userinfo "$base" || return 0
  if gh_url "$base" || gh_url "$prefix"; then refuse "$3" "$(mask "$base")"; fi
}
check_arg() {
  local a=$1 v
  if gh_userinfo "$a"; then refuse "argument" "$(mask "$a")"; fi
  v=${a#*=}
  if [ "$v" != "$a" ] && gh_userinfo "$v"; then refuse "argument" "$(mask "$v")"; fi
  if [[ $(lower "$a") =~ ^url\.(.+)\.(pushinsteadof|insteadof)=(.*)$ ]]; then
    k=${a%%=*} k=${k#[Uu][Rr][Ll].} k=${k%.*}
    check_rule "$k" "${a#*=}" "argument"
  fi
}
for a in "$@"; do check_arg "$a"; done

# git's own options, before the subcommand: one that selects another repository
# would escape the checks below, which read the repository as.sh starts in.
case ${1##*/} in
  git|git.exe)
    i=2
    while [ "$i" -le $# ]; do
      a=${!i}
      case $a in
        -C|-C*|--git-dir|--git-dir=*|--work-tree|--work-tree=*)
          echo "as.sh: git $a selects another repository; run as.sh from inside it; refusing" >&2; exit 3 ;;
        -c|--namespace|--super-prefix) i=$((i + 2)) ;;
        -*) i=$((i + 1)) ;;
        *) break ;;
      esac
    done ;;
esac

# but (GitButler): only `but pull` is fenced. It fetches by running the system `git fetch`,
# which takes the transport settings below from the environment. -C/--current-dir selects
# another repository (the checks here read the one as.sh starts in), so it is refused
# anywhere before `--`, and so is every other subcommand.
case ${1##*/} in
  but|but.exe)
    for a in "${@:2}"; do
      [ "$a" != -- ] || break
      case $a in
        -C|-C?*|--current-dir|--current-dir=*)
          echo "as.sh: but $a selects another repository; run as.sh from inside it; refusing" >&2; exit 3 ;;
      esac
    done
    w1= i=2
    while [ "$i" -le $# ]; do
      a=${!i}
      case $a in
        --) break ;;
        -*) i=$((i + 1)) ;;
        *) w1=$a; break ;;
      esac
    done
    if [ "$w1" != pull ]; then
      echo "as.sh: only 'but pull' is fenced; refusing 'but${w1:+ $w1}'" >&2; exit 3
    fi ;;
esac

# jj: only `jj git push` and `jj git fetch` are fenced. They run a Git child process,
# which takes the transport settings below from the environment. Any option that selects
# another repository or config (-R, --repository, --config, --config-file; global options
# may follow the subcommand) or any other subcommand is refused before it runs.
case ${1##*/} in
  jj|jj.exe)
    for a in "${@:2}"; do
      [ "$a" != -- ] || break
      case $a in
        -R|-R?*|--repository|--repository=*)
          echo "as.sh: jj $a selects another repository; run as.sh from inside it; refusing" >&2; exit 3 ;;
        --config|--config=*|--config-file|--config-file=*)
          echo "as.sh: jj $a selects another config; refusing" >&2; exit 3 ;;
      esac
    done
    w1= w2= i=2
    while [ "$i" -le $# ]; do
      a=${!i}
      case $a in
        --) break ;;
        --color|--at-op|--at-operation) i=$((i + 2)) ;;
        -*) i=$((i + 1)) ;;
        *) if [ -z "$w1" ]; then w1=$a; else w2=$a; break; fi; i=$((i + 1)) ;;
      esac
    done
    if [ "$w1" != git ] || { [ "$w2" != push ] && [ "$w2" != fetch ]; }; then
      echo "as.sh: only 'jj git push' and 'jj git fetch' are fenced; refusing 'jj ${w1}${w2:+ $w2}'" >&2; exit 3
    fi ;;
esac

if [ "$(git rev-parse --is-inside-work-tree 2>/dev/null || true)" = true ]; then
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    while IFS= read -r u; do
      ! gh_userinfo "$u" || refuse "remote '$r' fetch URL" "$(mask "$u")"
    done < <(git remote get-url --all "$r" 2>/dev/null || true)
    while IFS= read -r u; do
      ! gh_userinfo "$u" || refuse "remote '$r' push URL" "$(mask "$u")"
    done < <(git remote get-url --push --all "$r" 2>/dev/null || true)
  done < <(git remote 2>/dev/null || true)
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key=${line%% *} val=
    case $line in *' '*) val=${line#* } ;; esac
    base=${key#url.} base=${base%.*}
    check_rule "$base" "$val" "rewrite rule url.$(mask "$base").${key##*.}"
  done < <(git config --get-regexp '^url\..*\.(insteadof|pushinsteadof)$' 2>/dev/null || true)
fi

# git: the identity is enforced at the transport, not by reading the command
# line. SSH would authenticate with whatever key SSH picks, so it is disabled
# (GIT_SSH_COMMAND overrides core.sshCommand, even one passed with -c); HTTPS
# gets the pinned token for github.com only; nothing may prompt. Whatever
# remote, push URLs or options a git command uses, it can authenticate as
# <login> or not at all.
export GIT_SSH_COMMAND='sh -c "echo as.sh: SSH is disabled - push over https://github.com so the identity can be pinned >&2; exit 1"'
export GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never GIT_ASKPASS= SSH_ASKPASS=

# Command-scoped git config, never written to any config file. First empty
# every inherited http extraHeader: an Authorization header there would
# authenticate the push as someone else. An empty value resets only its own
# key - a URL-scoped header outranks a plain reset - so each key in effect
# here is reset by name. Then drop inherited credential helpers and answer
# with GH_TOKEN - for https://github.com only, never another host. The helper
# drops an explicit port (git sends host=github.com.:443 for such a URL) and
# then one trailing dot before it compares the host.
n=0
cfg() { export "GIT_CONFIG_KEY_$n=$1" "GIT_CONFIG_VALUE_$n=$2"; n=$((n + 1)); }
cfg http.extraHeader ''
while IFS= read -r key; do cfg "$key" ''; done \
  < <(git config --name-only --get-regexp '^http\..+\.extraheader$' 2>/dev/null | sort -u || true)
cfg credential.helper ''
cfg credential.helper '!f() { [ "$1" = get ] || exit 0; h= p=; while IFS= read -r l && [ -n "$l" ]; do case $l in host=*) h=${l#host=} ;; protocol=*) p=${l#protocol=} ;; esac; done; h=$(printf %s "$h" | tr A-Z a-z); h=${h%:*}; h=${h%.}; [ "$h" = github.com ] && [ "$p" = https ] || exit 0; echo username=x-access-token; echo "password=$GH_TOKEN"; }; f'
export GIT_CONFIG_COUNT=$n

exec "$@"
