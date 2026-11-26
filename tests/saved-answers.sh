#!/usr/bin/env bash
# shellcheck disable=SC2034
# Tests that a re-run from the saved answers (/etc/server-prep/server-prep.conf) repeats the first run
# (issue #74): keeping every service is saved as DISABLE_SERVICES=none, which disables nothing, whatever is
# installed; an empty value still means every candidate; LAPTOP_MODE is saved; - (or none) empties an
# optional answer at a prompt, and Enter keeps it empty on a re-run from the saved answers; the plan warns
# before a lockout; a run without the firewall step names the firewall rules of removed answers in its to-do (a
# run with it deletes them, issue #67). No root needed: the answers go to a temp folder and every call that would
# change the host is replaced.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/server-prep.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {   # fail MESSAGE [FILE]: print it, and FILE when given, then stop
    printf 'not ok: %s\n' "$1"
    [[ -n "${2:-}" && -f "$2" ]] && cat "$2" >&2
    exit 1
}

# Load the real functions without starting a run. --yes avoids requiring a terminal.
# shellcheck disable=SC1090
. "$SCRIPT" --yes
LOG_FILE="$tmp/run.log"
CURRENT_SSH_PORTS=22   # set by preflight, which is not run here
IS_LAPTOP=0 HAS_DOCKER=0 HAS_TAILSCALE=0 HAS_CLOUDFLARED=0 HAS_DESKTOP=0 OS_PRETTY=test
LAN_CIDR=192.168.1.0/24
ADMIN_USER=srvprep-test-admin TIMEZONE=UTC

# --- summary_and_confirm: empty is every candidate, none is nothing --------------------------------------
plan_services() {   # plan_services INTERACTIVE VALUE: DISABLE_SERVICES after summary_and_confirm (the plan in $tmp/plan)
    (
        INTERACTIVE="$1" ASSUME_YES=1 DISABLE_SERVICES="$2"   # ASSUME_YES: confirm reads no terminal
        summary_and_confirm > "$tmp/plan" 2>&1 || exit 1
        printf '%s' "$DISABLE_SERVICES"
    )
}
for c in "0||$SERVICE_CANDIDATES" "0|  |$SERVICE_CANDIDATES" "1||$SERVICE_CANDIDATES" '0|none|none' '1|none|none' \
         '0|cups apport|cups apport'; do
    IFS='|' read -r mode value want <<< "$c"
    got="$(plan_services "$mode" "$value")" || fail "summary_and_confirm stopped" "$tmp/plan"
    [[ "$got" == "$want" ]] || fail "summary_and_confirm with INTERACTIVE=$mode and DISABLE_SERVICES=\"$value\" gives \"$got\", want \"$want\""
    grep -qxF "  Disable services .. $want" "$tmp/plan" || fail "the plan does not say: Disable services .. $want" "$tmp/plan"
done
printf 'ok: summary_and_confirm turns an empty DISABLE_SERVICES into every candidate and keeps none\n'

# --- the services questions: the answer is the operator's choice, whatever is installed ------------------
# ask and ask_secret keep the default (Enter). ask_yn records the default of each "Disable <svc>" question and
# answers no for the services in NO. systemctl says the services in INSTALLED are installed.
services_answers() {   # services_answers VALUE INSTALLED NO: print each "Disable <svc>=default", then DISABLE_SERVICES=
    (
        installed=" $2 " no=" $3 "
        ask() { printf -v "$1" '%s' "${!1:-${3:-}}"; }
        ask_yn() {
            local d="${!1:-${3:-no}}" q
            read -r q <<< "$2"   # without the indent of "  Disable <svc>"
            if [[ $q == 'Disable '* ]]; then
                printf '%s=%s\n' "$q" "$d" >> "$tmp/asked"
                [[ $no == *" ${q#Disable } "* ]] && d=no
            fi
            printf -v "$1" '%s' "$d"
        }
        ask_secret() { :; }
        systemctl() { [[ $1 == cat && $installed == *" $2 "* ]]; }
        INTERACTIVE=1 ASSUME_YES=1 DISABLE_SERVICES="$1" PANEL_ACCESS=tailscale ADMIN_IPS=192.168.1.50
        : > "$tmp/asked"
        { questions && summary_and_confirm; } > "$tmp/questions" 2>&1 || exit 1
        cat "$tmp/asked"
        printf 'DISABLE_SERVICES=%s\n' "$DISABLE_SERVICES"
    )
}
expect_services() {   # expect_services LABEL VALUE INSTALLED NO WANT
    local got
    got="$(services_answers "$2" "$3" "$4")" || fail "questions stopped" "$tmp/questions"
    [[ "$got" == "$5" ]] || fail "$1: the services questions give:
$got
want:
$5"
    printf 'ok: %s\n' "$1"
}
all_yes="$(for s in $SERVICE_CANDIDATES; do printf 'Disable %s=yes\n' "$s"; done)"
all_no="$(for s in $SERVICE_CANDIDATES; do printf 'Disable %s=no\n' "$s"; done)"
expect_services 'a first run defaults every installed service to yes' '' "$SERVICE_CANDIDATES" '' \
    "$all_yes"$'\n'"DISABLE_SERVICES=$SERVICE_CANDIDATES"
