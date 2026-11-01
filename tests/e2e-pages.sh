#!/usr/bin/env bash
# Tests scripts/e2e-pages.sh: which runs it publishes, the error cards it adds and how it opens the
# artifact zips, which a fork pull request controls. No root, no network: a stub gh first on PATH
# answers the API calls from files made here, and the zips are made here with python3 (a zip-slip
# entry, a symlink, a 40 MiB log, bad names). Needs jq, unzip and python3.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/e2e-pages.sh"
FIX="$ROOT/tests/e2e/fixtures"
REPO=exceev-consulting/server-prep
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export LC_ALL=C

ok() { printf 'ok: %s\n' "$1"; }
not_ok() {   # not_ok "what" [details]
    printf 'not ok: %s\n' "$1"
    [[ -z "${2:-}" ]] || printf '%s\n' "$2" >&2
    exit 1
}
expect() {   # expect "what must be true" COMMAND...
    local what="$1"
    shift
    if "$@"; then ok "$what"; else not_ok "$what" "$(cat "$tmp/stderr" 2> /dev/null)"; fi
}
expect_jq() {   # expect_jq "what" FILE FILTER WANT: jq -r FILTER FILE prints WANT
    local got
    got="$(jq -r "$3" "$2" 2>&1)"
    [[ "$got" == "$4" ]] || not_ok "$1" "got:  $got"$'\n'"want: $4"
    ok "$1"
}
no_match() { ! grep -q "$@"; }
logged() { grep -qF -- "$1" "$tmp/stderr"; }   # logged TEXT: e2e-pages.sh wrote TEXT to stderr
called() { grep -qE -- "$1" "$2/calls.log"; }   # called REGEX STUB: the stub gh got that call

# ---------- the stub gh ----------
mkdir -p "$tmp/bin" "$tmp/scratch" "$tmp/secret"
cat > "$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Stub gh: answers "gh api" from the files in $STUB. STUB_FAIL and STUB_404 are endpoint regexes
# that fail with HTTP 502 or 404.
set -u
[[ "${1:-}" == api ]] || { echo "stub gh: only gh api" >&2; exit 1; }
shift
endpoint="" filter="" branch="" event="" status="" page=1 per_page=30
while (($#)); do
    case "$1" in
        -X) shift 2 ;;
        --paginate) shift ;;
        --jq) filter="$2"; shift 2 ;;
        -f) case "$2" in
                branch=*) branch="${2#*=}" ;;
                event=*) event="${2#*=}" ;;
                status=*) status="${2#*=}" ;;
                page=*) page="${2#*=}" ;;
                per_page=*) per_page="${2#*=}" ;;
                *) echo "stub gh: unknown field $2" >&2; exit 1 ;;
            esac
            shift 2 ;;
        -*) echo "stub gh: unknown option $1" >&2; exit 1 ;;
        *) endpoint="$1"; shift ;;
    esac
