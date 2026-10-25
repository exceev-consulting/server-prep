#!/usr/bin/env bash
# gen-data.sh - extract steps, settings, panels, access routes and audit checks from the scripts
# into site/data.json and site/data.js, the data behind the setup console (site/index.html).
# Run it after changing a script, the README step/VPS/guides tables or server-prep.conf.example.
#
#   scripts/gen-data.sh            write site/data.json and site/data.js
#   scripts/gen-data.sh --check    exit 1 when the committed files are out of date (CI)
#
# Needs bash, awk and jq. Output is deterministic (no timestamps), so CI can diff it.
set -euo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREP="$ROOT/server-prep.sh"
AUDIT="$ROOT/server-audit.sh"
PRECONFIG="$ROOT/server-preconfig.sh"
README="$ROOT/README.md"
CONF="$ROOT/server-prep.conf.example"
OUT_DIR="$ROOT/site"

CHECK=0
case "${1:-}" in
    --check) CHECK=1 ;;
    "") ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
esac

command -v jq >/dev/null || { echo "jq is required (apt install jq)" >&2; exit 2; }

die() { echo "gen-data: $*" >&2; exit 1; }

# value of VAR="..." at the start of a line
script_var() { sed -n "s/^$2=\"\\([^\"]*\\)\".*/\\1/p" "$1" | head -1; }

# --- server-prep.sh steps: name, title, gate variable, README details ---------
steps_tsv() {
    local names
    names="$(script_var "$PREP" ALL_STEPS)"
    awk -v names="$names" '
        FNR == NR {   # README: rows of the step table under "## What server-prep does"
            if ($0 ~ /^## What server-prep does/) { intable = 1; next }
            if (intable && $0 ~ /^## /) intable = 0
            if (intable && $0 ~ /^\| `/) {
                n = split($0, f, " \\| ")
                cell = f[1]; sub(/^\| /, "", cell)
                text = f[2]; for (i = 3; i <= n; i++) text = text " | " f[i]
                sub(/ \|$/, "", text)
                m = split(cell, keys, " / ")
                for (i = 1; i <= m; i++) { k = keys[i]; gsub(/`/, "", k); details[k] = text }
            }
            next
        }
        /^[[:space:]]*run_step [a-z]+ +"/ {
            name = $2
            t = $0; sub(/^[^"]*"/, "", t); sub(/".*/, "", t); title[name] = t
        }
        /^step_[a-z]+\(\)/ { fn = $0; sub(/^step_/, "", fn); sub(/\(\).*/, "", fn); inside = 1; next }
        inside && /^}/ { inside = 0 }
        inside && !(fn in gate) && /yes_ "\$[A-Z][A-Z0-9_]*"/ && /SKIP_RC/ {
            g = $0; sub(/.*yes_ "\$/, "", g); sub(/".*/, "", g); gate[fn] = g
        }
        END {
            n = split(names, list, " ")
            for (i = 1; i <= n; i++) {
                s = list[i]
                printf "%s\t%s\t%s\t%s\n", s, title[s], (s in gate ? gate[s] : ""), details[s]
            }
        }
    ' "$README" "$PREP"
}

