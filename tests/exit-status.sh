#!/usr/bin/env bash
# shellcheck disable=SC2034
# Tests server-prep.sh's final status, argument validation and secret masking without changing the host.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/server-prep.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

expect_usage_error() {   # expect_usage_error "MESSAGE" ARGS...
    local want="$1" out status=0
    shift
    out="$("$SCRIPT" "$@" 2>&1)" || status=$?
    if [[ "$status" -ne 2 || "$out" != *"$want"* ]]; then
        printf 'not ok: %s exited %s, want 2 and "%s"\n' "$*" "$status" "$want"
        exit 1
    fi
    printf 'ok: %s exits 2\n' "$*"
}
expect_usage_error "Unknown step: firewal" --only firewal
expect_usage_error "Unknown step: bogus" --skip ssh,bogus
expect_usage_error "--only needs a value" --only
expect_usage_error "--skip needs a value" --skip
expect_usage_error "--config needs a value" --config
expect_usage_error "--validate needs --config" --validate
expect_usage_error "Cannot read" --config "$tmp" --validate   # a folder is not a config file

# A config file is read before step names are validated, so it cannot bypass the check.
printf 'ONLY=firewal\n' > "$tmp/config"
expect_usage_error "Unknown step: firewal" --config "$tmp/config"

# A glob in a step name is reported literally, not expanded to local filenames.
expect_usage_error "Unknown step: *" --only '*'

# Observe the real initialization without entering preflight or running an audit.
# A test-only EXIT trap records SCRIPT_DIR when --help exits. In particular, stdin
# and bash -c must not treat the current folder (or an arbitrary $0) as a sibling.
cat > "$tmp/check-script-dir" <<'EOF'
trap 'printf "SCRIPT_DIR=%s\n" "${SCRIPT_DIR-<unset>}" > "$SCRIPT_DIR_RESULT"' EXIT
EOF
expect_help() {   # expect_help LABEL WANT_SCRIPT_DIR COMMAND...
    local label="$1" want_dir="$2" out status=0
    shift 2
    : > "$tmp/script-dir"
    out="$(BASH_ENV="$tmp/check-script-dir" SCRIPT_DIR_RESULT="$tmp/script-dir" "$@" 2>"$tmp/stderr")" || status=$?
    if [[ "$status" -ne 0 || "$out" != *"Exit codes:"* || -s "$tmp/stderr" ||
          "$(cat "$tmp/script-dir")" != "SCRIPT_DIR=$want_dir" ]]; then
        printf 'not ok: %s help exited %s, emitted an error or used the wrong script folder\n' "$label" "$status"
        cat "$tmp/stderr" >&2
        cat "$tmp/script-dir" >&2
        exit 1
    fi
    printf 'ok: %s help exits 0 without errors and uses the expected script folder\n' "$label"
}
expect_help file "$SCRIPT_DIR" bash "$SCRIPT" --help
expect_help stdin '' bash -s -- --help < "$SCRIPT"
# stdin again, with the script file itself as $0: a header that trusts $0 would pick its folder
expect_help 'stdin with a file as $0' '' bash -c 'exec -a "$1" bash -s -- --help' _ "$SCRIPT" < "$SCRIPT"
# Linux limits one argument to 128 KiB (MAX_ARG_STRLEN), so a larger script cannot run as bash -c "$(cat ...)"
# at all: nothing to test then. The other ways to run it (file, stdin, sourced) stay checked.
if (( $(wc -c < "$SCRIPT") < 131072 )); then
    expect_help 'bash -c' '' bash -c "$(cat "$SCRIPT")" server-prep.sh --help
    expect_help 'bash -c with a file as $0' '' bash -c "$(cat "$SCRIPT")" "$SCRIPT" --help
else
    printf 'skip: bash -c "$(cat server-prep.sh)" (the script is over the 128 KiB argument limit)\n'
fi
expect_help sourced "$SCRIPT_DIR" bash -c '. "$1" --help' _ "$SCRIPT"
mkdir "$tmp/script dir"
cp "$SCRIPT" "$tmp/script dir/server-prep.sh"
expect_help 'file path with spaces' "$tmp/script dir" bash "$tmp/script dir/server-prep.sh" --help

