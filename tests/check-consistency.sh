#!/usr/bin/env bash
# Runs scripts/check-consistency.sh, the consistency check (issue #35), on this repository first:
# tests/exit-status.sh runs this test, so CI fails when the steps, the README step table, the config
# example, the saved answers, the questions and the audit checks drift apart. Then it runs the
# check on broken copies of server-prep.sh, server-audit.sh, README.md and server-prep.conf.example
# in a temp folder: each one must fail with a message that names the file to fix. No root needed
# and nothing on the host changes.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="$SCRIPT_DIR/scripts/check-consistency.sh"

# 0. This repository, in under 2 seconds
start="${EPOCHREALTIME:-}"
status=0
out="$(bash "$CHECKER" 2>&1)" || status=$?
end="${EPOCHREALTIME:-}"
if [[ $status -ne 0 ]]; then
    printf '%s\n' "$out"
    printf 'not ok: check-consistency on this repository (status %s, want 0)\n' "$status"
    exit 1
fi
printf 'ok: check-consistency on this repository\n'
if [[ -n $start && -n $end ]]; then
    # EPOCHREALTIME uses the locale's decimal separator
    if ! awk -v s="${start/,/.}" -v e="${end/,/.}" 'BEGIN { exit !(e - s < 2) }'; then
        printf 'not ok: check-consistency took %s s (want under 2 s)\n' "$(awk -v s="${start/,/.}" -v e="${end/,/.}" 'BEGIN { printf "%.2f", e - s }')"
        exit 1
    fi
    printf 'ok: check-consistency runs in under 2 seconds\n'
fi

# Stop before any path is built if mktemp fails: an empty $tmp would put the copies in /.
if ! tmp="$(mktemp -d)" || [[ -z $tmp || ! -d $tmp ]]; then
    printf 'not ok: mktemp -d failed, no temporary directory for the copies\n'
    exit 1
fi
trap 'rm -rf "$tmp"' EXIT

fresh() {   # a clean copy of the four input files and the checker in $tmp/r
    rm -rf "$tmp/r"
    mkdir -p "$tmp/r/scripts"
    cp "$SCRIPT_DIR/server-prep.sh" "$SCRIPT_DIR/server-audit.sh" "$SCRIPT_DIR/README.md" \
        "$SCRIPT_DIR/server-prep.conf.example" "$tmp/r/"
    cp "$CHECKER" "$tmp/r/scripts/"
}

edit() {   # edit FILE PROGRAM: rewrites FILE of the copy with the awk PROGRAM; fails when nothing changed
    local file="$tmp/r/$1"
    if ! awk "$2" "$file" >"$file.new"; then
        printf 'not ok: awk failed on %s\n' "$1"
        exit 1
    fi
    if cmp -s "$file" "$file.new"; then
        printf 'not ok: the edit of %s changed nothing (the test no longer matches the file)\n' "$1"
        exit 1
    fi
    mv -f "$file.new" "$file"
}

replace() {   # replace FILE OLD NEW: replaces the first OLD of each line with NEW (plain text, no regex)
    OLD="$2" NEW="$3" edit "$1" '
        BEGIN { old = ENVIRON["OLD"]; new = ENVIRON["NEW"] }
        { i = index($0, old); if (i) $0 = substr($0, 1, i - 1) new substr($0, i + length(old)); print }'
}

expect() {   # expect WANT_STATUS LABEL [TEXT...]: runs the checker of the copy from another folder
    local want="$1" label="$2" status=0 text
    shift 2
    (cd "$tmp" && bash r/scripts/check-consistency.sh) >"$tmp/out" 2>&1 || status=$?
    if [[ $status -ne $want ]]; then
        printf 'not ok: check-consistency %s (status %s, want %s)\n' "$label" "$status" "$want"
        cat "$tmp/out"
        exit 1
    fi
    for text in "$@"; do
        if ! grep -qF -- "$text" "$tmp/out"; then
            printf 'not ok: check-consistency %s (no "%s" in the output)\n' "$label" "$text"
            cat "$tmp/out"
            exit 1
        fi
    done
    printf 'ok: check-consistency %s\n' "$label"
}

# 1. A clean copy, run from another folder
fresh
expect 0 'passes on a clean copy, from another folder' ': consistent'

# 2. Steps: a run_step line removed, two swapped, a wrong function, a renamed step function,
#    a step twice in ALL_STEPS, --list-steps out of step, server-prep.sh broken
fresh
edit server-prep.sh '!/^[[:space:]]*run_step telegram[[:space:]]/'
expect 1 'flags a step with no run_step line' "step 'telegram' is in ALL_STEPS but main() has no run_step line" 'server-prep.sh'

