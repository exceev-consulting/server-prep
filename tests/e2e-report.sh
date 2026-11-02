#!/usr/bin/env bash
# Tests tests/e2e/build-report.sh on fake results: exit codes, the files it writes and what it refuses.
# No root, no network and no VM: the inputs are tests/e2e/fixtures/ plus hostile files made here
# (a symlink, a 6 MiB log, path tricks). Needs jq. Uses node, when installed, to run data.js.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/tests/e2e/build-report.sh"
FIX="$ROOT/tests/e2e/fixtures"
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
    if "$@"; then ok "$what"; else not_ok "$what"; fi
}
expect_exit() {   # expect_exit WANT "what" ARGS...: build-report.sh ARGS exits WANT
    local want="$1" what="$2" status=0
    shift 2
    bash "$BUILD" "$@" > "$tmp/stdout" 2> "$tmp/stderr" || status=$?
    [[ "$status" -eq "$want" ]] || not_ok "$what: exit $status, want $want" "$(cat "$tmp/stderr")"
    ok "$what (exit $want)"
}
expect_jq() {   # expect_jq "what" FILE FILTER WANT: jq -r FILTER FILE prints WANT
    local got
    got="$(jq -r "$3" "$2" 2>&1)"
    [[ "$got" == "$4" ]] || not_ok "$1" "got:  $got"$'\n'"want: $4"
    ok "$1"
}
js_json() { sed -e '1d' -e 's/^window\.[A-Z0-9_]* = //' -e '$s/;$//' "$1"; }   # the JSON inside data.js or index.js
no_match() { ! grep -q "$@"; }
jq_true() { jq -e "$1" "$2" > /dev/null 2>&1; }   # jq_true FILTER FILE

# ---------- usage errors ----------
expect_exit 0 "--help" --help
expect_exit 2 "no argument is a usage error"
expect_exit 2 "--out without results or --missing" --out "$tmp/x"
expect_exit 2 "an unknown option" --out "$tmp/x" --colour "$FIX/passed"
expect_exit 2 "--meta without =" --out "$tmp/x" --meta repo "$FIX/passed"
expect_exit 2 "an unknown --meta key" --out "$tmp/x" --meta colour=red "$FIX/passed"
expect_exit 2 "--missing with a path as OS id" --out "$tmp/x" --missing "../x=gone"
expect_exit 2 "--missing with an OS id that is a report file" --out "$tmp/x" --missing "data.js=gone"
expect_exit 2 "--index without --out" --index "$tmp/index.json"
expect_exit 2 "--summary-md with other options" --summary-md "$tmp/x" --out "$tmp/y"
[[ ! -e "$tmp/x" ]] || not_ok "a usage error wrote nothing" "$(ls -la "$tmp/x")"
ok "a usage error writes nothing"

# run.sh writes tests/e2e/out/<os>/, so --out tests/e2e/out tests/e2e/out/<os> is an easy mistake:
# each log would be its own copy target and end up empty.
same="$tmp/same"
mkdir -p "$same" "$tmp/deep/runs"
cp -R "$FIX/passed" "$same/debian-12"
cp -R "$FIX/passed" "$tmp/deep/runs/debian-12"
ln -s "$same" "$tmp/same-link"
expect_exit 2 "a results folder right in --out" --out "$same" "$same/debian-12"
expect_exit 2 "a results folder that is --out" --out "$same/debian-12" "$same/debian-12"
expect_exit 2 "a results folder in --out through a symlink" --out "$tmp/same-link" "$same/debian-12"
expect "a refused --out leaves the results as they were" diff -rq "$FIX/passed" "$same/debian-12"
expect "a refused --out writes no report" test -z "$(find "$same" -name data.js -o -name index.html)"
expect_exit 0 "a results folder deeper in --out" --out "$tmp/deep" "$tmp/deep/runs/debian-12"
expect "it keeps its logs and the report gets a copy" diff -rq "$FIX/passed" "$tmp/deep/runs/debian-12"
expect "the copy is in --out/<os>" cmp -s "$FIX/passed/boot.log" "$tmp/deep/debian-12/boot.log"