# Only skip terminal cases when their helper or required options are unavailable.
# Inspect help, not the real test command: failures in a supported helper must fail.
have_terminal_tool() {   # have_terminal_tool LABEL TOOL OPTIONS...
    local label="$1" tool="$2" help option
    shift 2
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'skip: %s (%s not found)\n' "$label" "$tool"
        return 1
    fi
    help="$("$tool" --help 2>&1)" || :
    for option in "$@"; do
        if [[ "$help" != *"$option"* ]]; then
            printf 'skip: %s (%s lacks %s)\n' "$label" "$tool" "$option"
            return 1
        fi
    done
    return 0
}

# Load the real initialization without running main or changing the host. setsid
# removes the controlling terminal even if this test was started interactively.
cat > "$tmp/load-script" <<'EOF'
# shellcheck disable=SC1090
. "$1" "${@:2}"
printf 'loaded: INTERACTIVE=%s\n' "$INTERACTIVE"
EOF
expect_no_terminal() {   # expect_no_terminal WANT_STATUS WANT_OUTPUT ARGS...
    local want_status="$1" want_output="$2" out status=0
    shift 2
    out="$(setsid --wait bash "$tmp/load-script" "$SCRIPT" "$@" </dev/null 2>&1)" || status=$?
    if [[ "$status" -ne "$want_status" || "$out" != "$want_output" ]]; then
        printf 'not ok: no terminal with %s exited %s, want %s and "%s"\n' "$*" "$status" "$want_status" "$want_output"
        printf '%s\n' "$out" >&2
        exit 1
    fi
    printf 'ok: no terminal with %s exits %s\n' "$*" "$want_status"
}
if have_terminal_tool 'no-terminal tests' setsid --wait; then
    expect_no_terminal 2 'No terminal: use --yes with --config' --dry-run
    expect_no_terminal 0 'loaded: INTERACTIVE=0' --dry-run --yes

    # A failed terminal open must keep the same message and status in POSIX mode.
    status=0
    out="$(POSIXLY_CORRECT=1 setsid --wait bash "$tmp/load-script" "$SCRIPT" --dry-run </dev/null 2>&1)" || status=$?
    if [[ "$status" -ne 2 || "$out" != 'No terminal: use --yes with --config' ]]; then
        printf 'not ok: no terminal in POSIX mode exited %s, want 2 and the no-terminal message\n' "$status"
        printf '%s\n' "$out" >&2
        exit 1
    fi
    printf 'ok: no terminal in POSIX mode exits 2 with the expected message\n'
fi

# Redirected stdin must still work when /dev/tty can be opened (curl | bash).
# script allocates a controlling terminal; the child explicitly closes its
# terminal stdin so a guard based only on [[ -t 0 ]] would fail this regression.
if have_terminal_tool 'controlling-terminal test' script --quiet --return --command; then
    status=0
    out="$(TERMINAL_TEST_DRIVER="$tmp/load-script" TERMINAL_TEST_SCRIPT="$SCRIPT" \
        script --quiet --return --command 'bash "$TERMINAL_TEST_DRIVER" "$TERMINAL_TEST_SCRIPT" --dry-run </dev/null' /dev/null </dev/null 2>&1)" || status=$?
    out="${out//$'\r'/}"
    if [[ "$status" -ne 0 || "$out" != 'loaded: INTERACTIVE=1' ]]; then
        printf 'not ok: controlling terminal with redirected stdin exited %s\n' "$status"
        printf '%s\n' "$out" >&2
        exit 1
    fi
    printf 'ok: controlling terminal works with redirected stdin\n'
fi

# Load the real functions without starting a run, then replace the calls that
# touch the host. --yes also avoids requiring a terminal when sourcing in CI.
# shellcheck disable=SC1090
. "$SCRIPT" --yes
preflight() { :; }
intro() { :; }
questions() { :; }
summary_and_confirm() { :; }
save_answers() { :; }
run_audit() { :; }
write_rollback() { :; }
write_report() { :; }
# the real one would write under /root/server-prep-reports and into a home
REPORT_FILE="$tmp/server-prep-report-test.md"
write_report_json() { : > "${REPORT_FILE%.md}.json"; }
title() { :; }