fresh
edit server-prep.sh '
    /^[[:space:]]*run_step rkhunter[[:space:]]/ { held = $0; next }
    /^[[:space:]]*run_step aide[[:space:]]/ { print; print held; next }
    { print }'
expect 1 'flags two run_step lines swapped' 'run_step lines in main() are not in ALL_STEPS order' "'aide'"

fresh
edit server-prep.sh '/^[[:space:]]*run_step suid[[:space:]]/ { sub(/step_suid$/, "step_aide") } { print }'
expect 1 'flags a run_step line that calls the wrong function' 'run_step suid calls step_aide'

fresh
edit server-prep.sh '/^[[:space:]]*run_step suid[[:space:]]/ { $0 = $0 "  # last: lists what the steps installed" } { print }'
expect 0 'reads a run_step line with a trailing comment' ': consistent'

fresh
edit server-prep.sh '{ sub(/^step_suid[(][)]/, "step_suidx()"); print }'
expect 1 'flags a renamed step function' "step 'suid' has no step_suid() function" 'step_suidx() (server-prep.sh:'

fresh
replace server-prep.sh 'ALL_STEPS="update ' 'ALL_STEPS="update update '
expect 1 'flags a step twice in ALL_STEPS' "step 'update' appears twice in ALL_STEPS"

fresh
replace server-prep.sh '--list-steps) echo "$ALL_STEPS"' '--list-steps) echo "update"'
expect 1 'flags --list-steps that does not print ALL_STEPS' "./server-prep.sh --list-steps prints 'update'"

fresh
edit server-prep.sh 'NR == 2 { print "fi" } { print }'
expect 1 'flags a server-prep.sh that does not run' './server-prep.sh --list-steps failed (exit 2)'

# 3. README: a row removed, the shared row removed, a step-like row outside the table
fresh
edit README.md '!/^[|] `endlessh` [|]/'
expect 1 'flags a step with no README row' "step 'endlessh' has no README row" 'README.md'

fresh
edit README.md '!/^[|] `rkhunter` [/] `aide` [|]/'
expect 1 'flags both steps of the shared README row' "step 'rkhunter' has no README row" "step 'aide' has no README row"

fresh
edit README.md '{ print } END { print ""; print "## Other"; print ""; print "| Name | Value |"; print "|---|---|"; print "| `foo` | x |" }'
expect 0 'ignores a step-like row in another section' ': consistent'

fresh
edit README.md '{ print } index($0, "(no secrets) in ") == 1 { print ""; print "| `bar` | y |" }'
expect 0 'ignores a step-like row after the step table' ': consistent'

fresh
replace README.md '## What server-prep does' '## What it does'
expect 1 'stops when the step table is gone' "could not read the step table under '## What server-prep does' in README.md"

# 4. Settings: a key removed, a setting not saved, a setting after a blank line, a secret saved,
#    a secret-like name saved or in NOT_SAVED, a secret missing from validate_values(), NOT_SECRET,
#    a stale NOT_SAVED entry, an allowlist entry with no reason
fresh
edit server-prep.conf.example '!/^SWAP_SIZE=/'
expect 1 'flags a setting with no key in the config example' "setting 'SWAP_SIZE' has no key in server-prep.conf.example"

fresh
edit server-prep.sh '{ print } /^INSTALL_TELEGRAF=/ { print "INSTALL_FOO=\"${INSTALL_FOO:-no}\"" }'
edit server-prep.conf.example '{ print } /^INSTALL_TELEGRAF=/ { print "INSTALL_FOO=\"no\"" }'
expect 1 'flags a new setting missing from save_answers()' "setting 'INSTALL_FOO' is not in the save_answers() list in server-prep.sh" \
    "If it is a secret (a token or key), name it in the '# secrets (...) are not saved here' comment"

fresh
edit server-prep.sh '{ print } /^AUDIT_URL=/ { print ""; print "# Bar"; print "INSTALL_BAR=\"${INSTALL_BAR:-no}\"" }'
expect 1 'flags a setting after a blank line in the settings block' "setting 'INSTALL_BAR' has no key in server-prep.conf.example" \
    "setting 'INSTALL_BAR' is not in the save_answers() list"

fresh
edit server-prep.sh '{ print } /^TIMEZONE=/ { print "" }'
expect 0 'reads the settings block across a blank line' ': consistent'

