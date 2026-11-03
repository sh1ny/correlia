#!/usr/bin/env bash
# One-call PR snapshot: state, checks, unresolved threads, unhandled comments
# and reviews, as one JSON line. Needs gh (uses gh's built-in --jq) and Python 3.8+:
# bounded.py gives every gh call a deadline and a size bound, so a hung call ends as
# `deadline_exceeded` on stderr (exit 1 in a watch); without Python, exit 2 `no_python`.
# The same bound runs the reviewer evaluator (reviewers.py, see below).
#
# Usage: bash pr-snapshot.sh [PR-number|PR-url] [--repo owner/name] [--logs]
#                            [--reviewer-config FILE]
#                            [--wait [--timeout SECONDS] [--interval SECONDS] [--until attention]]
#        bash pr-snapshot.sh --full NODE_ID [--repo owner/name]
#   (no PR)   the PR for the current branch
#   --reviewer-config  the reviewer config file pr-pair.sh writes (context / policy):
#             which logins to watch, their role and timeout, and how each one's report
#             is recognised. The file is checked by `reviewers.py --check-config` before
#             any gh call: a missing file, bad JSON, a bad key or pattern exits 2 with one
#             line naming the file or `<login>: report.<key>`. This script knows no
#             reviewer by name: it gathers what the configured logins wrote, in full, into
#             a system-temp file (removed on exit, also when the evaluator is stopped at its
#             deadline) and reviewers.py decides, then adds "reviewers" (login, role,
#             timeout, state, by, evidence), "reviewer_config" (the file's digest) and "now".
#             Without the flag there are no reviewers ("reviewers": [], "reviewer_config":
#             null). The removed flag '--reviewer' (LOGIN:ROLE:SECONDS) exits 2 naming the new flag.
#   --logs    append the last 80 lines of each failing run's failed-step log
#   --full    read one item whole: the NODE_ID of a thread comment, PR comment or review
#             (the snapshot's "id"). Prints {"ok":true,"id","kind","body","rev","url"}
#             with the raw body; kind is thread_comment | comment | review; rev is the
#             item's own revision (lastEditedAt, else createdAt/submittedAt), never what
#             pr-reply.sh --rev takes. An unknown id prints {"ok":false,"error":"not_found"}
#             and exits 1; exits 3 when GitHub cannot be read. One call; no snapshot, no
#             --reviewer, no watch claim. Read every item with "clipped":true this way.
#   --wait    poll inside this process; print {"wake":..., "snapshot":...}
#             once anything changes (checks, threads, comments, reviews, head,
#             state, edits, a list getting cut off) or the timeout passes
#             (default 1800s, interval 300s) - elapsed time from the start, polls
#             included, and never slept past; "waited" is the elapsed seconds. Each
#             poll, the first snapshot included, has one 120 s deadline for all its gh
#             calls (SPECWRIGHT_NET_DEADLINE, a non-negative number of seconds, lowers it), so the timeout is reported
#             within ~130 s of passing. "incomplete" at once if the first good
#             snapshot is already cut off; exits 1 if the last poll failed (a failed
#             first snapshot has no base: the first good poll becomes it).
#             One watcher per PR on this machine: a newer --wait on the same
#             PR (from any agent; owner/name compared case-insensitively) takes
#             over, and the older one exits 4 before its next poll, so a lost
#             or forgotten watcher stops spending the account's API budget. A
#             watcher's exit never ends a newer watcher's ownership. If the
#             state directory cannot be created, it polls unowned and says so
#             on stderr.
#   --until attention  (with --wait only; "quiet" or any other mode exits 2 before any gh
#             call) keep waiting while a poll differs from the first good snapshot only
#             in checks or merge state, a CI check ("checks":{"ci_pending"} above 0: a
#             check that is not a reviewer's own) is still pending, no check fails that
#             was not failing in that snapshot, and the merge state is not DIRTY. Any
#             other difference wakes "changed", a reviewer's state change included. Skipped
#             polls add no polls and no gh
#             calls; the wake JSON counts them as "filtered" (always present with
#             --wait, 0 without --until). A "timeout" wake still means nothing else
#             changed, filtered polls included. The snapshot's "attn" is "sig" without
#             the checks and merge state; "fail_names" are the failing checks' names,
#             base64 each.
# "head_cutoff": {source, at} says where reports start to count and each
# reviewer's timeout starts: source push | first_seen | first_seen_unsaved (the
# push is not in the activity log; see prepare_cfg).
# "clipped": true on a thread comment, PR comment or review means its body was cut
# at 2500 (thread comments) or 1200 (the others) characters; stripping HTML comments
# alone does not count.
# "complete": false means a list was cut off at its page size - do not treat
# missing items as absent.
# Wrap with as.sh to pin the GitHub identity.
set -euo pipefail

# Every gh call runs through bounded.py (a deadline and a byte bound on stdout and stderr; see its header), so a stuck network or a
# huge response ends as a named limit instead of a hang. Python 3.8+ runs it. The wrapper starts gh through bash, so the
# same call works where gh is a shell shim.
py=
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1; then py=$c; break; fi
done
[ -n "$py" ] || { echo 'pr-snapshot.sh: no_python: needs python 3.8+ for its bounded gh calls' >&2; exit 2; }
# native Windows python cannot run an MSYS path: hand it Windows paths (-m: forward slashes bash accepts)
SW_DIR=$(cd "$(dirname "$0")" && pwd -P)
SW_BASH=${BASH:-bash}
if command -v cygpath >/dev/null 2>&1; then SW_DIR=$(cygpath -m "$SW_DIR"); SW_BASH=$(cygpath -w "$SW_BASH"); fi
gh() { "$py" -I "$SW_DIR/bounded.py" ${SW_PAGED:+--paged} ${SW_SECRET:+--secret} -- "$SW_BASH" -c 'exec gh "$@"' gh "$@"; }