expect_services 'answering no to every service saves none' '' "$SERVICE_CANDIDATES" "$SERVICE_CANDIDATES" \
    "$all_yes"$'\n'"DISABLE_SERVICES=none"
expect_services 'answering no to the only two installed services saves none, not the others' '' 'cups bluetooth' \
    'cups bluetooth' $'Disable cups=yes\nDisable bluetooth=yes\nDISABLE_SERVICES=none'
expect_services 'the services answered yes are saved, and only them' '' 'cups bluetooth' bluetooth \
    $'Disable cups=yes\nDisable bluetooth=yes\nDISABLE_SERVICES=cups'
expect_services 'with none saved, every service defaults to no and none stays' none "$SERVICE_CANDIDATES" '' \
    "$all_no"$'\n'"DISABLE_SERVICES=none"
expect_services 'with a saved list, only the listed services default to yes' 'cups apport' "$SERVICE_CANDIDATES" '' \
    "$(for s in $SERVICE_CANDIDATES; do
        if [[ $s == cups || $s == apport ]]; then printf 'Disable %s=yes\n' "$s"; else printf 'Disable %s=no\n' "$s"; fi
    done)"$'\nDISABLE_SERVICES=cups apport'
expect_services 'with no candidate installed nothing is asked and empty stays every candidate' '' '' '' \
    "DISABLE_SERVICES=$SERVICE_CANDIDATES"
expect_services 'with no candidate installed nothing is asked and none stays none' none '' '' 'DISABLE_SERVICES=none'
grep -q 'None of them is installed: nothing to ask' "$tmp/questions" && grep -q '(now: none; none = keep them)' "$tmp/questions" ||
    fail "with no candidate installed, the questions do not say that nothing is asked and what DISABLE_SERVICES holds" "$tmp/questions"
printf 'ok: with no candidate installed the questions say so, with the value a re-run uses\n'

# At a terminal, empty saved answers of 1.1.1 or older get a warning above the first service question, once,
# and the plan then has nothing to warn about: the services were answered here.
old_empty_questions() {   # old_empty_questions INSTALLED: OLD_EMPTY_SERVICES after the questions (they are in $tmp/questions)
    (
        installed=" $1 "
        ask() { printf -v "$1" '%s' "${!1:-${3:-}}"; }
        ask_yn() { printf -v "$1" '%s' "${!1:-${3:-no}}"; }
        ask_secret() { :; }
        systemctl() { [[ $1 == cat && $installed == *" $2 "* ]]; }
        INTERACTIVE=1 SAVED_ANSWERS=1 OLD_EMPTY_SERVICES=1 DISABLE_SERVICES="" PANEL_ACCESS=tailscale ADMIN_IPS=192.168.1.50
        questions > "$tmp/questions" 2>&1 || exit 1
        printf '%s' "$OLD_EMPTY_SERVICES"
    )
}
got="$(old_empty_questions 'cups bluetooth')" || fail "questions stopped" "$tmp/questions"
[[ "$got" == 0 && $(grep -c '1.1.1 or older saved it so when you kept every service' "$tmp/questions") -eq 1 ]] ||
    fail "with empty answers of 1.1.1 or older, the questions give OLD_EMPTY_SERVICES=$got and this warning count: $(grep -c '1.1.1 or older' "$tmp/questions")" "$tmp/questions"
got="$(old_empty_questions '')" || fail "questions stopped" "$tmp/questions"
[[ "$got" == 0 ]] && ! grep -q '1.1.1 or older' "$tmp/questions" && grep -q '(now: every one; none = keep them)' "$tmp/questions" ||
    fail "with empty answers of 1.1.1 or older and no candidate installed, the questions give OLD_EMPTY_SERVICES=$got" "$tmp/questions"
