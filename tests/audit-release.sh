#!/usr/bin/env bash
# Tests the audit's server-prep release check (release_status and ver_gt in server-audit.sh) on
# sample GitHub release lists. No root and no network needed; nothing on the host changes.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v jq >/dev/null || { printf 'not ok: jq is needed\n'; exit 1; }

# server-audit.sh runs its checks on load, so it cannot be sourced: load only the two functions.
eval "$(sed -n '/^ver_gt() {/p; /^release_status() {/,/^}/p' "$SCRIPT_DIR/server-audit.sh")"
for f in ver_gt release_status; do
    declare -F "$f" >/dev/null || { printf 'not ok: %s not found in server-audit.sh\n' "$f"; exit 1; }
done
export PROJECT_URL="https://github.com/example/server-prep"   # read by release_status

fail=0
expect() {   # expect LABEL INSTALLED JSON STATUS MESSAGE-SUBSTRING
    local label="$1" installed="$2" json="$3" want_st="$4" want_msg="$5" st msg fix
    IFS=$'\x1f' read -r st msg fix < <(release_status "$installed" <<<"$json")
    if [[ $st != "$want_st" || $msg != *"$want_msg"* ]]; then
        printf 'not ok: %s gives %s "%s", want %s "...%s..."\n' "$label" "$st" "$msg" "$want_st" "$want_msg"
        fail=1
        return
    fi
    if [[ $st == WARN && $fix != *"server-prep.sh --upgrade"* ]]; then
        printf 'not ok: %s: a WARN must give the upgrade command\n' "$label"
        fail=1
        return
    fi
    printf 'ok: %s gives %s\n' "$label" "$st"
}

rel() {   # rel TAG BODY [draft] [prerelease] -> one release object
    jq -n --arg t "$1" --arg b "$2" --argjson d "${3:-false}" --argjson p "${4:-false}" \
        '{tag_name: $t, body: $b, draft: $d, prerelease: $p}'
}
list() { jq -s . ; }

PLAIN="- Fix: a typo in the report."
SEC_LINE="- **Security fix:** the firewall step no longer leaves port 22 open."
SEC_HEADING="## What's Changed
### Security
* server-prep.sh: keep secrets out of the log by @someone"

L_UP=$( { rel v1.2.0 "$PLAIN"; rel v1.1.1 "$PLAIN"; } | list)
L_SEC=$( { rel v1.2.0 "$PLAIN"; rel v1.1.2 "$SEC_LINE"; rel v1.1.1 "$PLAIN"; } | list)
L_HEAD=$( { rel v1.1.2 "$SEC_HEADING"; rel v1.1.1 "$PLAIN"; } | list)
L_OLD_SEC=$( { rel v1.2.0 "$PLAIN"; rel v1.1.1 "$SEC_LINE"; } | list)
L_DRAFT=$( { rel v1.3.0 "$SEC_LINE" true; rel v1.2.1-rc1 "$SEC_LINE" false true; rel v1.2.0 "$PLAIN"; } | list)

expect "same version as the latest release" 1.2.0 "$L_UP" INFO "v1.2.0 is the latest release"
expect "a newer release without a security fix" 1.1.1 "$L_UP" INFO "v1.2.0 is out. This server uses v1.1.1"
expect "a newer release with a **Security fix:** line" 1.1.1 "$L_SEC" WARN "v1.1.2 (latest v1.2.0)"
expect "a Security heading alone (the security label) is not a fix" 1.1.1 "$L_HEAD" INFO "v1.1.2 is out"
expect "a security fix this server already has" 1.1.1 "$L_OLD_SEC" INFO "v1.2.0 is out"
expect "drafts and pre-releases are ignored" 1.2.0 "$L_DRAFT" INFO "v1.2.0 is the latest release"
expect "a development copy newer than the latest release" 1.3.0 "$L_UP" INFO "a development copy"
expect "unknown local version" "" "$L_SEC" INFO "unknown"
expect "an empty list" 1.1.1 "[]" INFO "Could not read"
expect "not JSON (an error page)" 1.1.1 "<html>rate limited</html>" INFO "Could not read"

# Version order: numeric, not text.
if ver_gt 1.10.0 1.9.2 && ! ver_gt 1.9.2 1.10.0 && ! ver_gt 1.2.0 1.2.0; then
    printf 'ok: ver_gt orders 1.10.0 after 1.9.2\n'
else
    printf 'not ok: ver_gt orders versions as text\n'
    fail=1
fi

exit "$fail"
