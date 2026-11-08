#!/usr/bin/env bash
# shellcheck disable=SC2034
# Tests the audit's JSON format (issue #16) without running the audit: the real JSON writer of
# server-audit.sh on fake results (key order, schema_version, types, escaping), the JSON Schema in
# docs/schemas/server-audit.schema.json, the --help link to docs/json-output.md, and that the doc's
# check id tables list every check id of the script in its category's table, and no other. The variables
# set here are read by the eval'd writer.
# No root needed and nothing on the host changes: the files go to a temp folder.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT="$SCRIPT_DIR/server-audit.sh"
SCHEMA="$SCRIPT_DIR/docs/schemas/server-audit.schema.json"
DOC="$SCRIPT_DIR/docs/json-output.md"

# jq reads the JSON. CI has it; on a machine without it, skip instead of failing the whole suite.
if ! command -v jq >/dev/null 2>&1; then
    printf 'ok: skip server-audit.sh JSON format tests (jq missing)\n'
    exit 0
fi

# Stop before any path is built if mktemp fails: an empty $tmp would write the files to /.
if ! tmp="$(mktemp -d)" || [[ -z $tmp || ! -d $tmp ]]; then
    printf 'not ok: mktemp -d failed, no temporary directory for the JSON files\n'
    exit 1
fi
trap 'rm -rf "$tmp"' EXIT

fail=0
ok() { printf 'ok: %s\n' "$*"; }
bad() { printf 'not ok: %s\n' "$*"; fail=1; }
expect() {   # expect LABEL JQ_FILTER FILE: the filter must give true
    if jq -e "$2" "$3" >/dev/null 2>&1; then
        ok "$1"
    else
        bad "$1 ($2)"
        jq -c . "$3" >&2 2>/dev/null || cat "$3" >&2
    fi
}

# --- 1. The real JSON writer on fake results ---------------------------------------------------------
# server-audit.sh runs its checks on load, so it cannot be sourced: load only json_esc and the writer.
writer="$(sed -n '/^json_esc() {/,/^}/p; /^if \[\[ -n "\$JSON_OUT" \]\]; then/,/^fi$/p' "$AUDIT")"
if [[ -z $writer || $writer != *schema_version* || $writer != *'JSON_OUT'* ]]; then
    printf 'not ok: json_esc or the JSON writer (with schema_version) not found in server-audit.sh\n'
    exit 1
fi
out() { :; }   # the writer prints "JSON report: FILE" through out

