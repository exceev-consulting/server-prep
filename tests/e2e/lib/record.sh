# shellcheck shell=bash disable=SC2034
# Scenario bookkeeping for tests/e2e/run.sh: assertions, logs and results.json (schema 1).
# Sourced, not run. Every scenario writes one JSON line to $WORK/scenarios.jsonl.

SC_ID="" SC_TITLE="" SC_GROUP="" SC_START=0 SC_FAILED=0 SC_COUNT=0 SC_REASON="" SC_LOGS=()
N_PASSED=0 N_FAILED=0 N_SKIPPED=0

begin() {   # begin ID: title and group come from SCENARIO_TABLE (scenarios.sh)
    SC_ID="$1" SC_GROUP="${SC_GROUP_OF[$1]}" SC_TITLE="${SC_TITLE_OF[$1]}"
    SC_START=$SECONDS SC_FAILED=0 SC_COUNT=0 SC_REASON=""
    SC_LOGS=("$SC_ID.log")
    : > "$WORK/assertions.jsonl"
    : > "$OUT/$SC_ID.log"
    printf '\n== %s: %s ==\n' "$OS_ID" "$SC_TITLE"
}

log_to() { tee -a "$OUT/$SC_ID.log"; }   # cmd | log_to: keep command output in the scenario log

attach() {   # attach FILE...: extra files (already in $OUT) shown with this scenario
    local f
    for f in "$@"; do [[ -f "$OUT/$f" ]] && SC_LOGS+=("$f"); done
}

check() {   # check "name" STATUS ["detail"]: STATUS 0 = ok
    local name="$1" st="$2" detail="${3:-}" ok=true
    SC_COUNT=$((SC_COUNT + 1))
    if [[ "$st" -ne 0 ]]; then
        ok=false
        SC_FAILED=$((SC_FAILED + 1))
        [[ -n "$SC_REASON" ]] || SC_REASON="$name${detail:+: $detail}"
        printf 'not ok: %s %s: %s%s\n' "$OS_ID" "$SC_ID" "$name" "${detail:+ ($detail)}"
    else
        printf 'ok: %s %s: %s\n' "$OS_ID" "$SC_ID" "$name"
    fi
    printf '%s %s\n' "$($ok && echo ok || echo 'not ok')" "$name${detail:+ - $detail}" >> "$OUT/$SC_ID.log"
    jq -cn --arg n "$name" --argjson ok "$ok" --arg d "$detail" '{name: $n, ok: $ok, detail: $d}' \
        >> "$WORK/assertions.jsonl"
}

check_eq() {   # check_eq "name" GOT WANT
    [[ "$2" == "$3" ]]; check "$1" $? "got '$2', want '$3'"
}

finish() {   # finish [skipped "reason"]: close the scenario and record it
    local status=passed
    if [[ "${1:-}" == skipped ]]; then
        status=skipped SC_REASON="${2:-}"
        printf 'skip: %s %s: %s\n' "$OS_ID" "$SC_ID" "$SC_REASON"
    elif ((SC_FAILED > 0 || SC_COUNT == 0)); then
        status=failed
        [[ -n "$SC_REASON" ]] || SC_REASON="no assertion ran"
    fi
    case $status in
        passed) N_PASSED=$((N_PASSED + 1)) ;;
        failed) N_FAILED=$((N_FAILED + 1)) ;;
        skipped) N_SKIPPED=$((N_SKIPPED + 1)) ;;
    esac
    jq -cn --arg id "$SC_ID" --arg t "$SC_TITLE" --arg g "$SC_GROUP" --arg st "$status" \
        --argjson d $((SECONDS - SC_START)) --arg r "$SC_REASON" \
        --slurpfile a "$WORK/assertions.jsonl" --args \
        '{id: $id, title: $t, group: $g, status: $st, duration_s: $d, reason: $r,
          assertions: $a, logs: $ARGS.positional}' "${SC_LOGS[@]}" >> "$WORK/scenarios.jsonl"
}

skip() {   # skip ID "reason": record a scenario that could not run
    begin "$1"
    finish skipped "$2"
}

write_results() {   # write_results [reason]: $OUT/results.json from everything recorded so far
    local reason="${1:-}" status=passed
    ((N_FAILED > 0)) || [[ -n "$reason" ]] && status=failed
    [[ -s "$WORK/scenarios.jsonl" ]] || : > "$WORK/scenarios.jsonl"
    [[ -s "$WORK/audits.json" ]] || echo '{}' > "$WORK/audits.json"
    [[ -s "$WORK/steps.json" ]] || echo '[]' > "$WORK/steps.json"
    jq -n --arg os "$OS_ID" --arg label "$OS_LABEL" --arg rel "${VM_OS_RELEASE:-}" \
        --arg kernel "${VM_KERNEL:-}" --arg url "$OS_IMAGE_URL" --arg sum "${IMAGE_CHECKSUM:-}" \
        --arg accel "${ACCEL:-}" --argjson cpus "$CPUS" --argjson mem "$MEMORY_MB" \
        --arg started "$STARTED" --argjson dur $((SECONDS - RUN_START)) --arg status "$status" \
        --arg reason "$reason" --argjson p "$N_PASSED" --argjson f "$N_FAILED" --argjson s "$N_SKIPPED" \
        --slurpfile sc "$WORK/scenarios.jsonl" --slurpfile audit "$WORK/audits.json" \
        --slurpfile steps "$WORK/steps.json" \
        '{schema: 1, os: $os, label: $label, os_release: $rel, kernel: $kernel,
          image: {url: $url, checksum: $sum}, accel: $accel, cpus: $cpus, memory_mb: $mem,
          started: $started, duration_s: $dur, status: $status, reason: $reason,
          counts: {passed: $p, failed: $f, skipped: $s}, scenarios: $sc, audit: $audit[0],
          steps: $steps[0],
          files: [{name: "serial.log", title: "Serial console"}, {name: "harness.log", title: "Harness output"}]}' \
        > "$OUT/results.json"
}
