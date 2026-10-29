#!/usr/bin/env bash
# shellcheck disable=SC2034
# End-to-end test of server-preconfig.sh, server-prep.sh and server-audit.sh in a throwaway
# VM booted from an official cloud image, driven over SSH like an operator would.
# Needs qemu-system-x86_64, qemu-img, xorriso, ssh, curl and jq. No root: KVM if /dev/kvm is
# usable, else TCG (slow). Results: <out>/<os>/results.json, read by build-report.sh.
set -u

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$E2E_DIR/../.." && pwd)"
# shellcheck source=tests/e2e/lib/vm.sh
. "$E2E_DIR/lib/vm.sh"
# shellcheck source=tests/e2e/lib/record.sh
. "$E2E_DIR/lib/record.sh"
# shellcheck source=tests/e2e/lib/interact.sh
. "$E2E_DIR/lib/interact.sh"
# shellcheck source=tests/e2e/scenarios.sh
. "$E2E_DIR/scenarios.sh"

usage() {
    cat <<EOF
Usage: tests/e2e/run.sh --os ID [options]
       tests/e2e/run.sh --list-os
       tests/e2e/run.sh --image-key --os ID

  --os ID          system to test (see --list-os)
  --out DIR        results folder (default tests/e2e/out); results go in DIR/ID/
  --only a,b,c     run only these scenarios (the ones they need still run first)
  --keep           leave the VM running at the end, with its disk and keys (in \$E2E_CACHE/runs/)
  --cpus N         VM vCPUs (default 2)
  --memory MB      VM memory (default 4096)
  --list-os        print the system ids
  --image-key      print a cache key for the image (reads only the checksum file)
  -h, --help       this help

Scenarios: ${SCENARIOS[*]}

Environment: E2E_CACHE (default ~/.cache/server-prep-e2e), E2E_ACCEL=auto|kvm|tcg,
E2E_DEADLINE_MIN (default 40: stop starting scenarios after that many minutes).

Exit codes: 0 every scenario passed or was skipped, 1 a scenario failed, 2 usage error.
EOF
}

OS_ARG="" OUT_BASE="$E2E_DIR/out" ONLY="" KEEP=0 CPUS=2 MEMORY_MB=4096 MODE=run
while [[ $# -gt 0 ]]; do
    case $1 in
        --os|--out|--only|--cpus|--memory)
            [[ $# -ge 2 ]] || { echo "$1 needs a value" >&2; exit 2; } ;;&
        --os) OS_ARG="$2"; shift 2 ;;
        --out) OUT_BASE="$2"; shift 2 ;;
        --only) ONLY="${2//,/ }"; shift 2 ;;
        --cpus) CPUS="$2"; shift 2 ;;
        --memory) MEMORY_MB="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        --list-os) MODE=list; shift ;;
        --image-key) MODE=key; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
done
[[ "$CPUS" =~ ^[1-9][0-9]?$ && "$MEMORY_MB" =~ ^[1-9][0-9]{2,5}$ ]] || { echo "--cpus and --memory need numbers" >&2; exit 2; }
for s in $ONLY; do
    [[ " ${SCENARIOS[*]} " == *" $s "* ]] || { echo "Unknown scenario: $s (valid: ${SCENARIOS[*]})" >&2; exit 2; }
done

CACHE_DIR="${E2E_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/server-prep-e2e}"

if [[ $MODE == list ]]; then os_list; exit 0; fi
[[ -n "$OS_ARG" ]] || { echo "--os is required (see --list-os)" >&2; exit 2; }
os_load "$OS_ARG" || { echo "Unknown system: $OS_ARG (valid: $(os_list | paste -sd' '))" >&2; exit 2; }
if [[ $MODE == key ]]; then
    sum="$(image_checksum)" && [[ -n "$sum" ]] || { echo "cannot read $OS_SUMS_URL" >&2; exit 1; }
    echo "$OS_ID-${sum:0:16}"
    exit 0
fi

for tool in qemu-system-x86_64 qemu-img xorriso ssh ssh-keygen curl jq git; do
    command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 2; }
done

