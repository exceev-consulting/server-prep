#!/usr/bin/env bash
# check-consistency.sh - fails when the parts of server-prep that must agree drift apart (issue #35).
#
# What it checks:
#   1. Steps: ALL_STEPS in server-prep.sh, the output of ./server-prep.sh --list-steps, the run_step
#      lines of main() (same names, same order, each calling step_<name>) and the step_<name>()
#      functions.
#   2. README: every step has a row in the step table under '## What server-prep does' (the
#      `rkhunter` / `aide` row counts for both), and every row of that table is a step. Only that
#      table is read: rows after it or in other sections do not count.
#   3. Settings: every top-level NAME="${NAME:-...}" line of server-prep.sh (the settings block at
#      the top, blank lines or not; the lines tests/validate-config.sh reads) has a key in
#      server-prep.conf.example (and every key there is a setting), and is in the save_answers()
#      list, unless it is a secret or is in NOT_SAVED below. A secret is a name in the
#      '# secrets (...) are not saved here' comment of save_answers() (scripts/gen-data.sh reads
#      the same comment): it is never in the save_answers() list (the saved answers stay
#      secret-free) and it is in the secret list of validate_values(), the for k in line under its
#      '# Secrets:' comment. A setting whose name looks like a secret (TOKEN, SECRET, PASSWORD,
#      PASSWD or AUTHKEY in it, or a _KEY ending other than a public key) must be in that comment,
#      unless it is in NOT_SECRET below.
#   4. Questions: every INSTALL_* or *_ENABLE setting asked in questions() shows in the plan of
#      summary_and_confirm(), every secret is asked with ask_secret, never ask or ask_yn, and every
#      name asked with ask_secret is a secret.
#   5. Audit: every step maps to at least one `result <cat>.<id>` call in server-audit.sh through a
#      '# step: <name>' comment above the check (several names allowed, separated by one space).
#      The comment marks the first result call after it; a section call, another step comment or
#      the end of the file before that call makes it an orphan. A step with no audit check on
#      purpose goes in NO_AUDIT_CHECK below.
#
# Usage: scripts/check-consistency.sh [-h|--help]
#   No arguments: it checks the repository it belongs to, from any folder.
#
# It reads server-prep.sh, server-audit.sh, README.md and server-prep.conf.example as text and never
# sources a script. The only command it runs is ./server-prep.sh --list-steps, which prints the steps
# and exits before anything that needs root. It needs only bash, grep and awk (gawk or mawk), no
# root and no network.
#
# Allowlists (at the top of the code): each entry is "name|reason", and an entry with no reason is
# a problem.
#   STEP_HELPERS     step_<x>() functions that are helpers, not steps
#   NOT_SAVED        settings left out of save_answers() on purpose, for a reason other than being a
#                    secret (a secret goes in the '# secrets (...) are not saved here' comment)
#   NOT_SECRET       settings whose name looks like a secret but that are not one
#   NO_AUDIT_CHECK   steps with no audit check on purpose
#
# Exit status: 0 everything agrees; 1 a problem (each line says what is missing and where to add
# it), including a missing input file or a part of a file the parser cannot find; 2 a usage error.
set -euo pipefail
export LC_ALL=C

