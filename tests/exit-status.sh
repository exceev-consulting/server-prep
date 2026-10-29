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
