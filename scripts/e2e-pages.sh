#!/usr/bin/env bash
# e2e-pages.sh - build the e2e/ part of the GitHub Pages site from the latest e2e workflow runs.
# pages.yml runs it from main on every deploy, so nothing is stored in git and a closed PR's report
# is gone after the next deploy.
#
#   REPO=owner/name GH_TOKEN=... scripts/e2e-pages.sh --out DIR
#
#   DIR/main/     the latest finished run on main (push, schedule or workflow_dispatch)
#   DIR/pr-<n>/   the latest finished run of each open pull request
#   DIR/index.*   the list of these reports
#
# Prints "published: main pr-12 ..." and writes prs=<numbers> to $GITHUB_OUTPUT when it is set.
# Needs gh, jq and unzip. Exit 0 when the pages are built (even with no report), 1 on an error, 2 on a usage error.
#
# The VM artifacts are untrusted data: a fork pull request controls their content. This script keeps only
# top-level files with safe names, within size limits, and hands them to tests/e2e/build-report.sh, which
# validates and escapes them. The PR number and title, the commit and the run link come from the GitHub API.
set -euo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_REPORT="$ROOT/tests/e2e/build-report.sh"
IMAGES="$ROOT/tests/e2e/images.tsv"
WORKFLOW=e2e.yml
MAIN_BRANCH=main

MAX_PAGES=10                          # pages of 100 runs searched for each report
MAX_ZIP=$((128 * 1024 * 1024))        # largest artifact downloaded
MAX_FILE=$((32 * 1024 * 1024))        # largest file kept from an artifact (the report keeps its last 5 MiB)
MAX_OS_BYTES=$((96 * 1024 * 1024))    # all files kept for one OS
MAX_FILES=60                          # files kept for one OS
MAX_REPORT=$((100 * 1024 * 1024))     # largest report published: a Pages site is limited to 1 GB
NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'
OS_RE='^[a-z0-9][a-z0-9.-]*$'