if (( $# > 0 )); then
    case "$1" in
        -h|--help)
            awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            printf 'Unknown option: %s (see --help)\n' "$1" >&2
            exit 2
            ;;
    esac
fi

# The repository root, from any folder (no dirname: bash, grep and awk only)
here="${BASH_SOURCE[0]}"
if [[ $here == */* ]]; then here="${here%/*}"; else here=.; fi
cd "$here/.."

# --- Allowlists: "name|reason" -----------------------------------------------
STEP_HELPERS=(
    "step_selected|run_step calls it to apply --only and --skip: a helper, not a step"
)
NOT_SAVED=(
    "AUDIT_SCRIPT|preflight fills it with the server-audit.sh it finds at run time: a saved path can move, and run_audit runs that file as root"
    "AUDIT_URL|a re-run from the saved answers would download the remote server-audit.sh and run it as root again: pass it on each run instead"
)
NOT_SECRET=(
)
NO_AUDIT_CHECK=(
)

PREP=server-prep.sh
AUDIT=server-audit.sh
README=README.md
CONF=server-prep.conf.example

problems=0
problem() {
    printf 'check-consistency: %s\n' "$1"
    problems=$((problems + 1))
}

finish_if_problems() {
    if (( problems > 0 )); then
        printf 'check-consistency: %s problem(s)\n' "$problems"
        exit 1
    fi
}

# has SET NAME: true when NAME is a word of SET, a list written " a b c " (a space on each side)
has() { [[ $1 == *" $2 "* ]]; }

# looks_secret NAME: true when the setting name looks like a token, password or private key.
# A public key (ADMIN_PUBKEY, PANEL_PUBKEY) is not a secret.
looks_secret() {
    case "$1" in
        *PUBKEY | *PUB_KEY | *PUBLIC_KEY) return 1 ;;
        *TOKEN* | *SECRET* | *PASSWORD* | *PASSWD* | *AUTHKEY* | *_KEY) return 0 ;;
    esac
    return 1
}

# allow LIST ENTRY...: sets ALLOWED (" a b ") and ALLOWED_LIST to the names of the entries, and
# reports an entry with no reason. The name still counts, so one mistake gives one problem.
allow() {
    local list="$1" entry name reason
    shift
    ALLOWED=" "
    ALLOWED_LIST=()
    for entry in "$@"; do
        name="${entry%%|*}"
        reason=""
        [[ $entry == *"|"* ]] && reason="${entry#*|}"
        if [[ -z $name || -z ${reason//[[:space:]]/} ]]; then
            problem "$list entry '$entry' in scripts/check-consistency.sh has no reason: write it as \"${name:-name}|why\""
        fi
        [[ -n $name ]] || continue
        ALLOWED+="$name "
        ALLOWED_LIST+=("$name")
    done
}

allow STEP_HELPERS ${STEP_HELPERS[@]+"${STEP_HELPERS[@]}"}
helpers="$ALLOWED"
helper_list=(${ALLOWED_LIST[@]+"${ALLOWED_LIST[@]}"})
allow NOT_SAVED ${NOT_SAVED[@]+"${NOT_SAVED[@]}"}
not_saved="$ALLOWED"
not_saved_list=(${ALLOWED_LIST[@]+"${ALLOWED_LIST[@]}"})
allow NOT_SECRET ${NOT_SECRET[@]+"${NOT_SECRET[@]}"}
not_secret="$ALLOWED"
not_secret_list=(${ALLOWED_LIST[@]+"${ALLOWED_LIST[@]}"})
allow NO_AUDIT_CHECK ${NO_AUDIT_CHECK[@]+"${NO_AUDIT_CHECK[@]}"}
no_audit="$ALLOWED"
no_audit_list=(${ALLOWED_LIST[@]+"${ALLOWED_LIST[@]}"})

# --- Input files ----------------------------------------------------------------
for f in "$PREP" "$AUDIT" "$README" "$CONF"; do
    if [[ ! -f $f || ! -r $f ]]; then
        problem "$f is missing or unreadable: run this script from a full copy of the repository"
    fi
done
finish_if_problems

# --- Extraction: one awk pass per list. mawk runs these programs too: bracket expressions
# instead of escapes, no interval expressions, no gensub, no match() array. ---------------

# parse VAR WHAT FILE PROGRAM: stores in VAR what the awk PROGRAM prints from FILE. An awk failure
# (a program exits 3 when it cannot find its part of the file) or an empty result is a problem.
parse() {
    local __var="$1" what="$2" file="$3" __out
    if ! __out="$(awk "$4" "$file")" || [[ -z $__out ]]; then
        problem "could not read $what in $file: update scripts/check-consistency.sh if the layout changed"
        __out=""
    fi
    printf -v "$__var" '%s' "$__out"
}
# set by parse below (declared here so ShellCheck sees them assigned)
all_steps_line="" runs="" fns="" rows="" settings="" keys="" saved="" secrets="" vsecrets="" asks="" summary=""

# (a) Steps
parse all_steps_line "ALL_STEPS" "$PREP" '
    /^ALL_STEPS="/ { s = $0; sub(/^ALL_STEPS="/, "", s); sub(/".*/, "", s); print s; exit }'

# "name function line" for each run_step call of main(); the run_step() definition is outside main().
# The function is the last word after the quoted title, a trailing # comment left out.
parse runs "main() and its run_step lines" "$PREP" '
    /^main[(][)]/ { inmain = 1; found = 1; next }
    !inmain { next }
    /^}/ { exit }
    /^[[:space:]]*run_step[[:space:]]+[a-z][a-z0-9_]*[[:space:]]+"/ {
        rest = $0
        sub(/^[[:space:]]*run_step[[:space:]]+[a-z][a-z0-9_]*[[:space:]]+"[^"]*"/, "", rest)
        sub(/#.*/, "", rest)
        n = split(rest, w, " ")
        print $2, (n > 0 ? w[n] : "nothing"), FNR
    }
    END { if (!found) exit 3 }'