fresh
edit server-prep.sh '/^[[:space:]]+TELEGRAM_ENABLE TELEGRAM_CHAT_ID/ { sub(/TELEGRAM_ENABLE/, "CLOUDFLARED_TOKEN TELEGRAM_ENABLE") } { print }'
expect 1 'flags a secret in the save_answers() list' "secret 'CLOUDFLARED_TOKEN' is in the save_answers() list"

fresh
edit server-prep.sh '{ print } /^AUDIT_URL=/ { print "TAILSCALE_AUTHKEY=\"${TAILSCALE_AUTHKEY:-}\"" }'
edit server-prep.conf.example '{ print } END { print "TAILSCALE_AUTHKEY=\"\"" }'
replace server-prep.sh ' PTRACE_SCOPE; do' ' PTRACE_SCOPE TAILSCALE_AUTHKEY; do'
expect 1 'flags a saved setting that looks like a secret' "setting 'TAILSCALE_AUTHKEY' looks like a secret" \
    "comment of save_answers() in server-prep.sh does not name it"

for name in SMTP_PASS MAIL_APIKEY BACKUP_CREDENTIALS; do
    fresh
    NAME="$name" edit server-prep.sh '{ print } /^AUDIT_URL=/ { n = ENVIRON["NAME"]; print n "=\"${" n ":-}\"" }'
    NAME="$name" edit server-prep.conf.example '{ print } END { print ENVIRON["NAME"] "=\"\"" }'
    replace server-prep.sh ' PTRACE_SCOPE; do' " PTRACE_SCOPE $name; do"
    expect 1 "flags a saved setting named like a secret ($name)" "setting '$name' looks like a secret"
done

fresh
edit server-prep.sh '{ print } /^AUDIT_URL=/ { print "INFLUX_TOKEN=\"${INFLUX_TOKEN:-}\"" }
    /ask_secret TELEGRAM_BOT_TOKEN/ { print "        ask INFLUX_TOKEN \"InfluxDB token\"" }'
edit server-prep.conf.example '{ print } END { print "INFLUX_TOKEN=\"\"" }'
edit scripts/check-consistency.sh '{ print } /^NOT_SAVED=[(]/ { print "    \"INFLUX_TOKEN|a token, never saved\"" }'
expect 1 'flags a NOT_SAVED setting that looks like a secret' "setting 'INFLUX_TOKEN' looks like a secret" 'ask it with ask_secret'

fresh
replace server-prep.sh 'for k in CLOUDFLARED_TOKEN TELEGRAM_BOT_TOKEN CROWDSEC_ENROLL_KEY;' 'for k in CLOUDFLARED_TOKEN TELEGRAM_BOT_TOKEN;'
expect 1 'flags a secret missing from validate_values()' "secret 'CROWDSEC_ENROLL_KEY' is not in the secret list of validate_values()"

fresh
edit server-prep.sh '{ print } /^AUDIT_URL=/ { print "BACKUP_KEY=\"${BACKUP_KEY:-}\"" }'
edit server-prep.conf.example '{ print } END { print "BACKUP_KEY=\"\"" }'
replace server-prep.sh ' PTRACE_SCOPE; do' ' PTRACE_SCOPE BACKUP_KEY; do'
edit scripts/check-consistency.sh '{ print } /^NOT_SECRET=[(]/ { print "    \"BACKUP_KEY|the path of a public key file\"" }'
expect 0 'accepts a NOT_SECRET entry for a setting that only looks like a secret' ': consistent'

fresh
edit scripts/check-consistency.sh '{ print } /^NOT_SECRET=[(]/ { print "    \"SWAP_SIZE|not a secret\"" }'
expect 1 'flags a NOT_SECRET entry that does not look like a secret' "NOT_SECRET in scripts/check-consistency.sh lists 'SWAP_SIZE', whose name does not look like a secret"

fresh
replace server-prep.sh ' PTRACE_SCOPE; do' ' PTRACE_SCOPE AUDIT_URL; do'
expect 1 'flags a stale NOT_SAVED entry' "NOT_SAVED in scripts/check-consistency.sh lists 'AUDIT_URL', but save_answers() saves it now"

fresh
edit scripts/check-consistency.sh '/^[[:space:]]*"AUDIT_URL[|]/ { print "    \"AUDIT_URL\""; next } { print }'
expect 1 'flags an allowlist entry with no reason' "NOT_SAVED entry 'AUDIT_URL' in scripts/check-consistency.sh has no reason"