printf 'ok: at a terminal, empty answers of 1.1.1 or older get one warning above the service questions\n'

# --- questions: from the saved answers, Enter keeps an answer emptied with - -------------------------------
access_defaults() {   # access_defaults SAVED_ANSWERS ADMIN_IPS PANEL_ACCESS: ADMIN_IPS|PANEL_ACCESS after Enter everywhere
    (
        ask() { printf -v "$1" '%s' "${!1:-${3:-}}"; }
        ask_yn() { printf -v "$1" '%s' "${!1:-${3:-no}}"; }
        ask_secret() { :; }
        systemctl() { return 1; }
        INTERACTIVE=1 SAVED_ANSWERS="$1" ADMIN_IPS="$2" PANEL_ACCESS="$3" PANEL_IP=198.51.100.2 DISABLE_SERVICES=""
        questions > "$tmp/questions" 2>&1 || exit 1
        printf '%s|%s' "$ADMIN_IPS" "$PANEL_ACCESS"
    )
}
for c in '1|||' '1|192.168.1.50|tailscale|192.168.1.50|tailscale' "0|||$LAN_CIDR|public"; do
    IFS='|' read -r saved ips access want_ips want_access <<< "$c"
    got="$(access_defaults "$saved" "$ips" "$access")" || fail "questions stopped" "$tmp/questions"
    [[ "$got" == "$want_ips|$want_access" ]] ||
        fail "with SAVED_ANSWERS=$saved, ADMIN_IPS=\"$ips\" and PANEL_ACCESS=\"$access\", Enter gives \"$got\", want \"$want_ips|$want_access\""
done
printf 'ok: from the saved answers Enter keeps an empty ADMIN_IPS and PANEL_ACCESS; a first run suggests the LAN and public\n'

# --- questions: without the firewall step, the to-do names the firewall rules an answer removed here -------
# A run with the firewall step deletes them, and its plan lists them (issue #67): no to-do then.
removed_todo() {   # removed_todo STEPS: the to-do after the questions of a run of STEPS (--only, empty = every step);
                   # answers come from the ANSWER array, others are Enter
    (
        ask() { if [[ -v "ANSWER[$1]" ]]; then printf -v "$1" '%s' "${ANSWER[$1]}"; else printf -v "$1" '%s' "${!1:-${3:-}}"; fi; }
        ask_yn() { if [[ -v "ANSWER[$1]" ]]; then printf -v "$1" '%s' "${ANSWER[$1]}"; else printf -v "$1" '%s' "${!1:-${3:-no}}"; fi; }
        ask_secret() { :; }
        systemctl() { return 1; }
        INTERACTIVE=1 SAVED_ANSWERS=1 MANUAL_TODO=() ONLY="$1"
        questions > "$tmp/questions" 2>&1 || exit 1
        printf '%s\n' "${MANUAL_TODO[@]}"
    )
}
declare -A ANSWER=([EXTRA_PORTS]='' [ADMIN_IPS]='192.168.1.0/24' [PANEL_ACCESS]=public [EXPOSE_WEB]=no [PANEL_IP]=198.51.100.7)
EXTRA_PORTS='5432/tcp 8000 *' ADMIN_IPS='192.168.1.0/24,203.0.113.4' PANEL_ACCESS='cloudflared,tailscale,public' PANEL_IP=198.51.100.2 \
    EXPOSE_WEB=yes got="$(removed_todo ssh)" || fail "questions stopped" "$tmp/questions"
want='ports 80/443, port 5432/tcp, port 8000, port *, SSH source 203.0.113.4, access tailscale, panel IP 198.51.100.2'
[[ "$got" == *"($want)"*'--only firewall --dry-run, then the same without --dry-run' && $(grep -c . <<< "$got") -eq 1 ]] ||
    fail "after removing answers in a run without the firewall step, the to-do is:
$got
want one line with: ($want)"
got="$(removed_todo '')" || fail "questions stopped" "$tmp/questions"
[[ -z "$got" ]] || fail "after removing answers in a run with the firewall step, which deletes their rules, the to-do is: $got"
ANSWER=([EXTRA_PORTS]='5432/tcp 8000' [ADMIN_IPS]='192.168.1.0/24 203.0.113.4' [EXPOSE_WEB]=yes)
EXTRA_PORTS='5432/tcp,8000' ADMIN_IPS='192.168.1.0/24' PANEL_ACCESS='tailscale,public' PANEL_IP=198.51.100.2 \
    EXPOSE_WEB=yes got="$(removed_todo ssh)" || fail "questions stopped" "$tmp/questions"