# "step_name line" for each step function (helpers included, they are left out below)
parse fns "the step_<name>() functions" "$PREP" '
    /^step_[a-z][a-z0-9_]*[(][)]/ { f = $0; sub(/[(][)].*/, "", f); print f, FNR }'

# (b) README: "name line" for each step of the first table under "## What server-prep does"
parse rows "the step table under '## What server-prep does'" "$README" '
    /^## What server-prep does/ { insec = 1; next }
    !insec { next }
    /^## / { exit }
    /^[|]/ { intable = 1 }
    !/^[|]/ { if (intable) exit; next }
    /^[|][[:space:]]*`/ {
        cell = $0
        sub(/^[|][[:space:]]*/, "", cell)
        sub(/[[:space:]]*[|].*/, "", cell)
        n = split(cell, keys, " / ")
        for (i = 1; i <= n; i++) {
            k = keys[i]
            gsub(/[`[:space:]]/, "", k)
            if (k != "") print k, FNR
        }
    }'

# (c) Settings: "NAME line" for each top-level NAME="${NAME:-...}" line of the whole file, the
# definition tests/validate-config.sh uses, so a setting after a blank line still counts. A name
# counts once, at its first line: the COOLIFY_* remap lines further down set PANEL_* settings again.
# PROJECT_URL (no "${PROJECT_URL:-") is not a setting.
parse settings "the settings (the NAME=\"\${NAME:-...}\" lines of the settings block)" "$PREP" '
    /^[A-Z][A-Z0-9_]*="[$][{][A-Z][A-Z0-9_]*:-/ {
        name = $0; sub(/=.*/, "", name)
        ref = $0; sub(/^[A-Z][A-Z0-9_]*="[$][{]/, "", ref); sub(/:-.*/, "", ref)
        if (name == ref && !(name in seen)) { seen[name] = 1; print name, FNR }
    }'

parse keys "the settings" "$CONF" '
    /^[A-Z][A-Z0-9_]*=/ { k = $0; sub(/=.*/, "", k); print k, FNR }'

# the words of save_answers() from "for v in" to "; do", backslashes dropped
parse saved "the for v in list of save_answers()" "$PREP" '
    /^save_answers[(][)]/ { infn = 1; next }
    !infn { next }
    /^}/ { exit }
    /^[[:space:]]*for[[:space:]]+v[[:space:]]+in[[:space:]]/ {
        inlist = 1
        sub(/^[[:space:]]*for[[:space:]]+v[[:space:]]+in[[:space:]]/, "")
    }
    inlist {
        last = ($0 ~ /;[[:space:]]*do/)
        sub(/;[[:space:]]*do.*/, "")
        gsub(/\\/, " ")
        n = split($0, w, " ")
        for (i = 1; i <= n; i++) print w[i]
        if (last) exit
    }'

# the same comment scripts/gen-data.sh reads: "# secrets (A, B, C) are not saved here"
parse secrets "the '# secrets (...) are not saved here' comment of save_answers()" "$PREP" '
    /# secrets [(][^)]*[)] are not saved here/ {
        s = $0
        sub(/.*# secrets [(]/, "", s)
        sub(/[)].*/, "", s)
        gsub(/,/, " ", s)
        n = split(s, w, " ")
        for (i = 1; i <= n; i++) print w[i]
        exit
    }'