OUT="$OUT_BASE/$OS_ID"
rm -rf "$OUT" && mkdir -p "$OUT" || exit 2
mkdir -p "$CACHE_DIR/runs"
WORK="$(mktemp -d "$CACHE_DIR/runs/$OS_ID.XXXXXX")" || exit 2
VM_HOSTNAME="e2e-${OS_ID//./-}"
STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RUN_START=$SECONDS
DEADLINE_S=$(( ${E2E_DEADLINE_MIN:-40} * 60 ))
ACCEL="$(vm_accel)"
[[ $ACCEL == kvm ]] && BOOT_TIMEOUT=300 || BOOT_TIMEOUT=1200
ANSWERS="$E2E_DIR/answers.tsv" ANSWER_ADMIN_USER=admin
CHANNEL=ops VM_UP=0 PREP_DONE=0 NO_ICMP=0 ABORT="" SKIP_REASON=""
VM_OS_RELEASE="" VM_KERNEL="" IMAGE="" IMAGE_CHECKSUM="" P22="" P822="" PDOCK=""
export E2E_ADMIN_PASSWORD="e2e-$RANDOM-$RANDOM-$RANDOM"

exec > >(tee -a "$OUT/harness.log") 2>&1

collect_logs() {   # the server's own logs, so a failure in CI can be read without the VM
    vm_running || return 0
    SSH_LIMIT=60 as_root 'journalctl -b --no-pager -o short-precise | tail -n 20000' > "$OUT/journal.log" 2>/dev/null \
        || rm -f "$OUT/journal.log"
    SSH_LIMIT=60 as_root 'cat $(ls -tr /var/log/server-prep/run-*.log 2>/dev/null) /dev/null' > "$OUT/server-prep-runs.log" 2>/dev/null
    [[ -s "$OUT/server-prep-runs.log" ]] || rm -f "$OUT/server-prep-runs.log"
}

on_exit() {
    collect_logs
    [[ $KEEP -eq 1 ]] || vm_kill
    jq -n --slurpfile a <(cat "$WORK/steps-first.json" 2>/dev/null || echo '[]') \
          --slurpfile b <(cat "$WORK/steps-second.json" 2>/dev/null || echo '[]') \
        '($b[0] | map({(.step): .result}) | add // {}) as $second
         | $a[0] | map({step, label, first: .result, second: ($second[.step] // "")})' \
        > "$WORK/steps.json" 2>/dev/null || echo '[]' > "$WORK/steps.json"
    write_results "$ABORT"
    if [[ $KEEP -eq 1 ]]; then
        echo "kept: $WORK (disk.qcow2, keys/)"
        if vm_running; then
            echo "the VM is still running. Log in with:"
            if [[ $CHANNEL == root ]]; then
                echo "  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $WORK/keys/panel -p $P822 root@127.0.0.1"
            else
                echo "  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $WORK/keys/ops -p $P22 ops@127.0.0.1"
            fi
            echo "stop it with: kill \$(cat $WORK/qemu.pid)"
        fi
    else
        rm -rf "$WORK"
    fi
    printf '\n%s: %d passed, %d failed, %d skipped in %ds -> %s\n' "$OS_ID" "$N_PASSED" "$N_FAILED" \
        "$N_SKIPPED" $((SECONDS - RUN_START)) "$OUT/results.json"
}
trap on_exit EXIT
trap 'ABORT="interrupted"; exit 1' INT TERM
# When the job is cancelled, tee can die first: keep going so on_exit still writes results.json.
trap '' PIPE

printf 'server-prep e2e: %s (%s), %s vCPU, %s MB, %s\n' "$OS_ID" "$OS_LABEL" "$CPUS" "$MEMORY_MB" "$ACCEL"

selected() {   # selected ID: in --only, or needed by a scenario in --only
    local s
    [[ -z "$ONLY" || " $ONLY " == *" $1 "* || $1 == boot ]] && return 0
    if [[ $1 == prep-run ]]; then
        # every scenario after the real run needs a prepared server
        for s in $ONLY; do
            [[ " audit-fresh preconfig prep-dry-run prep-interactive " == *" $s "* ]] || return 0
        done
    fi
    return 1
}

for id in "${SCENARIOS[@]}"; do
    selected "$id" || continue
    if ((SECONDS - RUN_START > DEADLINE_S)); then
        skip "$id" "time limit reached (E2E_DEADLINE_MIN=${E2E_DEADLINE_MIN:-40})"
        ABORT="time limit reached"
        continue
    fi
    if ! needs "$id"; then
        skip "$id" "$SKIP_REASON"
        continue
    fi
    "sc_${id//-/_}"
done

((N_FAILED == 0)) && [[ -z "$ABORT" ]]
