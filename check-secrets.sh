#!/bin/sh
# Block secrets from entering version control (std_git_safety GS-02); --help
# lists the checks.
#
# Each git command's output is captured and its status checked before anything
# filters it: sh has no pipefail, so a failing git piped into grep would read as
# an empty, passing scan (std_shell SH-03). A failure exits 2, never 0.
#
# It stays POSIX sh past std_shell's rough 100-line guide on purpose: the global
# pre-commit hook runs it in every repository, and a project's CI runs it
# through the public tunecrew/check-secrets action, to which
# scripts/publish-check-secrets.py publishes this file byte for byte, so it
# depends on nothing but sh, git, and the POSIX utilities.

set -eu

# Every tool runs under the C locale. Every credential format is ASCII, and
# under a UTF-8 locale a byte that is not valid UTF-8 breaks the text tools:
# GNU grep drops a matching line holding one, macOS's grep misses a credential
# that follows one, macOS's cut silently drops every line from one onward, and
# macOS's tr stops on one. The C locale makes every byte a character for every
# tool. LC_ALL outranks LANG and every LC_* variable a person sets; git, which
# inherits it, then prints its own messages untranslated.
LC_ALL=C
export LC_ALL

usage() {
  cat <<'EOF'
Usage: check-secrets.sh [--range BASE..HEAD]
       check-secrets.sh [-h | --help]

Block secrets from entering version control (std_git_safety GS-02).
Run from anywhere inside a git repository.

With no argument it scans what is staged for commit and fails (exit 1) when
any of these holds:
  1. a path under a secrets/ directory is staged for commit,
  2. a path under a secrets/ directory is already tracked,
  3. a secrets/ directory exists in the working tree but is not gitignored, or
  4. an added line in the staged diff matches a known credential format
     (cloud access keys, hosted-service API tokens, private-key blocks);
     the report names the file and line, never the value.

Options:
  --range BASE..HEAD  scan pushed commits instead of the index, for CI. Every
                      commit in the range is scanned on its own, so a
                      credential a later commit removed is still caught, and a
                      merge is scanned against its first parent. Checks 1 and 4
                      run over the range, naming the commit, file, and line;
                      checks 2 and 3 still apply.
  -h, --help          print this help and exit.

Exit status: 0 clean, 1 findings, 2 a usage error or a failed command (an
unknown revision, a shallow clone missing BASE); a scan that could not run is
never a pass.

Examples:
  sh scripts/check-secrets.sh                   # the staged commit, from this repository
  sh "$HOME/.agents/scripts/check-secrets.sh"   # the staged commit, from any other repository
  sh scripts/check-secrets.sh --range origin/main..HEAD           # the commits a branch adds
  sh scripts/check-secrets.sh --range "$BEFORE_SHA..$AFTER_SHA"   # the commits a push added

The global pre-commit hook (.githooks/pre-commit) runs this in every
repository; a repo-local copy at scripts/check-secrets.sh runs as well. A
project's CI can run it with --range through the tunecrew/check-secrets
action, pinned by commit SHA, which the standards repository publishes it to.
EOF
}

usage_error() {
  printf 'check-secrets.sh: %s\n\n' "$1" >&2
  usage >&2
  exit 2
}

# A step that fails leaves nothing to scan, and an empty scan must never read as
# a clean one, so the whole run stops as a failure.
scan_failed() {
  printf 'ERROR: %s failed, so the scan is incomplete; that is a failure, never a pass.\n' "$1" >&2
  exit 2
}

# Print the lines of file $2 that match the extended regular expression $1.
# grep's exit 1 means that no line matched, a clean result; 2 is a real failure.
matching_lines() {
  grep -E -- "$1" "$2" || [ "$?" -eq 1 ]
}

# Known credential formats. Only formats with a fixed, distinctive prefix are
# matched, so ordinary prose, code, and documentation placeholders
# (sk_live_...) never trip them.
credential_pattern='AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}'
credential_pattern="$credential_pattern|gh[pousr]_[0-9A-Za-z]{36}|github_pat_[0-9A-Za-z_]{22,}"
credential_pattern="$credential_pattern|glpat-[0-9A-Za-z_-]{20}"
credential_pattern="$credential_pattern|(sk|rk)_(live|test)_[0-9A-Za-z]{24,}|whsec_[0-9A-Za-z]{32,}"
credential_pattern="$credential_pattern|sk-ant-[0-9A-Za-z_-]{20,}|sk-proj-[0-9A-Za-z_-]{20,}"
credential_pattern="$credential_pattern|xox[abprs]-[0-9A-Za-z-]{10,}|AIza[0-9A-Za-z_-]{35}"
credential_pattern="$credential_pattern|-----BEGIN [A-Z ]*PRIVATE KEY-----"