done
printf '%s branch=%s event=%s page=%s\n' "$endpoint" "$branch" "$event" "$page" >> "$STUB/calls.log"
fail() { echo "gh: $1" >&2; exit 1; }
[[ -z "${STUB_FAIL:-}" || ! "$endpoint" =~ $STUB_FAIL ]] || fail "Server Error (HTTP 502)"
[[ -z "${STUB_404:-}" || ! "$endpoint" =~ $STUB_404 ]] || fail "Not Found (HTTP 404)"
path="${endpoint%%\?*}"
id="${path%/*}"
id="${id##*/}"
case "$path" in
    repos/*/actions/workflows/e2e.yml) body='{"id": 1, "name": "e2e", "path": ".github/workflows/e2e.yml"}' ;;
    repos/*/actions/workflows/e2e.yml/runs)
        # like the API: filtered, newest first, never more than 1000 runs
        body="$(jq --arg branch "$branch" --arg event "$event" --arg status "$status" \
                   --argjson page "$page" --argjson per "$per_page" '
            [.[] | select(($branch == "" or .head_branch == $branch) and ($event == "" or .event == $event)
                          and ($status == "" or .status == $status))]
            | sort_by(.created_at, .id) | reverse | .[:1000]
            | {total_count: length, workflow_runs: .[($page - 1) * $per:$page * $per]}' "$STUB/runs.json")" ;;
    repos/*/actions/runs/*/jobs) [[ -f "$STUB/jobs-$id.json" ]] || fail "Not Found (HTTP 404)"
        body="$(cat "$STUB/jobs-$id.json")" ;;
    repos/*/actions/runs/*/artifacts) [[ -f "$STUB/artifacts-$id.json" ]] || fail "Not Found (HTTP 404)"
        body="$(cat "$STUB/artifacts-$id.json")" ;;
    repos/*/actions/artifacts/*/zip) [[ -f "$STUB/zip-$id.zip" ]] || fail "Not Found (HTTP 404)"
        exec cat "$STUB/zip-$id.zip" ;;
    repos/*/pulls) body="$(cat "$STUB/pulls.json")" ;;
    *) fail "Not Found (HTTP 404)" ;;
esac
if [[ -n "$filter" ]]; then jq -r "$filter" <<< "$body"; else printf '%s\n' "$body"; fi
EOF
# e2e-pages.sh waits 5 and 10 s between retries: no waiting here
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/sleep"
chmod +x "$tmp/bin/gh" "$tmp/bin/sleep"

pages() {   # pages STUB OUT [VAR=value]...: run e2e-pages.sh --out OUT with the stub gh; sets $status
    local stub="$1" out="$2"
    shift 2
    status=0
    : > "$tmp/github-output"
    env -u GITHUB_ACTIONS -u RUNNER_TEMP -u GH_TOKEN -u GITHUB_TOKEN PATH="$tmp/bin:$PATH" TMPDIR="$tmp/scratch" \
        STUB="$stub" REPO="$REPO" GITHUB_OUTPUT="$tmp/github-output" "$@" \
        bash "$SCRIPT" --out "$out" > "$tmp/stdout" 2> "$tmp/stderr" || status=$?
}
expect_status() {   # expect_status WANT "what"
    [[ "$status" -eq "$1" ]] || not_ok "$2: exit $status, want $1" "$(cat "$tmp/stderr")"
    ok "$2 (exit $1)"
}

# ---------- the API data ----------
run() {   # run ID EVENT BRANCH HEAD_REPO CONCLUSION CREATED [UPDATED]: one run of the e2e listing
    jq -nc --argjson id "$1" --arg event "$2" --arg branch "$3" --arg head "$4" --arg concl "$5" \
           --arg created "$6" --arg updated "${7:-$6}" --arg sha "$(printf '%040d' "$1")" --arg repo "$REPO" '
        {id: $id, name: "e2e", event: $event, status: "completed", conclusion: $concl, head_branch: $branch,
         head_sha: $sha, head_repository: {full_name: $head}, html_url: "https://github.com/\($repo)/actions/runs/\($id)",
         created_at: $created, updated_at: $updated}'
}
jobs() {   # jobs STUB RUN NAME=CONCLUSION...
    local stub="$1" id="$2"
    shift 2
    printf '%s\n' "$@" | jq -Rn '{jobs: [inputs | capture("^(?<name>.*)=(?<conclusion>[^=]*)$") + {status: "completed"}]}' \
        > "$stub/jobs-$id.json"
}
arts() {   # arts STUB RUN < "ID NAME SIZE EXPIRED" lines
    jq -Rn '{artifacts: [inputs | split(" ")
             | {id: (.[0] | tonumber), name: .[1], size_in_bytes: (.[2] | tonumber), expired: (.[3] == "true")}]}' \
        > "$1/artifacts-$2.json"
}
cat > "$tmp/mkzip.py" <<'EOF'
# mkzip.py ZIP SPEC...: SPEC is file:NAME=PATH, text:NAME=TEXT, link:NAME=TARGET or big:NAME=MIB
import stat
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    for spec in sys.argv[2:]:
        kind, _, rest = spec.partition(":")
        name, _, value = rest.partition("=")
        if kind == "file":
            with open(value, "rb") as f:
                z.writestr(name, f.read())
        elif kind == "text":
            z.writestr(name, value)
        elif kind == "link":
            info = zipfile.ZipInfo(name)
            info.create_system = 3  # Unix, so that unzip reads the mode
            info.external_attr = (stat.S_IFLNK | 0o777) << 16
            z.writestr(info, value)
        elif kind == "big":
            with z.open(name, "w") as f:
                for _ in range(int(value)):
                    f.write(b"x" * 1048575 + b"\n")
        else:
            sys.exit("unknown spec: " + spec)
EOF
mkzip() { python3 -I "$tmp/mkzip.py" "$@" || not_ok "python3 made the zip $1"; }
results_zip() {   # results_zip ZIP OS [FIXTURE [SPEC...]]: a zip with a results.json for OS
    local zip="$1" os="$2" fixture="${3:-passed}"
    shift $(($# < 3 ? $# : 3))
    jq --arg os "$os" '.os = $os' "$FIX/$fixture/results.json" > "$tmp/results.json"
    mkzip "$zip" "file:results.json=$tmp/results.json" "$@"
}

# ---------- usage errors ----------
status=0; REPO="$REPO" bash "$SCRIPT" > /dev/null 2>&1 || status=$?
expect_status 2 "no --out is a usage error"
status=0; env -u REPO bash "$SCRIPT" --out "$tmp/u1" > /dev/null 2>&1 || status=$?
expect_status 2 "no REPO is a usage error"
mkdir -p "$tmp/u2"; : > "$tmp/u2/keep"
pages "$tmp" "$tmp/u2"
expect_status 2 "a folder that is not empty is a usage error"

# ---------- A: main, pull requests and hostile artifacts ----------
a="$tmp/stub-a"
mkdir -p "$a"
{
    run 100 schedule main "$REPO" success 2026-10-12T04:17:00Z 2026-10-12T05:00:00Z
    run 300 push main "$REPO" success 2026-10-20T10:00:00Z 2026-10-20T10:45:00Z
    # 1100 newer runs of a fork's pull request from its own branch "main": they fill the 1000 runs the
    # API lists for branch=main, so main's run is found only if the API filters the event.
    jq -nc --arg repo "$REPO" 'range(5000; 6100)
        | {id: ., name: "e2e", event: "pull_request", status: "completed", conclusion: "action_required",
           head_branch: "main", head_sha: (tostring | ("0" * (40 - length)) + .),
           head_repository: {full_name: "fork-a/server-prep"},
           html_url: "https://github.com/\($repo)/actions/runs/\(.)",
           created_at: "2026-10-21T00:00:00Z", updated_at: "2026-10-21T00:00:10Z"}'
    run 400 pull_request feat-a "$REPO" success 2026-10-21T12:00:00Z 2026-10-21T12:40:00Z
    run 450 pull_request feat-a fork-a/server-prep success 2026-10-22T12:00:00Z    # same branch name, another repo
    run 500 pull_request patch-1 fork-b/server-prep success 2026-10-01T09:00:00Z   # an older PR from the same branch
    run 600 pull_request broken-setup "$REPO" failure 2026-10-23T08:00:00Z
    run 610 pull_request broken-setup "$REPO" cancelled 2026-10-23T09:00:00Z
    run 700 pull_request old-pr "$REPO" success 2026-10-02T09:00:00Z
    run 800 pull_request fork-feature fork-c/server-prep success 2026-10-24T09:00:00Z
} | jq -s . > "$a/runs.json"
jq -n --arg repo "$REPO" '[
    {number: 25, title: "head repo deleted", created_at: "2026-10-26T09:00:00Z", head: {ref: "gone", repo: null}},
    {number: 22, title: "results expired", created_at: "2026-10-01T08:00:00Z",
     head: {ref: "old-pr", repo: {full_name: $repo}}},
    {number: 20, title: "setup breaks", created_at: "2026-10-23T07:00:00Z",
     head: {ref: "broken-setup", repo: {full_name: $repo}}},
    {number: 17, title: "a fork from an outside contributor", created_at: "2026-10-24T08:00:00Z",
     author_association: "CONTRIBUTOR", head: {ref: "fork-feature", repo: {full_name: "fork-c/server-prep"}}},
    {number: 15, title: "docs: a typo", created_at: "2026-10-25T09:00:00Z", author_association: "COLLABORATOR",
     head: {ref: "patch-1", repo: {full_name: "fork-b/server-prep"}}},
    {number: 12, title: "e2e: add Ubuntu 26.10 </script><img src=x onerror=alert(1)>",
     created_at: "2026-10-21T11:00:00Z", head: {ref: "feat-a", repo: {full_name: $repo}}}]' > "$a/pulls.json"

# main (run 300): debian-12 is a hostile zip, the others have no usable results
jobs "$a" 300 setup=success debian-12=success debian-13=success ubuntu-22.04=failure ubuntu-24.04=cancelled \
    ubuntu-26.04=success report=failure
arts "$a" 300 <<'EOF'
3005 e2e-vm-debian-12 1000 false
3010 e2e-vm-debian-12 1000 false
3011 e2e-vm-debian-13 1000 true
3012 e2e-vm-ubuntu-22.04 1000 false
3013 e2e-vm-ubuntu-26.04 999999999999 false
3014 e2e-report 1000 false
EOF
printf 'SECRET-CANARY\n' > "$tmp/secret/target"
jq '.files += [{name: "big.log", title: "Big"}, {name: "link.log", title: "Link"}, {name: "evil.log", title: "Evil"},
               {name: "slip.log", title: "Slip"}, {name: "abs.log", title: "Abs"}, {name: "x.log", title: "Sub"}]' \
    "$FIX/passed/results.json" > "$tmp/hostile-results.json"
specs=("file:results.json=$tmp/hostile-results.json")
for f in audit-rebooted.log boot.log harness.log prep-run.log serial.log; do specs+=("file:$f=$FIX/passed/$f"); done
specs+=("big:big.log=40" "link:link.log=$tmp/secret/target" "text:../evil.log=slip"
        "text:$(printf '../%.0s' {1..12})${tmp#/}/slip.log=slip" "text:$tmp/abs.log=abs" "text:sub/x.log=sub"
        $'text:bad\nname.log=newline' "text:.hidden.log=dot" "text:a b.log=space" "text:-n.log=dash"
        "text:index.html=<script>alert(1)</script>")
mkzip "$a/zip-3010.zip" "${specs[@]}"
mkzip "$a/zip-3012.zip" "text:boot.log=no results.json here"

# PR 12 (run 400) adds ubuntu-26.10 (failed) and 5 more systems: only 5 systems not in images.tsv are read
jobs "$a" 400 setup=success debian-12=success debian-13=success ubuntu-22.04=success ubuntu-24.04=success \
    ubuntu-26.04=success ubuntu-26.10=failure new-os-1=success new-os-2=success new-os-3=success \
    new-os-4=success new-os-5=success report=failure
arts "$a" 400 <<'EOF'
4001 e2e-vm-new-os-5 500 false
4002 e2e-vm-new-os-4 500 false
4003 e2e-vm-new-os-3 500 false
4004 e2e-vm-new-os-2 500 false
4005 e2e-vm-new-os-1 500 false
4006 e2e-vm-index.html 500 false
4007 e2e-vm-ubuntu-26.10 500 false
4008 e2e-vm-debian-12 500 false
4009 e2e-vm-debian-13 500 false
4010 e2e-vm-ubuntu-22.04 500 false
4011 e2e-vm-ubuntu-24.04 500 false
4012 e2e-vm-ubuntu-26.04 500 false
4013 e2e-report 500 false
EOF
n=4001
for os in new-os-5 new-os-4 new-os-3 new-os-2 new-os-1; do results_zip "$a/zip-$n.zip" "$os"; n=$((n + 1)); done
results_zip "$a/zip-4007.zip" ubuntu-26.10 failed
n=4008
for os in debian-12 debian-13 ubuntu-22.04 ubuntu-24.04 ubuntu-26.04; do results_zip "$a/zip-$n.zip" "$os"; n=$((n + 1)); done
# 70 files that sort before results.json: over the 60 files kept, and results.json must be one of them
specs=()
for i in $(seq -w 0 69); do specs+=("text:a$i.log=$i"); done
results_zip "$a/zip-4009.zip" debian-13 passed "${specs[@]}"

# PR 20 (run 600): the setup job failed, no VM job ran (the vm job keeps its unexpanded name)
# shellcheck disable=SC2016
jobs "$a" 600 setup=failure '${{ matrix.os }}=skipped' report=failure
arts "$a" 600 < /dev/null
# PR 22 (run 700): every artifact expired
jobs "$a" 700 setup=success debian-12=success debian-13=success ubuntu-22.04=success ubuntu-24.04=success \
    ubuntu-26.04=success report=success
arts "$a" 700 <<'EOF'
7001 e2e-vm-debian-12 500 true
7002 e2e-vm-debian-13 500 true
7003 e2e-vm-ubuntu-22.04 500 true
7004 e2e-vm-ubuntu-24.04 500 true
7005 e2e-vm-ubuntu-26.04 500 true
EOF
# PR 17 (run 800): a fork from an outside contributor, with results that would make a report
jobs "$a" 800 setup=success debian-13=success report=success
arts "$a" 800 <<< "8001 e2e-vm-debian-13 500 false"
results_zip "$a/zip-8001.zip" debian-13

out="$tmp/site-a"
pages "$a" "$out"
expect_status 0 "main and the open pull requests"
expect 'the "published:" line names main and the PRs with a report' grep -qx 'published: main pr-20 pr-12' "$tmp/stdout"
expect "prs= in GITHUB_OUTPUT lists those PRs" grep -qx 'prs=20 12' "$tmp/github-output"
expect_jq "index.json: main first, then the PRs by number" "$out/index.json" \
    '[.reports[] | "\(.path)=\(.status)"] | join(" ")' "main/=failed pr-20/=failed pr-12/=failed"

# main: the newest push, schedule or workflow_dispatch run, despite 1100 newer fork runs on a branch "main"
expect "every run listing filters the event on the API side" no_match -E 'workflows/e2e\.yml/runs .* event= ' "$a/calls.log"
s="$out/main/summary.json"
expect_jq "main: run 300, with the run's date as the generated time" "$s" \
    '"\(.meta.run_id) \(.meta.event) \(.meta.source) \(.meta.generated) \(.meta.sha)"' \
    "300 push main 2026-10-20T10:45:00Z $(printf '%040d' 300)"
expect_jq "main: one system with results, the others as error cards" "$s" \
    '[.oses[] | "\(.os):\(.status)"] | join(" ")' \
    "debian-12:passed debian-13:error ubuntu-22.04:error ubuntu-24.04:error ubuntu-26.04:error"
expect_jq "main: why each system has no results" "$s" \
    '[.oses[] | select(.status == "error") | "\(.os)=\(.reason)"] | join(" | ")' \
    "debian-13=the results of this run expired | ubuntu-22.04=results could not be read from the artifact | ubuntu-24.04=VM job ended without results (cancelled) | ubuntu-26.04=results could not be read from the artifact"
expect "the newest of two artifacts with the same name is read" no_match 'artifacts/3005/zip' "$a/calls.log"
expect "an artifact over the size limit is not downloaded" no_match 'artifacts/3013/zip' "$a/calls.log"

# the hostile zip: only safe top-level names, as plain files, within the size limits
(cd "$out/main" && find . -mindepth 1 | sort) > "$tmp/tree"
cat > "$tmp/want-tree" <<'EOF'
./data.js
./debian-12
./debian-12/audit-rebooted.log
./debian-12/big.log
./debian-12/boot.log
./debian-12/harness.log
./debian-12/link.log
./debian-12/prep-run.log
./debian-12/serial.log
./index.html
./report.css
./report.js
./summary.json
EOF
diff -u "$tmp/want-tree" "$tmp/tree" > "$tmp/tree.diff" ||
    not_ok "main/ holds only the listed files with safe names" "$(cat "$tmp/tree.diff")"
ok "main/ holds only the listed files with safe names (no ../, absolute path, subfolder, dot file or .html)"
expect "the site holds no symlink" test -z "$(find "$out" -type l)"
expect "the site holds only folders and regular files" test -z "$(find "$out" ! -type d ! -type f)"
expect "every name on the site is a safe name" no_match -vE '^[A-Za-z0-9][A-Za-z0-9._-]*$' \
    <(find "$out" -mindepth 1 -exec basename {} \;)
expect "the symlink entry is its target's path as text, not the target" \
    test "$(cat "$out/main/debian-12/link.log")" == "$tmp/secret/target"
expect "nothing the symlink points to was copied" no_match -r SECRET-CANARY "$out"
expect "no zip-slip entry was written outside the work folder" \
    test -z "$(find "$tmp" -name slip.log -o -name abs.log -o -name evil.log)"
expect_jq "a 40 MiB entry is cut at 32 MiB, then to the last 5 MiB by build-report.sh" \
    <(head -1 "$out/main/debian-12/big.log" | jq -R .) . "[truncated: last 5 MiB of 33554432 bytes]"
expect "a log is copied unchanged" cmp -s "$FIX/passed/boot.log" "$out/main/debian-12/boot.log"
expect "the temporary folder is removed" test -z "$(find "$tmp/scratch" -mindepth 1)"

# pull requests
s="$out/pr-12/summary.json"
expect_jq "pr-12: its own run 400, not the newer run of the same branch name in a fork" "$s" \
    '"\(.meta.run_id) \(.meta.pr) \(.meta.source) \(.meta.generated)"' "400 12 pr 2026-10-21T12:40:00Z"
expect_jq "pr-12: the PR title comes from the API" "$s" '.meta.pr_title' \
    "e2e: add Ubuntu 26.10 </script><img src=x onerror=alert(1)>"
expect_jq "pr-12: systems not in images.tsv are reported (5 at most), so a failed new system fails the report" "$s" \
    '"\(.status): " + ([.oses[] | "\(.os):\(.status)"] | join(" "))' \
    "failed: debian-12:passed debian-13:passed ubuntu-22.04:passed ubuntu-24.04:passed ubuntu-26.04:passed ubuntu-26.10:failed new-os-1:passed new-os-2:passed new-os-3:passed new-os-4:passed"
expect "an artifact with too many files keeps 60, results.json first" logged "artifact 4009 has more than 60 files"
expect "the sixth system not in images.tsv is skipped" logged "more than 5 systems not in images.tsv: new-os-5 skipped"
expect "an artifact named after a report file is never downloaded" no_match -E 'artifacts/(4001|4006)/zip' "$a/calls.log"
s="$out/pr-20/summary.json"
expect_jq "pr-20: a run whose setup failed is a failed report with every system" "$s" \
    '"\(.status) \(.meta.run_id) " + ([.oses[] | "\(.os):\(.status)"] | join(" "))' \
    "failed 600 debian-12:error debian-13:error ubuntu-22.04:error ubuntu-24.04:error ubuntu-26.04:error"
expect_jq "pr-20: the reason says the VM jobs never ran" "$s" '[.oses[].reason] | unique | join(" | ")' \
    "the run ended before the VM jobs"
expect "pr-15: a run from before the PR was opened is not its run" logged "pr-15: no finished run"
expect "pr-17: a fork from an outside contributor gets no report" \
    logged "pr-17: fork pull request from an outside contributor: no report"
expect "pr-17: its runs are never read" no_match -E 'runs/800/|artifacts/8001/' "$a/calls.log"
expect "pr-15: that older run is never read" no_match -E 'runs/(450|500)/' "$a/calls.log"
expect "pr-22: expired artifacts give no report" logged "pr-22: the artifacts of run 700 expired: no report"
expect "pr-25: a deleted head repository gives no report" logged "pr-25: the head repository was deleted"
expect "only the published reports are folders" \
    test "$(cd "$out" && find . -mindepth 1 -maxdepth 1 -type d | sort | tr '\n' ' ')" == "./main ./pr-12 ./pr-20 "

# ---------- B: a workflow_dispatch run of one system on main ----------
b="$tmp/stub-b"
mkdir -p "$b"
{
    run 300 push main "$REPO" success 2026-10-20T10:00:00Z 2026-10-20T10:45:00Z
    run 310 workflow_dispatch main "$REPO" success 2026-10-26T10:00:00Z 2026-10-26T10:30:00Z
    run 320 schedule main "$REPO" cancelled 2026-10-27T04:17:00Z
} | jq -s . > "$b/runs.json"
printf '[]\n' > "$b/pulls.json"
jobs "$b" 310 setup=success debian-13=success report=success
arts "$b" 310 <<< "3101 e2e-vm-debian-13 500 false"
results_zip "$b/zip-3101.zip" debian-13
pages "$b" "$tmp/site-b"
expect_status 0 "a one-system dispatch on main"
expect 'the "published:" line names main' grep -qx 'published: main' "$tmp/stdout"
expect "prs= is empty with no PR report" grep -qx 'prs=' "$tmp/github-output"
s="$tmp/site-b/main/summary.json"
expect_jq "main: the newest run is the dispatch, not the older push" "$s" '"\(.meta.run_id) \(.meta.event)"' \
    "310 workflow_dispatch"
expect_jq "main: the systems it did not test are error cards, so the report is not passed" "$s" \
    '"\(.status): " + ([.oses[] | "\(.os):\(.status)"] | join(" "))' \
    "failed: debian-12:error debian-13:passed ubuntu-22.04:error ubuntu-24.04:error ubuntu-26.04:error"
expect_jq "main: the reason says the run did not test them" "$s" \
    '[.oses[] | select(.status == "error") | .reason] | unique | join(" | ")' "not tested in this run"
expect_jq "the index says the same" "$tmp/site-b/index.json" \
    '[.reports[] | "\(.path)=\(.status) \([.oses[].status] | join(","))"] | join(" ")' \
    "main/=failed error,passed,error,error,error"

# ---------- C: API errors ----------
pages "$a" "$tmp/site-c" STUB_FAIL='/actions/workflows/e2e\.yml/runs$'
expect_status 1 "every run listing fails"
expect "it refuses to publish an empty e2e/" logged "not publishing an empty e2e/"
expect "it writes no index" test ! -e "$tmp/site-c/index.json"
expect "it writes no prs= output" test ! -s "$tmp/github-output"

pages "$a" "$tmp/site-d" STUB_FAIL='.'
expect_status 1 "every API call fails"
expect "it says the workflow can't be read" logged "can't read the e2e.yml workflow"
expect "it writes no index either" test ! -e "$tmp/site-d/index.json"

pages "$a" "$tmp/site-e" STUB_404='/workflows/e2e\.yml$'
expect_status 0 "no e2e workflow yet"
expect 'the "published:" line says none' grep -qx 'published: none' "$tmp/stdout"
expect_jq "the index is empty" "$tmp/site-e/index.json" '.reports | length' "0"
expect "the temporary folder is removed after every run" test -z "$(find "$tmp/scratch" -mindepth 1)"
