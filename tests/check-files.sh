#!/usr/bin/env bash
# Runs scripts/check-files.sh, the committed-file guard (issue #40), on this repository first:
# tests/exit-status.sh runs this test, so CI fails when a report, filled config, key or
# CLAUDE.local.md is tracked, or when an IPv4 address is not an example. Then it tests the guard on
# throwaway git repos built in a temp folder: tracked reports, filled configs, keys and
# CLAUDE.local.md fail, the forbidden list stays in step with .gitignore, and an IPv4 address that
# is not an example fails with its file and line. No root needed and nothing on the host changes.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v git >/dev/null 2>&1; then
    printf 'skip: committed-file guard (git not found)\n'
    exit 0
fi

# 0. This repository. A release tarball has no .git: skip then, and never check an outer repository
# the tarball was unpacked in.
top="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" || top=""
if [[ -n $top && $top -ef $SCRIPT_DIR ]]; then
    if ! bash "$SCRIPT_DIR/scripts/check-files.sh"; then
        printf 'not ok: check-files on this repository (it reads the staged copy: fix the file and git add it, or git rm --cached a forbidden file)\n'
        git -C "$SCRIPT_DIR" diff --quiet 2>/dev/null || printf 'note: some tracked files have changes that are not staged yet: git add them, then run this again\n'
        exit 1
    fi
    printf 'ok: check-files on this repository\n'
else
    printf 'skip: check-files on this repository (not a git work tree)\n'
fi

# Stop before any path is built if mktemp fails: an empty $tmp would put the test repos in /.
if ! tmp="$(mktemp -d)" || [[ -z $tmp || ! -d $tmp ]]; then
    printf 'not ok: mktemp -d failed, no temporary directory for the test repos\n'
    exit 1
fi
trap 'rm -rf "$tmp"' EXIT

# Keep git away from the user's and the system's settings, and from any outer repository.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CEILING_DIRECTORIES="$tmp"

repo="$tmp/repo"

ip() {   # ip A B C D: prints A.B.C.D, so this file holds no dotted address the guard would flag
    local IFS=.
    printf '%s' "$*"
}

new_repo() {   # a fresh repo holding the guard and the real .gitignore (ls-files and git grep read the index: no commit needed)
    rm -rf "$repo"
    mkdir -p "$repo/scripts"
    cp "$SCRIPT_DIR/scripts/check-files.sh" "$repo/scripts/"
    cp "$SCRIPT_DIR/.gitignore" "$repo/"
    git -C "$repo" -c init.defaultBranch=main init -q
    git -C "$repo" add -- .gitignore scripts/check-files.sh
}

add_file() {   # add_file PATH [CONTENT]: writes PATH in the repo and tracks it, even when .gitignore ignores it
    mkdir -p "$(dirname "$repo/$1")"
    printf '%s\n' "${2-x}" >"$repo/$1"
    git -C "$repo" add -f -- "$1"
}

