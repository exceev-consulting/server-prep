#!/usr/bin/env bash
# shellcheck disable=SC2034
# Tests the swap file part of step_logging with fake commands; no system changes.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
FSTAB_FAKE="$tmp/fstab"
: > "$FSTAB_FAKE"
grep() {
    if [[ $# -ge 1 && ${!#} == /etc/fstab ]]; then
        command grep "${@:1:$#-1}" "$FSTAB_FAKE"
        return
    fi
    command grep "$@"
}

# Load the real functions without starting a run (see tests/exit-status.sh).
# shellcheck disable=SC1091
. "$SCRIPT_DIR/server-prep.sh" --yes
LOG_FILE="$tmp/run.log"
DRY_RUN=0
SWAP_SIZE="2G"
ONLY=""; SKIP=""

# Fake host: no swap yet. `run` only records the command; fallocate, dd, mkswap
# and swapon return the code set by each test. swapon returns SWAPON_RCS in order.
swapon() { :; }
write_file() { cat > /dev/null; WRITTEN+=("$1"); }
run() {
    CMDS+=("$*")
    case "$1" in
        fallocate) return "$FALLOCATE_RC" ;;
        dd) return "$DD_RC" ;;
        mkswap) return "$MKSWAP_RC" ;;
        swapon)
            local rc="${SWAPON_RCS[0]}"
            SWAPON_RCS=("${SWAPON_RCS[@]:1}" "$rc")
            return "$rc" ;;
    esac
    return 0
}

fail() { printf 'not ok: %s\n' "$*"; printf '  commands: %s\n' "${CMDS[@]}"; exit 1; }
ran() { local c; for c in "${CMDS[@]}"; do [[ "$c" == "$1"* ]] && return 0; done; return 1; }

# expect_swap LABEL WANT_RESULT WANT_CREATED [WANT_DETAIL_SUBSTR]   (set fake return codes first)
expect_swap() {
    local label="$1" want_res="$2" want_created="$3" want_detail="${4:-}" fstab=0 created=0
    CMDS=(); WRITTEN=(); STEP_NAMES=(); STEP_RESULTS=(); STEP_DETAILS=(); MANUAL_TODO=()
    run_step logging "Journald & swap" step_logging > "$tmp/out" 2>&1
    [[ " ${WRITTEN[*]} " == *" /etc/fstab "* ]] && fstab=1
    [[ "${STEP_DETAILS[0]}" == *"swap ${SWAP_SIZE} created"* ]] && created=1
    [[ "${STEP_RESULTS[0]}" == "$want_res" ]] || fail "$label: step result ${STEP_RESULTS[0]}, want $want_res"
    [[ $created -eq $want_created ]] || fail "$label: 'swap created' note is $created, want $want_created"
    if [[ -n "$want_detail" ]]; then
        [[ "${STEP_DETAILS[0]}" == *"$want_detail"* ]] || fail "$label: detail ${STEP_DETAILS[0]}, want *$want_detail*"
    fi
    if [[ $want_created -eq 0 ]]; then
        [[ $fstab -eq 0 ]] || fail "$label: /etc/fstab written for a swap file that does not work"
        ran "rm -f /swapfile" || fail "$label: the partial /swapfile was not removed"
    fi
    printf 'ok: %s\n' "$label"
}

FALLOCATE_RC=0; DD_RC=0; MKSWAP_RC=0; SWAPON_RCS=(0)
expect_swap "fallocate swap file works" CHANGED 1
ran "dd " && fail "dd used although the fallocate swap file worked"

FALLOCATE_RC=1; DD_RC=0; MKSWAP_RC=0; SWAPON_RCS=(0)
expect_swap "fallocate fails (disk full): step FAILED" FAILED 0
ran "dd " && fail "dd tried after fallocate itself failed"

FALLOCATE_RC=0; DD_RC=0; MKSWAP_RC=0; SWAPON_RCS=(1 0)
expect_swap "swapon refuses the fallocate file: dd fallback" CHANGED 1
ran "dd if=/dev/zero of=/swapfile bs=1M count=2048" || fail "dd fallback not run with count=2048 for 2G"

FALLOCATE_RC=0; DD_RC=1; MKSWAP_RC=0; SWAPON_RCS=(1)
expect_swap "swapon refuses the fallocate file and dd fails: step FAILED" FAILED 0

FALLOCATE_RC=0; DD_RC=0; MKSWAP_RC=1; SWAPON_RCS=(0)
expect_swap "mkswap fails both times: step FAILED" FAILED 0

SWAP_SIZE="2 G"
FALLOCATE_RC=0; DD_RC=0; MKSWAP_RC=0; SWAPON_RCS=(1)
expect_swap 'SWAP_SIZE="2 G" (invalid for dd fallback): step FAILED' FAILED 0 "size not understood"
SWAP_SIZE="2G"

echo '/swapfile none swap sw 0 0' > "$FSTAB_FAKE"
FALLOCATE_RC=1; DD_RC=0; MKSWAP_RC=0; SWAPON_RCS=(0)
expect_swap "stale fstab line on fallocate failure: todo" FAILED 0
[[ " ${MANUAL_TODO[*]} " == *"Remove the /swapfile line from /etc/fstab"* ]] ||
    fail "stale fstab: expected MANUAL_TODO about removing /swapfile from fstab"
: > "$FSTAB_FAKE"
