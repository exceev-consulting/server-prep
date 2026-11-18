#!/usr/bin/env bash
# shellcheck disable=SC2034   # QUIET, CURRENT_CAT and the C_* colours are read by the eval'd functions
# Tests the audit's console output (issue #79): result() prints the title, the message and the fix through
# tty_safe, so a control character in a file or process name (an escape sequence in a SUID file name, or a
# C1 control in UTF-8 such as CSI U+009B, say) never reaches the terminal, while the script's own colour codes
# still work and R_TITLE, R_MSG and R_FIX keep the raw text for the JSON report. The real out(), tty_safe() and
# result() of server-audit.sh run on fake results. No root needed and nothing on the host changes: the output
# goes to a temp folder.
set -u
# as server-audit.sh does: [[:cntrl:]] then matches 0x00-0x1F and 0x7F only and works byte by byte, so
# tty_safe replaces the C1 controls in UTF-8 itself (section 6) and leaves other UTF-8 alone
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT="$SCRIPT_DIR/server-audit.sh"

# Stop before any path is built if mktemp fails: an empty $tmp would write the files to /.
if ! tmp="$(mktemp -d)" || [[ -z $tmp || ! -d $tmp ]]; then
    printf 'not ok: mktemp -d failed, no temporary directory for the console output\n'
    exit 1
fi
trap 'rm -rf "$tmp"' EXIT

fail=0
ok() { printf 'ok: %s\n' "$*"; }
bad() { printf 'not ok: %s\n' "$*"; fail=1; }
show() {   # show FILE: FILE with its control characters made visible (cat -v), so a failure prints no escape
    cat -v "$1" | sed 's/^/    /' >&2
}

# server-audit.sh runs its checks on load, so it cannot be sourced: load only out, tty_safe and result.
funcs="$(sed -n '/^out() {/p; /^tty_safe() {/,/^}/p; /^result() {/,/^}/p' "$AUDIT")"
for f in 'out() {' 'tty_safe() {' 'result() {'; do
    if [[ $funcs != *"$f"* ]]; then
        printf 'not ok: %s not found at the start of a line in server-audit.sh\n' "${f% \{}"
        exit 1
    fi
done
eval "$funcs"

QUIET=0
CURRENT_CAT=kernel
R_ID=(); R_CAT=(); R_STATUS=(); R_TITLE=(); R_MSG=(); R_FIX=()
# the colours of server-audit.sh when the output is a terminal
C_GREEN=$'\033[0;32m'; C_RED=$'\033[0;31m'; C_YELLOW=$'\033[1;33m'
C_BLUE=$'\033[0;34m'; C_GRAY=$'\033[0;90m'; C_BOLD=$'\033[1m'; C_0=$'\033[0m'

# --- 1. Control characters in the title, the message and the fix ---------------------------------------
# ESC sequences (clear screen, set the window title with an OSC ended by BEL), 0x01, 0x1f, DEL, \r, a tab,
# a newline, a UTF-8 'é' and the script's own red colour code, as a file name could hold them.
title=$'Odd \e[2Jtitle\x01'
msg=$'SUID /tmp/a\e]0;x\a b\x1f c\x7f d\re\tf\ng \xc3\xa9 '"${C_RED}red"
fix=$'rm \e[31m/tmp/x\x01 \e[0m'
result kern.suid WARN "$title" "$msg" "$fix" >"$tmp/out"
printf '%s\n' \
    "${C_YELLOW}[WARN]${C_0} Odd ?[2Jtitle? ${C_GRAY}- SUID /tmp/a?]0;x? b? c? d?e f g "$'\xc3\xa9'" ?[0;31mred${C_0}" \
    "       ${C_GRAY}fix: rm ?[31m/tmp/x? ?[0m${C_0}" >"$tmp/want"
if cmp -s "$tmp/want" "$tmp/out"; then
    ok "each control character in the title, the message and the fix prints as '?', a tab or a newline as a space, 'é' and the colour codes stay"
else
    bad "the console lines differ. Want:"; show "$tmp/want"
    printf '  got:\n' >&2; show "$tmp/out"
fi