# Label each added line of diff file $1 with its commit (range mode), path, and
# new-file line number, and write "label<tab>content" lines to file $2. The
# path keeps git's C-quoting ("caf\303\251.txt"), with the b/ prefix dropped
# inside or outside the quotes, so the label is the name as git status prints
# it by default. A tab splits label from content exactly: git quotes any path
# holding one, and a commit id and a line number never do, while a path may
# hold colons. grep does the matching, because POSIX awk does not guarantee
# interval expressions, and only the label is ever printed, so a value never
# reaches the terminal. A hunk's lines are counted down from its header, so an
# added line that itself reads "++ …" (shown as "+++ …") is content, never a
# file header.
label_added_lines() {
  awk '
    function count(range, parts) { return split(range, parts, ",") > 1 ? parts[2] + 0 : 1 }
    old_left > 0 || new_left > 0 {
      marker = substr($0, 1, 1)
      if (marker == "+") { print commit file ":" line "\t" substr($0, 2); line++; new_left-- }
      else if (marker == "-") old_left--
      next
    }
    /^commit / { commit = $2 ":"; next }
    /^\+\+\+ / {
      file = substr($0, 5); sub(/\t$/, "", file)
      if (substr(file, 1, 3) == "\"b/") file = "\"" substr(file, 4)
      else if (substr(file, 1, 2) == "b/") file = substr(file, 3)
      next
    }
    /^@@ / { old_left = count($2); new_left = count($3); split($3, start, ","); line = substr(start[1], 2) + 0 }
  ' "$1" >"$2" || scan_failed 'awk'
}

range=''
if [ "$#" -gt 0 ]; then
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --range)
      [ "$#" -eq 2 ] || usage_error '--range takes exactly one BASE..HEAD argument.'
      range="$2"
      # Two dots only: three would scan the base side's commits too, and a
      # value starting with a dash would reach git as an option.
      case "$range" in
        -* | *...*) usage_error "--range wants BASE..HEAD, not $range" ;;
        ?*..?*) ;;
        *) usage_error "--range wants BASE..HEAD, not $range" ;;
      esac
      ;;
    *) usage_error "unknown argument: $1" ;;
  esac
fi

root="$(git rev-parse --show-toplevel)" || scan_failed 'git rev-parse --show-toplevel'
work="$(mktemp -d)" || scan_failed 'mktemp'
trap 'rm -rf "$work"' EXIT
# A hangup, interrupt, or termination (a host stopping a hook at its timeout)
# becomes an ordinary exit, so the exit trap removes the temporary files, which
# hold the added lines in full. bash runs the exit trap on TERM by itself; dash
# does not.
trap 'exit 2' HUP INT TERM

status=0
# Git quotes a path holding unusual characters ("secrets/caf\303\251"), so the
# pattern allows the opening quote.
secrets_path_pattern='(^"?|/)secrets/'

# Every change but a deletion is read, a type change (a symlink turned into a
# file) included. --text and --no-textconv show a file's real lines even when
# .gitattributes marks it binary or converts it for display, so an attribute
# can never hide a credential from the scan. The pinned prefixes keep a
# diff.noprefix or diff.mnemonicPrefix setting from changing the "+++ b/<file>"
# header the labelling reads, the pinned inter-hunk context keeps a
# diff.interHunkContext setting from fusing nearby hunks, and --no-relative
# keeps a diff.relative setting from limiting a run in a subfolder to that
# folder and labelling paths relative to it. core.quotePath=true keeps every
# path git prints in its C-quoted ASCII form ("caf\303\251.txt"), whatever a
# person's setting, so a label names the file as git status prints it by
# default and a raw name never reaches grep or sed. A context length in
# GIT_DIFF_OPTS outranks -U0 and brings context lines back, so it is dropped;
# every hunk the labelling reads then holds no context lines, only "+", "-",
# and "\ No newline at end of file" lines. --submodule=short keeps a
# diff.submodule=diff setting from inlining a submodule's own diff, whose
# context lines git prints past -U0 and the labelling would miscount, dropping
# the next file's added lines. -M keeps rename detection on, as git's default
# has it, whatever diff.renames says: a moved file's new lines are read and its
# old ones are not read again, and a copy is read whole; the history scan's
# --no-renames differs on purpose, since this gate blocks new content and that
# audit reports every occurrence.
# --no-replace-objects keeps a refs/replace entry from swapping a clean commit
# in for the one scanned, or for HEAD, which the staged diff compares with.
# test_check_secrets.py keeps these calls in step with scan-history-secrets.py's
# diff call: a pin one carries and the other lacks needs a stated reason there.
unset GIT_DIFF_OPTS
if [ -z "$range" ]; then
  git --no-replace-objects -c core.quotePath=true diff --cached --name-only --no-relative --diff-filter=d \
    >"$work/paths" || scan_failed 'git diff --cached --name-only'
  git --no-replace-objects -c core.quotePath=true diff --cached --no-relative --diff-filter=d --submodule=short \
    -M --text --no-textconv --no-color --no-ext-diff -U0 --inter-hunk-context=0 --src-prefix=a/ \
    --dst-prefix=b/ >"$work/diff" || scan_failed 'git diff --cached'