pr= repo= full= logs=0 wait=0 timeout=1800 interval=300 rcfg= rcfg_set=0 until=
while [ $# -gt 0 ]; do
  case $1 in
    --repo) repo=${2:?--repo needs owner/name}; shift 2 ;;
    --reviewer) echo "pr-snapshot: '--reviewer' is gone; pass the reviewers as --reviewer-config FILE (pr-pair.sh context writes it)" >&2; exit 2 ;;
    --reviewer-config) rcfg=${2:?--reviewer-config needs a file}; rcfg_set=1; shift 2 ;;
    --logs) logs=1; shift ;;
    --full) full=${2:?--full needs a node id}; shift 2 ;;
    --wait) wait=1; shift ;;
    --timeout) timeout=${2:?--timeout needs seconds}; shift 2 ;;
    --until) until=${2:?--until needs a mode (attention)}; shift 2 ;;
    --interval)
      interval=${2:?--interval needs seconds}
      printf '%s' "$interval" | grep -Eq '^[1-9][0-9]*$'         || { echo "pr-snapshot: bad --interval '$2' (want whole seconds > 0)" >&2; exit 2; }
      shift 2 ;;
    https://*/pull/*)
      repo=$(printf '%s' "$1" | sed -E 's#https://[^/]+/([^/]+/[^/]+)/pull/.*#\1#')
      pr=$(printf '%s' "$1" | sed -E 's#.*/pull/([0-9]+).*#\1#'); shift ;;
    [0-9]*) pr=$1; shift ;;
    *) echo "pr-snapshot: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
if [ -n "$until" ]; then
  [ "$until" = attention ] || { echo "pr-snapshot: bad --until '$until' (want attention)" >&2; exit 2; }
  [ "$wait" = 1 ] || { echo "pr-snapshot: --until needs --wait" >&2; exit 2; }
fi
if [ -n "$full" ]; then
  printf '%s' "$full" | grep -Eq '^[A-Za-z0-9_=-]+$' \
    || { echo "pr-snapshot: bad --full id '$full'" >&2; exit 2; }
  out=$(gh api graphql -f id="$full" -f query='
    query($id:ID!){ node(id:$id) { __typename
      ... on IssueComment { id body createdAt lastEditedAt url }
      ... on PullRequestReview { id body submittedAt lastEditedAt url }
      ... on PullRequestReviewComment { id body createdAt lastEditedAt url } } }' \
    --jq '.data.node as $n
      | ({IssueComment: "comment", PullRequestReview: "review", PullRequestReviewComment: "thread_comment"}[$n.__typename // ""]) as $kind
      | if $kind == null then {ok: false, error: "not_found"}
        else {ok: true, id: $n.id, kind: $kind, body: ($n.body // ""),
              rev: ($n.lastEditedAt // $n.createdAt // $n.submittedAt), url: $n.url} end
      | tojson') || { echo "pr-snapshot: cannot read $full" >&2; exit 3; }
  printf '%s\n' "$out"
  # key order depends on the evaluator, so look for the error member, not a prefix
  case $out in *'"error":"not_found"'*) exit 1 ;; *) exit 0 ;; esac
fi
# The reviewer config is checked before any gh call. reviewers.py names the file or `<login>: report.<key>` on one stderr
# line; that line goes through and the exit is 2. logins: the configured logins as a JSON list body ("a","b").
rcfg_arg= logins=
if [ "$rcfg_set" = 1 ]; then
  rcfg_arg=$rcfg
  if command -v cygpath >/dev/null 2>&1; then rcfg_arg=$(cygpath -m "$rcfg"); fi
  chk=$("$py" -I "$SW_DIR/reviewers.py" --check-config "$rcfg_arg") || exit 2
  logins=$(printf '%s' "$chk" | sed -n 's/.*"logins":\[\([^]]*\)\].*/\1/p')
fi
[ -n "$repo" ] || repo=$(gh repo view --json owner,name --jq '.owner.login + "/" + .name')
[ -n "$pr" ] || pr=$(gh pr view --json number --jq .number)
owner=${repo%%/*} name=${repo#*/}

# Watch ownership: a directory of claims per PR,
# <state>/watch/v2/<owner>/<name>/<pr>/ (lower case). A claim is a file named
# <n>-<nonce>: a new --wait takes the highest number plus one and a nonce of
# its own, so no two claims ever share a name, even when a number comes back
# after the directory emptied. Claims order by number, then by nonce. A new
# claim removes the lower ones. A watcher owns the PR while its own file exists
# and no higher claim does, so the newest claim wins and an older watcher exits
# 4 before its next poll. Exit removes only the watcher's own file, by its
# unique name: no clock, and no read-then-remove. $HOME, not a temp dir,
# because each harness may have its own temp dir. 0.1.10's token file
# (watch/<owner>-<name>-<pr>) is not read and is left in place.
owner_file= claim_dir= claim_no= claim_nonce=
ownership_off() { echo "pr-snapshot: cannot create the watch state directory; ownership is off for PR $pr (this watcher polls unowned)" >&2; }
claim_list() {  # prints "<n> <nonce> <file name>" per claim in $claim_dir (a bare <n> has an empty nonce)
  local f b n
  for f in "$claim_dir"/*; do
    [ -e "$f" ] || continue
    b=${f##*/} n=${b%%-*}
    case $n in ''|*[!0-9]*) continue ;; esac
    case $b in *-*) echo "$((10#$n)) ${b#*-} $b" ;; *) echo "$((10#$n)) - $b" ;; esac
  done
}
claim_above() {  # <n> <nonce>: is claim <n>-<nonce> above ours?
  [ "$1" -gt "$claim_no" ] || { [ "$1" -eq "$claim_no" ] && [[ $2 > $claim_nonce ]]; }
}
claim_watch() {
  local base=${SPECWRIGHT_STATE_DIR:-$HOME/.cache/specwright} n s b top=0
  claim_dir="$base/watch/v2/$(printf '%s/%s/%s' "$owner" "$name" "$pr" | tr 'A-Z' 'a-z')"
  if ! mkdir -p "$claim_dir" 2>/dev/null; then claim_dir=; ownership_off; return 0; fi
  while read -r n s b; do if [ "$n" -gt "$top" ]; then top=$n; fi; done < <(claim_list)
  claim_no=$((top + 1)) claim_nonce=$(printf '%d.%05d%05d' "$$" "$RANDOM" "$RANDOM")
  owner_file="$claim_dir/$claim_no-$claim_nonce"
  if ! (set -C; : > "$owner_file") 2>/dev/null; then owner_file= claim_dir=; ownership_off; return 0; fi
  while read -r n s b; do
    [ "$b" = "${owner_file##*/}" ] || claim_above "$n" "$s" || rm -f "$claim_dir/$b" 2>/dev/null || true
  done < <(claim_list)
}
release_watch() {
  if [ -n "$owner_file" ]; then rm -f "$owner_file" 2>/dev/null || true; fi
  return 0
}
still_owner() {
  local n s b
  [ -n "$owner_file" ] || return 0
  [ -e "$owner_file" ] || return 1
  while read -r n s b; do
    if [ "$b" != "${owner_file##*/}" ] && claim_above "$n" "$s"; then return 1; fi
  done < <(claim_list)
  return 0
}