# --- 2. No control character left but the script's own colour codes ------------------------------------
printed="$(<"$tmp/out")"
printed=${printed//"$C_YELLOW"/}; printed=${printed//"$C_GRAY"/}; printed=${printed//"$C_0"/}
printed=${printed//$'\n'/}
if [[ -n $printed && $printed != *[[:cntrl:]]* ]]; then
    ok "without the colour codes of result(), the console output holds no control character"
else
    bad "the console output holds a control character that is not one of the script's colour codes:"
    show "$tmp/out"
fi

# --- 3. The stored results keep the raw text, for the JSON report ---------------------------------------
if [[ ${#R_ID[@]} -eq 1 && ${R_ID[0]} == kern.suid && ${R_CAT[0]} == kernel && ${R_STATUS[0]} == WARN &&
    ${R_TITLE[0]} == "$title" && ${R_MSG[0]} == "$msg" && ${R_FIX[0]} == "$fix" ]]; then
    ok "R_TITLE, R_MSG and R_FIX keep the raw title, message and fix"
else
    bad "the stored result is not the raw input: $(printf '%s|' "${R_ID[@]}" "${R_TITLE[@]}" "${R_MSG[@]}" "${R_FIX[@]}" | cat -v)"
fi

# --- 4. A plain result prints as before ------------------------------------------------------------------
# Glob and replacement characters ([ ] * ? \ &) are text, never patterns.
plain_msg='UFW is inactive: ports [80, 443]* and ? open \ fix & retry, déjà vu'
result fw.status FAIL "Firewall" "$plain_msg" "sudo ufw enable" >"$tmp/plain"
printf '%s\n' "${C_RED}[FAIL]${C_0} Firewall ${C_GRAY}- ${plain_msg}${C_0}" \
    "       ${C_GRAY}fix: sudo ufw enable${C_0}" >"$tmp/want"
if cmp -s "$tmp/want" "$tmp/plain"; then
    ok "a result without control characters prints byte for byte as before"
else
    bad "a plain result prints differently. Want:"; show "$tmp/want"
    printf '  got:\n' >&2; show "$tmp/plain"
fi
result ssh.port PASS "SSH port" "SSH listens on 2222" "unused fix" >"$tmp/pass"
if [[ "$(<"$tmp/pass")" == "${C_GREEN}[PASS]${C_0} SSH port ${C_GRAY}- SSH listens on 2222${C_0}" ]]; then
    ok "a PASS result prints one line, without its fix"
else
    bad "a PASS result prints differently:"; show "$tmp/pass"
fi

# --- 5. --quiet prints nothing and still stores the raw text ----------------------------------------------
QUIET=1
result kern.world_writable WARN "$title" "$msg" "$fix" >"$tmp/quiet"
if [[ ! -s $tmp/quiet && ${R_ID[-1]} == kern.world_writable && ${R_TITLE[-1]} == "$title" &&
    ${R_MSG[-1]} == "$msg" && ${R_FIX[-1]} == "$fix" ]]; then
    ok "with --quiet, result() prints nothing and stores the raw text"
else
    bad "with --quiet, result() printed or stored the wrong text:"; show "$tmp/quiet"
fi

# --- 6. C1 controls in UTF-8 -------------------------------------------------------------------------------
# Under LC_ALL=C, [[:cntrl:]] misses U+0080 to U+009F, sent as the bytes C2 80 to C2 9F. xterm and VTE terminals
# (GNOME Terminal) read U+009B as CSI and U+009D as OSC, ended by U+009C (ST), so each one must print as '?'.
# The no-break space (C2 A0) and '¿' (C2 BF) just past that range, 'é' and '€' (E2 82 AC: its 0x82 follows no
# C2, so it is no C1 control) stay.
QUIET=0
c1_title=$'C1 \xc2\x9b2Jtitle'
c1_msg=$'SUID /tmp/\xc2\x9d0;x\xc2\x9c \xc2\x80 \xc2\x9f \xc2\xa0 \xc2\xbf \xc3\xa9 \xe2\x82\xac'
c1_fix=$'rm /tmp/\xc2\x9b31mx'
result kern.suid FAIL "$c1_title" "$c1_msg" "$c1_fix" >"$tmp/c1"
printf '%s\n' \
    "${C_RED}[FAIL]${C_0} C1 ?2Jtitle ${C_GRAY}- SUID /tmp/?0;x? ? ? "$'\xc2\xa0 \xc2\xbf \xc3\xa9 \xe2\x82\xac'"${C_0}" \
    "       ${C_GRAY}fix: rm /tmp/?31mx${C_0}" >"$tmp/want"
if cmp -s "$tmp/want" "$tmp/c1"; then
    ok "each C1 control in UTF-8 (CSI U+009B, OSC U+009D, ST U+009C, U+0080, U+009F) prints as '?', the no-break space, '¿', 'é' and '€' stay"
else
    bad "the console lines with C1 controls differ. Want:"; show "$tmp/want"
    printf '  got:\n' >&2; show "$tmp/c1"
fi
printed="$(<"$tmp/c1")"
if [[ -n $printed && $printed != *$'\xc2'[$'\x80'-$'\x9f']* ]]; then
    ok "the console output holds no C1 control in UTF-8"
else
    bad "the console output holds a C1 control in UTF-8 (C2 80 to C2 9F):"; show "$tmp/c1"
fi
if [[ ${R_ID[-1]} == kern.suid && ${R_TITLE[-1]} == "$c1_title" && ${R_MSG[-1]} == "$c1_msg" &&
    ${R_FIX[-1]} == "$c1_fix" ]]; then
    ok "R_TITLE, R_MSG and R_FIX keep the raw C1 controls"
else
    bad "the stored result with C1 controls is not the raw input: $(printf '%s|' "${R_TITLE[-1]}" "${R_MSG[-1]}" "${R_FIX[-1]}" | od -An -c)"
fi

exit "$fail"