[[ -z "$got" ]] || fail "with nothing removed, the to-do is: $got"
unset ANSWER
printf 'ok: without the firewall step, the to-do names the ports, sources and access methods removed from the answers, and only them\n'
EXTRA_PORTS="" ADMIN_IPS="" PANEL_ACCESS="" PANEL_IP="" EXPOSE_WEB=""

# --- summary_and_confirm: no SSH source and public access only is a lockout, Proceed defaults to no -------
lockout_default() {   # lockout_default ADMIN_IPS PANEL_ACCESS [ONLY]: the default of "Proceed?" at a terminal (the plan in $tmp/plan)
    (
        # as the real confirm, refuse a default other than yes or no (status 9: summary_and_confirm stopped)
        confirm() {
            [[ ${2:-} == yes || ${2:-} == no ]] || { printf 'confirm: no default (yes or no) for: %s\n' "$1"; exit 9; }
            printf '%s' "$2" > "$tmp/proceed"
        }
        INTERACTIVE=1 ASSUME_YES=0 ADMIN_IPS="$1" PANEL_ACCESS="$2" ONLY="${3:-}" PANEL_IP=198.51.100.2 DISABLE_SERVICES=none
        summary_and_confirm > "$tmp/plan" 2>&1 || exit 1
        cat "$tmp/proceed"
    )
}
for c in '|public|' ' , |public|'; do
    IFS='|' read -r ips access only <<< "$c"
    got="$(lockout_default "$ips" "$access" "$only")" || fail "summary_and_confirm stopped" "$tmp/plan"
    [[ "$got" == no ]] && grep -q "you will be locked out of new SSH logins. Answer n and add" "$tmp/plan" ||
        fail "with ADMIN_IPS=\"$ips\" and public access only, Proceed defaults to \"$got\", want no and a lockout warning" "$tmp/plan"
done
# --yes keeps the default of Proceed? (issue #65): the real confirm, so a --yes run stops there before any
# change, and only --yes --force goes on. The warning says which.
lockout_yes() {   # lockout_yes FORCE ADMIN_IPS PANEL_ACCESS: the status of summary_and_confirm with --yes (the plan in $tmp/plan)
    (
        INTERACTIVE=0 ASSUME_YES=1 FORCE="$1" ADMIN_IPS="$2" PANEL_ACCESS="$3" ONLY="" PANEL_IP=198.51.100.2 DISABLE_SERVICES=none
        summary_and_confirm > "$tmp/plan" 2>&1
    )
}
for ips in '' ' , '; do
    st=0; lockout_yes 0 "$ips" public || st=$?
    [[ $st -eq 1 ]] && grep -q 'locked out of new SSH logins. With --yes the run stops here (Proceed? keeps its default, no): add your IP or network to ADMIN_IPS, or use --yes --force only with a console at hand' "$tmp/plan" &&
        grep -q 'Proceed? no (--yes keeps the default)' "$tmp/plan" && grep -q 'Stopped before any change: no allowed SSH source' "$tmp/plan" &&
        ! grep -qE 'goes on|Ctrl-C|Aborted by user' "$tmp/plan" ||
        fail "with --yes, ADMIN_IPS=\"$ips\" and public access only, summary_and_confirm exits $st, want 1 and a warning that the run stops here" "$tmp/plan"
done
st=0; lockout_yes 1 '' public || st=$?
[[ $st -eq 0 ]] && grep -q 'locked out of new SSH logins. With --yes --force the run goes on: until ADMIN_IPS holds your IP or network, only a console lets you log in' "$tmp/plan" &&
    grep -q 'Proceed? yes (--force)' "$tmp/plan" && ! grep -q 'stops here' "$tmp/plan" ||
    fail "with --yes --force, no SSH source and public access only, summary_and_confirm exits $st, want 0 and a warning that the run goes on" "$tmp/plan"
# --yes with an allowed SSH source, or Tailscale: no lockout, Proceed? keeps its default (yes)
for c in '0|192.168.1.50|public' '0||tailscale,public'; do
    IFS='|' read -r force ips access <<< "$c"
    st=0; lockout_yes "$force" "$ips" "$access" || st=$?
    [[ $st -eq 0 ]] && grep -q 'Proceed? yes (--yes keeps the default)' "$tmp/plan" && ! grep -q 'locked out' "$tmp/plan" ||
        fail "with --yes, ADMIN_IPS=\"$ips\" and PANEL_ACCESS=$access, summary_and_confirm exits $st, want 0 and no warning" "$tmp/plan"
