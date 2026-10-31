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
expect_help 'bash -c' '' bash -c "$(cat "$SCRIPT")" server-prep.sh --help
expect_help 'bash -c with a file as $0' '' bash -c "$(cat "$SCRIPT")" "$SCRIPT" --help
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

# step_firewall: a re-run that changes nothing is "OK (already)" and a ufw-docker
# failure fails the step. Every call that would reach the host is replaced first.
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
ufw() { echo "Status: active"; }                   # only "ufw status" is called directly
run() { UFW_STATE="$UFW_STATE_AFTER"; }            # the ufw commands leave the rules as UFW_STATE_AFTER
ufw_state() { printf '%s\n' "$UFW_STATE"; }
ufw_docker_rules() { return "$UFW_DOCKER_RC"; }    # the real one runs ufw-docker, iptables and systemctl
iptables() { printf '%s\n' "${DOCKER_USER_RULES:-}"; }   # the live DOCKER-USER chain

expect_firewall() {   # expect_firewall LABEL HAS_DOCKER STATE_AFTER UFW_DOCKER_RC WANT(ok|fail) WANT_CHANGED [WANT_NOTE]
    local label="$1" want="$5" want_changed="$6" want_note="${7:-}" status=0 got=ok
    HAS_DOCKER="$2"; UFW_STATE_AFTER="$3"; UFW_DOCKER_RC="$4"
    STEP_CHANGED=0; STEP_NOTES=""; MANUAL_TODO=(); UFW_STATE=old
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
expect_firewall 're-run with nothing to change is OK (already)' 1 old 0 ok 0
expect_firewall 'with a new rule is CHANGED' 1 new 0 ok 1
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
DRY_RUN=1
expect_firewall 'dry run is WOULD CHANGE' 1 old 0 ok 1
DRY_RUN=0

# CI runs only this file, so it also runs the audit's DOCKER-USER matcher test (issue #69).
bash "$SCRIPT_DIR/tests/audit-docker-user.sh" || exit 1