# One exit trap: the watch claim and the evaluator's material file (set by evaluate()) are both removed on any exit.
mat_file=
cleanup() {
  if [ -n "$mat_file" ]; then rm -f "$mat_file" 2>/dev/null || true; fi
  release_watch
}
trap cleanup EXIT

read -r -d '' QUERY <<'GQL' || true
query($owner:String!, $name:String!, $pr:Int!) {
  viewer { login }
  repository(owner:$owner, name:$name) { pullRequest(number:$pr) {
    number url state isDraft mergeable mergeStateStatus reviewDecision
    headRefName headRefOid baseRefName author { login }
    commits(last:1) { nodes { commit { statusCheckRollup { state contexts(first:100) { pageInfo { hasNextPage } nodes {
      __typename
      ... on CheckRun { name status conclusion detailsUrl startedAt completedAt checkSuite { app { slug } workflowRun { databaseId } } }
      ... on StatusContext { context state targetUrl createdAt }
    } } } } } }
    reviewThreads(first:100) { pageInfo { hasNextPage } nodes {
      id isResolved isOutdated path line originalLine
      comments(first:100) { totalCount nodes { id databaseId author { login } body createdAt lastEditedAt url
                                               reactionGroups { content viewerHasReacted } } }
    } }
    comments(last:100) { pageInfo { hasPreviousPage } nodes { id author { login } body createdAt lastEditedAt url
                                                              reactionGroups { content viewerHasReacted } } }
    reviews(last:100) { pageInfo { hasPreviousPage } nodes { id author { login } body state submittedAt lastEditedAt url
                                                             commit { oid }
                                                             reactionGroups { content viewerHasReacted } } }
  } }
}
GQL