# the secrets --validate warns about: the "for k in" line right under "# Secrets:" in validate_values()
parse vsecrets "the secret list of validate_values() (the for k in line under its '# Secrets:' comment)" "$PREP" '
    /^validate_values[(][)]/ { infn = 1; next }
    !infn { next }
    /^}/ { exit 3 }
    /^[[:space:]]*# Secrets:/ { want = 1; next }
    want && /^[[:space:]]*for[[:space:]]+k[[:space:]]+in[[:space:]]/ {
        s = $0
        sub(/^[[:space:]]*for[[:space:]]+k[[:space:]]+in[[:space:]]+/, "", s)
        sub(/;.*/, "", s)
        n = split(s, w, " ")
        for (i = 1; i <= n; i++) print w[i]
        exit
    }
    want { exit 3 }'

# (d) Questions: "function VAR line" for each ask, ask_yn or ask_secret call of questions()
parse asks "the ask, ask_yn and ask_secret calls of questions()" "$PREP" '
    /^questions[(][)]/ { infn = 1; next }
    !infn { next }
    /^}/ { exit }
    /^[[:space:]]*#/ { next }
    {
        l = $0
        while (match(l, /(^|[^A-Za-z0-9_])(ask|ask_yn|ask_secret)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/)) {
            m = substr(l, RSTART, RLENGTH)
            l = substr(l, RSTART + RLENGTH)
            sub(/^[^A-Za-z0-9_]/, "", m)
            split(m, p, " ")
            print p[1], p[2], FNR
        }
    }'

# the whole body of summary_and_confirm(), heredoc included
parse summary "summary_and_confirm()" "$PREP" '
    /^summary_and_confirm[(][)]/ { infn = 1; next }
    !infn { next }
    /^}/ { exit }
    { print }'

# (e) Audit step comments, as tab-separated records:
#   comment LINE NAMES   a strict "# step: a b" comment
#   map NAME ID          NAME maps to the first result call after its comment
#   orphan LINE NAMES    a comment with no result call before a section call, a step comment or EOF
#   malformed LINE TEXT  a "# step:" comment that is not in the strict form
if ! audit_map="$(awk '
    function orphan() {
        if (pending != "") printf "orphan\t%s\t%s\n", pline, pending
        pending = ""
    }
    /^[[:space:]]*#[[:space:]]*step[[:space:]]*:/ {
        if ($0 !~ /^[[:space:]]*# step: [a-z][a-z0-9_]*( [a-z][a-z0-9_]*)*$/) {
            printf "malformed\t%s\t%s\n", FNR, $0
            next
        }
        orphan()
        pending = $0
        sub(/^[[:space:]]*# step: /, "", pending)
        pline = FNR
        printf "comment\t%s\t%s\n", FNR, pending
        next
    }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*section [a-z]+ "/ { orphan(); next }
    match($0, /(^|[[:space:];&|)])result [a-z0-9_]+[.][a-z0-9_]+ /) {
        if (pending == "") next
        id = substr($0, RSTART, RLENGTH)
        sub(/^.*result /, "", id)
        sub(/ $/, "", id)
        n = split(pending, w, " ")
        for (i = 1; i <= n; i++) printf "map\t%s\t%s\n", w[i], id
        pending = ""
    }
    END { orphan() }
' "$AUDIT")"; then
    problem "could not read the '# step:' comments in $AUDIT: update scripts/check-consistency.sh if the layout changed"
    audit_map=""
fi

# A part the parser cannot find makes every rule below unreliable: stop here.
finish_if_problems

# --- 1. Steps ------------------------------------------------------------------
steps=()
read -r -a steps <<<"$all_steps_line"
step_set=" "
names_match=1
for s in "${steps[@]}"; do
    if has "$step_set" "$s"; then
        problem "step '$s' appears twice in ALL_STEPS in server-prep.sh: keep one"
        names_match=0
    fi
    step_set+="$s "
done

rc=0
list_out="$(bash "./$PREP" --list-steps </dev/null 2>&1)" || rc=$?
if (( rc != 0 )); then
    problem "./server-prep.sh --list-steps failed (exit $rc): run bash -n server-prep.sh"
    while IFS= read -r l; do printf '    %s\n' "$l"; done <<<"$list_out"
