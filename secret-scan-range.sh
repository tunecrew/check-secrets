#!/bin/sh
# Print the commit range CI's secret scan reads for one GitHub Actions event
# (std_git_safety_mechanics GSM-02); --help says how each event maps to a range.
#
# It stays POSIX sh, as check-secrets.sh does, because the public
# tunecrew/check-secrets action runs both on any runner with nothing but sh,
# git, and the POSIX utilities; half its length is the help text.

set -eu
LC_ALL=C
export LC_ALL

usage() {
  cat <<'EOF'
Usage: secret-scan-range.sh
       secret-scan-range.sh [-h | --help]

Print the BASE..HEAD range of commits a GitHub Actions event brings, for
check-secrets.sh --range (std_git_safety_mechanics GSM-02). Run it from inside
the checkout, which must hold the full history (actions/checkout with
fetch-depth: 0).

It reads the event from the environment, never from its arguments, so no
event value is ever parsed as shell:
  EVENT_NAME             push or pull_request
  PUSH_BEFORE_SHA        the branch tip before a push (github.event.before)
  PUSH_AFTER_SHA         the branch tip after a push (github.sha)
  PULL_REQUEST_BASE_SHA  a pull request's base (github.event.pull_request.base.sha)
  PULL_REQUEST_HEAD_SHA  a pull request's head (github.event.pull_request.head.sha)

What it prints:
  push           BEFORE..AFTER, the commits the push brought; after a
                 force-push, whose old tip is in no fetched branch, BEFORE is
                 fetched once from origin first;
  push, new tip  AFTER~1..AFTER when BEFORE is empty or all zeros, as when the
                 push creates the branch;
  pull_request   BASE..HEAD, every commit of the pull request; a BASE the
                 clone lacks (its branch was force-pushed) is fetched once;
  root commit    nothing, with a warning: a commit with no parent has no range.

Exit status: 0 with the range printed (or nothing, for a root commit); 2,
naming the cause, when no range can be named: an unknown event, a value that
is not a full 40-hex commit SHA, a shallow clone, a commit the clone lacks, or
an old tip origin cannot supply after a force-push. A scan that could not run
is never a pass.

Example:
  range="$(sh scripts/secret-scan-range.sh)"
EOF
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac

# Print each argument as one line of an error that fails the scan, and stop:
# a range that cannot be named is a failure, never a pass (std_philosophy
# PHIL-08). The first line carries GitHub's error marker.
fail() {
  printf '::error::secret-scan-range.sh: %s\n' "$1" >&2
  shift
  for line in "$@"; do
    printf '%s\n' "$line" >&2
  done
  exit 2
}

# Succeed when this clone holds the commit $1.
has_commit() {
  git cat-file -e "${1}^{commit}" 2>/dev/null
}

# Stop unless variable $1 holds $2, a full lowercase 40-hex commit SHA, so no
# ref name, expression, or option ever reaches git. The value itself is never
# printed, so no text in it can reach the log as a workflow command.
require_sha() {
  case "$2" in
    *[!0-9a-f]* | '') fail "$1 is not a full commit SHA." ;;
  esac
  [ "${#2}" -eq 40 ] || fail "$1 is not a full commit SHA."
}

# Stop unless this clone holds commit $1, the variable $2 names.
require_commit() {
  has_commit "$1" || fail "$2 $1 is not in this clone; check out the full history (fetch-depth: 0)."
}

# Make sure this clone holds the range's base, $1, before the range $1..$2 is
# printed. A force-push leaves an old tip in no branch the checkout fetched (a
# push's previous tip, or a pull request's base after its base branch was
# rewritten), so it is fetched once by its hash; the range then covers exactly
# the commits the event brings.
require_base() {
  if ! has_commit "$1"; then
    if ! git fetch --quiet --no-tags origin "$1" >&2 || ! has_commit "$1"; then
      fail "the base $1 is not in this clone and origin did not supply it, as after a force-push" \
        "whose old commits are gone. Scan the commits locally instead:" \
        "  sh check-secrets.sh --range $1..$2"
    fi
  fi
}

event="${EVENT_NAME:-}"
case "$event" in
  pull_request)
    base="${PULL_REQUEST_BASE_SHA:-}"
    head="${PULL_REQUEST_HEAD_SHA:-}"
    require_sha PULL_REQUEST_BASE_SHA "$base"
    require_sha PULL_REQUEST_HEAD_SHA "$head"
    ;;
  push)
    before="${PUSH_BEFORE_SHA:-}"
    after="${PUSH_AFTER_SHA:-}"
    require_sha PUSH_AFTER_SHA "$after"
    # Empty or all zeros is a push with no previous tip, as one that creates
    # the branch; any other value must be a SHA.
    case "$before" in
      *[!0]*) require_sha PUSH_BEFORE_SHA "$before" ;;
    esac
    ;;
  *) fail "no commit range is defined for the \"$event\" event; run on push or pull_request." ;;
esac

# A shallow clone may lack the base, and the scan would then see too little.
shallow="$(git rev-parse --is-shallow-repository)" || fail 'git rev-parse --is-shallow-repository failed.'
[ "$shallow" = false ] || fail 'this clone is shallow; check out the full history (actions/checkout with fetch-depth: 0).'

if [ "$event" = pull_request ]; then
  require_commit "$head" PULL_REQUEST_HEAD_SHA
  require_base "$base" "$head"
  printf '%s..%s\n' "$base" "$head"
  exit 0
fi

require_commit "$after" PUSH_AFTER_SHA
case "$before" in
  *[!0]*)
    require_base "$before" "$after"
    printf '%s..%s\n' "$before" "$after"
    ;;
  *)
    if has_commit "${after}~1"; then
      printf '%s~1..%s\n' "$after" "$after"
    else
      printf '::warning::%s is a root commit; the range scan cannot cover it\n' "$after" >&2
    fi
    ;;
esac
