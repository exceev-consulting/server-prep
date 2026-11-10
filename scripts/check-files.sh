#!/usr/bin/env bash
# Fails when a file that must stay local is tracked by git, or when a tracked text file holds an
# IPv4 address that is not an example (issue #40). It reads the index, not the work tree: run it after
# `git add`, before `git commit`. CI runs it on the repository through tests/check-files.sh (run by
# tests/exit-status.sh). The security workflow and the scripts/check.sh section of #40 are still to come.
#
# Forbidden files: the list mirrors the sensitive groups of .gitignore: reports and audit files,
# logs, filled configs, Claude Code's local files and secrets (.env, *.pem, *.key). Keep the two
# in step: tests/check-files.sh checks that every forbidden name is also ignored. The list comes
# from `git ls-files`, so a file added with `git add -f` is caught too.
#
# IPv4 addresses: the staged copy of every tracked text file is searched (binary files and symlinks
# are skipped).
# Allowed:
#   - any address in 127.0.0.0/8, 10.0.0.0/8 and 192.168.0.0/16 (loopback and private examples)
#   - any address in the documentation ranges 192.0.2.0/24, 198.51.100.0/24 and 203.0.113.0/24
#   - exactly 0.0.0.0 (with or without a prefix), 1.1.1.1 and 100.100.100.100 (Tailscale's DNS)
#   - exactly the ranges 100.64.0.0/10 (Tailscale) and 172.16.0.0/12 (private), written that way:
#     a single address inside them fails
# Octets and prefixes with leading zeros are read as decimal (010.0.0.1 is 10.0.0.1). A number
# with an octet over 255 or longer than 3 digits is not an address and is skipped. A dotted number
# with five parts or more is a version (1.2.3.4.5) and is skipped too, unless a domain follows it:
# in a host name like <id>.203.0.113.10.sslip.io or web-01.203.0.113.10.nip.io its last four parts
# are the address. A version with exactly four parts cannot be told apart from an address: it is
# checked as one, and fails unless it falls in an allowed range.
#
# It does not catch a real address inside 10.x or 192.168.x, or tokens and keys: gitleaks
# (.gitleaks.toml) looks for those.
#
# Usage: scripts/check-files.sh
#   No arguments: it checks the repository it belongs to, from any folder.
#   Exit status: 0 nothing found, 1 a forbidden file or a non-example address,
#   2 not a git work tree (or a copy inside another repository), git missing or git failed.
set -euo pipefail
export LC_ALL=C