else
    listed=()
    read -r -d '' -a listed <<<"$list_out" || true
    if [[ "${listed[*]-}" != "${steps[*]}" ]]; then
        problem "./server-prep.sh --list-steps prints '${listed[*]-}', not ALL_STEPS '${steps[*]}': its branch in the option loop of server-prep.sh must print \$ALL_STEPS"
    fi
fi

run_names=()
run_lines=()
run_set=" "
while read -r name fn line; do
    [[ -n $name ]] || continue
    if has "$run_set" "$name"; then
        problem "main() runs step '$name' twice (server-prep.sh:$line): keep one run_step $name line"
        names_match=0
    fi
    run_names+=("$name")
    run_lines+=("$line")
    run_set+="$name "
    if ! has "$step_set" "$name"; then
        problem "main() runs step '$name' (server-prep.sh:$line), which is not in ALL_STEPS: add $name to ALL_STEPS in server-prep.sh, in run order, or remove the run_step line"
        names_match=0
    fi
    if [[ $fn != "step_$name" ]]; then
        problem "run_step $name calls $fn (server-prep.sh:$line): it must call step_$name"
    fi
done <<<"$runs"
for s in "${steps[@]}"; do
    if ! has "$run_set" "$s"; then
        problem "step '$s' is in ALL_STEPS but main() has no run_step line: add run_step $s \"Title\" step_$s to main() in server-prep.sh, in ALL_STEPS order"
        names_match=0
    fi
done
if (( names_match )) && [[ "${run_names[*]}" != "${steps[*]}" ]]; then
    for i in "${!steps[@]}"; do
        if [[ ${run_names[i]} != "${steps[i]}" ]]; then
            problem "run_step lines in main() are not in ALL_STEPS order: run_step number $((i + 1)) is '${run_names[i]}' (server-prep.sh:${run_lines[i]}) where ALL_STEPS has '${steps[i]}'. ALL_STEPS: ${steps[*]}. main(): ${run_names[*]}"
            break
        fi
    done
fi

fn_set=" "
while read -r fn line; do
    [[ -n $fn ]] || continue
    fn_set+="$fn "
    has "$helpers" "$fn" && continue
    if ! has "$step_set" "${fn#step_}"; then
        problem "$fn() (server-prep.sh:$line) is not a step in ALL_STEPS: add ${fn#step_} to ALL_STEPS and a run_step line to main(), or list $fn in STEP_HELPERS in scripts/check-consistency.sh with a reason"
    fi
done <<<"$fns"
for s in "${steps[@]}"; do
    has "$fn_set" "step_$s" ||
        problem "step '$s' has no step_$s() function in server-prep.sh: add it with the other steps (see .claude/skills/add-step/SKILL.md)"
done
for h in ${helper_list[@]+"${helper_list[@]}"}; do
    if ! has "$fn_set" "$h"; then
        problem "STEP_HELPERS in scripts/check-consistency.sh lists $h, but server-prep.sh has no $h() function: remove the entry"
    elif has "$step_set" "${h#step_}"; then
        problem "STEP_HELPERS in scripts/check-consistency.sh lists $h, but ${h#step_} is a step in ALL_STEPS: remove the entry"
    fi
done

# --- 2. README -----------------------------------------------------------------
row_set=" "
while read -r name line; do
    [[ -n $name ]] || continue
    row_set+="$name "
    if ! has "$step_set" "$name"; then
        problem "README.md:$line: \`$name\` is in the step table under '## What server-prep does' but is not a step in ALL_STEPS: fix the name or remove the row"
    fi
done <<<"$rows"
for s in "${steps[@]}"; do
    has "$row_set" "$s" ||
        problem "step '$s' has no README row: add a row | \`$s\` | ... | to the table under '## What server-prep does' in README.md, in run order"
done

# --- 3. Settings, saved answers and secrets -----------------------------------
setting_list=()
setting_set=" "
while read -r name line; do
    [[ -n $name ]] || continue
    setting_list+=("$name")
    setting_set+="$name "
