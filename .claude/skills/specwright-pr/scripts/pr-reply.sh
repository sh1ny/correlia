#!/usr/bin/env bash
# Reply to one piece of PR feedback, then (optionally) resolve its thread.
# Every reply carries a hidden `specwright:handled <source-id>` marker (plus
# `resolve` when the thread is to be resolved), so pr-snapshot.sh stops listing
# that item and can spot a resolution that failed - dedup state lives on GitHub.
#
# Usage:
#   bash pr-reply.sh <PR> thread  <thread-id> <root-comment-id> <body-file> [--resolve] [--react +1|-1] [--waiting] [--rev REV] [--repo o/n]
#   bash pr-reply.sh <PR> comment <source-id> <body-file> [--react +1|-1] [--waiting] [--rev REV] [--repo o/n]
#   bash pr-reply.sh <PR> react   <comment-id> +1|-1 [--repo o/n]
#   bash pr-reply.sh <PR> resolve <thread-id> [--rev REV] [--repo o/n]   (retry a failed resolution, or close a
#                                                              thread the reviewer only acknowledged)
# --react puts a thumbs up (+1: the finding was right) or down (-1: it was
# wrong) on the item answered: the thread's root comment, or the comment or
# review <source-id>. react alone answers a reviewer's follow-up without a
# reply; <comment-id> is a node id from the snapshot, or a review comment's
# numeric id. --waiting marks a "waiting on owner" reply (specwright:waiting):
# the snapshot keeps the item listed, with waiting_owner, until it is handled.
# --rev REV is the item's `rev` from the snapshot (or the pass record's
# revision.rev): the script re-reads the item first and posts, resolves and
# reacts to nothing when its revision now differs (exit 5, "judged A, now B" on
# stderr) or cannot be read, or is a thread of more than 100 comments (exit 3).
# The marker then carries `rev=REV`, which binds the reply to the text that
# was judged. Without --rev it behaves as in 0.1.10: no re-read, a marker
# without a revision.
# Thread replies use REST (GraphQL replies can attach to a pending review and
# stay invisible). Exit 2: a pending review of yours exists - submit or
# discard it on GitHub first. Exit 4: refused before any GitHub call (bad
# arguments, or a body file missing, unreadable, empty or not written in full
# with its marker); nothing was posted, and stderr names the cause.
# Wrap with as.sh to pin the GitHub identity.
# Needs bash, gh and Python 3.8+; every gh call has a deadline (bounded.py), and a limit stops the script non-zero
# (`bounded: deadline_exceeded: gh api` on stderr) after its temp file is removed.
set -euo pipefail

# Every gh call runs through bounded.py (a deadline and a byte bound on stdout and stderr; see its header), so a stuck network or a
# huge response ends as a named limit instead of a hang. Python 3.8+ runs it. The wrapper starts gh through bash, so the
# same call works where gh is a shell shim.
py=
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1; then py=$c; break; fi
done
[ -n "$py" ] || { echo 'pr-reply.sh: no_python: needs python 3.8+ for its bounded gh calls' >&2; exit 2; }
# native Windows python cannot run an MSYS path: hand it Windows paths (-m: forward slashes bash accepts)
SW_DIR=$(cd "$(dirname "$0")" && pwd -P)
SW_BASH=${BASH:-bash}
if command -v cygpath >/dev/null 2>&1; then SW_DIR=$(cygpath -m "$SW_DIR"); SW_BASH=$(cygpath -w "$SW_BASH"); fi
gh() { "$py" -I "$SW_DIR/bounded.py" ${SW_PAGED:+--paged} ${SW_SECRET:+--secret} -- "$SW_BASH" -c 'exec gh "$@"' gh "$@"; }

pr=${1:?PR}; kind=${2:?thread|comment|resolve}; shift 2
repo= resolve=0 react= waiting=0 rev= args=()
while [ $# -gt 0 ]; do
  case $1 in
    --repo) repo=${2:?--repo needs owner/name}; shift 2 ;;
    --resolve) resolve=1; shift ;;
    --react) react=${2:?--react needs +1 or -1}; shift 2 ;;
    --waiting) waiting=1; shift ;;
    --rev) rev=${2:?--rev needs the item rev}; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done