# ---------- hostile inputs, made here so git never holds a symlink or a big file ----------
in="$tmp/in"
mkdir -p "$in" "$tmp/etc"
cp -R "$FIX/hostile" "$in/hostile"
printf 'canary: outside the results folder\n' > "$tmp/etc/passwd"   # what ../../etc/passwd points to
ln -s "$FIX/passed/boot.log" "$in/hostile/link.log"
mkdir "$in/hostile/a"
printf 'canary: in a subfolder\n' > "$in/hostile/a/b"
printf 'canary: hidden file\n' > "$in/hostile/.hidden"
printf '<script>alert(1)</script>\n' > "$in/hostile/evil.html"
yes 'a long log line from a VM that wrote far too much' | head -c 6291456 > "$in/hostile/big.log"
mkdir "$in/e2e-vm-debian-13" "$in/schema2" "$in/badid" "$in/symlinked" "$in/huge"
printf 'not json\n' > "$in/e2e-vm-debian-13/results.json"
printf '{"schema": 2, "os": "debian-13"}\n' > "$in/schema2/results.json"
printf '{"schema": 1, "os": "../../x"}\n' > "$in/badid/results.json"
ln -s "$FIX/passed/results.json" "$in/symlinked/results.json"
{ printf '{"schema": 1, "os": "debian-12", "pad": "'; head -c 6000000 /dev/zero | tr '\0' x; printf '"}\n'; } > "$in/huge/results.json"
cp -R "$FIX/passed" "$in/dup"