OUT=""
while (($#)); do
    case "$1" in
        --out) [[ $# -ge 2 && -n "$2" ]] || { echo "--out needs a directory" >&2; exit 2; }
               OUT="$2"; shift 2 ;;
        -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
done
[[ -n "$OUT" ]] || { echo "Usage: scripts/e2e-pages.sh --out DIR (see --help)" >&2; exit 2; }
[[ "${REPO:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "Set REPO=owner/name" >&2; exit 2; }
for cmd in gh jq unzip; do
    command -v "$cmd" >/dev/null || { echo "$cmd is required" >&2; exit 2; }
done

# Text from the API or the artifacts can't start a workflow command: log lines start with "e2e-pages:"
# ("::cmd::" works only at the start of a line) and "##[" is broken up (the old form works anywhere).
log() { local msg="$*"; printf 'e2e-pages: %s\n' "${msg//"##["/"# #["}" >&2; }
warn() {
    local msg="$*"
    if [[ "${GITHUB_ACTIONS:-}" == true ]]; then printf '::warning::e2e-pages: %s\n' "${msg//"##["/"# #["}" >&2
    else log "warning: $msg"; fi
}
die() { log "error: $*"; exit 1; }

[[ -f "$BUILD_REPORT" ]] || die "missing $BUILD_REPORT"
if [[ -e "$OUT" && -n "$(find "$OUT" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    echo "$OUT is not empty: give a new or empty directory" >&2; exit 2
fi
mkdir -p -- "$OUT"
OUT="$(cd -- "$OUT" && pwd)"

TMP="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/e2e-pages.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
GENERATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# OS ids from images.tsv, in file order: only these names are read from a run.
KNOWN_OS=()
if [[ -f "$IMAGES" ]]; then
    while IFS=$'\t' read -r id _ || [[ -n "$id" ]]; do
        [[ "$id" =~ $OS_RE ]] && KNOWN_OS+=("$id")
    done < "$IMAGES"
else
    warn "no tests/e2e/images.tsv: no OS results can be read"
fi
is_os() {
    local id
    for id in "${KNOWN_OS[@]}"; do [[ "$1" == "$id" ]] && return 0; done
    return 1
}

# gh api with retries, so one 502 does not drop a report. Prints the body; returns 4 on HTTP 404.
api() {
    local try
    for try in 1 2 3; do
        if gh api "$@" > "$TMP/api.out" 2> "$TMP/api.err"; then
            cat "$TMP/api.out"; return 0
        fi
        grep -q 'HTTP 404' "$TMP/api.err" && return 4
        ((try == 3)) || sleep $((try * 5))
    done
    log "gh api $1: $(tail -n 1 "$TMP/api.err")"
    return 1
}

# latest_run BRANCH HEAD_REPO EVENT... - print the newest finished run (one JSON line), or nothing.
# Cancelled runs were superseded or stopped by hand: only success and failure count.
latest_run() {
    local branch="$1" head_repo="$2" page runs found count events
    shift 2
    events="$(printf '%s\n' "$@" | jq -Rnc '[inputs]')"
    local query=(-X GET -f branch="$branch" -f status=completed -f per_page=100)
    (($# == 1)) && query+=(-f event="$1")
    for ((page = 1; page <= MAX_PAGES; page++)); do
        runs="$(api "repos/$REPO/actions/workflows/$WORKFLOW/runs" "${query[@]}" -f page="$page")" || return 1
        found="$(jq -c --arg repo "$head_repo" --argjson events "$events" '
            first(.workflow_runs[]?
                  | select(.head_repository.full_name == $repo
                           and (.event as $e | any($events[]; . == $e))
                           and (.conclusion == "success" or .conclusion == "failure"))
                  | {id, event, head_sha, head_branch, html_url, updated_at}) // empty' <<< "$runs")" || return 1
        if [[ -n "$found" ]]; then printf '%s\n' "$found"; return 0; fi
        count="$(jq '.workflow_runs | length' <<< "$runs")" || return 1
        ((count == 100)) || return 0
    done
    log "no finished run on $branch in the last $MAX_PAGES pages of runs"
    return 0
}

# fetch_results ARTIFACT_ID DIR - download one VM artifact into DIR and keep its top-level files with
# safe names, within the size limits. Fails when the artifact can't be read or has no results.json.
fetch_results() {
    local aid="$1" dest="$2" zip="$2.zip" try size entry cap budget="$MAX_OS_BYTES" n=0
    mkdir -p -- "$dest" || return 1
    for try in 1 2 3; do
        # gh follows the redirect to the zip; head caps what a lying size_in_bytes could write
        { gh api "repos/$REPO/actions/artifacts/$aid/zip" 2> "$TMP/api.err" || :; } \
            | head -c $((MAX_ZIP + 1)) > "$zip"
        size="$(wc -c < "$zip")"
        ((size <= MAX_ZIP)) || { warn "artifact $aid is over $MAX_ZIP bytes: skipped"; return 1; }
        unzip -qql "$zip" > /dev/null 2>&1 && break
        if ((try == 3)); then
            log "artifact $aid: not a zip after 3 downloads: $(tail -n 1 "$TMP/api.err")"; return 1
        fi
        sleep $((try * 5))
    done
    # results.json first, so the size budget never drops it
    while IFS= read -r entry; do
        [[ "$entry" =~ $NAME_RE ]] || continue
        if ((++n > MAX_FILES)); then warn "artifact $aid has more than $MAX_FILES files: kept the first ones"; break; fi
        cap=$((budget < MAX_FILE ? budget : MAX_FILE))
        if ((cap <= 0)); then warn "artifact $aid is over $MAX_OS_BYTES bytes unpacked: kept part of it"; break; fi
        # unzip -p writes data only (no path, no symlink, no mode); head bounds a zip bomb
        { unzip -p "$zip" "$entry" 2> /dev/null || :; } | head -c "$cap" > "$dest/$entry"
        size="$(wc -c < "$dest/$entry")"
        ((size < cap)) || warn "artifact $aid: $entry cut at $cap bytes"
        budget=$((budget - size))
    done < <(unzip -Z1 "$zip" 2> /dev/null | sort -u \
             | awk '$0 == "results.json" { print; next } { rest[++n] = $0 } END { for (i = 1; i <= n; i++) print rest[i] }')
    rm -f -- "$zip"
    [[ -f "$dest/results.json" ]]
}

# publish RUN_JSON NAME SOURCE [PR TITLE] - build OUT/NAME from one run, in the empty directory $WORK.
# Returns 0 when published, 3 when the run has nothing to show (artifacts expired: not an error),
# 4 when the report is refused (too big, build failed) and 1 when the API failed.
# Called from a condition, where set -e is off: every failure needs its own return.
publish() {
    local run="$1" name="$2" source="$3" pr="${4:-}" title="${5:-}"
    local id sha event branch url date jobs arts job concl aid aname asize aexpired os size status line
    local -A expected=() got=() seen=() broken=() expired=()
    local dirs=() missing=() meta=() entry

    IFS=$'\t' read -r id sha event branch url date \
        < <(jq -r '[.id, .head_sha, .event, .head_branch, .html_url, .updated_at] | @tsv' <<< "$run") || return 1
    if ! [[ "$id" =~ ^[0-9]+$ && "$sha" =~ ^[0-9a-f]{40}$ && "$event" =~ ^[a-z_]+$ && "$url" == https://* ]]; then
        log "$name: unexpected run data from the API"; return 1
    fi
    log "$name: run $id ($event, ${sha:0:7})"

    # Expected OSes: the VM jobs are named after their OS id.
    jobs="$(api "repos/$REPO/actions/runs/$id/jobs?per_page=100" --paginate \
                --jq '.jobs[] | [.name, (.conclusion // .status // "")] | @tsv')" || return 1
    while IFS=$'\t' read -r job concl; do
        is_os "$job" || continue
        [[ "$concl" =~ ^[a-z_]+$ ]] || concl=unknown
        expected["$job"]="$concl"
    done <<< "$jobs"

    arts="$(api "repos/$REPO/actions/runs/$id/artifacts?per_page=100" --paginate \
                --jq '.artifacts[] | [.id, .name, .size_in_bytes, .expired] | @tsv')" || return 1
    # Newest first: a re-run uploads a second artifact with the same name. The list is read on
    # fd 3 so that nothing in the loop can read it from standard input.
    while IFS=$'\t' read -r -u 3 aid aname asize aexpired; do
        [[ "$aid" =~ ^[0-9]+$ && "$aname" == e2e-vm-* ]] || continue
        os="${aname#e2e-vm-}"
        is_os "$os" || continue
        [[ -z "${seen[$os]:-}" ]] || continue
        seen["$os"]=1
        if [[ "$aexpired" == true ]]; then expired["$os"]=1; continue; fi
        if ! [[ "$asize" =~ ^[0-9]+$ ]] || ((asize > MAX_ZIP)); then
            warn "$name: artifact for $os is over $MAX_ZIP bytes: skipped"; broken["$os"]=1; continue
        fi
        if fetch_results "$aid" "$WORK/$os" < /dev/null; then got["$os"]=1
        else log "$name: no usable results for $os"; broken["$os"]=1
        fi
    done 3< <(sort -t $'\t' -k1,1nr <<< "$arts")

    for os in "${KNOWN_OS[@]}"; do
        if [[ -n "${got[$os]:-}" ]]; then
            dirs+=("$WORK/$os")
        elif [[ -n "${broken[$os]:-}" ]]; then
            missing+=(--missing "$os=results could not be read from the artifact")
        elif [[ -n "${expired[$os]:-}" ]]; then
            missing+=(--missing "$os=the results of this run expired")
        elif [[ -n "${expected[$os]:-}" ]]; then
            missing+=(--missing "$os=VM job ended without results (${expected[$os]})")
        fi
    done
    if ((${#dirs[@]} == 0)); then
        if ((${#expired[@]} > 0)); then log "$name: the artifacts of run $id expired: no report"; return 3; fi
        if ((${#missing[@]} == 0)); then log "$name: run $id has no VM results: no report"; return 3; fi
    fi

    meta=(--meta "repo=$REPO" --meta "sha=$sha" --meta "ref=$branch" --meta "run_id=$id" --meta "run_url=$url"
          --meta "event=$event" --meta "generated=$GENERATED" --meta "source=$source")
    [[ -z "$pr" ]] || meta+=(--meta "pr=$pr" --meta "pr_title=$title")
    mkdir -p -- "$WORK/report" || return 1
    if ! bash "$BUILD_REPORT" --out "$WORK/report" "${meta[@]}" "${missing[@]}" "${dirs[@]}" \
            < /dev/null > "$WORK/build.log" 2>&1; then
        while IFS= read -r line; do log "  $line"; done < "$WORK/build.log"
        warn "$name: build-report.sh failed: report skipped"; return 4
    fi
    size="$(du -sb "$WORK/report" | cut -f1)" || return 1
    if ((size > MAX_REPORT)); then warn "$name: report is $size bytes, over $MAX_REPORT: skipped"; return 4; fi

    # The index entry first: a report on the site is always in the index.
    status="$(jq -r '.status' "$WORK/report/summary.json" 2> /dev/null)" || status=""
    [[ "$status" == passed ]] || status=failed
    entry="$(jq -nc --arg path "$name/" --arg kind "$source" --arg pr "$pr" --arg title "$title" \
                    --arg sha "$sha" --arg status "$status" --arg run_url "$url" --arg date "$date" \
                    --slurpfile s "$WORK/report/summary.json" '
        {path: $path, kind: $kind}
        + (if $pr == "" then {} else {pr: ($pr | tonumber)} end)
        + {title: $title, sha: $sha, status: $status, run_url: $run_url, date: $date}
        + ($s[0] | {counts, oses: [.oses[]? | {os, label, status, duration_s,
                                               audit_fail: (.audit_rebooted.fail? // null)}]})')" || return 1
    rm -rf -- "${OUT:?}/$name"
    mv -- "$WORK/report" "$OUT/$name" || return 1
    printf '%s\n' "$entry" >> "$TMP/reports.jsonl"
}

PUBLISHED=()
API_ERRORS=0
: > "$TMP/reports.jsonl"

# try_publish RUN_JSON NAME SOURCE [PR TITLE] - publish one report; a failure is logged and skipped.
try_publish() {
    local rc=0
    WORK="$(mktemp -d "$TMP/work.XXXXXX")"
    publish "$@" < /dev/null || rc=$?
    rm -rf -- "$WORK"
    case "$rc" in
        0) PUBLISHED+=("$2") ;;
        3|4) ;;
        *) API_ERRORS=$((API_ERRORS + 1)); warn "$2: report skipped after an API error" ;;
    esac
}

rc=0
api "repos/$REPO/actions/workflows/$WORKFLOW" > /dev/null || rc=$?
if ((rc == 4)); then
    log "no $WORKFLOW workflow in $REPO yet: no runs"
elif ((rc != 0)); then
    die "can't read the $WORKFLOW workflow of $REPO"
else
    if run="$(latest_run "$MAIN_BRANCH" "$REPO" push schedule workflow_dispatch)"; then
        if [[ -n "$run" ]]; then try_publish "$run" main main "" "$MAIN_BRANCH"
        else log "main: no finished run"; fi
    else
        API_ERRORS=$((API_ERRORS + 1)); warn "main: can't list the runs"
    fi

    pulls="$(api "repos/$REPO/pulls?state=open&per_page=100" --paginate \
                 --jq '.[] | {number, title, branch: .head.ref, head_repo: (.head.repo.full_name // "")} | tojson')" \
        || die "can't list the open pull requests"
    # fd 3, so that nothing in the loop can read the list from standard input
    while IFS= read -r -u 3 pull; do
        [[ -n "$pull" ]] || continue
        number="$(jq -r '.number' <<< "$pull")"
        [[ "$number" =~ ^[0-9]+$ ]] || continue
        head_repo="$(jq -r '.head_repo' <<< "$pull")"
        branch="$(jq -r '.branch' <<< "$pull")"
        title="$(jq -r '.title' <<< "$pull")"
        if [[ -z "$head_repo" ]]; then log "pr-$number: the head repository was deleted"; continue; fi
        if run="$(latest_run "$branch" "$head_repo" pull_request)"; then
            if [[ -n "$run" ]]; then try_publish "$run" "pr-$number" pr "$number" "$title"
            else log "pr-$number: no finished run"; fi
        else
            API_ERRORS=$((API_ERRORS + 1)); warn "pr-$number: can't list the runs"
        fi
    done 3<<< "$pulls"
fi

# An API outage would otherwise deploy an empty e2e/ over the current reports.
if ((API_ERRORS > 0 && ${#PUBLISHED[@]} == 0)); then
    die "no report could be built ($API_ERRORS API errors): not publishing an empty e2e/"
fi

jq -s --arg generated "$GENERATED" \
    '{schema: 1, generated: $generated, reports: sort_by(.kind != "main", -(.pr // 0))}' \
    "$TMP/reports.jsonl" > "$TMP/index.json"
if ! bash "$BUILD_REPORT" --index --out "$OUT" "$TMP/index.json" < /dev/null > "$TMP/index.log" 2>&1; then
    while IFS= read -r line; do log "  $line"; done < "$TMP/index.log"
    die "build-report.sh --index failed"
fi

prs=""
for name in "${PUBLISHED[@]}"; do
    [[ "$name" == pr-* ]] && prs+="${prs:+ }${name#pr-}"
done
list="${PUBLISHED[*]}"
echo "published: ${list:-none}"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "prs=$prs" >> "$GITHUB_OUTPUT"; fi