done <<<"$settings"

key_set=" "
while read -r name line; do
    [[ -n $name ]] || continue
    key_set+="$name "
    has "$setting_set" "$name" ||
        problem "server-prep.conf.example:$line sets '$name', which is not a setting in server-prep.sh: add $name=\"\${$name:-...}\" to the settings block at the top of server-prep.sh, or remove the line"
done <<<"$keys"

secret_list=()
read -r -d '' -a secret_list <<<"$secrets" || true
secret_set=" ${secret_list[*]} "
for s in "${secret_list[@]}"; do
    has "$setting_set" "$s" ||
        problem "the '# secrets (...) are not saved here' comment of save_answers() in server-prep.sh names '$s', which is not a setting: fix the comment"
done

# validate_values() warns when a config file holds a secret: same list as the comment
vsecret_list=()
read -r -d '' -a vsecret_list <<<"$vsecrets" || true
vsecret_set=" ${vsecret_list[*]} "
for s in "${secret_list[@]}"; do
    has "$vsecret_set" "$s" ||
        problem "secret '$s' is not in the secret list of validate_values() in server-prep.sh (the for k in line under '# Secrets:'): add it, so --validate warns when a config file holds it"
done
for s in "${vsecret_list[@]}"; do
    has "$secret_set" "$s" ||
        problem "validate_values() in server-prep.sh treats '$s' as a secret (the for k in line under '# Secrets:'), but the '# secrets (...) are not saved here' comment of save_answers() does not name it: add it to that comment, or remove it from that line"
done

saved_list=()
read -r -d '' -a saved_list <<<"$saved" || true
saved_set=" "
for v in "${saved_list[@]}"; do
    has "$saved_set" "$v" && problem "save_answers() in server-prep.sh saves '$v' twice: keep one in the for v in list"
    saved_set+="$v "
    if has "$secret_set" "$v"; then
        problem "secret '$v' is in the save_answers() list in server-prep.sh: remove it, the saved answers (/etc/server-prep/server-prep.conf) stay secret-free"
    elif ! has "$setting_set" "$v"; then
        problem "save_answers() in server-prep.sh saves '$v', which is not a setting: remove it from the for v in list, or add $v=\"\${$v:-...}\" to the settings block"
    fi
done

# where a secret goes, the end of two messages below
make_secret="name it there and in the secret list of validate_values() (the for k in line under '# Secrets:'), and keep it out of the for v in list and NOT_SAVED (secrets are never saved)"

flagged_secret=" "
for name in "${setting_list[@]}"; do
    has "$key_set" "$name" ||
        problem "setting '$name' has no key in server-prep.conf.example: add $name=\"...\" with a comment under its '# --- <section> ---' header"
    has "$secret_set" "$name" && continue
    if looks_secret "$name" && ! has "$not_secret" "$name"; then
        problem "setting '$name' looks like a secret, but the '# secrets (...) are not saved here' comment of save_answers() in server-prep.sh does not name it: ask it with ask_secret, $make_secret. If it is not a secret, list it in NOT_SECRET in scripts/check-consistency.sh with a reason"
        flagged_secret+="$name "
        continue
    fi
    has "$saved_set" "$name" && continue
    has "$not_saved" "$name" && continue
    problem "setting '$name' is not in the save_answers() list in server-prep.sh: add it to the for v in list. If it is a secret (a token or key), name it in the '# secrets (...) are not saved here' comment of save_answers() instead and ask it with ask_secret. If it must never be saved for another reason, list it in NOT_SAVED in scripts/check-consistency.sh with a reason"
done
for name in ${not_saved_list[@]+"${not_saved_list[@]}"}; do
    if ! has "$setting_set" "$name"; then
        problem "NOT_SAVED in scripts/check-consistency.sh lists '$name', which is not a setting in server-prep.sh: remove the entry"
    elif has "$secret_set" "$name"; then
        problem "NOT_SAVED in scripts/check-consistency.sh lists '$name', which is a secret and never saved anyway: remove the entry"
    elif has "$saved_set" "$name"; then
        problem "NOT_SAVED in scripts/check-consistency.sh lists '$name', but save_answers() saves it now: remove the entry"
    fi
