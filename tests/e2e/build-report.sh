#!/usr/bin/env bash
# build-report.sh - build the HTML report of an e2e run from the results.json of each OS.
#
#   tests/e2e/build-report.sh --out DIR [--meta key=value]... [--missing os=reason]... RESULT_DIR...
#   tests/e2e/build-report.sh --summary-md DIR
#   tests/e2e/build-report.sh --index --out DIR INDEX_JSON
#
# Report: DIR/index.html, report.css, report.js, data.js (window.E2E_REPORT), summary.json and
# DIR/<os>/<file> for each log the results list. The page draws everything from data.js.
# Index: DIR/index.html (the list of reports), list.js, report.css, index.js (window.E2E_INDEX), index.json.
#
# The results come from VMs that ran pull request code, and pages.yml publishes them on the project site.
# So every input is untrusted: no eval, a path is built only from names that pass a strict pattern,
# only regular files are copied (never a symlink), each one is capped, and data only goes into JSON
# written by jq. The pages set every string with textContent. One bad results.json gives an error
# card for that system; it never stops the whole report.
set -uo pipefail
export LC_ALL=C

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS="$E2E_DIR/report"
IMAGES="$E2E_DIR/images.tsv"

MAX_FILE=$((5 * 1024 * 1024))   # a bigger log keeps its last 5 MiB
MAX_JSON=$((5 * 1024 * 1024))   # a real results.json is a few KB
MAX_NAMES=100                   # files listed by one OS
META_KEYS=" repo sha ref pr pr_title run_id run_url event generated source "
OS_RE='^[a-z0-9][a-z0-9.-]*$'
# Only text types: the files are served from the project site, where an .html or .svg would run as a page.
FILE_RE='^[A-Za-z0-9][A-Za-z0-9._-]*\.(log|txt|json|md|tsv|csv)$'
# Folders an OS id must not take: they are files of the report.
RESERVED=" index.html index.js index.json data.js summary.json report.css report.js list.js "

usage() {
    cat <<'EOF'
Usage:
  tests/e2e/build-report.sh --out DIR [--meta key=value]... [--missing os=reason]... RESULT_DIR...
  tests/e2e/build-report.sh --summary-md DIR
  tests/e2e/build-report.sh --index --out DIR INDEX_JSON

  RESULT_DIR           a folder with one results.json from tests/e2e/run.sh and the files it lists
  --out DIR            where the report goes (created if needed)
  --meta key=value     shown in the header: repo, sha, ref, pr, pr_title, run_id, run_url, event,
                       generated (default: now), source (pr, main, dispatch or local; default: local)
  --missing os=reason  a system whose VM job ended without results: shown as an error card
  --summary-md DIR     print a Markdown table from DIR/summary.json (job summary, PR comment)
  --index              build the list of reports from INDEX_JSON (scripts/e2e-pages.sh)

Exit codes: 0 written (even when tests failed), 1 invalid input or write error, 2 usage error.
EOF
}

die() { echo "build-report: $2" >&2; exit "$1"; }
warn() { echo "build-report: $*" >&2; }

# Shared jq helpers: every value is checked for its type and capped, so a crafted file cannot break
# the page or make it huge. \A and \z anchor a pattern to the whole string ($ also matches before a newline).
JQ_DEFS='
def str($max): if type == "string" then (if length > $max then .[0:$max] + "…" else . end)
               elif type == "number" then tostring else "" end;
def num: if type == "number" and . >= 0 and . <= 1000000000 then . else 0 end;
def arr($max): if type == "array" then .[0:$max] else [] end;
def obj: if type == "object" then . else {} end;
def uniq_by_key(f): reduce .[] as $x ({seen: {}, out: []};
    ($x | f) as $k | if .seen[$k] then . else .seen[$k] = true | .out += [$x] end) | .out;
def is_os: type == "string" and test("\\A[a-z0-9][a-z0-9.-]*\\z");
def is_file: type == "string" and length <= 100
    and test("\\A[A-Za-z0-9][A-Za-z0-9._-]*\\.(log|txt|json|md|tsv|csv)\\z");
'

# One results.json (schema 1) to the shape the page reads. Status is fail closed: a scenario with a
# failed check is failed, and an OS is passed only with no failed scenario and no abort reason.
JQ_NORM="$JQ_DEFS"'
def audit: if type == "object"
    then {pass: (.pass | num), warn: (.warn | num), fail: (.fail | num), info: (.info | num), score: (.score | num)}
    else null end;
