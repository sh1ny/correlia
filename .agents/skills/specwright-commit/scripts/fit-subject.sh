#!/usr/bin/env bash
# Fit a task or group commit subject to 72 characters, in the message file itself.
#
# Usage: bash fit-subject.sh <msgfile>
# Line 1 must be `<type>(<scope>): task X.Y <task text>` or
# `<type>(<scope>): group N <group heading>`. When it is longer than 72
# characters, it keeps that prefix plus the longest run of whole words of the
# text that fits, and rewrites line 1 in place; every other line
# is kept byte for byte. Prints the final subject.
# The text is only ever read from the file: it never reaches a command
# line, so backticks, `$` and quotes in it stay literal.
# Exit 0: fitted, or already fits (file untouched).
# Exit 1: not even the first word fits after the prefix (file untouched).
# Exit 2: missing file, or line 1 has no `<type>(<scope>): task X.Y ` or
# `<type>(<scope>): group N ` prefix.
set -u

limit=72
msg=${1:-}
[ -n "$msg" ] && [ -f "$msg" ] || { echo "fit-subject.sh: no message file: '$msg'" >&2; exit 2; }

IFS= read -r line < "$msg" || true
cr=
case $line in *$'\r') cr=$'\r'; line=${line%$'\r'} ;; esac

# POSIX awk (length, match, substr, gsub); the subject comes in through the
# environment, so awk -v never reinterprets its backslashes. awk runs on bytes
# (LC_ALL=C) in every environment, and chars() counts UTF-8 characters by
# leaving out continuation bytes (0x80-0xBF), so the limit is in characters
# whatever the caller's locale.
fitted=$(SUBJECT=$line LC_ALL=C awk -v lim="$limit" '
function chars(t) { return length(t) - gsub(/[\200-\277]/, "", t) }
BEGIN {
  s = ENVIRON["SUBJECT"]
  if (!match(s, /^[^ ]+: task [0-9]+\.[0-9]+ /) && !match(s, /^[^ ]+: group [0-9]+ /)) exit 2
  if (chars(s) <= lim) { print s; exit 0 }
  p = RLENGTH
  for (i = length(s); i > p; i--) {
    if (substr(s, i, 1) != " ") continue
    out = substr(s, 1, i - 1)
    sub(/ +$/, "", out)
    if (length(out) < p) exit 1
    if (chars(out) <= lim) { print out; exit 0 }
  }
  exit 1
}')
rc=$?
case $rc in
  0) ;;
  1) echo "fit-subject.sh: no word of the task or group text fits in $limit characters: $line" >&2; exit 1 ;;
  *) echo "fit-subject.sh: line 1 is not '<type>(<scope>): task X.Y <task text>' or '<type>(<scope>): group N <group heading>': $line" >&2; exit 2 ;;
esac

if [ "$fitted" != "$line" ]; then
  tmp="$msg.fit.$$"
  {
    printf '%s%s' "$fitted" "$cr"
    # Everything from the first newline on, byte for byte (nothing when line 1 is the whole file).
    if [ "$(wc -l < "$msg")" -gt 0 ]; then
      skip=$(( $(printf '%s%s' "$line" "$cr" | wc -c) + 1 ))
      tail -c +"$skip" -- "$msg"
    fi
  } > "$tmp" && mv -f -- "$tmp" "$msg" || { rm -f -- "$tmp"; echo "fit-subject.sh: could not rewrite $msg" >&2; exit 2; }
fi
printf '%s\n' "$fitted"