read -r -d '' SHAPE <<'JQ' || true
def tidy: (. // "") | gsub("(?s)<!--.*?-->"; "") | gsub("\n{3,}"; "\n\n");
def clip($n): tidy
  | if length > $n then .[0:$n] + " …[truncated, see url]" else . end;
def clipped($n): tidy | length > $n;
# Unhandled: no reply of yours marks it handled, or it was edited after that reply.
# A marker may carry `rev=<revision it answered>` (pr-reply.sh --rev). $r maps an
# item id to the revisions its markers name; when there are any, the item is
# handled only while one of them is the item's current revision, whatever the
# times say (a reply that raced an edit therefore leaves the item listed).
# Markers without a revision (0.1.10) keep the time rule. Mixed versions: a
# 0.1.10 session that answers after an edit, once a 0.1.11 marker exists for the
# item, adds a marker without rev, which is ignored; the item is listed again
# and gets one more reply. That duplicate is the safe failure: an item never
# stays unanswered.
def unhandled($h; $r): .id as $id | (.lastEditedAt // .createdAt // .submittedAt // "") as $rev
  | if (($r[$id] // []) | length) > 0 then ([ $r[$id][] | select(. == $rev) ] | length) == 0
    else ($h[$id] == null) or ($rev > $h[$id]) end;
# The same rules for a "waiting on owner" reply: does one still hold the item?
def holds($w; $r): .id as $id | (.lastEditedAt // .createdAt // .submittedAt // "") as $rev
  | if (($r[$id] // []) | length) > 0 then ([ $r[$id][] | select(. == $rev) ] | length) > 0
    else ($w[$id] // "") >= $rev end;
# A 👍/👎 of yours answers an item too (the reaction-only answer to a
# reviewer's follow-up), but only until the item is edited after it. Other
# reactions (👀 and the like) answer nothing. reactionGroups say whether you
# reacted but not when; rtimes (id -> time of your latest 👍/👎) is filled by a
# second, small query only for the items in "recheck": reacted, then edited.
# Fetching reaction lists in the main query would cost ~200 points a call.
def thumbs: [ .reactionGroups[]? | select(.viewerHasReacted and (.content | IN("THUMBS_UP","THUMBS_DOWN"))) ] | length > 0;
def reacted: thumbs and (.lastEditedAt == null or (rtimes[.id] // "") >= .lastEditedAt);
# Is a comment or review still to answer? With rev-bound markers, a marker for
# the current revision answers it. An edit made before your latest marked reply
# means that reply raced the edit: it stays listed, and the reaction posted with
# the reply answers nothing. Only an edit after the reply (a follow-up) can be
# answered by a reaction alone. Without rev-bound markers: the time rule.
def still_open($h; $r): .id as $id | (.lastEditedAt // .createdAt // .submittedAt // "") as $rev
  | if (($r[$id] // []) | length) > 0 then
      if ([ $r[$id][] | select(. == $rev) ] | length) > 0 then false
      elif $rev <= ($h[$id] // "") then true
      else (reacted | not) end
    else unhandled($h; $r) and (reacted | not) end;
def norm: sub("\\[bot\\]$"; "");
.data.viewer.login as $me
| .data.repository.pullRequest as $p
# $handled: source id -> time of your latest reply carrying its marker. An item
# edited after that reply counts as unhandled again. $waiting: the same for
# "waiting on owner" replies (specwright:waiting), which leave the item listed.
| ([ ($p.comments.nodes[]), ($p.reviews.nodes[]), ($p.reviewThreads.nodes[].comments.nodes[]) ]
   | map(select((.author.login // "") == $me) | { t: (.createdAt // .submittedAt // ""), b: (.body // "") }))
  as $mine
| def marks($kind): [ $mine[] | .t as $t | .b | [scan("specwright:" + $kind + " ([A-Za-z0-9_=-]+)") | {(.[0]): $t}] | add // {} ]
    | reduce .[] as $m ({}; reduce ($m | to_entries[]) as $e (.; .[$e.key] = ([.[$e.key] // "", $e.value] | max)));
  def marksrev($kind): [ $mine[] | .b | scan("specwright:" + $kind + " ([A-Za-z0-9_=-]+) rev=([A-Za-z0-9@:._+-]+)") | { id: .[0], rev: .[1] } ]
    | group_by(.id) | map({ (.[0].id): map(.rev) }) | add // {};
  marks("handled") as $handled | marks("waiting") as $waiting
| marksrev("handled") as $hrevs | marksrev("waiting") as $wrevs
| ([ $p.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[]? |
     if .__typename == "CheckRun" then
       { name, url: .detailsUrl, run_id: .checkSuite.workflowRun.databaseId, app: .checkSuite.app.slug,
         at: (.completedAt // .startedAt // null),
         state: (if .status != "COMPLETED" then "pending"
                 elif (.conclusion | IN("SUCCESS","NEUTRAL","SKIPPED")) then "pass" else "fail" end) }
     else
       { name: .context, url: .targetUrl, run_id: null, app: null, at: (.createdAt // null),
         state: (if .state == "SUCCESS" then "pass"
                 elif (.state | IN("PENDING","EXPECTED")) then "pending" else "fail" end) }
     end ]) as $checks
# A thread's rev covers every comment, so an edit anywhere in it counts. A
# reviewer may answer by editing an earlier comment instead of replying:
# $edited marks a comment of theirs edited after your latest reply. $open: the
# reviewer comments that came (or were edited) after your latest reply and
# carry no reaction of yours - unanswered. Resolved threads are listed too
# when $open is non-empty (bots often reply after the thread was resolved) or
# your latest reply is a "waiting on owner" one: still to fix once allowed.
| ([ $p.reviewThreads.nodes[] |
     .id as $tid | .comments.nodes[-1] as $last |
     ([ .comments.nodes[] | select((.author.login // "") == $me) | .createdAt ] | max // "") as $replied |
     ([ .comments.nodes[] | select((.author.login // "") != $me and (.lastEditedAt // "") > $replied) ] | length > 0) as $edited |
     ([ .comments.nodes[] | select((.author.login // "") != $me
          and (.lastEditedAt // .createdAt // "") > $replied and (reacted | not)) ]) as $open |
     # $mark: your latest reply that carries a marker for this thread. When it
     # names a revision (pr-reply.sh --rev), that is the thread as you judged it;
     # compare it with the thread as it stood when the reply was posted (the
     # comments before it). A difference means the reviewer edited, or added, a
     # comment between your re-read and the reply, so the reply answered older
     # text: $rebound lists the thread again, even resolved. An edit made after
     # the reply is not counted here ($edited and $open catch it). GitHub keeps
     # only a comment's latest edit time, so a comment edited again after the
     # reply hides the edit time it had then: it is known only to lie between
     # its creation and the reply. With such a comment, only a judged time
     # outside that range ($low .. the reply) counts as a mismatch.
     ([ .comments.nodes[] | select((.author.login // "") == $me) | . as $c | ($c.body // "")
        | scan("specwright:(?:handled|waiting) " + $tid + "(?: resolve)?(?: rev=([A-Za-z0-9@:._+-]+))?(?: |$)")
        | { id: $c.databaseId, at: $c.createdAt, rev: .[0] } ] | max_by(.id)) as $mark |
     (if $mark == null or $mark.rev == null then false else
        ([ .comments.nodes[] | select(.databaseId < $mark.id) ]) as $before
        | ($mark.rev | split("@")) as $j
        | ([ $before[] | select((.lastEditedAt // "") > $mark.at) ] | length > 0) as $unknown
        | ([ $before[] | (if (.lastEditedAt // "") > $mark.at then null else .lastEditedAt end) // .createdAt // "" ] | max // "") as $low
        | ((($before[-1].databaseId // 0) | tostring) != $j[0])
          or (if $unknown then ($j[1] < $low or $j[1] > $mark.at) else $low != $j[1] end)
      end) as $rebound |
     ($replied != "" and ($waiting[$tid] // "") == $replied and ($rebound | not)) as $held |
     select((.isResolved | not) or ($open | length > 0) or $held or $rebound) |
     { id, root_id: .comments.nodes[0].databaseId, path, line: (.line // .originalLine),
       outdated: .isOutdated, resolved: .isResolved,
       rev: (($last.databaseId // 0 | tostring) + "@"
             + ([ .comments.nodes[] | .lastEditedAt // .createdAt // "" ] | max // "")),
       # your latest reply said "waiting on owner": still to fix once allowed
       waiting_owner: (($open | length == 0) and $held),
       awaiting_reviewer: ($replied != "" and ($open | length == 0) and ($held | not) and ($rebound | not)),
       rebound: $rebound,
       resolve_pending: ((.isResolved | not) and (($last.author.login // "") == $me) and ($edited | not)
         and (($last.body // "") | contains("specwright:handled " + $tid + " resolve"))),
       comments: [ .comments.nodes[] | { id, author: (.author.login // "ghost"), body: (.body | clip(2500)), clipped: (.body | clipped(2500)),
                                        at: .createdAt, edited: .lastEditedAt, url, reacted: reacted } ] } ]) as $threads
| ([ $p.comments.nodes[] | select((.author.login // "") != $me and still_open($handled; $hrevs)) |
     { id, rev: (.lastEditedAt // .createdAt), author: (.author.login // "ghost"),
       waiting_owner: holds($waiting; $wrevs),
       body: (.body | clip(1200)), clipped: (.body | clipped(1200)), at: .createdAt, url } ]) as $comments
| ([ $p.reviews.nodes[] | select(.state != "PENDING" and (.body // "") != ""
       and (.author.login // "") != $me and still_open($handled; $hrevs)) |
     { id, rev: (.lastEditedAt // .submittedAt), author: (.author.login // "ghost"), state,
       waiting_owner: holds($waiting; $wrevs),
       body: (.body | clip(1200)), clipped: (.body | clipped(1200)), at: .submittedAt, url } ]) as $reviews
# A reviewer's latest verdict stays CHANGES_REQUESTED until they approve or it
# is dismissed. Stale: none of the threads they started is still open.
| ([ $p.reviews.nodes[] | select(.state | IN("APPROVED","CHANGES_REQUESTED","DISMISSED")) ]
   | group_by(.author.login // "ghost") | map(max_by(.submittedAt // ""))
   | map(select(.state == "CHANGES_REQUESTED") | (.author.login // "ghost") as $a
         | select([ $threads[] | select((.resolved | not) and .comments[0].author == $a) ] | length == 0)
         | { author: $a, review_id: .id, at: .submittedAt })) as $stale_verdicts
# What did the configured logins write? cfg (prepended by the script) gives the
# configured logins, the head's push time and GitHub's "now". This script names no
# reviewer and knows no format: it hands each login's items whole (full raw body)
# to reviewers.py, which decides who reported.
| (if cfg.head == $p.headRefOid then cfg.pushed else null end) as $pushed
# Output counts as a report from $since on: the push time, or when the push is
# unknown the time a snapshot first saw the head (never the commit date).
| (if cfg.head == $p.headRefOid then cfg.since else null end) as $since
| def mine($l): ((.author.login // "") | norm | ascii_downcase) == ($l | ascii_downcase);
  (cfg.logins | map(. as $l | { key: $l, value: ([
      ($p.comments.nodes[] | select(mine($l))
        | { kind: "comment", id, body: (.body // ""), created: .createdAt, edited: .lastEditedAt, state: null, commit: null }),
      ($p.reviews.nodes[] | select(mine($l))
        | { kind: "review", id, body: (.body // ""), created: .submittedAt, edited: .lastEditedAt, state: .state, commit: (.commit.oid // null) }),
      ($p.reviewThreads.nodes[].comments.nodes[] | select(mine($l))
        | { kind: "thread_comment", id, body: (.body // ""), created: .createdAt, edited: .lastEditedAt, state: null, commit: null })
    ]) }) | from_entries) as $material
| ([ (if $p.reviewThreads.pageInfo.hasNextPage then "threads" else empty end),
     ($p.reviewThreads.nodes[] | select(.comments.totalCount > 100) | "thread " + .id + " comments"),
     (if $p.comments.pageInfo.hasPreviousPage then "comments" else empty end),
     (if $p.reviews.pageInfo.hasPreviousPage then "reviews" else empty end),
     (if ($p.commits.nodes[0].commit.statusCheckRollup.contexts.pageInfo.hasNextPage // false) then "checks" else empty end)
   ]) as $truncated
| {
    viewer: $me, number: $p.number, url: $p.url, state: $p.state, draft: $p.isDraft,
    mergeable: $p.mergeable, merge_state: $p.mergeStateStatus, review_decision: $p.reviewDecision,
    head: $p.headRefName, head_oid: $p.headRefOid, base: $p.baseRefName, author: $p.author.login,
    pending_review: ([ $p.reviews.nodes[] | select(.state == "PENDING" and (.author.login // "") == $me) ] | length > 0),
    # pending, advisory_pending and ci_pending come from reviewers.py, which knows which checks are a reviewer's own
    checks: { total: ($checks | length), failing: [ $checks[] | select(.state == "fail") | del(.at) ] },
    fail_run_ids: ([ $checks[] | select(.state == "fail" and .run_id != null) | .run_id ] | unique),
    threads: $threads, comments: $comments, reviews: $reviews, stale_verdicts: $stale_verdicts,
    head_pushed_at: $pushed,
    head_cutoff: (if cfg.head == $p.headRefOid then cfg.cutoff else null end),
    recheck: [ ($p.comments.nodes[], $p.reviews.nodes[], $p.reviewThreads.nodes[].comments.nodes[])
               | select(thumbs and .lastEditedAt != null and rtimes[.id] == null) | .id ],
    complete: ($truncated | length == 0), truncated: $truncated,
    fail_names: [ $checks[] | select(.state == "fail") | .name | @base64 ],
    # the raw material for reviewers.py; it drops these members and adds reviewers, now, reviewer_config, sig and attn
    cfg: { since: $since, now: cfg.now },
    checks_all: [ $checks[] | { name, state, app, at } ],
    material: $material,
    # sig_base / attn_base: the signature without the reviewers' states, which reviewers.py appends before it base64s them
    # (base64 keeps sig free of quotes, so sig_of can cut it out safely). attn: sig without the checks and merge state
    # (what --until attention compares).
    attn_base: ([ $p.state, $p.headRefOid,
            ($threads | map(.id + ":" + .rev + (if .rebound then ":rebound" else "" end) + (if .resolved then ":resolved" else "" end)) | join(",")),
            ($comments | map(.id + ":" + .rev) | join(",")),
            ($reviews | map(.id + ":" + .rev) | join(",")),
            ($stale_verdicts | map(.author + ":" + .review_id) | join(",")),
            ($truncated | sort | join(",")) ] | join("|")),
    sig_base: ([ $p.state, $p.headRefOid, $p.mergeStateStatus,
            ($checks | map(.name + "=" + .state) | sort | join(",")),
            ($threads | map(.id + ":" + .rev + (if .rebound then ":rebound" else "" end) + (if .resolved then ":resolved" else "" end)) | join(",")),
            ($comments | map(.id + ":" + .rev) | join(",")),
            ($reviews | map(.id + ":" + .rev) | join(",")),
            ($stale_verdicts | map(.author + ":" + .review_id) | join(",")),
            ($truncated | sort | join(",")) ] | join("|"))
  }
| tojson
JQ

# cfg for the reviewer check: the head's push time from the repository's
# activity log (cached per head) and GitHub's clock from a Date header, so
# timeouts never depend on the local clock. If the push is not in the log, the
# cutoff and the timeout start are the earliest GitHub time any snapshot on this
# machine saw the head, kept in <state>/heads/<owner>/<name>/<pr>/<oid>: never
# earlier than the push, so a timeout can come late but never early, and a
# report made before the head was first seen is not counted (never the commit
# date, which can precede the push by hours and so admits reports of a
# previous head). The record is written to a temp file and published with a
# no-clobber hard link, so the first writer wins and nobody sees an empty
# record; publishing it removes the records of the PR's other heads. If it can
# be neither published nor read (or does not parse), this process's own first
# sighting is used and kept across polls ("first_seen_unsaved").
# Sets CFG in the current shell; call it outside $(...).
CFG='def cfg: {logins: [], head: null, pushed: null, since: null, cutoff: null, now: (now | floor)};' pushed_oid= pushed_at= first_seen= seen_src= seen_date=
DATE_RE='^[A-Za-z]{3}, [0-9]{2} [A-Za-z]{3} [0-9]{4} [0-9:]{8} GMT$'
# Sets seen_date (an HTTP date) and seen_src (first_seen | first_seen_unsaved).
resolve_first_seen() {
  local base dir rec tmp d f
  base=${SPECWRIGHT_STATE_DIR:-$HOME/.cache/specwright}
  dir="$base/heads/$(printf '%s/%s' "$owner/$name" "$pr" | tr 'A-Z' 'a-z')"
  rec="$dir/$pushed_oid"
  seen_date=$first_seen seen_src=first_seen_unsaved
  if mkdir -p "$dir" 2>/dev/null && tmp=$(mktemp "$dir/.tmp.XXXXXX" 2>/dev/null); then
    if printf '%s\n' "$first_seen" > "$tmp" 2>/dev/null && ln "$tmp" "$rec" 2>/dev/null; then
      for f in "$dir"/*; do [ "$f" = "$rec" ] || rm -f "$f" 2>/dev/null || true; done
    fi
    rm -f "$tmp" 2>/dev/null || true
  fi
  d=$(head -n 1 "$rec" 2>/dev/null | tr -d '\r') || d=
  if printf '%s' "$d" | grep -Eq "$DATE_RE"; then seen_date=$d seen_src=first_seen; fi
  return 0
}
# bounded.py exits 124 (deadline_exceeded) or 125 (response_too_large). A lookup
# below that hits one fails the snapshot, in every mode, with the limit named on
# stderr; it never takes the lookup's fallback (no clock, no push time). Returns 0
# when <rc> is a limit.
limit_hit() {  # <rc> <command>
  case $1 in 124) echo "bounded: deadline_exceeded: $2" >&2 ;; 125) echo "bounded: response_too_large: $2" >&2 ;; *) return 1 ;; esac
}
# A snapshot without a configured reviewer still sets the head's cutoff (watch
# times pr.settle on an archive head from it), and never fails over it: any error
# there but a named limit returns 0 and leaves cfg unset.
prepare_cfg() {
  local info raw oid branch hrepo date pushed cutoff fail=1 rc
  [ -n "$logins" ] || fail=0
  info=$(gh api graphql -f owner="$owner" -f name="$name" -F pr="$pr" -f query='
    query($owner:String!,$name:String!,$pr:Int!){ repository(owner:$owner,name:$name){ pullRequest(number:$pr){
      headRefOid headRefName headRepository { nameWithOwner } } } }' \
    --jq '.data.repository.pullRequest | [.headRefOid, .headRefName, (.headRepository.nameWithOwner // "-")] | join(" ")') \
    || { rc=$?; case $rc in 124|125) return 1 ;; esac; return $fail; }  # bounded.py named the limit
  read -r oid branch hrepo <<<"$info"
  raw=$(gh api -i rate_limit 2>/dev/null) || { rc=$?; limit_hit $rc "gh api rate_limit" && return 1; raw=; }
  date=$(printf '%s\n' "$raw" | tr -d '\r' | sed -n 's/^[Dd]ate: //p' | head -n 1) || date=
  printf '%s' "$oid" | grep -Eq '^[0-9a-f]{40}$' || return $fail
  printf '%s' "$date" | grep -Eq "$DATE_RE" || return $fail
  [ "$oid" = "$pushed_oid" ] || { pushed_oid=$oid pushed_at= first_seen=$date seen_src= seen_date=; }
  # look the push up until found; it can reach the log after the first poll
  if [ -z "$pushed_at" ] && [ "$hrepo" != - ]; then
    pushed_at=$(gh api "repos/$hrepo/activity?ref=refs/heads/$branch&per_page=100" \
      --jq "[.[] | select(.after == \"$oid\")][0].timestamp // empty" 2>/dev/null) \
      || { rc=$?; limit_hit $rc "gh api repos/$hrepo/activity" && return 1; pushed_at=; }
    printf '%s' "$pushed_at" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$' || pushed_at=
  fi
  if [ -n "$pushed_at" ]; then
    pushed="\"$pushed_at\"" cutoff="{source: \"push\", at: $pushed}"
  else
    # decided once per head per process, so the cutoff and timeout start stay fixed
    [ -n "$seen_src" ] || resolve_first_seen
    pushed="(\"$seen_date\" | strptime(\"%a, %d %b %Y %H:%M:%S GMT\") | mktime | todate)"
    cutoff="{source: \"$seen_src\", at: $pushed}"
  fi
  CFG="def cfg: {logins: [$logins], head: \"$oid\", pushed: $pushed, since: $pushed, cutoff: $cutoff,
    now: (\"$date\" | strptime(\"%a, %d %b %Y %H:%M:%S GMT\") | mktime)};"
}
query_pr() {  # <rtimes def>
  gh api graphql -f query="$QUERY" -f owner="$owner" -f name="$name" -F pr="$pr" --jq "$CFG
$1
$SHAPE"
}
# The finished snapshot of the material $1 (the jq output): reviewers.py decides the reviewers and appends their states to
# sig and attn. It runs under the same deadline and byte bound as gh; a limit or any other failure fails the poll. The
# material goes through $mat_file (made once, in the main shell, so the exit trap removes it), never through an argument.
evaluate() {
  local oid
  oid=$(printf '%s' "$1" | grep -o '"head_oid":"[0-9a-f]*"' | sed -n '1s/.*:"\(.*\)"/\1/p') || oid=
  printf '%s\n' "$1" > "$mat_file" || return 1
  # `bash -c 'exec "$@"' reviewers.py ...` names reviewers.py in bounded.py's limit message (it names cmd[0] cmd[1] otherwise)
  "$py" -I "$SW_DIR/bounded.py" -- "$SW_BASH" -c 'exec "$@"' reviewers.py "$py" -I "$SW_DIR/reviewers.py" \
    ${rcfg_arg:+--config "$rcfg_arg"} --material "$mat_arg" --head "$oid"
}
# One query (~1 point); more only when an item you reacted to was edited
# since: its reaction times, 100 ids per query (1-2 points each), then the PR
# query once more with them. Your reaction is looked for among the latest 100
# of its kind on the item (the page size does not change the cost).
snapshot() {
  local out batches ids part rt=
  out=$(query_pr 'def rtimes: {};') || return 1
  batches=$(printf '%s' "$out" | grep -o '"recheck":\[[^]]*\]' | sed 's/^"recheck"://' \
    | grep -oE '"[A-Za-z0-9_=-]+"' | paste -d, - - - - - - - - - - - - - - - - - - - - - - - - - \
    | paste -d, - - - - | sed 's/,*$//') || batches=
  [ -n "$batches" ] || { evaluate "$out"; return; }
  while read -r ids; do
    [ -n "$ids" ] || continue
    part=$(gh api graphql -f query="query{ viewer { login } nodes(ids:[$ids]) { id ... on Reactable {
        up: reactions(content:THUMBS_UP, last:100) { nodes { createdAt user { login } } }
        down: reactions(content:THUMBS_DOWN, last:100) { nodes { createdAt user { login } } } } } }" \
      --jq '.data.viewer.login as $me | [ .data.nodes[] | select(. != null) | { (.id): ([ (.up.nodes[]?, .down.nodes[]?)
        | select((.user.login // "") == $me) | .createdAt ] | max // "") } ] | add // {} | tojson') || return 1
    rt="$rt${rt:+ + }$part"
  done <<<"$batches"
  out=$(query_pr "def rtimes: ($rt);") || return 1
  evaluate "$out"
}
sig_of() { printf '%s' "$1" | grep -o '"sig":"[^"]*"' || true; }
attn_of() { printf '%s' "$1" | grep -o '"attn":"[^"]*"' || true; }
fails_of() { printf '%s' "$1" | grep -o '"fail_names":\[[^]]*\]' | grep -oE '"[A-Za-z0-9+/=]+"' || true; }
# --until attention: may the poll $1, which differs from the baseline $base, be skipped?
only_progress() {
  local f
  [ "$(attn_of "$1")" = "$(attn_of "$base")" ] || return 1
  case $1 in *'"merge_state":"DIRTY"'*) return 1 ;; esac
  printf '%s' "$1" | grep -Eq '"ci_pending":[1-9]' || return 1
  while read -r f; do
    [ -n "$f" ] || continue
    fails_of "$base" | grep -qxF -- "$f" || return 1
  done < <(fails_of "$1")
  return 0
}

# The evaluator's material file, in the system temp dir (mktemp with no directory), made here and not in snapshot() because
# that runs in a $(...) subshell; the exit trap removes it. Native Windows python is handed a Windows path.
mat_file=$(mktemp 2>/dev/null) && [ -n "$mat_file" ] || { mat_file=; echo 'pr-snapshot: cannot create a temp file for the reviewer evaluator' >&2; exit 1; }
mat_arg=$mat_file
if command -v cygpath >/dev/null 2>&1; then mat_arg=$(cygpath -m "$mat_file"); fi

if [ "$wait" = 1 ]; then
  claim_watch
  # One poll, the first snapshot included, has one deadline for all its gh calls (SPECWRIGHT_NET_DEADLINE, default 120 s),
  # so a hung poll ends at that deadline and the timeout below is still reported on time. It is unset right after, so
  # --logs and anything else get the normal per-command deadline. Sets $next.
  poll() {
    local rc=0 at
    # bounded.py reads SPECWRIGHT_NET_DEADLINE by its one rule (a non-negative decimal that lowers 120 s, never raises it)
    at=$("$py" -I "$SW_DIR/bounded.py" --deadline-at 2>/dev/null) || at=
    case $at in ''|*[!0-9.]*) at=$(( $(date +%s) + 120 )) ;; esac
    export SPECWRIGHT_NET_DEADLINE_AT=$at
    { prepare_cfg && next=$(snapshot); } || rc=$?
    unset SPECWRIGHT_NET_DEADLINE_AT
    return $rc
  }
  take_over() { echo "pr-snapshot: a newer watcher took over PR $pr; this one stops" >&2; exit 4; }
  # --timeout is elapsed time from here, polls included.
  start=$SECONDS base= base_sig= snap= wake=timeout ok=1 filtered=0
  if poll; then base=$next snap=$next; else ok=0; fi  # a failed first snapshot has no base: the first good poll becomes it
  base_sig=$(sig_of "$base")
  # Activity beyond a cut-off page cannot be seen, so do not wait for it.
  case $base in *'"complete":false'*) wake=incomplete ;; esac
  while [ "$wake" = timeout ]; do
    elapsed=$((SECONDS - start))
    [ "$elapsed" -lt "$timeout" ] || break
    nap=$interval; [ "$nap" -le $((timeout - elapsed)) ] || nap=$((timeout - elapsed))
    sleep "$nap"
    still_owner || take_over
    # keep the last good snapshot; a failed poll never replaces it
    if poll; then snap=$next; ok=1; else ok=0; continue; fi
    if [ -z "$base" ]; then
      base=$snap base_sig=$(sig_of "$snap")
      case $base in *'"complete":false'*) wake=incomplete ;; esac
    elif [ "$(sig_of "$snap")" != "$base_sig" ]; then
      if [ "$until" = attention ] && only_progress "$snap"; then filtered=$((filtered + 1)); else wake=changed; fi
    fi
  done
  # a watcher taken over during a hung poll stops here, not with a timeout report
  [ "$wake" != timeout ] || still_owner || take_over
  [ "$ok" = 1 ] || { echo "pr-snapshot: the last poll failed; GitHub state unknown" >&2; exit 1; }
  printf '{"wake":"%s","waited":%s,"filtered":%s,"snapshot":%s}\n' "$wake" "$((SECONDS - start))" "$filtered" "$snap"
else
  prepare_cfg; snap=$(snapshot)
  printf '%s\n' "$snap"
fi

if [ "$logs" = 1 ]; then
  ids=$(printf '%s' "$snap" | grep -o '"fail_run_ids":\[[0-9,]*\]' | grep -o '[0-9][0-9]*' || true)
  limited=
  for id in $ids; do
    printf '\n===== failed log: run %s =====\n' "$id"
    rc=0; gh run view "$id" -R "$repo" --log-failed 2>&1 | tail -n 80 || rc=${PIPESTATUS[0]}
    if limit_hit "$rc" "gh run view $id"; then limited=1; fi
  done
  [ -z "$limited" ] || exit 1  # the snapshot is printed; a cut-off log is still a named failure
fi