AUDIT_VERSION="$(sed -n 's/^AUDIT_VERSION="\([^"]*\)"$/\1/p' "$AUDIT" | head -1)"
[[ -n $AUDIT_VERSION ]] || bad "AUDIT_VERSION not found in server-audit.sh"
HOST=web-01
OS_PRETTY='Debian GNU/Linux 13 (trixie)'
KERNEL=6.12.48+deb13-amd64
PUBLIC_IP=203.0.113.10
STARTED_AT=2026-01-15T10:30:00+01:00

# A message with a double quote, a backslash, a newline, a tab and a trailing \r: json_esc must keep
# the first four and strip the \r.
tricky=$'say "hi" \\ back\nnext line\ttab\r'
tricky_want=$'say "hi" \\ back\nnext line\ttab'
R_ID=(sys.os upd.security panel.data_dir)
R_CAT=(system updates panel)
R_STATUS=(PASS WARN INFO)
R_TITLE=("Operating system" "Security updates" "Panel data")
R_MSG=("Debian GNU/Linux 13 (trixie) is supported" "$tricky" "/data/coolify exists")
R_FIX=("" "sudo apt update && sudo apt full-upgrade" "")
N_PASS=1; N_WARN=1; N_FAIL=0; N_INFO=1
SCORE=75

for IS_ROOT in 0 1; do
    JSON_OUT="$tmp/audit-root$IS_ROOT.json"
    eval "$writer" || bad "the JSON writer failed with IS_ROOT=$IS_ROOT"
done
nonroot="$tmp/audit-root0.json"
root="$tmp/audit-root1.json"

for f in "$nonroot" "$root"; do
    if ! jq -e . "$f" >/dev/null 2>&1; then
        printf 'not ok: the writer gives invalid JSON: %s\n' "$(head -c 300 "$f" 2>/dev/null)"
        exit 1
    fi
done
if [[ "$(wc -l < "$nonroot")" -eq 1 ]]; then
    ok "the writer gives one line of valid JSON"
else
    bad "the JSON is not one line ending in a newline"
fi

expect 'top-level keys, in order' \
    'keys_unsorted == ["tool","version","schema_version","host","os","kernel","public_ip","date","root","score","summary","checks"]' "$nonroot"
expect 'schema_version is the number 1' '.schema_version == 1 and (.schema_version | type) == "number"' "$nonroot"
expect 'tool is server-audit' '.tool == "server-audit"' "$nonroot"
expect 'version is AUDIT_VERSION' ".version == \"$AUDIT_VERSION\"" "$nonroot"
expect 'host, os, kernel, public_ip and date' \
    '.host == "web-01" and .os == "Debian GNU/Linux 13 (trixie)" and .kernel == "6.12.48+deb13-amd64"
     and .public_ip == "203.0.113.10" and .date == "2026-01-15T10:30:00+01:00"' "$nonroot"
expect 'root is false without root' '.root == false' "$nonroot"
expect 'root is true as root' '.root == true' "$root"
expect 'score and summary are numbers' \
    '.score == 75 and .summary == {"pass":1,"warn":1,"fail":0,"info":1}' "$nonroot"
expect 'summary keys, in order' '.summary | keys_unsorted == ["pass","warn","fail","info"]' "$nonroot"
expect 'every check has its keys, in order' \
    '(.checks | length) == 3 and all(.checks[]; keys_unsorted == ["id","category","status","title","message","fix"])' "$nonroot"
expect 'checks keep their id, category, status and fix' \
    '[.checks[] | [.id, .category, .status, .fix]] == [["sys.os","system","PASS",""],
     ["upd.security","updates","WARN","sudo apt update && sudo apt full-upgrade"],["panel.data_dir","panel","INFO",""]]' "$nonroot"
if [[ "$(jq -r '.checks[1].message' "$nonroot")" == "$tricky_want" ]]; then
    ok "a message with a quote, a backslash, a newline and a tab round-trips, the \\r is stripped"
else
    bad "the tricky message does not round-trip: $(jq '.checks[1].message' "$nonroot")"
fi

# --- 2. The schema -----------------------------------------------------------------------------------
if jq -e . "$SCHEMA" >/dev/null 2>&1; then
    ok "the schema is valid JSON"
    expect 'the schema is draft 2020-12' '."$schema" == "https://json-schema.org/draft/2020-12/schema"' "$SCHEMA"
    expect 'the schema has schema_version const 1' '.properties.schema_version.const == 1' "$SCHEMA"
    # Every key the writer outputs is described in the schema, and every key the schema requires is written.
    # Not equality: a field added later under schema_version 1 goes in properties only, not in required,
    # so files written by older releases still pass the version 1 schema.
    keys_match() {   # keys_match LABEL OUTPUT_FILTER SCHEMA_FILTER
        local undescribed unwritten
        undescribed="$(jq -c --slurpfile s "$SCHEMA" "($2 | keys) - (\$s[0] | $3 | .properties | keys)" "$nonroot")"
        unwritten="$(jq -c --slurpfile s "$SCHEMA" "(\$s[0] | $3 | .required) - ($2 | keys)" "$nonroot")"
        if [[ $undescribed == '[]' && $unwritten == '[]' ]]; then
            ok "the schema describes every $1 key of the output and requires only keys it writes"
        else
            bad "$1 keys: not in the schema's properties: ${undescribed:-?}; required but not written: ${unwritten:-?}"
        fi
    }
    keys_match top-level '.' '.'
    keys_match check '.checks[0]' '."$defs".check'
else
    bad "the schema is missing or not valid JSON ($SCHEMA)"
fi

# Full validation needs Python's jsonschema module (python3 -I: no module from the current folder).
validate() {   # validate FILE: succeeds when FILE matches the schema
    python3 -I -c 'import json,sys,jsonschema; jsonschema.validate(json.load(open(sys.argv[2])), json.load(open(sys.argv[1])))' \
        "$SCHEMA" "$1" 2>/dev/null
}
if command -v python3 >/dev/null 2>&1 && python3 -I -c 'import jsonschema' 2>/dev/null; then
    accept() {   # accept LABEL FILE: FILE must pass validation
        if validate "$2"; then ok "the schema accepts $1"; else bad "the schema rejects $1"; fi
    }
    reject() {   # reject LABEL JQ_EDIT: the edited copy of the output must fail validation
        jq -c "$2" "$nonroot" > "$tmp/edited.json"
        if validate "$tmp/edited.json"; then bad "the schema accepts $1"; else ok "the schema rejects $1"; fi
    }
    accept 'the non-root output' "$nonroot"
    accept 'the root output' "$root"
    reject 'a status of OK' '.checks[0].status = "OK"'
    reject 'schema_version 2' '.schema_version = 2'
    reject 'the score as a string' '.score = "75"'
    reject 'a check without fix' 'del(.checks[0].fix)'
    # adding a field is allowed by the versioning rule
    jq -c '.extra = "new field" | .checks[0].extra = 1 | .checks += [.checks[2]]' "$nonroot" > "$tmp/edited.json"
    accept 'a new field and an id that appears twice' "$tmp/edited.json"
else
    ok "skip schema validation (python3 jsonschema missing)"
fi

# --- 3. --help points to the doc (it exits while parsing the options, before any check) -------------
help="$(bash "$AUDIT" --help 2>&1)"
if grep -qE 'https://github\.com/[^ ]+/blob/main/docs/json-output\.md' <<<"$help"; then
    ok "--help links to docs/json-output.md with an absolute GitHub URL"
else
    bad "--help has no absolute link to docs/json-output.md"
fi

# --- 4. The doc's check id tables match the script, both ways -----------------------------------------
# The script's (category, id) pairs: each `result <id>` call under the last `section <cat> "..."` line
# before it (the extraction of gen-data.sh's audit_tsv). The doc's pairs: each `| `<id>` |` table row under
# "### Check ids", with the `#### <cat>` heading above it. An id named only in prose does not count, so a
# missing row, a row in the wrong category's table and a stale row (id renamed or removed) all fail.
pairs_list() {   # pairs_list < "CAT<TAB>ID" lines: "id (cat), id (cat)..."
    awk -F'\t' '{ printf "%s%s (%s)", sep, $2, $1; sep = ", " }'
}
code_pairs="$(awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*section [a-z]+ "/ { cur = $2; next }
    match($0, /(^|[[:space:];&|)])result [a-z0-9_]+\.[a-z0-9_]+ /) {
        line = substr($0, RSTART); sub(/^[^r]*result /, "", line); split(line, w, " ")
        print (cur == "" ? "(no section)" : cur) "\t" w[1]
    }