done
for c in '192.168.1.50|public|' '|tailscale,public|' '|cloudflared,public|' '|public|services'; do
    IFS='|' read -r ips access only <<< "$c"
    got="$(lockout_default "$ips" "$access" "$only")" || fail "summary_and_confirm stopped" "$tmp/plan"
    [[ "$got" == yes ]] && ! grep -q 'locked out' "$tmp/plan" ||
        fail "with ADMIN_IPS=\"$ips\", PANEL_ACCESS=$access and ONLY=\"$only\", Proceed defaults to \"$got\", want yes and no warning" "$tmp/plan"
done
printf 'ok: with no SSH source and public access only the plan warns and Proceed defaults to no (--yes stops there, --yes --force goes on), otherwise yes\n'

# --- save_answers: none and LAPTOP_MODE are saved, the secrets are not -----------------------------------
(
    DRY_RUN=0 CONF_DIR="$tmp/conf" DISABLE_SERVICES=none LAPTOP_MODE=no ADMIN_IPS="" PANEL_ACCESS=tailscale EXPOSE_WEB=no
    TELEGRAM_BOT_TOKEN='123456:fake-bot-token' CLOUDFLARED_TOKEN=fake-tunnel-token CROWDSEC_ENROLL_KEY=fake-enroll-key
    mkdir -p "$CONF_DIR"
    save_answers
)
saved="$tmp/conf/server-prep.conf"
[[ -f "$saved" ]] || fail "save_answers wrote no file"
grep -qx 'DISABLE_SERVICES=none' "$saved" || fail "the saved answers do not hold DISABLE_SERVICES=none" "$saved"
grep -qx 'LAPTOP_MODE=no' "$saved" || fail "the saved answers do not hold LAPTOP_MODE=no" "$saved"
[[ "$(stat -c %a "$saved")" == 600 ]] || fail "the saved answers have mode $(stat -c %a "$saved"), want 600"
grep -qE '^(TELEGRAM_BOT_TOKEN|CLOUDFLARED_TOKEN|CROWDSEC_ENROLL_KEY)=|fake-' "$saved" && fail "the saved answers hold a secret" "$saved"
printf 'ok: save_answers writes DISABLE_SERVICES=none and LAPTOP_MODE (mode 600), and no secret\n'

# A --yes re-run from the saved answers loads them over the environment, recognizes them, and saves the same
# answers again: the services, LAPTOP_MODE and the empty ADMIN_IPS do not change.
got="$(env -i PATH="$PATH" LAPTOP_MODE=yes DISABLE_SERVICES=cups bash -c '
    . "$1" --config "$2" --yes --only services
    LOG_FILE="$3/rerun.log" CURRENT_SSH_PORTS=22 IS_LAPTOP=0 DRY_RUN=0 CONF_DIR="$3/rerun"
    mkdir -p "$CONF_DIR"
    summary_and_confirm > "$3/plan" 2>&1 && save_answers &&
        printf "%s|%s|%s" "$SAVED_ANSWERS" "$LAPTOP_MODE" "$DISABLE_SERVICES"' _ "$SCRIPT" "$saved" "$tmp" 2>&1)"
[[ "$got" == '1|no|none' ]] || fail "a --yes re-run from the saved answers gives \"$got\", want \"1|no|none\"" "$tmp/plan"
diff <(sed 1d "$saved") <(sed 1d "$tmp/rerun/server-prep.conf") > "$tmp/diff" ||
    fail "a --yes re-run from the saved answers saves other answers" "$tmp/diff"
printf 'ok: a --yes re-run from the saved answers keeps LAPTOP_MODE, none and an empty ADMIN_IPS, over the environment\n'

# Only the file save_answers wrote counts as saved answers: not a config written by hand, and not a pipe
# (reading its first line would take it from the config), which must still be read whole.
sed 1d "$saved" > "$tmp/hand.conf"
got="$(env -i PATH="$PATH" bash -c '. "$1" --config "$2" --yes; printf "%s|%s" "$SAVED_ANSWERS" "$LAPTOP_MODE"' \
    _ "$SCRIPT" "$tmp/hand.conf" 2>&1)"