# --- settings from server-prep.conf.example + defaults from server-prep.sh -----
settings_tsv() {
    local saved
    saved="$(sed -n '/^save_answers()/,/^}/p' "$PREP" | sed -n '/for v in/,/; do/p' \
        | sed -e 's/.*for v in//' -e 's/; do.*//' -e 's/\\//g' | tr -s ' \n' ' ')"
    awk -v saved=" $saved " '
        FNR == NR {   # first VAR="${VAR:-default}" of each variable; nested expansions count as empty
            if (match($0, /^[A-Z][A-Z0-9_]*="\$\{[A-Z][A-Z0-9_]*:-/)) {
                v = $0; sub(/=.*/, "", v)
                if (v in def) next
                d = $0; sub(/^[A-Z][A-Z0-9_]*="\$\{[A-Z][A-Z0-9_]*:-/, "", d); sub(/\}".*/, "", d)
                if (d ~ /^\$\{/) d = ""
                def[v] = d
            }
            next
        }
        /^# --- / { sec = $0; sub(/^# --- /, "", sec); sub(/ -+$/, "", sec); help = ""; next }
        /^#/ {
            if (sec == "") next
            h = $0; sub(/^#[[:space:]]*/, "", h)
            help = (help == "" ? h : help " " h); next
        }
        /^[A-Z][A-Z0-9_]*=/ {
            v = $0; sub(/=.*/, "", v)
            ex = $0; sub(/^[A-Z][A-Z0-9_]*="/, "", ex); sub(/".*/, "", ex)
            c = ""; if (index($0, "# ")) { c = $0; sub(/^[^#]*# /, "", c) }
            sv = index(saved, " " v " ") ? "yes" : "no"
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", sec, v, ex, (v in def ? def[v] : ""), c, help, sv
            help = ""; next
        }
        /^$/ { help = "" }
    ' "$PREP" "$CONF"
}

# secrets: the list server-prep.sh itself writes into the saved answers ("# secrets (A, B) are not saved here")
secrets_list() {
    sed -n 's/.*# secrets (\([^)]*\)) are not saved here.*/\1/p' "$PREP" | head -1 | tr -d ','
}

# --- panels (set_panel_label) and access routes (compute_root_sources) --------
panels_tsv() {
    sed -n '/^set_panel_label()/,/^}/p' "$PREP" \
        | sed -n 's/^[[:space:]]*\([a-z][a-z0-9-]*\)) PANEL_LABEL="\([^"]*\)".*/\1\t\2/p'
}
access_tsv() {
    sed -n '/^compute_root_sources()/,/^}/p' "$PREP" \
        | sed -n 's/.*\*\([a-z]*\)\*.*ROOT_SOURCES+=(\(.*\))$/\1\t\2/p' | tr -d '"$'
}

# --- usage options of each script (continuation lines joined to their flag) ---
flags_tsv() {   # flags_tsv SCRIPT LABEL
    sed -n '/^usage()/,/^}/p' "$1" | awk -v s="$2" '
        function flush() { if (f != "") print s "\t" f "\t" h; f = "" }
        /^  +-/ {
            flush(); l = $0; sub(/^ +/, "", l)
            f = l; sub(/  +.*/, "", f)
            h = l; sub(/^[^ ]+( [^ -][^ ]*)?  +/, "", h); n = 0; next
        }
        f != "" && /^      +[^ -]/ { x = $0; sub(/^ +/, "", x); gsub(/  +/, " ", x); h = h (n++ ? "; " : " ") x; next }
        { flush() }
        END { flush() }
    '
}

# --- server-preconfig.sh steps, in run order, with their section title ---------
preconfig_tsv() {
    awk '
        /^step_[a-z]+\(\)/ { fn = $0; sub(/\(\).*/, "", fn); next }
        fn != "" && /^[[:space:]]*title "/ && !(fn in t) { x = $0; sub(/^[^"]*"/, "", x); sub(/".*/, "", x); t[fn] = x }
        /^step_[a-z]+$/ { order[++n] = $0 }
        END { for (i = 1; i <= n; i++) { s = order[i]; name = s; sub(/^step_/, "", name); printf "%s\t%s\n", name, t[s] } }
    ' "$PRECONFIG"
}

# --- server-audit.sh sections and checks (a result can follow then, &&, a case label...) ---
audit_tsv() {
    awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*section [a-z]+ "/ {
            key = $2; t = $0; sub(/^[^"]*"/, "", t); sub(/".*/, "", t)
            if (!(key in stitle)) { order[++n] = key; stitle[key] = t }
            cur = key; next
        }
        match($0, /(^|[[:space:];&|)])result [a-z0-9_]+\.[a-z0-9_]+ /) {
            line = substr($0, RSTART); sub(/^[^r]*result /, "", line)
            split(line, w, " "); id = w[1]; st = w[2]
            t = line; sub(/^[^"]*"/, "", t); sub(/".*/, "", t)
            if (!(id in ctitle)) { ids[cur] = ids[cur] (ids[cur] == "" ? "" : " ") id; ctitle[id] = t }
            if (st ~ /^(PASS|WARN|FAIL|INFO)$/ && index(" " cst[id] " ", " " st " ") == 0) cst[id] = cst[id] (cst[id] == "" ? "" : " ") st
        }
        END {
            for (i = 1; i <= n; i++) {
                k = order[i]; m = split(ids[k], list, " ")
                for (j = 1; j <= m; j++) printf "%s\t%s\t%s\t%s\t%s\n", k, stitle[k], list[j], ctitle[list[j]], cst[list[j]]
            }
        }
    ' "$AUDIT"
}

# --- README tables: VPS vs dedicated, guides ------------------------------------
vps_tsv() {
    awk '
        /^### VPS or dedicated server/ { on = 1; next }
        on && /^## / { on = 0 }
        on && /^\| \*\*/ {
            split($0, f, " \\| "); l = f[1]; sub(/^\| \*\*/, "", l); sub(/\*\*$/, "", l)
            d = f[3]; sub(/ \|$/, "", d)
            printf "%s\t%s\t%s\n", l, f[2], d
        }
    ' "$README"
}
guides_tsv() {
    awk '
        /^## Guides/ { on = 1; next }
        on && /^## / { on = 0 }
        on && /^\| \[/ {
            split($0, f, " \\| "); g = f[1]; sub(/^\| \[/, "", g)
            title = g; sub(/\].*/, "", title); path = g; sub(/^[^(]*\(/, "", path); sub(/\).*/, "", path)
            d = f[2]; sub(/ \|$/, "", d)
            printf "%s\t%s\t%s\n", title, path, d
        }
    ' "$README"
}

tsv_json() {   # tsv_json "field1 field2 ..." < tsv -> JSON array of objects (empty fields -> null)
    jq -R --arg keys "$1" '
        ($keys | split(" ")) as $k | split("\t") as $v
        | reduce range(0; $k | length) as $i ({}; . + { ($k[$i]): (($v[$i] // "") | if . == "" then null else . end) })
    ' | jq -s .
}

build() {
    local steps settings panels access flags preconfig audit vps guides
    steps="$(steps_tsv | tsv_json "name title gate details")"
    settings="$(settings_tsv | tsv_json "section name example default comment help saved")"
    panels="$(panels_tsv | tsv_json "id label")"
    access="$(access_tsv | tsv_json "id sources")"
    flags="$( { flags_tsv "$PREP" server-prep.sh; flags_tsv "$AUDIT" server-audit.sh; flags_tsv "$PRECONFIG" server-preconfig.sh; } \
        | tsv_json "script flag help")"
    preconfig="$(preconfig_tsv | tsv_json "name title")"
    audit="$(audit_tsv | tsv_json "section section_title id title statuses")"
    vps="$(vps_tsv | tsv_json "topic vps dedicated")"
    guides="$(guides_tsv | tsv_json "title path details")"

    jq -n \
        --arg prep_version "$(script_var "$PREP" PREP_VERSION)" \
        --arg audit_version "$(script_var "$AUDIT" AUDIT_VERSION)" \
        --arg ssh_port "$(sed -n 's/^SSH_PORT="\${SSH_PORT:-\([0-9]*\)}".*/\1/p' "$PREP")" \
        --arg lapi_port "$(sed -n 's/^CROWDSEC_LAPI_PORT="\${CROWDSEC_LAPI_PORT:-\([0-9]*\)}".*/\1/p' "$PREP")" \
        --arg services "$(script_var "$PREP" SERVICE_CANDIDATES)" \
        --arg project_url "$(script_var "$PREP" PROJECT_URL)" \
        --arg tested "$(sed -n 's/^Tested target: \(.*\), on .*/\1/p' "$README" | head -1)" \
        --arg secrets "$(secrets_list)" \
        --argjson steps "$steps" --argjson settings "$settings" --argjson panels "$panels" \
        --argjson access "$access" --argjson flags "$flags" --argjson preconfig "$preconfig" \
        --argjson audit "$audit" --argjson vps "$vps" --argjson guides "$guides" '
        ($secrets | split(" ") | map(select(. != ""))) as $sec |
        {
            generated_by: "scripts/gen-data.sh",
            project_url: $project_url,
            versions: { server_prep: $prep_version, server_audit: $audit_version },
            tested_targets: $tested,
            defaults: { ssh_port: $ssh_port, crowdsec_lapi_port: $lapi_port, disable_services: ($services | split(" ")) },
            steps: $steps,
            preconfig_steps: $preconfig,
            settings: ($settings | map(.saved = (.saved == "yes") | .secret = (.name as $n | $sec | index($n) != null))),
            panels: $panels,
            access: ($access | map(.sources = (.sources | split(" ")))),
            flags: $flags,
            audit: {
                checks: ($audit | length),
                sections: (reduce ($audit[].section) as $s ([]; if any(.[]; . == $s) then . else . + [$s] end)
                    | map(. as $k | [$audit[] | select(.section == $k)] as $c
                        | { key: $k, title: $c[0].section_title,
                            checks: [$c[] | { id, title, statuses: ((.statuses // "") | split(" ")) }] }))
            },
            vps_vs_dedicated: $vps,
            guides: $guides
        }'
}

json="$(build)"

# --- sanity checks: compare with plain greps, so a parser that drops entries fails loudly ---
count() { jq "$1" <<<"$json"; }
[[ $(count '.steps | length') -eq $(wc -w <<<"$(script_var "$PREP" ALL_STEPS)") ]] || die "steps do not match ALL_STEPS"
[[ $(count '.settings | length') -eq $(grep -cE '^[A-Z][A-Z0-9_]*=' "$CONF") ]] || die "settings do not match server-prep.conf.example"
[[ $(count '.audit.checks') -eq $(grep -v '^[[:space:]]*#' "$AUDIT" | grep -oE '(^|[[:space:];&|)])result [a-z0-9_]+\.[a-z0-9_]+ ' | sed 's/.*result //' | sort -u | wc -l) ]] \
    || die "audit checks do not match the result calls in server-audit.sh"
for q in '.panels' '.access' '.preconfig_steps' '.flags' '.vps_vs_dedicated' '.guides'; do
    [[ $(count "$q | length") -gt 0 ]] || die "'$q' is empty: a parser no longer matches its source"
done
for q in '.versions.server_prep' '.versions.server_audit' '.tested_targets' '.defaults.ssh_port' '.project_url'; do
    [[ -n "$(jq -r "$q // empty" <<<"$json")" ]] || die "'$q' is empty: a parser no longer matches its source"
done
[[ $(count '[.settings[] | select(.secret)] | length') -gt 0 ]] || die "no secrets found: the save_answers() comment changed"
missing="$(jq -r '[.steps[] | select(.title == null or .details == null) | .name] | join(" ")' <<<"$json")"
[[ -z "$missing" ]] || die "steps without a run_step title or README row: $missing"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
printf '%s\n' "$json" > "$tmp/data.json"
{
    echo "/* Generated by scripts/gen-data.sh from the scripts, README.md and server-prep.conf.example. Do not edit. */"
    printf 'window.SERVER_PREP_DATA = %s;\n' "$json"
} > "$tmp/data.js"

if [[ $CHECK -eq 1 ]]; then
    rc=0
    for f in data.json data.js; do
        if ! cmp -s "$tmp/$f" "$OUT_DIR/$f"; then
            echo "site/$f is out of date: run scripts/gen-data.sh and commit the result" >&2
            diff -u "$OUT_DIR/$f" "$tmp/$f" 2>/dev/null | head -40 >&2 || true
            rc=1
        fi
    done
    exit $rc
fi

mkdir -p "$OUT_DIR"
cp "$tmp/data.json" "$tmp/data.js" "$OUT_DIR/"
echo "wrote site/data.json and site/data.js ($(count '.steps | length') steps, $(count '.settings | length') settings, $(count '.audit.checks') audit checks)"