done
for name in ${not_secret_list[@]+"${not_secret_list[@]}"}; do
    if ! has "$setting_set" "$name"; then
        problem "NOT_SECRET in scripts/check-consistency.sh lists '$name', which is not a setting in server-prep.sh: remove the entry"
    elif has "$secret_set" "$name"; then
        problem "NOT_SECRET in scripts/check-consistency.sh lists '$name', but the '# secrets (...) are not saved here' comment of save_answers() names it: remove it from one of them"
    elif ! looks_secret "$name"; then
        problem "NOT_SECRET in scripts/check-consistency.sh lists '$name', whose name does not look like a secret: remove the entry"
    fi
done

# --- 4. Questions and plan -----------------------------------------------------
questions=0
asked_set=" "
asked_secret_set=" "
while read -r how var line; do
    [[ -n $how ]] || continue
    questions=$((questions + 1))
    asked_set+="$var "
    if [[ $var == INSTALL_* || $var == *_ENABLE ]]; then
        re="[\$][{]?${var}([^A-Za-z0-9_]|\$)"
        [[ $summary =~ $re ]] ||
            problem "$var is asked in questions() (server-prep.sh:$line) but not shown in summary_and_confirm(): add \${$var} to the Plan"
    fi
    if has "$secret_set" "$var"; then
        if [[ $how == ask_secret ]]; then
            asked_secret_set+="$var "
        else
            problem "secret '$var' is asked with $how in questions() (server-prep.sh:$line): use ask_secret in questions(), so the input stays hidden"
        fi
    elif [[ $how == ask_secret ]] && ! has "$flagged_secret" "$var"; then
        problem "'$var' is asked with ask_secret in questions() (server-prep.sh:$line), but the '# secrets (...) are not saved here' comment of save_answers() does not name it: $make_secret"
    fi
done <<<"$asks"
for s in "${secret_list[@]}"; do
    has "$asked_set" "$s" ||
        problem "secret '$s' has no ask_secret prompt in questions() in server-prep.sh: add ask_secret $s \"... (input hidden)\""
done

# --- 5. Audit checks -------------------------------------------------------------
comments=0
mapped=" "
while IFS=$'\t' read -r kind a b; do
    case "$kind" in
        comment)
            comments=$((comments + 1))
            names=()
            read -r -a names <<<"$b"
            for s in "${names[@]}"; do
                has "$step_set" "$s" ||
                    problem "server-audit.sh:$a: '# step: $b' names '$s', which is not a step in ALL_STEPS: fix the name"
            done
            ;;
        map) mapped+="$a " ;;
        orphan)
            problem "server-audit.sh:$a: '# step: $b' has no result <id> call after it before the next section, step comment or the end of the file: put it right above the check it marks"
            ;;
        malformed)
            b="${b#"${b%%[![:space:]]*}"}"
            problem "server-audit.sh:$a: malformed step comment '$b': write it as '# step: <name>', lowercase step names separated by one space"
            ;;
    esac
done <<<"$audit_map"
for s in "${steps[@]}"; do
    has "$mapped" "$s" && continue
    has "$no_audit" "$s" && continue
    problem "step '$s' has no audit check: add one in server-audit.sh (INFO when optional) with a '# step: $s' comment right above it, or list it in NO_AUDIT_CHECK in scripts/check-consistency.sh with a reason"
done
for name in ${no_audit_list[@]+"${no_audit_list[@]}"}; do
    if ! has "$step_set" "$name"; then
        problem "NO_AUDIT_CHECK in scripts/check-consistency.sh lists '$name', which is not a step in ALL_STEPS: remove the entry"
    elif has "$mapped" "$name"; then
        problem "NO_AUDIT_CHECK in scripts/check-consistency.sh lists '$name', but server-audit.sh has a '# step: $name' check for it: remove the entry"
    fi
done

finish_if_problems
printf 'check-consistency: %s steps, %s settings (%s secrets, %s not saved on purpose), %s questions, %s step comments in server-audit.sh: consistent\n' \
    "${#steps[@]}" "${#setting_list[@]}" "${#secret_list[@]}" "${#not_saved_list[@]}" "$questions" "$comments"