expect() {   # expect WANT_STATUS LABEL [TEXT [ARG...]]: runs the guard from outside the repo
    local want="$1" label="$2" text="${3-}" status=0
    shift 2
    (( $# > 0 )) && shift
    (cd "$tmp" && bash "$repo/scripts/check-files.sh" "$@") >"$tmp/out" 2>&1 || status=$?
    if [[ $status -ne $want ]] || { [[ -n $text ]] && ! grep -qF -- "$text" "$tmp/out"; }; then
        printf 'not ok: check-files %s (status %s, want %s)\n' "$label" "$status" "$want"
        cat "$tmp/out"
        exit 1
    fi
    printf 'ok: check-files %s\n' "$label"
}

forbidden=(
    CLAUDE.local.md .claude/settings.local.json web-01.conf docs/web-01.conf
    server-audit-web-01-20260101.txt server-prep-report-web-01-2026-01-01.md
    server-prep-report-web-01-2026-01-01.json server-prep-report-web-01-2026-01-01.md.bak
    x-report-1.md x-report-1.txt
    audit.md audit.json audit.tsv sub/audit.json .env deploy.pem id.key run.log
    tests/e2e/fixtures/passed/sub/boot.log
)
allowed=(
    server-prep.conf.example extras/telegraf/telegraf.conf.example tests/e2e/fixtures/passed/boot.log
    tests/e2e/ci.cfg CLAUDE.local.md.example tests/e2e-report.sh
)

# 1. A repo with nothing to flag
new_repo
expect 0 'clean repo passes' 'none forbidden, every IPv4 address is an example'

# 2. Every forbidden name, force-added, fails and names the file
for name in "${forbidden[@]}"; do
    new_repo
    add_file "$name"
    expect 1 "flags $name" "check-files: $name: must not be committed"
done
expect 1 'tells how to untrack it' "Untrack it: git rm --cached -- 'tests/e2e/fixtures/passed/sub/boot.log'"

# 3. Names that look close but are allowed
new_repo
for name in "${allowed[@]}"; do add_file "$name"; done
expect 0 'allows the example config, the fixtures and the report scripts' 'none forbidden'

# 4. A forbidden file deleted from the work tree but still in the index
new_repo
add_file web-01.conf
rm -f "$repo/web-01.conf"
expect 1 'flags a deleted file still in the index' 'check-files: web-01.conf: must not be committed (filled config)'

# 5. The forbidden list stays in step with .gitignore
new_repo
for name in "${forbidden[@]}"; do
    if ! git -C "$repo" check-ignore -q --no-index -- "$name"; then
        printf 'not ok: check-files forbids %s but .gitignore does not ignore it\n' "$name"
        exit 1
    fi
done
for name in "${allowed[@]}"; do
    status=0
    git -C "$repo" check-ignore -q --no-index -- "$name" || status=$?
    if [[ $status -ne 1 ]]; then
        printf 'not ok: check-files allows %s but .gitignore ignores it (status %s)\n' "$name" "$status"
        exit 1
    fi
done
printf 'ok: check-files forbidden list in step with .gitignore\n'

# 6. Every allowed form of address, and numbers that are not addresses
new_repo
add_file docs/examples.md "Loopback 127.0.0.1, 127.0.1.1 and 127.0.0.1/8.
Any interface: 0.0.0.0 and 0.0.0.0/0.
Private examples: 10.0.0.0/8, 10.1.2.3 and 192.168.1.50/24.
Documentation: 192.0.2.10, 198.51.100.7, 203.0.113.10 and 203.0.113.0/24.
Tailscale 100.64.0.0/10, MagicDNS 100.100.100.100, Cloudflare 1.1.1.1, Docker 172.16.0.0/12.
Not addresses: 203.0.113.300, 256.1.2.3, 1000.1.1.1 and the versions 1.2.3.4.5, v1.2.3.4.5 and 1.2.3.4.5.6.7.8.
Example host names: app.192.168.1.50.sslip.io, web-01.10.0.0.1.nip.io and abc1.203.0.113.10.sslip.io.
Leading zeros: 010.0.0.1, 192.168.001.050 and 192.168.1.0/024."
expect 0 'allows the example addresses' 'every IPv4 address is an example'

# 7. Addresses that are not examples fail with the file and the line
bad="$(ip 100 64 1 2)"
new_repo
add_file 'docs/my notes.md' "# Notes

Connect to $bad over Tailscale."
expect 1 'flags a single Tailscale address' "check-files: docs/my notes.md:3: $bad is not an example IPv4 address"
for addr in "$(ip 172 16 5 4)" "$(ip 1 1 1 2)" "$(ip 11 0 0 1)" "$(ip 100 101 102 103)" "$(ip 100 64 0 0)/11" "$(ip 1 1 1 1)/0"; do
    new_repo
    add_file docs/a.md "Server: $addr"
    expect 1 "flags $addr" "check-files: docs/a.md:1: $addr is not an example IPv4 address"
done
new_repo
add_file docs/a.md "The server is $bad."
expect 1 'flags an address before a full stop' "docs/a.md:1: $bad is not"
new_repo
add_file docs/a.md "From $bad to $(ip 1 1 1 2)"
expect 1 'flags each address of a line' 'check-files: 2 problem(s)'
# An address inside a host name, like the app URLs of sslip.io and nip.io: the label before it is
# not a version, even when it ends with digits.
for url in "http://x8k4gs0c8w0ksgo4kc4s0w4w.$bad.sslip.io" "https://app.$bad.nip.io/" \
    "http://x8k4gs0c8w0ksgo4kc4s0w40.$bad.sslip.io" "https://web-01.$bad.nip.io" "https://1.$bad.nip.io"; do
    new_repo
    add_file docs/a.md "Open $url to see the app."
    expect 1 "flags the address in $url" "check-files: docs/a.md:1: $bad is not an example IPv4 address"
done

# 8. Only tracked text files are searched
new_repo
printf 'Server: %s\n' "$bad" >"$repo/untracked.md"
printf 'binary\0%s\n' "$bad" >"$repo/data.bin"
printf 'Server: %s\n' "$bad" >"$tmp/outside.md"
ln -s "$tmp/outside.md" "$repo/link.md"
git -C "$repo" add -- data.bin link.md
expect 0 'skips untracked files, binary files and symlinks' 'every IPv4 address is an example'

# 9. The staged copy is what counts: an address staged, then removed from the work tree only
new_repo
add_file docs/a.md "Server: $bad"
printf 'Server: %s\n' "$(ip 203 0 113 10)" >"$repo/docs/a.md"
expect 1 'flags an address that is staged but no longer in the work tree' "check-files: docs/a.md:1: $bad is not"
# ... and the other way round: an address only in the work tree is not part of a commit yet
new_repo
add_file docs/a.md "Server: $(ip 203 0 113 10)"
printf 'Server: %s\n' "$bad" >"$repo/docs/a.md"
expect 0 'reads the staged copy, not the work tree' 'every IPv4 address is an example'

# 10. Outside a git work tree
mkdir -p "$tmp/plain/scripts"
cp "$SCRIPT_DIR/scripts/check-files.sh" "$tmp/plain/scripts/"
status=0
(cd "$tmp" && bash "$tmp/plain/scripts/check-files.sh") >"$tmp/out" 2>&1 || status=$?
if [[ $status -ne 2 ]] || ! grep -qF 'check-files: not a git work tree' "$tmp/out"; then
    printf 'not ok: check-files outside a git work tree (status %s, want 2)\n' "$status"
    cat "$tmp/out"
    exit 1
fi
printf 'ok: check-files outside a git work tree\n'

# 11. It takes no arguments
new_repo
expect 2 'rejects an argument' 'Usage: scripts/check-files.sh' --help