# Fake steps only record their result. main() and its final result loop are real.
OS_PRETTY="test"
run_step() {
    STEP_NAMES+=("$2")
    STEP_DETAILS+=(-)
    if [[ "$1" == "$FAIL_STEP" ]]; then
        STEP_RESULTS+=("FAILED")
    else
        STEP_RESULTS+=("$PASS_RESULT")
    fi
}

expect_main_status() {   # expect_main_status FAIL_STEP PASS_RESULT WANT
    local status=0
    STEP_NAMES=(); STEP_RESULTS=(); STEP_DETAILS=()
    FAIL_STEP="$1"
    PASS_RESULT="$2"
    main >"$tmp/main-output" 2>&1 || status=$?
    if [[ "$status" -ne "$3" || ${#STEP_RESULTS[@]} -eq 0 ]]; then
        printf 'not ok: main with failed step "%s" and other steps "%s" gave %s, want %s\n' "$1" "$2" "$status" "$3"
        cat "$tmp/main-output" >&2
        exit 1
    fi
    printf 'ok: main with failed step "%s" and other steps "%s" gives %s\n' "$1" "$2" "$3"
}
expect_main_status firewall 'OK (already)' 1   # failure before the final step
expect_main_status suid 'OK (already)' 1       # failure in the final step
expect_main_status none 'OK (already)' 0       # a missing return 0 must fail this
expect_main_status none SKIPPED 0             # no selected step failed
# The Done block names the JSON report next to the Markdown one (issue #15).
if ! grep -qE '^  JSON: +[^ ]+\.json$' "$tmp/main-output"; then
    printf 'not ok: the Done block does not print the JSON report path\n'
    cat "$tmp/main-output" >&2
    exit 1
fi
printf 'ok: the Done block prints the JSON report path\n'
# A JSON report that was not written (write_report_json only warned) is not named.
REPORT_FILE="$tmp/unwritten/server-prep-report-test.md"
write_report_json() { :; }
expect_main_status none SKIPPED 0
if grep -q '^  JSON:' "$tmp/main-output"; then
    printf 'not ok: the Done block names a JSON report that was not written\n'
    cat "$tmp/main-output" >&2
    exit 1
fi
printf 'ok: the Done block leaves out a JSON report that was not written\n'

# run_secret shows a token as *** in the log and in dry-run output, but runs the
# command with the real value. Glob characters in the token must match literally.
LOG_FILE="$tmp/run.log"
: > "$LOG_FILE"
secret='123:tok*[x]'
fake_install() { printf 'installed with %s\n' "$*"; }
DRY_RUN=1
dry_out="$(run_secret "$secret" fake_install service install "$secret")"
DRY_RUN=0
run_secret "$secret" fake_install service install "$secret"
if [[ "$dry_out" != *"[dry-run] fake_install service install ***"* || "$dry_out" == *"$secret"* ]]; then
    printf 'not ok: run_secret dry-run output does not mask the secret: %s\n' "$dry_out"
    exit 1
fi
if [[ "$(grep -cxF '+ fake_install service install ***' "$LOG_FILE")" -ne 2 ]] ||
   grep '^+ ' "$LOG_FILE" | grep -qF -- "$secret"; then
    printf 'not ok: run_secret writes the secret in the log\n'
    cat "$LOG_FILE" >&2
    exit 1
fi
if ! grep -qxF "installed with service install $secret" "$LOG_FILE"; then
    printf 'not ok: run_secret did not pass the real secret to the command\n'
    cat "$LOG_FILE" >&2
    exit 1
fi
printf 'ok: run_secret masks the secret in the log and dry-run output, and runs with the real value\n'

# server-prep-notify gives the Telegram bot URL (with the token) to curl on stdin,
# never on its command line. Capture the scripts step_telegram would write.
write_file() { cat > "$tmp/written-${1##*/}"; }
run() { :; }
DRY_RUN=1
TELEGRAM_ENABLE=yes
TELEGRAM_BOT_TOKEN='123456:test-token'
TELEGRAM_CHAT_ID=42
step_telegram >/dev/null 2>&1
if [[ ! -s "$tmp/written-server-prep-notify" || ! -s "$tmp/written-telegram.env" ]]; then
    printf 'not ok: step_telegram did not write server-prep-notify and telegram.env\n'
    exit 1
fi
sed "s|/etc/server-prep/telegram.env|$tmp/telegram.env|" "$tmp/written-server-prep-notify" > "$tmp/notify"
cp "$tmp/written-telegram.env" "$tmp/telegram.env"
mkdir -p "$tmp/bin"
cat > "$tmp/bin/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$CURL_ARGS"
cat > "$CURL_STDIN"
EOF
chmod +x "$tmp/bin/curl"
CURL_ARGS="$tmp/curl-args" CURL_STDIN="$tmp/curl-stdin" PATH="$tmp/bin:$PATH" bash "$tmp/notify" hello </dev/null
if [[ ! -f "$tmp/curl-args" ]] || grep -qF -- "$TELEGRAM_BOT_TOKEN" "$tmp/curl-args"; then
    printf 'not ok: server-prep-notify puts the bot token on the curl command line\n'
    cat "$tmp/curl-args" >&2
    exit 1
fi
if ! grep -qxF 'chat_id=42' "$tmp/curl-args" || ! grep -qxF 'text=hello' "$tmp/curl-args"; then
    printf 'not ok: server-prep-notify does not send the chat id and the text\n'
    cat "$tmp/curl-args" >&2
    exit 1
fi
if [[ "$(cat "$tmp/curl-stdin")" != 'url = "https://api.telegram.org/bot123456:test-token/sendMessage"' ]]; then
    printf 'not ok: server-prep-notify does not give curl the bot URL on stdin\n'
    cat "$tmp/curl-stdin" >&2
    exit 1
fi
printf 'ok: server-prep-notify gives the bot token to curl on stdin, not on its command line\n'

# A bot token that does not look like 123456:ABC-... (a stray space or quote from a bad
# paste) stops step_telegram before it writes anything.
rm -f "$tmp"/written-*
TELEGRAM_BOT_TOKEN='123456:bad "token'
if step_telegram >/dev/null 2>&1 || compgen -G "$tmp/written-*" >/dev/null; then
    printf 'not ok: step_telegram accepts a malformed bot token\n'
    exit 1
fi
printf 'ok: step_telegram refuses a malformed bot token\n'

# The answers file never holds the bot token: a re-run with --yes and no token keeps
# the one already installed in telegram.env.
CONF_DIR="$tmp/conf"
mkdir -p "$CONF_DIR"
printf 'TELEGRAM_BOT_TOKEN=123456:installed-token\nTELEGRAM_CHAT_ID=42\n' > "$CONF_DIR/telegram.env"
rm -f "$tmp"/written-*
TELEGRAM_BOT_TOKEN=''
if ! step_telegram >/dev/null 2>&1 ||
   ! grep -qxF 'TELEGRAM_BOT_TOKEN=123456:installed-token' "$tmp/written-telegram.env" 2>/dev/null; then
    printf 'not ok: step_telegram does not keep the installed bot token on a re-run without one\n'
    exit 1
fi
printf 'ok: step_telegram keeps the installed bot token on a re-run without one\n'

# step_firewall: a re-run that changes nothing is "OK (already)" and reloads nothing, a
# ufw-docker failure fails the step, and a missing CrowdSec rule in DOCKER-USER restarts the
# bouncer. Every call that would reach the host is replaced first.
LOG_FILE="$tmp/run.log"
DRY_RUN=0
SSH_PORT=822
CURRENT_SSH_PORTS=822
ADMIN_IPS=192.168.1.50
PANEL_ACCESS=""
PANEL_IP=""
EXPOSE_WEB=no
EXTRA_PORTS=""
pkg_install() { :; }
# Only "ufw status [verbose]" is called directly. The real ufw translates these lines on a server set
# to another language, and its Python gettext reads LANGUAGE before LC_ALL (issue #197). This one
# prints French unless it is asked for English the way ufw_status does, so every check that reads
# the status must go through ufw_status.
UFW_UP=1
ufw() {
    local policy="${UFW_POLICY:-deny (incoming), allow (outgoing), deny (routed)}"
    if [[ ${LC_ALL:-} == C && -z ${LANGUAGE:-} ]]; then
        if [[ $UFW_UP -eq 1 ]]; then echo "Status: active"; else echo "Status: inactive"; return 0; fi
        [[ ${2:-} == verbose ]] && echo "Default: $policy"
    else
        if [[ $UFW_UP -eq 1 ]]; then echo "État : actif"; else echo "État : inactif"; return 0; fi
        [[ ${2:-} == verbose ]] && echo "Par défaut : $policy"
    fi
    return 0
}
RAN=()
run() { RAN+=("$*"); UFW_STATE="$UFW_STATE_AFTER"; }   # the ufw commands leave the rules as UFW_STATE_AFTER
ufw_state() { printf '%s\n' "$UFW_STATE"; }
ufw_docker_rules() { return "$UFW_DOCKER_RC"; }    # the real one runs ufw-docker, iptables and systemctl
iptables() { printf '%s\n' "${DOCKER_USER_RULES:-}"; }   # the live DOCKER-USER chain
CROWDSEC_RC=0
crowdsec_in_docker_user() { return "$CROWDSEC_RC"; }   # the real one reads systemctl and the bouncer config

expect_firewall() {   # expect_firewall LABEL HAS_DOCKER STATE_AFTER UFW_DOCKER_RC WANT(ok|fail) WANT_CHANGED [WANT_NOTE]
    local label="$1" want="$5" want_changed="$6" want_note="${7:-}" status=0 got=ok
    HAS_DOCKER="$2"; UFW_STATE_AFTER="$3"; UFW_DOCKER_RC="$4"
    STEP_CHANGED=0; STEP_NOTES=""; MANUAL_TODO=(); UFW_STATE=old; RAN=()
    step_firewall >"$tmp/firewall-output" 2>&1 || status=$?
    [[ "$status" -eq 0 ]] || got=fail
    if [[ "$got" != "$want" || "$STEP_CHANGED" -ne "$want_changed" || "$STEP_NOTES" != *"$want_note"* ]]; then
        printf 'not ok: firewall %s gave %s (status %s), changed=%s, notes "%s"; want %s, changed=%s, notes with "%s"\n' \
            "$label" "$got" "$status" "$STEP_CHANGED" "$STEP_NOTES" "$want" "$want_changed" "$want_note"
        cat "$tmp/firewall-output" >&2
        exit 1
    fi
    printf 'ok: firewall %s\n' "$label"
}
expect_ran() {   # expect_ran LABEL yes|no COMMAND: did the last step_firewall run a command starting with COMMAND
    local label="$1" want="$2" cmd="$3" c got=no
    for c in "${RAN[@]}"; do [[ "$c" == "$cmd"* ]] && got=yes; done
    if [[ "$got" != "$want" ]]; then
        printf 'not ok: firewall %s ran "%s": %s, want %s\n' "$label" "$cmd" "$got" "$want"
        exit 1
    fi
    printf 'ok: firewall %s ran "%s": %s\n' "$label" "$cmd" "$got"
}
expect_firewall 're-run with nothing to change is OK (already)' 1 old 0 ok 0
# 'ufw default' and 'ufw reload' both reload the firewall, which drops CrowdSec's DOCKER-USER rule
expect_ran 're-run with nothing to change' no 'ufw default'
expect_ran 're-run with nothing to change' no 'ufw reload'
expect_ran 're-run with nothing to change' no 'ufw --force enable'
# A server set to French: the step must still read the status in English (issue #197).
LANG=fr_FR.UTF-8 LANGUAGE=fr_FR:fr expect_firewall 're-run on a French server is OK (already)' 1 old 0 ok 0
expect_ran 're-run on a French server' no 'ufw --force enable'
expect_ran 're-run on a French server' no 'ufw default'
UFW_UP=0
expect_firewall 'with UFW off enables it' 1 old 0 ok 1 'UFW enabled'
expect_ran 'with UFW off' yes 'ufw --force enable'
UFW_UP=1
expect_firewall 'with a new rule is CHANGED' 1 new 0 ok 1
expect_ran 'with a new rule' yes 'ufw reload'
UFW_POLICY='allow (incoming), allow (outgoing), disabled (routed)'
expect_firewall 'with other default policies is CHANGED' 1 new 0 ok 1
expect_ran 'with other default policies' yes 'ufw default deny incoming'
UFW_POLICY=""
expect_firewall 'fails when the ufw-docker rules are not loaded' 1 old 1 fail 0 'Docker ports still bypass UFW'
DOCKER_USER_RULES='-A DOCKER-USER -j ufw-user-forward'
expect_firewall 'fails but says when the rules of an earlier run are still loaded' 1 old 1 fail 0 'rules of an earlier run are still loaded'
DOCKER_USER_RULES=""
expect_firewall 'without Docker does not call ufw-docker' 0 old 1 ok 0
if [[ ${#MANUAL_TODO[@]} -eq 0 ]]; then
    printf 'not ok: firewall without Docker gave no to-do\n'
    exit 1
fi
printf 'ok: firewall without Docker adds a to-do\n'
CROWDSEC_RC=1
expect_firewall 'restarts the CrowdSec bouncer when its DOCKER-USER rule is missing' 1 old 0 ok 1 'CrowdSec bouncer restarted'
expect_ran 'with the CrowdSec rule missing' yes 'systemctl restart crowdsec-firewall-bouncer'
DRY_RUN=1
expect_firewall 'dry run is WOULD CHANGE' 1 old 0 ok 1
expect_ran 'dry run' no 'systemctl restart crowdsec-firewall-bouncer'
DRY_RUN=0
CROWDSEC_RC=0

# The SSH safety check tells the user which address to test from a second terminal
# (issue #73). With Tailscale-only access the firewall blocks the local IP, so only the
# Tailscale IP is shown. Without a Tailscale IP, the old text stays as it was, plus a warning
# when the firewall allows only Tailscale.
# "tailscale" is a fake function here: the test never reads this host's real tailnet.
# 192.0.2.10 (a documentation address) stands in for the server's 100.x Tailscale IP.
timeout() { shift; "$@"; }   # drops the duration (always the first argument): the fake tailscale answers at once
tailscale() {
    [[ "$*" == 'ip -4' ]] || return 1
    [[ -n "${TS_OUT:-}" ]] && printf '%s\n' "$TS_OUT"
    return "${TS_RC:-0}"
}
SSH_PORT=822
ADMIN_USER='admin'
LOCAL_IP=192.168.1.50
fallback='  Open a NEW terminal and test:  ssh -p 822 admin@192.168.1.50'

expect_hint() {   # expect_hint LABEL PANEL_ACCESS ADMIN_IPS TS_OUT is|has WANT_FIRST WANT_ALSO NOT_WANT
    local label="$1" match="$5" want_first="$6" want_also="$7" not_want="$8" out first ok=1
    PANEL_ACCESS="$2"; ADMIN_IPS="$3"; TS_OUT="$4"
    out="$(ssh_test_hint)"
    first="${out%%$'\n'*}"
    if [[ "$match" == is ]]; then
        [[ "$first" == "$want_first" ]] || ok=0
    else
        [[ "$first" == *"$want_first"* ]] || ok=0
    fi
    [[ "$out" == *"$want_also"* && "$out" == *"Keep this terminal open"* ]] || ok=0
    [[ -n "$not_want" && "$out" == *"$not_want"* ]] && ok=0
    if [[ $ok -eq 0 ]]; then
        printf 'not ok: SSH test hint %s; first line %s "%s", also "%s", never "%s"; got:\n%s\n' \
            "$label" "$match" "$want_first" "$want_also" "$not_want" "$out"
        exit 1
    fi
    printf 'ok: SSH test hint %s\n' "$label"
}
TS_RC=0
expect_hint 'with Tailscale only shows only the Tailscale IP' tailscale '' 192.0.2.10 \
    has 'admin@192.0.2.10' 'ADMIN_IPS is empty' 'admin@192.168.1.50'
expect_hint 'with Tailscale and a blank ADMIN_IPS shows only the Tailscale IP' tailscale $' ,\t' 192.0.2.10 \
    has 'admin@192.0.2.10' 'ADMIN_IPS is empty' 'admin@192.168.1.50'
expect_hint 'with Tailscale and ADMIN_IPS shows the local IP first' tailscale 192.168.1.0/24 192.0.2.10 \
    has 'admin@192.168.1.50' 'admin@192.0.2.10' 'ADMIN_IPS is empty'
LANG=fr_FR.UTF-8 LANGUAGE=fr_FR:fr expect_hint 'on a French server with Tailscale only shows only the Tailscale IP' \
    tailscale '' 192.0.2.10 has 'admin@192.0.2.10' 'ADMIN_IPS is empty' 'admin@192.168.1.50'
UFW_UP=0   # --skip firewall, or --only ssh on a fresh server
expect_hint 'with Tailscale and the firewall off also shows the local IP' tailscale '' 192.0.2.10 \
    is "$fallback" 'admin@192.0.2.10' ADMIN_IPS
UFW_UP=1
TS_RC=1
expect_hint 'with Tailscale logged out keeps the old text and warns' tailscale '' '' \
    is "$fallback" 'No Tailscale IP found' 'over Tailscale'
expect_hint 'ignores a "Logged out." message' tailscale '' 'Logged out.' \
    is "$fallback" 'No Tailscale IP found' 'over Tailscale'
expect_hint 'with Tailscale logged out and ADMIN_IPS keeps the old text' tailscale 192.168.1.0/24 '' \
    is "$fallback" '' Tailscale
UFW_UP=0
expect_hint 'with Tailscale logged out and the firewall off keeps the old text' tailscale '' '' \
    is "$fallback" '' Tailscale
UFW_UP=1
TS_RC=0
expect_hint 'without tailscale in PANEL_ACCESS keeps the old text' cloudflared '' 192.0.2.10 \
    is "$fallback" '' 192.0.2.10
# Issue #163: with no ADMIN_IPS, ufw_allow_ssh allows SSH only from PANEL_IP (public) or
# only through the tunnel (cloudflared, no SSH rule at all), so the local IP is blocked too.
# 203.0.113.7 (a documentation address) stands in for the panel's public IP.
expect_hint 'with only the tunnel warns and says to test through it' cloudflared '' '' \
    is "$fallback" 'only through the Cloudflare tunnel' 'panel'
expect_hint 'with only the tunnel says to use cloudflared access ssh' cloudflared '' '' \
    is "$fallback" 'Test through the tunnel (cloudflared access ssh, once the tunnel hostname exists), or add' 'root@'
PANEL_IP=203.0.113.7
expect_hint 'with only the panel IP warns and says to test from the panel host' public '' '' \
    is "$fallback" "only from the panel's IP (203.0.113.7)" 'tunnel'
expect_hint 'with only the panel IP says to test as root with the panel key' public '' '' \
    is "$fallback" "Test from the panel's host as root with the panel key (ssh -p 822 root@<server public IP>), or add" 'tunnel'
expect_hint 'with the panel IP and the tunnel names both' public,cloudflared '' '' \
    is "$fallback" "(ssh -p 822 root@<server public IP>), through the tunnel (cloudflared access ssh" 'Tailscale'
expect_hint 'with the panel IP and ADMIN_IPS keeps the old text' public 192.168.1.0/24 '' \
    is "$fallback" '' 'ADMIN_IPS is empty'
UFW_UP=0
expect_hint 'with the panel IP and the firewall off keeps the old text' public '' '' \
    is "$fallback" '' 'ADMIN_IPS is empty'
UFW_UP=1
PANEL_IP=''
expect_hint 'with public and no PANEL_IP keeps the old text (SSH open to anywhere)' public '' '' \
    is "$fallback" '' 'ADMIN_IPS is empty'
# No tailscale at all: have() says so for tailscale only, which also hides a real tailscale
# binary on this host, and the rest of PATH (grep) keeps working. The firewall allows only
# Tailscale, so the warning is expected.
unset -f tailscale
real_have="$(declare -f have)"
have() { [[ "$1" != tailscale ]] && command -v "$1" >/dev/null 2>&1; }
expect_hint 'without the tailscale command keeps the old text and warns' tailscale '' '' \
    is "$fallback" 'No Tailscale IP found' 'over Tailscale'
unset LOCAL_IP
expect_hint 'without a local IP shows a placeholder' tailscale '' '' \
    is '  Open a NEW terminal and test:  ssh -p 822 admin@<server-ip>' 'No Tailscale IP found' 'over Tailscale'
eval "$real_have"
unset -f timeout

# step_docker on a server without jq: a dry run only prints the jq install, so the step must
# not read daemon.json with jq (it used to FAIL with "not valid JSON"). A real run where jq
# is still missing fails with a clear note.
pkg_install() { :; }               # the real one calls dpkg-query and apt-get through run
run() { :; }
have() { [[ "$1" == docker ]]; }   # Docker is installed, jq is not
jq() { return 127; }               # hides a real jq on this host, like a missing command
docker() { :; }                    # "docker compose version" must not reach a real Docker
INSTALL_DOCKER=yes
expect_docker() {   # expect_docker LABEL DRY_RUN WANT_STATUS WANT_TEXT
    local label="$1" status=0
    DRY_RUN="$2"
    STEP_NOTES=""
    step_docker >"$tmp/docker-output" 2>&1 || status=$?
    printf '%s\n' "$STEP_NOTES" >> "$tmp/docker-output"
    if [[ $status -ne $3 ]] || ! grep -qF -- "$4" "$tmp/docker-output" || grep -q 'not valid JSON' "$tmp/docker-output"; then
        printf 'not ok: docker %s (status %s, want %s)\n' "$label" "$status" "$3"
        cat "$tmp/docker-output"
        exit 1
    fi
    printf 'ok: docker %s\n' "$label"
}
expect_docker 'dry run without jq says what it would merge' 1 0 '[dry-run] check /etc/docker/daemon.json and merge log rotation (10m x 3) if missing'
expect_docker 'real run without jq fails with a clear note' 0 1 'jq is missing - /etc/docker/daemon.json left untouched'
eval "$real_have"
unset -f jq docker
DRY_RUN=0

# CI runs only this file, so it also runs the audit's DOCKER-USER matcher test (issue #69), the
# audit's lid-switch parser test (issue #80) and the server-preconfig.sh --check --json test (issue #13).
bash "$SCRIPT_DIR/tests/audit-docker-user.sh" || exit 1
bash "$SCRIPT_DIR/tests/audit-logind-lid.sh" || exit 1
bash "$SCRIPT_DIR/tests/preconfig-json.sh" || exit 1

# ... and the --validate test on a good config and broken ones (issue #17).
bash "$SCRIPT_DIR/tests/validate-config.sh" || exit 1
# ... and the audit's UFW port matcher test (issue #78).
bash "$SCRIPT_DIR/tests/audit-ufw-ports.sh" || exit 1
# ... and the audit on a server set to French: ufw and free read in English (issue #197).
bash "$SCRIPT_DIR/tests/audit-locale.sh" || exit 1
# ... and the audit's server-prep release check on sample release lists (hotfix lane, ADR 0003).
bash "$SCRIPT_DIR/tests/audit-release.sh" || exit 1
# ... and the audit's JSON format: writer keys, schema_version, the schema and every check id in its category's table in docs/json-output.md (issue #16).
bash "$SCRIPT_DIR/tests/audit-json.sh" || exit 1
# ... and server-prep.sh --upgrade against a fake release (no network).
bash "$SCRIPT_DIR/tests/upgrade.sh" || exit 1
# ... and the audit's third-party update matcher (issue #155).
bash "$SCRIPT_DIR/tests/audit-third-party.sh" || exit 1

# ... and the skills check: .agents/skills links to .claude/skills for Codex, SKILL.md frontmatter (issue #33).
bash "$SCRIPT_DIR/tests/skills-sync.sh" || exit 1
# ... and the JSON report test (issue #15).
bash "$SCRIPT_DIR/tests/report-json.sh" || exit 1
# ... and the rollback.sh that write_rollback writes (issue #71).
bash "$SCRIPT_DIR/tests/rollback.sh" || exit 1
# ... and the sshd Port line helpers of the SSH step (issue #72).
bash "$SCRIPT_DIR/tests/sshd-ports.sh" || exit 1
# ... and the Openship AIDE excludes and auditd watch (issue #54).
bash "$SCRIPT_DIR/tests/openship-aide-auditd.sh" || exit 1
# ... and the label taxonomy check on .github/labels.yml (issue #24).
bash "$SCRIPT_DIR/tests/labels.sh" || exit 1
# ... and the committed-file guard (issue #40): on this repository first, so CI fails on a tracked
# report, filled config or key, or an IPv4 address that is not an example; then on temp repos.
bash "$SCRIPT_DIR/tests/check-files.sh" || exit 1