def scenario($i):
    obj
    | (.assertions | arr(500) | map(obj | {name: (.name | str(500)), ok: (.ok == true), detail: (.detail | str(20000))})) as $a
    | (.id | str(64)) as $id
    | {id: (if $id | test("\\A[a-z0-9][a-z0-9-]*\\z") then $id else "scenario-\($i + 1)" end),
       title: (.title | str(200)), group: (.group | str(60)),
       status: (if .status == "skipped" then "skipped"
                elif .status == "passed" and all($a[]; .ok) then "passed" else "failed" end),
       duration_s: (.duration_s | num), reason: (.reason | str(2000)), assertions: $a,
       logs: (.logs | arr(50) | map(str(100) | select(length > 0)) | uniq_by_key(.))};
. as $r
| [$r.scenarios | arr(300) | to_entries | .[] | (.key as $i | .value | scenario($i))] | uniq_by_key(.id)
| . as $sc
| ($r.audit | obj) as $au
| ($r.files | arr(50) | map(obj | {name: (.name | str(100)), title: (.title | str(100))} | select(.name != ""))) as $files
| ($r.reason | str(500)) as $reason
| {schema: 1, os: $r.os, label: (($r.label | str(100)) as $l | if $l == "" then $label else $l end),
   os_release: ($r.os_release | str(200)), kernel: ($r.kernel | str(200)),
   image: {url: ($r.image | obj | .url | str(500)), checksum: ($r.image | obj | .checksum | str(200))},
   accel: ($r.accel | str(20)), cpus: ($r.cpus | num), memory_mb: ($r.memory_mb | num),
   started: ($r.started | str(40)), duration_s: ($r.duration_s | num),
   status: (if $r.status == "passed" and $reason == "" and all($sc[]; .status != "failed") then "passed" else "failed" end),
   reason: $reason,
   counts: {passed: ([$sc[] | select(.status == "passed")] | length),
            failed: ([$sc[] | select(.status == "failed")] | length),
            skipped: ([$sc[] | select(.status == "skipped")] | length)},
   scenarios: $sc,
   audit: (reduce ("fresh", "prepared", "rebooted") as $k ({};
              if ($au[$k] | type) == "object" then .[$k] = ($au[$k] | audit) else . end)),
   steps: ($r.steps | arr(100) | map(obj | {step: (.step | str(60)), label: (.label | str(120)),
                                            first: (.first | str(40)), second: (.second | str(40))})
                       | map(select(.step != ""))),
   files: $files,
   names: ([$sc[].logs[], $files[].name] | uniq_by_key(.) | .[0:$max_names])}
'