[[ "$got" == '0|no' ]] || fail "--config with a config written by hand gives \"$got\", want \"0|no\""
# A named pipe stands for --config <(...): the fd of a process substitution does not outlive a sourced command.
mkfifo "$tmp/pipe.conf"
cat "$saved" > "$tmp/pipe.conf" &
got="$(env -i PATH="$PATH" timeout 30 bash -c '. "$1" --config "$2" --yes; printf "%s|%s" "$SAVED_ANSWERS" "$LAPTOP_MODE"' \
    _ "$SCRIPT" "$tmp/pipe.conf" 2>&1)"
wait
[[ "$got" == '0|no' ]] || fail "--config with the saved answers through a pipe gives \"$got\", want \"0|no\""
printf 'ok: only the file save_answers wrote counts as saved answers, and a pipe is still read whole\n'

# Answers saved by a version before #74 hold DISABLE_SERVICES='' when every service was kept: with --yes it
# still means every candidate (an empty value means that in any config), but the plan warns under it and the
# to-do says to write none, with the command to turn a service back on when the services step runs.
{
    printf '# server-prep answers - 20260101_000000 - reuse with: --config /etc/server-prep/server-prep.conf --yes\n'
    printf "ADMIN_USER=srvprep-test-admin\nPANEL_ACCESS=tailscale\nDISABLE_SERVICES=''\nTIMEZONE=UTC\n"
} > "$tmp/old-answers.conf"
old_answers_run() {   # old_answers_run CONFIG ONLY [OPTION]: OLD_EMPTY_SERVICES|DISABLE_SERVICES, then the to-do (the plan in $tmp/plan)
    env -i PATH="$PATH" bash -c '
        . "$1" --config "$2" --yes ${5:+"$5"} --only "$4"
        LOG_FILE="$3/old.log" CURRENT_SSH_PORTS=22 IS_LAPTOP=0
        printf "%s|" "$OLD_EMPTY_SERVICES"
        summary_and_confirm > "$3/plan" 2>&1 && printf "%s\n" "$DISABLE_SERVICES" && printf "%s\n" "${MANUAL_TODO[@]}"' \
        _ "$SCRIPT" "$1" "$tmp" "$2" "${3:-}" 2>&1
}
got="$(old_answers_run "$tmp/old-answers.conf" services)"
[[ "$(head -n 1 <<< "$got")" == "1|$SERVICE_CANDIDATES" ]] ||
    fail "a --yes run from old answers with DISABLE_SERVICES='' gives \"$(head -n 1 <<< "$got")\", want \"1|$SERVICE_CANDIDATES\"" "$tmp/plan"
# --yes keeps the default of Proceed? (yes, issue #65): the run does not wait, so the warning says what it
# does and when to write none, not to press Ctrl-C
grep -q "empty DISABLE_SERVICES, which means every service listed above.*With --yes the run goes on and disables them: if you kept them, the to-do at the end says what to do. To keep them, set DISABLE_SERVICES=none in $tmp/old-answers.conf before a --yes run" "$tmp/plan" &&
    grep -q 'Proceed? yes (--yes keeps the default)' "$tmp/plan" && ! grep -q 'Ctrl-C' "$tmp/plan" ||
    fail "the plan from old answers does not warn that the --yes run goes on and disables every service" "$tmp/plan"
[[ $(grep -c . <<< "$got") -eq 2 && "$got" == *"empty DISABLE_SERVICES"*"set DISABLE_SERVICES=none in /etc/server-prep/server-prep.conf, and turn back on"*"systemctl enable --now <name>" ]] ||
    fail "the to-do from old answers with --only services is:
$got"
got="$(old_answers_run "$tmp/old-answers.conf" telegram)"
[[ $(grep -c . <<< "$got") -eq 2 && "$got" == *"set DISABLE_SERVICES=none in /etc/server-prep/server-prep.conf" ]] ||
    fail "the to-do from old answers with --only telegram (the answers keep the empty value) is:
$got"
# without the services step the run disables nothing: the warning does not say it does
grep -q 'With --yes the run goes on: if you kept them' "$tmp/plan" && ! grep -q 'disables them' "$tmp/plan" ||
    fail "the plan from old answers with --only telegram does not say that the run goes on without disabling the services" "$tmp/plan"