if (( $# > 0 )); then
    printf 'Usage: scripts/check-files.sh (no arguments)\n' >&2
    exit 2
fi

cd "$(dirname "$0")/.." || exit 2
if ! command -v git >/dev/null 2>&1 || ! top="$(git rev-parse --show-toplevel 2>/dev/null)" || [[ -z $top ]]; then
    printf 'check-files: not a git work tree\n' >&2
    exit 2
fi
# A copy with no .git of its own, unpacked inside another repository, would scan that outer one
if [[ ! $top -ef . ]]; then
    printf 'check-files: %s is not the top of a git work tree (git found %s instead)\n' "$PWD" "$top" >&2
    exit 2
fi
cd "$top"

# git output goes through a file: bash variables cannot hold the NUL bytes of -z
out="$(mktemp)" || exit 2
trap 'rm -f "$out"' EXIT

git_failed() {
    printf 'check-files: git %s failed\n' "$1" >&2
    exit 2
}

problems=0
problem() {
    printf 'check-files: %s\n' "$1"
    problems=$((problems + 1))
}

# forbidden_reason PATH: prints why PATH must not be committed, or returns 1 when it may be.
# Name patterns (no slash) apply at any depth, the way .gitignore reads them.
forbidden_reason() {
    local path="$1" base="${1##*/}" fixture
    [[ $path == .claude/settings.local.json ]] && { printf 'Claude Code local settings'; return 0; }
    case "$base" in
        CLAUDE.local.md) printf 'local Claude Code context' ;;
        *.conf) printf 'filled config' ;;
        server-audit-* | server-prep-report-* | *-report-*.md | *-report-*.txt) printf 'report' ;;
        audit.md | audit.json | audit.tsv) printf 'audit file' ;;
        *.log)
            # .gitignore keeps tests/e2e/fixtures/*/*.log: the fake results the report test reads
            fixture="${path#tests/e2e/fixtures/}"
            if [[ $fixture != "$path" && $fixture == */* && ${fixture#*/} != */* ]]; then
                return 1
            fi
            printf 'log'
            ;;
        .env | *.pem | *.key) printf 'secret' ;;
        *) return 1 ;;
    esac
}

# Part 1: names of the tracked files
git ls-files -z >"$out" || git_failed ls-files
files=0
while IFS= read -r -d '' path; do
    files=$((files + 1))
    if reason="$(forbidden_reason "$path")"; then
        problem "$path: must not be committed ($reason). Untrack it: git rm --cached -- '${path//\'/\'\\\'\'}'"
    fi
done <"$out"

# ip_allowed A B C D [PREFIX]: the octets and the prefix are already decimal, without leading zeros
ip_allowed() {
    local addr="$1.$2.$3.$4" full="$1.$2.$3.$4${5:+/$5}"
    [[ $addr == 0.0.0.0 ]] && return 0
    case "$full" in
        1.1.1.1 | 100.100.100.100 | 100.64.0.0/10 | 172.16.0.0/12) return 0 ;;
    esac
    case "$addr" in
        127.* | 10.* | 192.168.* | 192.0.2.* | 198.51.100.* | 203.0.113.*) return 0 ;;
    esac
    return 1
}

# Every dotted number of four parts or more, with its prefix. POSIX regexes take the leftmost and
# then the longest match, so a match is always a whole dotted number, never a piece of one.
ip_re='[0-9]+(\.[0-9]+){3,}(/[0-9]+)?'

# scan_line FILE N TEXT: reports every IPv4 address of line N that is not an example
scan_line() {
    local file="$1" n="$2" rest="$3" m after prefix shown octet i ok
    local -a parts
    while [[ $rest =~ $ip_re ]]; do
        m="${BASH_REMATCH[0]}"
        after="${rest#*"$m"}"
        rest="$after"
        prefix=""
        [[ $m == */* ]] && prefix="${m#*/}"
        IFS=. read -r -a parts <<<"${m%%/*}"
        if (( ${#parts[@]} > 4 )); then
            # a version like 1.2.3.4.5, unless a domain follows: <id>.203.0.113.10.sslip.io
            [[ $after == .[A-Za-z]* ]] || continue
            parts=("${parts[@]: -4}")
        fi
        shown="${parts[0]}.${parts[1]}.${parts[2]}.${parts[3]}${prefix:+/$prefix}"
        ok=1
        for i in 0 1 2 3; do
            octet="${parts[i]}"
            # the length test comes first: 10# on a long number would overflow
            if (( ${#octet} > 3 )) || (( 10#$octet > 255 )); then
                ok=0
                break
            fi
            parts[i]=$((10#$octet))
        done
        (( ok )) || continue   # not an address, like 203.0.113.300
        if [[ -n $prefix ]]; then
            prefix="${prefix#"${prefix%%[!0]*}"}"
            prefix="${prefix:-0}"
        fi
        ip_allowed "${parts[@]}" "$prefix" && continue
        problem "$file:$n: $shown is not an example IPv4 address (use 192.168.1.50, 203.0.113.10 or another documentation range)"
    done
}

# Part 2: IPv4 addresses in the tracked text files. With --cached, git grep searches the staged
# copy of each tracked file (what a commit takes), skips binary ones (-I) and reads a symlink as its
# link text. --no-column overrides grep.column.
status=0
git grep --cached --no-color --no-column -I -n -z -E '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' >"$out" || status=$?
(( status >= 2 )) && git_failed grep
# each record: file NUL line-number NUL text newline
while IFS= read -r -d '' file && IFS= read -r -d '' n && IFS= read -r line; do
    scan_line "$file" "$n" "$line"
done <"$out"

if (( problems > 0 )); then
    printf 'check-files: %s problem(s)\n' "$problems"
    exit 1
fi
printf 'check-files: %s tracked files, none forbidden, every IPv4 address is an example\n' "$files"