# ---------- --summary-md DIR ----------
summary_md() {
    local dir="$1" f="$1/summary.json" labels
    [[ -f "$f" && ! -L "$f" ]] || die 1 "no summary.json in $dir"
    jq -e '.schema == 1 and (.oses | type == "array")' "$f" > /dev/null 2>&1 || die 1 "$f is not a schema 1 summary"
    labels="$(image_labels_json)"
    # The PR comment is Markdown: free text from the results goes only inside code spans, without
    # backticks or pipes, so it cannot add links, mentions or table cells. Labels come from images.tsv.
    jq -r --argjson labels "$labels" "$JQ_DEFS"'
        def code: str(160) | gsub("[^ -~]"; "") | gsub("[`|]"; " ") | if . == "" then "-" else "`\(.)`" end;
        def two: tostring | if length < 2 then "0" + . else . end;
        def dur: (num | floor) as $s
            | if $s < 60 then "\($s)s"
              elif $s < 3600 then "\($s / 60 | floor)m \($s % 60 | two)s"
              else "\($s / 3600 | floor)h \(($s % 3600) / 60 | floor | two)m" end;
        def osid: .os | if is_os then . else "unknown" end;
        def sysname: osid as $id | (($labels[$id] // "") | if . == "" then "" else . + " " end) + "`\($id)`";
        [.oses | arr(50) | .[] | obj] as $oses
        | "| System | Result | Scenarios | Time | Audit after reboot |",
          "| --- | --- | --- | --- | --- |",
          ($oses[]
           | (.counts | obj) as $c | (.audit_rebooted | obj) as $a
           | if .status == "error" then "| \(sysname) | **no results** | - | - | - |"
             else "| \(sysname) | \(if .status == "passed" then "passed" else "**failed**" end)"
                  + " | \($c.passed | num) passed, \($c.failed | num) failed, \($c.skipped | num) skipped"
                  + " | \(.duration_s | dur)"
                  + " | \(if (.audit_rebooted | type) == "object"
                         then "\($a.fail | num) FAIL, \($a.warn | num) WARN, score \($a.score | num)" else "-" end) |"
             end),
          ([$oses[] | select(.status != "passed")] as $bad
           | if ($bad | length) == 0 then empty else "",
               ($bad[]
                | "`\(osid)`" as $id
                | ([.failed | arr(1000) | .[] | select(type == "string" and test("\\A[a-z0-9][a-z0-9-]*\\z"))]) as $f
                | (.reason | str(160)) as $why
                | if .status == "error" then "- \($id): no results, \($why | code)"
                  else
                    (if ($f | length) > 0
                     then "- \($id): failed " + ($f[0:10] | map("`\(.)`") | join(", "))
                          + (if ($f | length) > 10 then " and \(($f | length) - 10) more" else "" end)
                     else empty end),
                    (if $why != "" then "- \($id): run stopped, \($why | code)" else empty end)
                  end)
             end)
    ' "$f" || die 1 "can't read $f"
}

image_labels_json() {   # {"debian-13": "Debian 13 (trixie)", ...} from images.tsv (trusted: it is in the repo)
    local id label rest
    {
        if [[ -f "$IMAGES" ]]; then
            while IFS=$'\t' read -r id label rest; do
                [[ -n "$id" && "$id" != \#* && "$id" =~ $OS_RE ]] || continue
                printf '%s\t%s\n' "$id" "$label"
            done < "$IMAGES"
        fi
    } | jq -R -s '[split("\n")[] | select(length > 0) | split("\t") | {(.[0]): (.[1] // "")}] | add // {}'
}

# ---------- --index --out DIR INDEX_JSON ----------
build_index() {
    local out="$1" file="$2" size tmp f
    [[ -f "$file" && ! -L "$file" ]] || die 1 "$file is not a regular file"
    size="$(wc -c < "$file")" || die 1 "can't read $file"
    ((size <= MAX_JSON)) || die 1 "$file is over 5 MiB"
    jq -e -s 'length == 1 and (.[0] | type == "object" and .schema == 1 and (.reports | type == "array"))' \
        "$file" > /dev/null 2>&1 || die 1 "$file is not a schema 1 index"
    for f in list.html list.js report.css; do
        [[ -f "$ASSETS/$f" ]] || die 1 "missing $ASSETS/$f"
    done
    mkdir -p -- "$out" || die 1 "can't create $out"
    tmp="$(mktemp "$out/.index.XXXXXX")" || die 1 "can't write in $out"
    # Only paths this script can have built get a link: main/ and pr-<n>/.
    if ! jq "$JQ_DEFS"'
        {schema: 1, generated: (.generated | str(40)),
         reports: ([.reports | arr(500) | .[] | obj
                    | (.path | str(20)) as $p
                    | select($p | test("\\A(main|pr-[1-9][0-9]{0,6})/\\z"))
                    | {path: $p, kind: (if $p == "main/" then "main" else "pr" end)}
                      + (if $p == "main/" then {} else {pr: ($p | ltrimstr("pr-") | rtrimstr("/") | tonumber)} end)
                      + {title: (.title | str(300)),
                         sha: (.sha | str(40) | if test("\\A[0-9a-f]{7,40}\\z") then . else "" end),
                         status: (if .status == "passed" then "passed" else "failed" end),
                         run_url: (.run_url | str(300) | if test("\\Ahttps://") then . else "" end),
                         date: (.date | str(40)),
                         counts: (.counts | obj | {passed: (.passed | num), failed: (.failed | num),
                                                  skipped: (.skipped | num)}),
                         oses: [.oses | arr(20) | .[] | obj | select(.os | is_os)
                                | {os, label: (.label | str(80)),
                                   status: (if .status == "passed" or .status == "error" then .status else "failed" end),
                                   duration_s: (.duration_s | num),
                                   audit_fail: (if (.audit_fail | type) == "number" then (.audit_fail | num) else null end)}]}]
                   | uniq_by_key(.path) | sort_by(.kind != "main", -(.pr // 0)))}' "$file" > "$tmp"; then
        rm -f -- "$tmp"; die 1 "can't read $file"
    fi
    rm -f -- "$out/index.json" "$out/index.js" "$out/index.html" "$out/list.js" "$out/report.css"
    mv -- "$tmp" "$out/index.json" || die 1 "can't write $out/index.json"
    write_js E2E_INDEX "$out/index.json" "$out/index.js" || die 1 "can't write $out/index.js"
    cp -- "$ASSETS/list.html" "$out/index.html" && cp -- "$ASSETS/list.js" "$ASSETS/report.css" "$out/" \
        || die 1 "can't copy the page to $out"
    echo "build-report: $(jq '.reports | length' "$out/index.json") reports -> $out/index.html"
}

# write_js NAME JSON_FILE OUT: "window.NAME = <json>;". jq -a escapes every non-ASCII character
# (U+2028 and U+2029 included) and sed turns "</" into "<\/", so the data cannot end a script tag.
write_js() {
    {
        echo "/* Built by tests/e2e/build-report.sh from test results. Untrusted data: do not edit. */"
        jq -ac . "$2" | sed -e 's#</#<\\/#g' -e "1s/^/window.$1 = /" -e '$s/$/;/'
    } > "$3"
}

# ---------- report ----------
declare -A ORDER=() LABEL=() SEEN=()
load_images() {
    local i=0 id label rest
    [[ -f "$IMAGES" ]] || return 0
    while IFS=$'\t' read -r id label rest; do
        [[ -n "$id" && "$id" != \#* && "$id" =~ $OS_RE ]] || continue
        ORDER["$id"]=$i
        LABEL["$id"]="$label"
        i=$((i + 1))
    done < "$IMAGES"
}

N=0
next_file() {   # next_file: sets F to the next per-OS file (not in a subshell: N must count)
    N=$((N + 1))
    printf -v F '%s/os/%04d.json' "$TMP" "$N"
}

sort_key() {   # sort_key OS: the images.tsv order, then the order of the arguments
    if [[ -n "$1" && -n "${ORDER[$1]:-}" ]]; then echo "${ORDER[$1]}"
    elif [[ -n "$1" ]]; then echo $((1000 + N))
    else echo $((100000 + N)); fi
}

error_os() {   # error_os OS LABEL REASON: a system without usable results
    local os="$1" label="$2" reason="$3"
    next_file
    [[ -z "$os" ]] || SEEN["$os"]=1
    jq -n --arg os "$os" --arg label "$label" --arg reason "$reason" --argjson order "$(sort_key "$os")" '
        {_order: $order, schema: 1, os: $os, label: $label, os_release: "", kernel: "",
         image: {url: "", checksum: ""}, accel: "", cpus: 0, memory_mb: 0, started: "", duration_s: 0,
         status: "error", reason: $reason, counts: {passed: 0, failed: 0, skipped: 0},
         scenarios: [], audit: {}, steps: [], files: [], attachments: []}' > "$F"
}

guess_os() {   # guess_os DIR: an OS id from the folder name (CI artifacts are e2e-vm-<os>), or ""
    local base="${1%/}"
    base="${base##*/}"
    base="${base#e2e-vm-}"
    if [[ "$base" =~ $OS_RE && ${#base} -le 64 && "$RESERVED" != *" $base "* && -z "${SEEN[$base]:-}" ]]; then
        echo "$base"
    fi
}

add_result() {   # add_result DIR: one OS from its results.json, with its files copied
    local dir="$1" file="$1/results.json" size os label guess name src dst state bytes
    guess="$(guess_os "$dir")"
    label="${guess:+${LABEL[$guess]:-$guess}}"
    if [[ ! -d "$dir" ]]; then
        error_os "$guess" "${label:-Unknown system}" "No results folder."; return
    fi
    if [[ -L "$file" || ( -e "$file" && ! -f "$file" ) ]]; then
        error_os "$guess" "${label:-Unknown system}" "results.json is not a regular file."; return
    fi
    if [[ ! -f "$file" ]]; then
        error_os "$guess" "${label:-Unknown system}" "The VM job left no results.json."; return
    fi
    size="$(wc -c < "$file")" || size=-1
    if ((size < 0 || size > MAX_JSON)); then
        error_os "$guess" "${label:-Unknown system}" "results.json is unreadable or over 5 MiB."; return
    fi
    if ! jq -e -s 'length == 1 and (.[0] | type == "object")' "$file" > /dev/null 2>&1; then
        error_os "$guess" "${label:-Unknown system}" "results.json is not a JSON object."; return
    fi
    if ! jq -e '.schema == 1' "$file" > /dev/null 2>&1; then
        error_os "$guess" "${label:-Unknown system}" "results.json is not schema 1."; return
    fi
    os="$(jq -r "$JQ_DEFS"'.os | if is_os and length <= 64 then . else "" end' "$file")" || os=""
    if [[ -z "$os" || ! "$os" =~ $OS_RE || "$RESERVED" == *" $os "* ]]; then
        error_os "$guess" "${label:-Unknown system}" "results.json has no valid os id."; return
    fi
    if [[ -n "${SEEN[$os]:-}" ]]; then
        warn "a second results.json for $os ($dir) is ignored"
        error_os "" "$os" "A second results.json for this system was ignored."; return
    fi
    SEEN["$os"]=1
    label="${LABEL[$os]:-$os}"

    if ! jq -c --arg label "$label" --argjson max_names "$MAX_NAMES" "$JQ_NORM" "$file" > "$TMP/norm.json"; then
        error_os "$os" "$label" "results.json could not be read."; return
    fi

    # Copy the listed files: names were checked by jq, and are checked again here before use in a path.
    : > "$TMP/states.tsv"
    while IFS= read -r name; do
        [[ "$name" =~ $FILE_RE && ${#name} -le 100 ]] || continue
        src="$dir/$name" dst="$OUT/$os/$name" bytes=0
        if [[ -L "$src" ]]; then
            state=refused
            warn "$os: $name is a symlink: not copied"
        elif [[ ! -f "$src" ]]; then
            state=missing
        else
            bytes="$(wc -c < "$src")" || bytes=-1
            mkdir -p -- "$OUT/$os" || die 1 "can't create $OUT/$os"
            rm -f -- "$dst"
            if ((bytes < 0)); then
                state=missing bytes=0
            elif ((bytes > MAX_FILE)); then
                state=truncated
                { printf '[truncated: last 5 MiB of %s bytes]\n' "$bytes"; tail -c "$MAX_FILE" -- "$src"; } > "$dst" \
                    || state=missing
            else
                state=ok
                cat -- "$src" > "$dst" || state=missing
            fi
            [[ "$state" != missing ]] || rm -f -- "$dst"
        fi
        printf '%s\t%s\t%s\n' "$name" "$state" "$bytes" >> "$TMP/states.tsv"
    done < <(jq -r "$JQ_DEFS"'.names[] | select(is_file)' "$TMP/norm.json")

    # Names that failed the pattern are listed as refused: the page shows them without a link.
    if jq -c --rawfile st "$TMP/states.tsv" --argjson order "$(sort_key "$os")" '
        ($st | split("\n") | map(select(length > 0) | split("\t")
               | {key: .[0], value: {state: .[1], size: ((.[2] | tonumber?) // 0)}}) | from_entries) as $m
        | {_order: $order} + . + {attachments: [.names[] | {name: .} + ($m[.] // {state: "refused", size: 0})]}
        | del(.names)' "$TMP/norm.json" > "$TMP/os.json"; then
        next_file
        mv -- "$TMP/os.json" "$F" || die 1 "can't write $F"
    else
        error_os "$os" "$label" "results.json could not be read."
    fi
}

build_report() {
    local d f os reason meta line
    load_images
    mkdir -p -- "$OUT" "$TMP/os" || die 1 "can't create $OUT"
    for f in index.html report.css report.js; do
        [[ -f "$ASSETS/$f" ]] || die 1 "missing $ASSETS/$f"
    done
    for d in "${DIRS[@]}"; do
        add_result "$d"
    done
    for d in "${MISSING[@]}"; do
        os="${d%%=*}" reason="${d#*=}"
        if [[ -n "${SEEN[$os]:-}" ]]; then
            warn "--missing $os ignored: its results are here"; continue
        fi
        SEEN["$os"]=1
        error_os "$os" "${LABEL[$os]:-$os}" "${reason:-The VM job ended without results.}"
    done

    meta="$(jq -n "$JQ_DEFS"'$ARGS.named | map_values(str(300)) | to_entries | sort_by(.key) | from_entries' "${META_ARGS[@]}")" || die 1 "can't build the meta data"
    if ! jq -s --argjson meta "$meta" '
        (sort_by(._order) | map(del(._order))) as $oses
        | {schema: 1,
           status: (if ($oses | length) > 0 and all($oses[]; .status == "passed") then "passed" else "failed" end),
           counts: {passed: ([$oses[].counts.passed] | add // 0), failed: ([$oses[].counts.failed] | add // 0),
                    skipped: ([$oses[].counts.skipped] | add // 0)},
           meta: $meta, oses: $oses}' "$TMP"/os/*.json > "$TMP/report.json"; then
        die 1 "can't assemble the report"
    fi
    jq '{schema, status, counts, meta,
         oses: [.oses[] | {os, label, status, counts, duration_s, audit_rebooted: (.audit.rebooted // null),
                           reason, failed: [.scenarios[] | select(.status == "failed") | .id]}]}' \
        "$TMP/report.json" > "$TMP/summary.json" || die 1 "can't build summary.json"

    rm -f -- "$OUT/index.html" "$OUT/report.css" "$OUT/report.js" "$OUT/data.js" "$OUT/summary.json"
    write_js E2E_REPORT "$TMP/report.json" "$OUT/data.js" || die 1 "can't write $OUT/data.js"
    cp -- "$TMP/summary.json" "$OUT/summary.json" &&
        cp -- "$ASSETS/index.html" "$ASSETS/report.css" "$ASSETS/report.js" "$OUT/" ||
        die 1 "can't copy the page to $OUT"

    line="$(jq -r 'def n($s): [.oses[] | select(.status == $s)] | length;
        "\(.status): \(.oses | length) systems (\(n("passed")) passed, \(n("failed")) failed, \(n("error")) without results),"
        + " scenarios \(.counts.passed) passed, \(.counts.failed) failed, \(.counts.skipped) skipped"' "$TMP/report.json")"
    echo "build-report: $line -> $OUT/index.html"
}

# ---------- arguments ----------
command -v jq > /dev/null 2>&1 || die 2 "jq is needed"
OUT="" MODE=report SUMMARY_DIR=""
DIRS=() MISSING=() META_ARGS=()
declare -A META=()
while (($#)); do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --out)
            [[ $# -ge 2 && -n "$2" ]] || die 2 "--out needs a directory"
            OUT="$2"; shift 2 ;;
        --meta)
            [[ $# -ge 2 && "$2" == *=* ]] || die 2 "--meta needs key=value"
            key="${2%%=*}"
            [[ "$key" =~ ^[a-z_]+$ && "$META_KEYS" == *" $key "* ]] || die 2 "unknown --meta key: ${key:0:40}"
            META["$key"]="${2#*=}"; shift 2 ;;
        --missing)
            [[ $# -ge 2 && "$2" == *=* ]] || die 2 "--missing needs os=reason"
            os="${2%%=*}"
            [[ "$os" =~ $OS_RE && ${#os} -le 64 && "$RESERVED" != *" $os "* ]] || die 2 "invalid OS id in --missing: ${os:0:40}"
            MISSING+=("$2"); shift 2 ;;
        --summary-md)
            [[ $# -ge 2 && -n "$2" ]] || die 2 "--summary-md needs a directory"
            MODE=summary SUMMARY_DIR="$2"; shift 2 ;;
        --index) MODE=index; shift ;;
        --) shift; DIRS+=("$@"); break ;;
        -*) die 2 "unknown option: ${1:0:40} (see --help)" ;;
        *) DIRS+=("$1"); shift ;;
    esac
done

case "$MODE" in
    summary)
        [[ -z "$OUT" && ${#DIRS[@]} -eq 0 && ${#MISSING[@]} -eq 0 && ${#META[@]} -eq 0 ]] ||
            die 2 "--summary-md takes only a directory"
        summary_md "$SUMMARY_DIR" ;;
    index)
        [[ -n "$OUT" ]] || die 2 "--index needs --out DIR"
        [[ ${#DIRS[@]} -eq 1 && ${#MISSING[@]} -eq 0 && ${#META[@]} -eq 0 ]] || die 2 "--index takes one INDEX_JSON"
        build_index "$OUT" "${DIRS[0]}" ;;
    report)
        [[ -n "$OUT" ]] || die 2 "--out DIR is needed (see --help)"
        ((${#DIRS[@]} + ${#MISSING[@]} > 0)) || die 2 "no RESULT_DIR and no --missing: nothing to report"
        [[ -n "${META[generated]:-}" ]] || META[generated]="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        [[ -n "${META[source]:-}" ]] || META[source]=local
        for key in "${!META[@]}"; do
            META_ARGS+=(--arg "$key" "${META[$key]}")
        done
        TMP="$(mktemp -d)" || die 1 "can't create a temporary folder"
        trap 'rm -rf -- "$TMP"' EXIT
        build_report ;;
esac