# save_answers keeps the empty value when the services step did not run, so the next run with it warns again;
# after a run of the services step, the answers list what it disabled (every candidate).
for only in telegram services; do
    rm -rf "$tmp/old-saved"; mkdir -p "$tmp/old-saved"
    env -i PATH="$PATH" bash -c '
        . "$1" --config "$2" --yes --only "$4"
        LOG_FILE="$3/old.log" CURRENT_SSH_PORTS=22 IS_LAPTOP=0 DRY_RUN=0 CONF_DIR="$3/old-saved"
        summary_and_confirm > "$3/plan" 2>&1 && save_answers' _ "$SCRIPT" "$tmp/old-answers.conf" "$tmp" "$only" > /dev/null 2>&1 ||
        fail "a --yes run from old answers with --only $only did not save its answers" "$tmp/plan"
    want="DISABLE_SERVICES=''"
    [[ $only == services ]] && want="DISABLE_SERVICES=$(printf '%q' "$SERVICE_CANDIDATES")"
    grep -qxF "$want" "$tmp/old-saved/server-prep.conf" ||
        fail "after a --yes run from old answers with --only $only, the saved answers hold $(grep '^DISABLE_SERVICES=' "$tmp/old-saved/server-prep.conf"), want $want"
done
# With no allowed SSH source and only the panel's public IP, Proceed? defaults to no and a --yes run stops
# there: the warning says so, not that the run goes on and disables them. --yes --force goes on, and says it.
sed -e "s/^PANEL_ACCESS=.*/PANEL_ACCESS=public\nPANEL_IP=198.51.100.2\nADMIN_IPS=''/" "$tmp/old-answers.conf" > "$tmp/old-lockout.conf"
st=0; got="$(old_answers_run "$tmp/old-lockout.conf" 'firewall services')" || st=$?
[[ $st -eq 1 && "$got" == '1|' ]] &&
    grep -q "empty DISABLE_SERVICES, which means every service listed above.*With --yes this run stops at Proceed? below, before any change (no allowed SSH source, see the warning below). To keep them, set DISABLE_SERVICES=none in $tmp/old-lockout.conf before a --yes run" "$tmp/plan" &&
    grep -q 'locked out of new SSH logins. With --yes the run stops here' "$tmp/plan" &&
    grep -q 'Proceed? no (--yes keeps the default)' "$tmp/plan" && grep -q 'Stopped before any change: no allowed SSH source' "$tmp/plan" &&
    ! grep -qE 'goes on|disables them|to-do at the end' "$tmp/plan" ||
    fail "a --yes run from old answers with no allowed SSH source exits $st with \"$got\", want 1, \"1|\" and a plan that says the run stops at Proceed?" "$tmp/plan"
got="$(old_answers_run "$tmp/old-lockout.conf" 'firewall services' --force)" ||
    fail "a --yes --force run from old answers with no allowed SSH source stopped" "$tmp/plan"
[[ "$(head -n 1 <<< "$got")" == "1|$SERVICE_CANDIDATES" ]] &&
    grep -q 'With --yes the run goes on and disables them: if you kept them, the to-do at the end says what to do' "$tmp/plan" &&
    grep -q 'locked out of new SSH logins. With --yes --force the run goes on' "$tmp/plan" &&
    grep -q 'Proceed? yes (--force)' "$tmp/plan" && ! grep -q 'stops' "$tmp/plan" ||
    fail "a --yes --force run from old answers with no allowed SSH source gives \"$(head -n 1 <<< "$got")\", want \"1|$SERVICE_CANDIDATES\" and a plan that says the run goes on" "$tmp/plan"
# none, a list, or an empty value in a config written by hand: no warning, no to-do
sed "s/^DISABLE_SERVICES=.*/DISABLE_SERVICES=none/" "$tmp/old-answers.conf" > "$tmp/new-answers.conf"
sed 1d "$tmp/old-answers.conf" > "$tmp/hand-empty.conf"
for f in new-answers hand-empty; do
    got="$(old_answers_run "$tmp/$f.conf" services)"
    [[ $(grep -c . <<< "$got") -eq 1 && "$got" == 0\|* ]] && ! grep -q 'DISABLE_SERVICES' "$tmp/plan" ||
        fail "a --yes run from $f.conf warns about DISABLE_SERVICES or adds a to-do:
$got" "$tmp/plan"
done
printf "ok: with --yes, an empty DISABLE_SERVICES from old answers still means every candidate, and the plan and the to-do say to write none\n"