# ---------- a full report ----------
r="$tmp/report"
meta=(--meta repo=exceev-consulting/server-prep --meta sha=0123456789abcdef0123456789abcdef01234567
      --meta pr=12 --meta "pr_title=e2e: </script><img src=x onerror=alert(1)>" --meta source=pr
      --meta event=pull_request --meta run_id=123 --meta generated=2026-10-27T18:30:00Z
      --meta run_url=https://github.com/exceev-consulting/server-prep/actions/runs/123)
build=(--out "$r" "${meta[@]}" --missing "ubuntu-26.04=VM job ended without results (failure)"
       --missing "debian-12=ignored: its results are here"
       "$FIX/passed" "$FIX/failed" "$in/hostile" "$in/e2e-vm-debian-13" "$in/schema2" "$in/badid"
       "$in/symlinked" "$in/huge" "$in/dup")
expect_exit 0 "a report with failed, invalid and missing systems" "${build[@]}"

expect "the page is report/index.html as it is" cmp -s "$ROOT/tests/e2e/report/index.html" "$r/index.html"
expect "report.css and report.js are copied" cmp -s "$ROOT/tests/e2e/report/report.js" "$r/report.js"
(cd "$r" && find . -mindepth 1 | sort) > "$tmp/tree"
cat > "$tmp/want-tree" <<'EOF'
./data.js
./debian-12
./debian-12/audit-rebooted.log
./debian-12/boot.log
./debian-12/harness.log
./debian-12/prep-run.log
./debian-12/serial.log
./index.html
./report.css
./report.js
./summary.json
./ubuntu-22.04
./ubuntu-22.04/big.log
./ubuntu-22.04/ok.log
./ubuntu-22.04/results.json
./ubuntu-24.04
./ubuntu-24.04/prep-rerun.log
./ubuntu-24.04/prep-run.log
./ubuntu-24.04/serial.log
EOF
diff -u "$tmp/want-tree" "$tmp/tree" > "$tmp/tree.diff" ||
    not_ok "only the listed files with safe names are copied" "$(cat "$tmp/tree.diff")"
ok "only the listed files with safe names are copied (no symlink, subfolder, dot file, .html or ../)"
expect "the report holds no symlink" test -z "$(find "$r" -type l)"
expect "no canary file was copied" no_match -r canary "$r"
expect "a log is copied unchanged" cmp -s "$FIX/passed/boot.log" "$r/debian-12/boot.log"

big="$r/ubuntu-22.04/big.log"
expect_jq "a log over 5 MiB starts with the truncation line" <(head -1 "$big" | jq -R .) . \
    "[truncated: last 5 MiB of 6291456 bytes]"
expect "a log over 5 MiB keeps its last 5 MiB" cmp -s <(tail -n +2 "$big") <(tail -c 5242880 "$in/hostile/big.log")

# data.js: one global, valid JSON, nothing that could end a script tag
expect "data.js starts with a comment" grep -q '^/\* ' <(head -1 "$r/data.js")
expect "data.js sets window.E2E_REPORT" grep -q '^window\.E2E_REPORT = {' <(sed -n 2p "$r/data.js")
expect "data.js is two lines" test "$(wc -l < "$r/data.js")" -eq 2
expect 'data.js has no "</"' no_match -F '</' "$r/data.js"
expect "data.js has no raw U+2028 or U+2029" no_match -e $'\xe2\x80\xa8' -e $'\xe2\x80\xa9' "$r/data.js"
js_json "$r/data.js" > "$tmp/report.json"
expect "the data in data.js is valid JSON" jq_true '.schema == 1' "$tmp/report.json"
expect_jq "a hostile label is kept as text, byte for byte" "$tmp/report.json" \
    '.oses[] | select(.os == "ubuntu-22.04") | .label' "$(jq -r .label "$FIX/hostile/results.json")"
expect_jq "file states: refused names, a symlink, a .html, a truncated and a missing log" "$tmp/report.json" \
    '[.oses[] | select(.os == "ubuntu-22.04" or .os == "ubuntu-24.04") | .attachments[] | "\(.name | @json)=\(.state)"] | join(" ")' \
    '"ok.log"=ok "../../etc/passwd"=refused "a/b"=refused ".hidden"=refused "link.log"=refused "evil.html"=refused "big.log"=truncated "ok.log\n"=refused "results.json"=ok "42"=refused "../serial.log"=refused "prep-run.log"=ok "prep-rerun.log"=ok "reboot.log"=missing "serial.log"=ok'
expect_jq "hostile scenarios: a failed check or a bad status is failed, a bad id is replaced, duplicates go" \
    "$tmp/report.json" '[.oses[] | select(.os == "ubuntu-22.04") | .scenarios[] | "\(.id)=\(.status)"] | join(" ")' \
    "boot=failed scenario-2=failed scenario-4=failed"
expect_jq "hostile numbers and shapes become zero or empty" "$tmp/report.json" \
    '.oses[] | select(.os == "ubuntu-22.04") | [.cpus, .memory_mb, .duration_s, (.audit | keys | join(",")), (.steps | length)] | map(tostring) | join(" ")' \
    "0 0 0 rebooted 1"
if command -v node > /dev/null 2>&1; then
    n="$(node -e 'const vm = require("vm"); const w = {}; vm.runInNewContext(require("fs").readFileSync(process.argv[1], "utf8"), {window: w});
                  process.stdout.write(String(w.E2E_REPORT.oses.length))' "$r/data.js" 2>&1)"
    [[ "$n" == 10 ]] || not_ok "data.js runs as JavaScript" "$n"
    ok "data.js runs as JavaScript"
else
    ok "data.js runs as JavaScript # skip: no node"
fi

# summary.json
s="$r/summary.json"
expect_jq "summary.json: failed, with the scenario counts of every system" "$s" \
    '"\(.schema) \(.status) \(.counts.passed) \(.counts.failed) \(.counts.skipped)"' "1 failed 4 4 1"
expect_jq "summary.json: systems in images.tsv order, then the others, each with its status" "$s" \
    '[.oses[] | "\(.os):\(.status)"] | join(" ")' \
    "debian-12:passed debian-13:error ubuntu-22.04:failed ubuntu-24.04:failed ubuntu-26.04:error schema2:error badid:error symlinked:error huge:error :error"
expect_jq "summary.json: why each input was refused" "$s" '[.oses[] | select(.status == "error") | .reason] | join(" | ")' \
    "results.json is not a JSON object. | VM job ended without results (failure) | results.json is not schema 1. | results.json has no valid os id. | results.json is not a regular file. | results.json is unreadable or over 5 MiB. | A second results.json for this system was ignored."
expect_jq "summary.json: the --missing card has the images.tsv label" "$s" \
    '.oses[] | select(.os == "ubuntu-26.04") | "\(.label) \(.counts.passed) \(.audit_rebooted)"' "Ubuntu 26.04 LTS 0 null"
expect_jq "summary.json: failed scenarios and the audit after the reboot" "$s" \
    '[.oses[] | select(.os == "ubuntu-24.04" or .os == "debian-12") | "\(.os) \(.failed | join(",")) \(.audit_rebooted.score)"] | join(" | ")' \
    "debian-12  100 | ubuntu-24.04 prep-rerun null"
expect_jq "summary.json: the meta data as given" "$s" '"\(.meta.pr) \(.meta.source) \(.meta.generated) \(.meta | keys | length)"' \
    "12 pr 2026-10-27T18:30:00Z 9"

cp "$r/data.js" "$tmp/data.js.first"
expect_exit 0 "a second build into the same folder" "${build[@]}"
expect "the same input gives the same data.js" cmp -s "$tmp/data.js.first" "$r/data.js"

# ---------- --summary-md ----------
expect_exit 0 "--summary-md" --summary-md "$r"
md="$tmp/stdout"
expect "the table has a header and one row per system" test "$(grep -c '^| ' "$md")" -eq 12
expect "a passed system" grep -qF '| Debian 12 (bookworm) `debian-12` | passed | 3 passed, 0 failed, 0 skipped | 21m 52s | 0 FAIL, 0 WARN, score 100 |' "$md"
expect "a system without results" grep -qF '| Ubuntu 26.04 LTS `ubuntu-26.04` | **no results** | - | - | - |' "$md"
expect "the failed scenarios" grep -qF -- '- `ubuntu-24.04`: failed `prep-rerun`' "$md"
expect "the reason for a missing system, in a code span" grep -qF -- '- `ubuntu-26.04`: no results, `VM job ended without results (failure)`' "$md"
# The OS-level reason is the only free text from the results in the Markdown. The hostile fixture's
# has a backtick, a pipe, control characters, HTML, a link, a mention and an issue ref.
expect "a hostile reason is one code span, without its backticks, pipes or control characters" grep -qxF -- \
    '- `ubuntu-22.04`: run stopped, `VM stopped: rm -rf /    <img src=x onerror=alert(1)>- @user see [the log](http://x) #1 end`' "$md"
expect "every line is a table row, the blank line or a detail line with one code span of free text" no_match -vxE \
    -e '' -e '\|( [^|]+ \|)+' \
    -e '- `[a-z0-9.-]+`: (failed `[a-z0-9-]+`(, `[a-z0-9-]+`)*( and [0-9]+ more)?|(run stopped|no results), `[^`|]*`)' "$md"
expect "the detail lines are printable ASCII" no_match '[^ -~]' <(grep '^- ' "$md")
# GitHub shows HTML, links, mentions and issue refs in a code span as plain text, so none may be outside one.
sed 's/`[^`]*`//g' "$md" > "$tmp/md-plain"
expect 'no HTML, link, mention, issue ref or stray backtick outside code spans' \
    no_match -e '<' -e '](' -e '@' -e '#' -e '`' "$tmp/md-plain"
expect_exit 1 "--summary-md on a folder without summary.json" --summary-md "$tmp/in"

# A passed run: status passed and a table with no detail lines.
expect_exit 0 "a report where every system passed" --out "$tmp/ok" --meta generated=2026-10-27T18:30:00Z "$FIX/passed"
expect_jq "a passed report says passed" "$tmp/ok/summary.json" '"\(.status) \(.meta.source)"' "passed local"
expect_exit 0 "--summary-md of a passed report" --summary-md "$tmp/ok"
expect "a passed report has only the table" test "$(wc -l < "$tmp/stdout")" -eq 3

# Only --missing: the job ended with no results at all.
expect_exit 0 "a report with only --missing" --out "$tmp/none" --missing "debian-13=VM job ended without results (cancelled)"
expect_jq "it is failed, with one error card" "$tmp/none/summary.json" '"\(.status) \(.oses | length) \(.oses[0].os) \(.oses[0].status)"' \
    "failed 1 debian-13 error"

# ---------- --index ----------
cat > "$tmp/index.json" <<'EOF'
{"schema": 1, "generated": "2026-10-27T20:00:00Z", "reports": [
  {"path": "pr-12/", "kind": "pr", "pr": 12, "title": "e2e: </script><img src=x onerror=alert(1)>",
   "sha": "0123456789abcdef0123456789abcdef01234567", "status": "failed",
   "run_url": "https://github.com/exceev-consulting/server-prep/actions/runs/124", "date": "2026-10-27T19:00:00Z",
   "counts": {"passed": 20, "failed": "3", "skipped": -1},
   "oses": [{"os": "debian-13", "label": "Debian 13", "status": "passed", "duration_s": 420, "audit_fail": 0},
            {"os": "../x", "status": "passed"}, {"os": "ubuntu-24.04", "status": "hacked", "audit_fail": "1"}]},
  {"path": "../evil/", "kind": "pr", "pr": 13, "title": "x", "status": "passed"},
  {"path": "pr-15/", "kind": "pr", "pr": 15, "title": "docs", "sha": "nothex", "status": "passed",
   "run_url": "javascript:alert(1)", "date": "2026-10-27T18:00:00Z"},
  {"path": "main/", "kind": "main", "title": "main", "sha": "89abcdef0123456789abcdef0123456789abcdef",
   "status": "passed", "run_url": "https://github.com/exceev-consulting/server-prep/actions/runs/120",
   "date": "2026-10-27T17:00:00Z"},
  "junk"]}
EOF
mkdir -p "$tmp/site/main"
expect_exit 0 "--index" --index --out "$tmp/site" "$tmp/index.json"
(cd "$tmp/site" && find . -mindepth 1 | sort | tr '\n' ' ') > "$tmp/tree"
expect "--index writes the list page and leaves the reports alone" \
    test "$(cat "$tmp/tree")" == "./index.html ./index.js ./index.json ./list.js ./main ./report.css "
expect "the list page is report/list.html as it is" cmp -s "$ROOT/tests/e2e/report/list.html" "$tmp/site/index.html"
expect_jq "index.json: main first, then PRs by number, bad paths dropped" "$tmp/site/index.json" \
    '[.reports[] | "\(.path):\(.status)"] | join(" ")' "main/:passed pr-15/:passed pr-12/:failed"
expect_jq "index.json: a bad sha or run link is dropped" "$tmp/site/index.json" \
    '.reports[] | select(.pr == 15) | "[\(.sha)] [\(.run_url)]"' "[] []"
expect_jq "index.json: systems keep a valid id, a known status and numbers only" "$tmp/site/index.json" \
    '.reports[] | select(.pr == 12) | [.oses[] | "\(.os):\(.status):\(.audit_fail)"] | join(" ")' \
    "debian-13:passed:0 ubuntu-24.04:failed:null"
expect_jq "index.json: counts are numbers, bad ones become 0" "$tmp/site/index.json" \
    '.reports[] | select(.pr == 12) | .counts | "\(.passed) \(.failed) \(.skipped)"' "20 0 0"
expect "index.js sets window.E2E_INDEX" grep -q '^window\.E2E_INDEX = {' <(sed -n 2p "$tmp/site/index.js")
expect 'index.js has no "</"' no_match -F '</' "$tmp/site/index.js"
expect "the data in index.js is the same as index.json" cmp -s <(js_json "$tmp/site/index.js" | jq -S .) <(jq -S . "$tmp/site/index.json")
printf 'not json\n' > "$tmp/bad-index.json"
expect_exit 1 "--index with an invalid INDEX_JSON" --index --out "$tmp/site2" "$tmp/bad-index.json"
printf '{"schema": 2, "reports": []}\n' > "$tmp/bad-index.json"
expect_exit 1 "--index with another schema" --index --out "$tmp/site2" "$tmp/bad-index.json"