# 5. Questions: a secret asked with ask, a name asked with ask_secret that is not a secret, an
#    INSTALL_* setting missing from the plan
fresh
replace server-prep.sh 'ask_secret TELEGRAM_BOT_TOKEN' 'ask TELEGRAM_BOT_TOKEN'
expect 1 'flags a secret asked without ask_secret' "secret 'TELEGRAM_BOT_TOKEN' is asked with ask" 'use ask_secret'

fresh
edit server-prep.sh '{ print } /^AUDIT_URL=/ { print "FOO_PIN=\"${FOO_PIN:-}\"" }
    /ask_secret TELEGRAM_BOT_TOKEN/ { print "        ask_secret FOO_PIN \"Foo PIN (input hidden)\"" }'
edit server-prep.conf.example '{ print } END { print "FOO_PIN=\"\"" }'
replace server-prep.sh ' PTRACE_SCOPE; do' ' PTRACE_SCOPE FOO_PIN; do'
expect 1 'flags a saved name asked with ask_secret that is not a secret' "'FOO_PIN' is asked with ask_secret in questions()" \
    "comment of save_answers() does not name it" 'keep it out of the for v in list'

fresh
replace server-prep.sh ' | telegraf: ${INSTALL_TELEGRAF}' ''
expect 1 'flags an INSTALL_* setting missing from the plan' 'INSTALL_TELEGRAF is asked in questions()' 'not shown in summary_and_confirm()'

fresh
edit server-prep.sh '{ print } /ask_secret TELEGRAM_BOT_TOKEN/ {
    print "        explain \"Text only: ask_secret TELEGRAM_CHAT_ID is not a call here.\" \\"
    print "                \"ask INSTALL_FOO is not one either.\"" }'
expect 0 'ignores ask words inside an explain text' ': consistent'

# 6. Audit: a step comment removed, misspelt, malformed, or with no check after it
fresh
edit server-audit.sh '!/^[[:space:]]*# step: telegram$/'
expect 1 'flags a step with no audit check' "step 'telegram' has no audit check: add one in server-audit.sh"

fresh
replace server-audit.sh '# step: telegram' '# step: telegrma'
expect 1 'flags a step comment that names no step' "names 'telegrma', which is not a step"

fresh
replace server-audit.sh '# step: telegram' '# step:telegram'
expect 1 'flags a malformed step comment' "malformed step comment '# step:telegram'"

fresh
edit server-audit.sh '{ print } END { print "# step: suid" }'
expect 1 'flags a step comment with no check after it' "'# step: suid' has no result <id> call after it"

# 7. Missing input file and usage
fresh
rm -f "$tmp/r/README.md"
expect 1 'flags a missing input file' 'README.md is missing or unreadable'

fresh
status=0
(cd "$tmp" && bash r/scripts/check-consistency.sh --bogus) >"$tmp/out" 2>&1 || status=$?
if [[ $status -ne 2 ]] || ! grep -qF 'Unknown option: --bogus (see --help)' "$tmp/out"; then
    printf 'not ok: check-consistency rejects an unknown option (status %s, want 2)\n' "$status"
    cat "$tmp/out"
    exit 1
fi
printf 'ok: check-consistency rejects an unknown option\n'
status=0
(cd "$tmp" && bash r/scripts/check-consistency.sh --help) >"$tmp/out" 2>&1 || status=$?
if [[ $status -ne 0 ]] || ! grep -qF 'Usage: scripts/check-consistency.sh' "$tmp/out" || grep -q '^#' "$tmp/out"; then
    printf 'not ok: check-consistency --help (status %s, want 0)\n' "$status"
    cat "$tmp/out"
    exit 1
fi
printf 'ok: check-consistency --help\n'

# 8. Tools: bash, grep and awk only (no sed, jq, sort or comm), and server-prep.sh is never sourced
code="$(grep -vE '^[[:space:]]*#' "$CHECKER")"
if grep -nwE 'sed|jq|sort|comm' <<<"$code"; then
    printf 'not ok: check-consistency calls sed, jq, sort or comm (bash, grep and awk only)\n'
    exit 1
fi
if grep -nE '(^|[;&|[:space:]])(source|\.)[[:space:]]+[^[:space:]]*server-prep' <<<"$code"; then
    printf 'not ok: check-consistency sources server-prep.sh (it must read it as text)\n'
    exit 1
fi
printf 'ok: check-consistency uses only bash, grep and awk and never sources server-prep.sh\n'