# --- step_services: none disables nothing ------------------------------------------------------------------
services_calls() {   # services_calls VALUE: the svc_disable and run calls of step_services
    (
        : > "$tmp/calls"
        svc_disable() { printf 'svc_disable %s\n' "$*" >> "$tmp/calls"; }
        run() { printf 'run %s\n' "$*" >> "$tmp/calls"; }
        systemctl() {
            case "$1" in
                is-enabled) echo masked ;;            # ctrl-alt-del.target is masked already
                get-default) echo multi-user.target ;;
            esac
            return 0                                   # list-units: no running service
        }
        DISABLE_SERVICES="$1" HEADLESS=no STEP_NOTES=""
        step_services > "$tmp/services" 2>&1 || exit 1
        cat "$tmp/calls"
        printf 'note: %s\n' "$STEP_NOTES"
    )
}
for v in none NONE; do
    got="$(services_calls "$v")" || fail "step_services with $v failed" "$tmp/services"
    [[ "$got" == "note: disabled: $v; running services 0 -> 0" ]] || fail "step_services with DISABLE_SERVICES=$v gives:
$got"
done
got="$(services_calls 'cups apport')" || fail "step_services with cups apport failed" "$tmp/services"
[[ "$got" == $'svc_disable cups.path cups.socket cups.service\nsvc_disable apport.service\nrun sysctl -q -w fs.suid_dumpable=0\nnote: disabled: cups apport; running services 0 -> 0' ]] ||
    fail "step_services with cups apport gives:
$got"
printf 'ok: step_services with DISABLE_SERVICES=none disables nothing, and disables a list\n'

# --- removed_words: list items, comma or space separated, never globbed -----------------------------------
got="$(removed_words port '5432/tcp,8000 8000 * 6001/udp' '8000,6001/udp')"
[[ "$got" == $'port 5432/tcp\nport *' ]] || fail "removed_words gives \"$got\""
[[ -z "$(removed_words port '' '8000')" ]] || fail "removed_words with nothing removed prints something"
printf 'ok: removed_words lists the items that are gone, once each\n'

# --- ask at a terminal: - or none empties an optional answer, a question that needs a value asks again ----
# ask reads /dev/tty: script gives the driver a controlling terminal and types the piped lines there.
help="$(script --help 2>&1)" || :
if ! command -v script >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
    printf 'skip: ask at a terminal (script or timeout not found)\n'
elif [[ "$help" != *--quiet* || "$help" != *--return* || "$help" != *--command* ]]; then
    printf 'skip: ask at a terminal (script lacks --quiet, --return or --command)\n'
else
    cat > "$tmp/ask-driver" <<'EOF'
# shellcheck disable=SC1090
. "$1" --yes
LOG_FILE="$ASK_LOG"
INTERACTIVE=1
EXTRA_PORTS=5432/tcp ADMIN_IPS="" TELEGRAM_IGNORE_USERS=root SSH_PORT=822 TIMEZONE=""
ask EXTRA_PORTS "Extra ports (- = none)" "$EXTRA_PORTS" optional
ask ADMIN_IPS "Allowed SSH sources (- = none)" 192.168.1.50 optional
ask TELEGRAM_IGNORE_USERS "Users without login alerts (- = none)" "$TELEGRAM_IGNORE_USERS" optional
ask SSH_PORT "New SSH port" "$SSH_PORT"
ask TIMEZONE "Timezone" UTC
printf '%s|%s|%s|%s|%s\n' "$EXTRA_PORTS" "$ADMIN_IPS" "$TELEGRAM_IGNORE_USERS" "$SSH_PORT" "$TIMEZONE" > "$ASK_RESULT"
EOF
    : > "$tmp/ask-result"
    status=0
    # - and None empty the first two, Enter keeps root, - asks the port again (2222), NONE asks the
    # timezone again, then Enter keeps UTC. script does not pass the end of the input on to the terminal,
    # so an ask that reads one line too many would wait forever: timeout stops it.
    out="$(printf -- '-\nNone\n\n-\n2222\nNONE\n\n' |
        ASK_DRIVER="$tmp/ask-driver" ASK_SCRIPT="$SCRIPT" ASK_LOG="$tmp/ask.log" ASK_RESULT="$tmp/ask-result" \
        timeout -k 5 60 script --quiet --return --command 'bash "$ASK_DRIVER" "$ASK_SCRIPT"' /dev/null 2>&1)" || status=$?
    out="${out//$'\r'/}"
    got="$(cat "$tmp/ask-result")"
    if [[ $status -ne 0 || "$got" != '||root|2222|UTC' || $(grep -c 'This answer cannot be empty' <<< "$out") -ne 2 ]]; then
        printf 'not ok: ask at a terminal exited %s and gave "%s", want 0, "||root|2222|UTC" and two "cannot be empty" lines\n' \
            "$status" "$got"
        printf '%s\n' "$out" >&2
        exit 1
    fi
    printf 'ok: ask at a terminal: - and none empty an optional answer, a question that needs a value asks again\n'
fi
