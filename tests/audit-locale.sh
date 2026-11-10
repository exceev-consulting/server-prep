#!/usr/bin/env bash
# shellcheck disable=SC2034   # IS_ROOT is read by the eval'd checks
# Tests that server-audit.sh reads ufw and free in English on a server set to another language,
# issue #197: both translate the lines the checks look for ("Status: active", "Default:", "Swap:"),
# and ufw's Python gettext reads LANGUAGE before LC_ALL. No root needed and nothing on the host
# changes: ufw and free are shell functions that print French unless they are asked for English.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT="$SCRIPT_DIR/server-audit.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
    printf 'not ok: %s\n' "$1"
    exit 1
}

# --- The real script, started in French ----------------------------------------------------------
# An EXIT trap loaded through BASH_ENV records the locale the audit runs with when --help exits.
cat >"$tmp/record-locale" <<'EOF'
trap 'printf "LC_ALL=%s LANGUAGE=%s\n" "${LC_ALL-<unset>}" "${LANGUAGE-<unset>}" >"$LOCALE_RESULT"' EXIT
EOF
LANG=fr_FR.UTF-8 LANGUAGE=fr_FR:fr LC_ALL=fr_FR.UTF-8 BASH_ENV="$tmp/record-locale" LOCALE_RESULT="$tmp/locale" \
    bash "$AUDIT" --help >/dev/null 2>"$tmp/stderr" || fail "server-audit.sh --help failed: $(cat "$tmp/stderr")"
got=$(cat "$tmp/locale" 2>/dev/null)
[[ "$got" == 'LC_ALL=C LANGUAGE=<unset>' ]] ||
    fail "server-audit.sh started in French runs with '$got', want 'LC_ALL=C LANGUAGE=<unset>'"
printf 'ok: server-audit.sh started in French reads command output with LC_ALL=C and no LANGUAGE\n'

# --- The firewall and swap checks on French output -----------------------------------------------
# server-audit.sh runs its checks on load, so it cannot be sourced: load its locale lines and the two
# checks only.
LOCALE_LINES=$(sed -n '/^export LC_ALL=C$/,/^unset LANGUAGE$/p' "$AUDIT")
FW_CHECK=$(sed -n '/^section firewall /,/^fi$/p' "$AUDIT")
SWAP_CHECK=$(sed -n '/^SWAP_TOTAL=/,/^fi$/p' "$AUDIT")
[[ "$FW_CHECK" == *'result fw.status PASS'* ]] || fail "the firewall check (fw.status) was not found in server-audit.sh"
[[ "$SWAP_CHECK" == *'result res.swap PASS'* ]] || fail "the swap check (res.swap) was not found in server-audit.sh"

english() { [[ ${LC_ALL:-} == C && -z ${LANGUAGE:-} ]]; }   # the stubs print English only when asked like this
section() { :; }
have() { [[ "$1" == ufw ]]; }
result() { printf '%s %s %s\n' "$1" "$2" "$4"; }   # ID STATUS MESSAGE
ufw() {
    [[ "$*" == 'status verbose' ]] || { printf 'unexpected ufw %s\n' "$*" >&2; return 1; }
    if english; then
        printf '%s\n' 'Status: active' 'Logging: on (low)' 'Default: deny (incoming), allow (outgoing), deny (routed)'
    else
        printf '%s\n' 'État : actif' 'Journalisation : on (low)' 'Par défaut : deny (incoming), allow (outgoing), deny (routed)'
    fi
    printf '\n%s\n%s\n%s\n' 'To                         Action      From' \
        '--                         ------      ----' '822/tcp on tailscale0      ALLOW IN    Anywhere'
}
free() {
    local swap='Swap:' size=2097148
    english || swap='Échange:'
    [[ "${1:-}" == -h ]] && size=2.0Gi
    printf '%s\n' '               total        used        free      shared  buff/cache   available'
    printf 'Mem:        8000000     2000000     4000000       10000     2000000     6000000\n'
    printf '%s     %s           0     %s\n' "$swap" "$size" "$size"
}

checks() {   # checks with|without: both checks on a French server, with or without the audit's locale lines
    (
        export LANG=fr_FR.UTF-8 LANGUAGE=fr_FR:fr
        unset LC_ALL
        [[ "$1" == with ]] && eval "$LOCALE_LINES"
        IS_ROOT=1
        eval "$FW_CHECK"
        eval "$SWAP_CHECK"
    ) 2>"$tmp/stderr"
}

# Without the locale lines, the harness must show the bug: UFW looks inactive and swap missing.
out=$(checks without)
[[ "$out" == *'fw.status FAIL'* && "$out" == *'res.swap WARN'* ]] ||
    fail "the French stubs do not show the bug without the locale lines; got:"$'\n'"$out"
printf 'ok: without the locale lines, French output gives fw.status FAIL and res.swap WARN (the bug)\n'

out=$(checks with)
if [[ "$out" != *'fw.status PASS Active, incoming traffic denied by default'* || "$out" != *'res.swap PASS 2.0Gi configured'* ||
      -s "$tmp/stderr" ]]; then
    printf 'not ok: on a French server, the firewall and swap checks gave:\n%s\n' "$out"
    cat "$tmp/stderr"
    exit 1
fi
printf 'ok: on a French server, fw.status and res.swap read the English output and PASS\n'