# A thread or comment reply needs a readable, non-empty body file before any GitHub call.
body_check() {  # <body-file>
  [ -f "$1" ] && [ -r "$1" ] && [ -s "$1" ] || {
    echo "pr-reply: body file $1 is missing, unreadable or empty; nothing was posted" >&2
    exit 4
  }
}

# Every argument and body check runs before the first GitHub call, the repository lookup included.
[ -z "$react" ] || [ "$react" = +1 ] || [ "$react" = -1 ] || { echo "pr-reply: --react must be +1 or -1" >&2; exit 4; }
[ "$waiting" = 0 ] || [ "$resolve$react" = 0 ] || { echo "pr-reply: --waiting takes neither --resolve nor --react" >&2; exit 4; }
case $kind in
  thread)
    [ ${#args[@]} -eq 3 ] || { echo "usage: pr-reply.sh <PR> thread <thread-id> <root-comment-id> <body-file> [--resolve] [--react +1|-1]" >&2; exit 4; }
    body_check "${args[2]}" ;;
  comment)
    [ ${#args[@]} -eq 2 ] || { echo "usage: pr-reply.sh <PR> comment <source-id> <body-file> [--react +1|-1]" >&2; exit 4; }
    body_check "${args[1]}" ;;
  react)
    [ ${#args[@]} -eq 2 ] || { echo "usage: pr-reply.sh <PR> react <comment-id> +1|-1" >&2; exit 4; }
    case ${args[1]} in +1|-1) ;; *) echo "pr-reply: reaction must be +1 or -1" >&2; exit 4 ;; esac ;;
  resolve)
    [ ${#args[@]} -eq 1 ] || { echo "usage: pr-reply.sh <PR> resolve <thread-id>" >&2; exit 4; } ;;
  *) echo "pr-reply: kind must be thread, comment, react or resolve" >&2; exit 4 ;;
esac
[ -n "$repo" ] || repo=$(gh repo view --json owner,name --jq '.owner.login + "/" + .name')
owner=${repo%%/*} name=${repo#*/}

pending_check() {
  n=$(gh api graphql -f owner="$owner" -f name="$name" -F pr="$pr" -f query='
    query($owner:String!,$name:String!,$pr:Int!){ viewer{login}
      repository(owner:$owner,name:$name){ pullRequest(number:$pr){
        reviews(states:PENDING, first:10){ nodes{ author{login} } } } } }' \
    --jq '.data.viewer.login as $me | [.data.repository.pullRequest.reviews.nodes[] | select(.author.login == $me)] | length')
  if [ "$n" != 0 ]; then
    echo "pr-reply: you have a pending (unsubmitted) review on #$pr; replies may be hidden in it. Submit or discard it first." >&2
    exit 2
  fi
}

# With --rev: read the item now and compare its revision with the one judged.
# A thread longer than one page (100 comments) cannot be compared: exit 3.
# The formula is the snapshot's: thread <last databaseId>@<newest of lastEditedAt|createdAt>,
# comment lastEditedAt // createdAt, review lastEditedAt // submittedAt.
rev_check() {  # <node id>
  [ -n "$rev" ] || return 0
  local now
  now=$(gh api graphql -f id="$1" -f query='
    query($id:ID!){ node(id:$id){ __typename
      ... on PullRequestReviewThread { comments(first:100){ totalCount nodes{ databaseId createdAt lastEditedAt } } }
      ... on IssueComment { createdAt lastEditedAt }
      ... on PullRequestReview { submittedAt lastEditedAt } } }' \
    --jq '.data.node | if . == null then error("item not found")
      elif .__typename == "PullRequestReviewThread" and .comments.totalCount > (.comments.nodes | length) then
        "long:" + (.comments.totalCount | tostring)
      elif .__typename == "PullRequestReviewThread" then
        ((.comments.nodes[-1].databaseId // 0 | tostring) + "@" + ([ .comments.nodes[] | .lastEditedAt // .createdAt // "" ] | max // ""))
      elif .__typename == "PullRequestReview" then (.lastEditedAt // .submittedAt)
      else (.lastEditedAt // .createdAt) end') && [ -n "$now" ] || {
    echo "pr-reply: cannot read $1 to check its revision; nothing was posted" >&2
    exit 3
  }
  case $now in long:*)
    echo "pr-reply: $1 has ${now#long:} comments, more than one read returns, so its revision cannot be checked; nothing was posted. Answer it on GitHub." >&2
    exit 3 ;;
  esac
  if [ "$now" != "$rev" ]; then
    echo "pr-reply: $1 changed since it was judged (judged $rev, now $now); nothing was posted. Take a fresh snapshot and judge it again." >&2
    exit 5
  fi
}

body_with_marker() {  # <body-file> <marker>: fills the global $tmp; runs in the main shell, so a failed write stops the script
  local mkind=handled
  [ "$waiting" = 0 ] || mkind=waiting
  tmp=$(mktemp) || { echo "pr-reply: no temp file for body file $1; nothing was posted" >&2; exit 4; }
  { cat "$1" > "$tmp" && printf '\n\n<!-- specwright:%s %s%s -->\n' "$mkind" "$2" "${rev:+ rev=$rev}" >> "$tmp"; } || {
    echo "pr-reply: the reply for body file $1 could not be written in full; nothing was posted" >&2
    exit 4
  }
}

tmp=
trap 'rm -f "${tmp:-}"' EXIT

add_reaction() {  # <comment-id> <+1|-1>: numeric = review comment (REST), else node id
  case $2 in +1) rest=+1 node=THUMBS_UP ;; -1) rest=-1 node=THUMBS_DOWN ;;
    *) echo "pr-reply: reaction must be +1 or -1" >&2; exit 4 ;; esac
  case $1 in
    *[!0-9]*) gh api graphql -f subjectId="$1" -f content="$node" -f query='
        mutation($subjectId:ID!,$content:ReactionContent!){ addReaction(input:{subjectId:$subjectId,content:$content}){ reaction{ content } } }'         --jq '"reacted: " + .data.addReaction.reaction.content' ;;
    *) gh api --method POST "repos/$owner/$name/pulls/comments/$1/reactions" -f content="$rest" --jq '"reacted: " + .content' ;;
  esac
}
failed=0
react_or_report() {  # <comment-id>: after a posted reply; a failure names the retry
  [ -n "$react" ] || return 0
  add_reaction "$1" "$react" || {
    echo "pr-reply: reply posted but the reaction failed; retry only the reaction: pr-reply.sh $pr react $1 $react" >&2
    failed=1
  }
}

resolve_thread() {  # <thread-id>
  gh api graphql -f threadId="$1" -f query='
    mutation($threadId:ID!){ resolveReviewThread(input:{threadId:$threadId}){ thread{ id isResolved } } }' \
    --jq '"resolved: " + (.data.resolveReviewThread.thread.isResolved | tostring)'
}

case $kind in
  thread)
    thread=${args[0]} root=${args[1]}
    marker=$thread; [ "$resolve" = 1 ] && marker="$thread resolve"
    body_with_marker "${args[2]}" "$marker"
    pending_check
    rev_check "$thread"
    gh api --method POST "repos/$owner/$name/pulls/$pr/comments/$root/replies" -F body=@"$tmp" --jq '.html_url'
    pending_check
    if [ "$resolve" = 1 ]; then
      resolve_thread "$thread" || {
        if [ -n "$rev" ]; then  # the reply is part of the thread's rev: the judged one would now exit 5
          echo "pr-reply: reply posted but resolution failed; retry only the resolution, with the thread's rev from a fresh snapshot that lists it resolve_pending (your reply changed it): pr-reply.sh $pr resolve $thread --rev <rev>" >&2
        else
          echo "pr-reply: reply posted but resolution failed; retry only the resolution: pr-reply.sh $pr resolve $thread" >&2
        fi
        failed=1
      }
    fi
    react_or_report "$root"
    ;;
  comment)
    body_with_marker "${args[1]}" "${args[0]}"
    pending_check
    rev_check "${args[0]}"
    gh pr comment "$pr" -R "$repo" --body-file "$tmp"
    react_or_report "${args[0]}"
    ;;
  react)
    pending_check
    add_reaction "${args[0]}" "${args[1]}"
    ;;
  resolve)
    pending_check
    rev_check "${args[0]}"
    resolve_thread "${args[0]}"
    ;;
esac
exit $failed