else
  # Each commit's own diff, so one a later commit undid is still seen; a merge
  # against its first parent, so content added while merging is seen too. No
  # signature display, which would call gpg on every commit. --root keeps a
  # log.showRoot=false setting from hiding what a root commit in the range
  # added, as one an unrelated history's merge brings in.
  git --no-replace-objects -c core.quotePath=true log --root --no-show-signature --diff-filter=d \
    --diff-merges=first-parent --format= --name-only --no-relative "$range" -- >"$work/paths" ||
    scan_failed "git log $range"
  git --no-replace-objects -c core.quotePath=true log --root --no-show-signature --diff-filter=d \
    --diff-merges=first-parent --format='commit %h' -p --no-relative --submodule=short -M --text \
    --no-textconv --no-color --no-ext-diff -U0 --inter-hunk-context=0 --src-prefix=a/ --dst-prefix=b/ \
    "$range" -- >"$work/diff" || scan_failed "git log $range"
fi
# A NUL byte would make grep treat the whole scan as binary and print no lines.
tr -d '\000' <"$work/diff" >"$work/diff-text" || scan_failed 'tr'

# 1. Block paths under a secrets/ directory that are staged, or that a commit in
# the range added.
added="$(matching_lines "$secrets_path_pattern" "$work/paths")" || scan_failed 'grep'
if [ -n "$added" ]; then
  if [ -z "$range" ]; then
    echo "ERROR: refusing to commit files under a secrets/ directory:" >&2
  else
    printf 'ERROR: commits in %s add files under a secrets/ directory:\n' "$range" >&2
  fi
  printf '%s\n' "$added" | sed 's/^/  /' >&2
  echo "secrets/ must be gitignored; dev secrets are symlinks to a local dir outside the repo (std_git_safety)." >&2
  status=1
fi

# 2. Block already-tracked paths under a secrets/ directory (catches prior force-adds).
# Checks 2 and 3 pin core.quotePath=true for the same reason as the diffs above:
# each path is listed in its C-quoted form and a raw name never reaches grep or
# sed. Both run from the top with -C "$root": git ls-files lists only the
# current folder and names paths relative to it, so a run from a subfolder
# would miss or mislabel one.
git -c core.quotePath=true -C "$root" ls-files >"$work/tracked" || scan_failed 'git ls-files'
tracked="$(matching_lines "$secrets_path_pattern" "$work/tracked")" || scan_failed 'grep'
if [ -n "$tracked" ]; then
  echo "ERROR: tracked files exist under a secrets/ directory; remove them with 'git rm --cached':" >&2
  printf '%s\n' "$tracked" | sed 's/^/  /' >&2
  status=1
fi

# 3. A secrets/ directory or link git would add is not gitignored. git lists
# each untracked, unignored file, so ignored folders such as node_modules are
# never walked, and a secrets link shows as a file of that name.
git -c core.quotePath=true -C "$root" ls-files --others --exclude-standard >"$work/untracked" ||
  scan_failed 'git ls-files --others'
unignored="$(sed -n 's#^\("\{0,1\}\(.*/\)*secrets\)\(/.*\)\{0,1\}"\{0,1\}$#\1/#p' "$work/untracked" | sort -u)" ||
  scan_failed 'sed'
if [ -n "$unignored" ]; then
  printf '%s\n' "$unignored" | while IFS= read -r dir; do
    printf "ERROR: %s exists but is not gitignored. Add 'secrets/' to .gitignore (std_git_safety).\n" "$dir" >&2
  done
  status=1
fi

# 4. Block added content that matches a known credential format. The path
# checks above cannot see a token pasted into a journal entry or a config file,
# which is the one route by which a secret still reached git. Only the diff's
# added lines are scanned, so a commit that removes a credential goes through.
# The report names the commit (in range mode), file, and line and never echoes
# the value (std_shell SH-06); cut keeps only the label, the field before the
# tab. Redact a match at its source; never allowlist it.
label_added_lines "$work/diff-text" "$work/labelled"
matching_lines "$credential_pattern" "$work/labelled" >"$work/matches" || scan_failed 'grep'
credential_hits="$(cut -f1 "$work/matches")" || scan_failed 'cut'
if [ -n "$credential_hits" ]; then
  if [ -z "$range" ]; then
    echo "ERROR: staged content matches a known credential format (file:line):" >&2
  else
    printf 'ERROR: commits in %s add content matching a known credential format (commit:file:line):\n' "$range" >&2
  fi
  printf '%s\n' "$credential_hits" | sed 's/^/  /' >&2
  echo "Redact the value at its source and rotate it (std_git_safety GS-02); never allowlist it." >&2
  status=1
fi

exit "$status"