' "$AUDIT" | LC_ALL=C sort -u)"
if [[ -z $code_pairs ]]; then
    bad "no check id found in server-audit.sh"
elif [[ ! -f $DOC ]]; then
    bad "docs/json-output.md is missing"
else
    doc_rows="$(awk '
        /^### / { on = ($0 == "### Check ids"); next }
        /^## / { on = 0; next }
        on && /^#### / { cat = $2; next }
        on && /^\| `[a-z0-9_]+\.[a-z0-9_]+` \|/ {
            id = $2; gsub(/`/, "", id); print (cat == "" ? "(no category)" : cat) "\t" id
        }
    ' "$DOC")"
    doc_pairs="$(LC_ALL=C sort -u <<<"$doc_rows")"
    if [[ -z $doc_rows ]]; then
        bad "docs/json-output.md has no check id table under '### Check ids'"
    else
        missing="$(LC_ALL=C comm -23 <(printf '%s\n' "$code_pairs") <(printf '%s\n' "$doc_pairs") | pairs_list)"
        stale="$(LC_ALL=C comm -13 <(printf '%s\n' "$code_pairs") <(printf '%s\n' "$doc_pairs") | pairs_list)"
        twice="$(LC_ALL=C sort <<<"$doc_rows" | uniq -d | pairs_list)"
        if [[ -z $missing && -z $stale && -z $twice ]]; then
            ok "docs/json-output.md lists all $(cut -f2 <<<"$code_pairs" | sort -u | wc -l) check ids, each in its category's table"
        fi
        [[ -z $missing ]] || bad "docs/json-output.md has no table row for: $missing (add each to its category's table)"
        [[ -z $stale ]] || bad "docs/json-output.md has rows that server-audit.sh does not have, or in the wrong category's table: $stale"
        [[ -z $twice ]] || bad "docs/json-output.md lists twice: $twice"
    fi
fi

exit "$fail"
