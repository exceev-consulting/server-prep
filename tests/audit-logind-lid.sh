#!/usr/bin/env bash
# Tests the audit's lid-switch parser (lid_ignored in server-audit.sh, used by sys.laptop) on sample
# `systemd-analyze cat-config systemd/logind.conf` output. No root needed and nothing on the host
# changes.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# server-audit.sh runs its checks on load, so it cannot be sourced: load only the parser.
eval "$(sed -n '/^lid_ignored() {/,/^}/p' "$SCRIPT_DIR/server-audit.sh")"
if ! declare -F lid_ignored >/dev/null; then
    printf 'not ok: lid_ignored not found in server-audit.sh\n'
    exit 1
fi

expect() {   # expect yes|no LABEL INPUT ("" = no config at all)
    local want="$1" label="$2" input="$3" got=no
    if [[ -z "$input" ]]; then
        printf '' | lid_ignored && got=yes
    else
        printf '%s\n' "$input" | lid_ignored && got=yes
    fi
    if [[ "$got" != "$want" ]]; then
        printf 'not ok: %s gives %s, want %s\n' "$label" "$got" "$want"
        exit 1
    fi
    printf 'ok: %s gives %s\n' "$label" "$got"
}

# The stock logind.conf: every setting commented out, so the defaults apply.
STOCK='# /etc/systemd/logind.conf
[Login]
#HandleLidSwitch=suspend
#HandleLidSwitchExternalPower=suspend
#HandleLidSwitchDocked=ignore'
# What the laptop step writes to /etc/systemd/logind.conf.d/50-server-prep-lid.conf.
PREP_DROPIN='# /etc/systemd/logind.conf.d/50-server-prep-lid.conf
# Managed by server-prep.sh - keep serving with the lid closed
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
IdleAction=ignore'

# Not ignored: the defaults suspend on lid close.
expect no "empty config (defaults)" ""
expect no "stock logind.conf, all commented (defaults)" "$STOCK"

# Ignored: the server-prep drop-in after the stock file, or HandleLidSwitch alone.
expect yes "server-prep drop-in" "$STOCK
$PREP_DROPIN"
expect yes "HandleLidSwitch=ignore alone (ExternalPower falls back to it)" "[Login]
HandleLidSwitch=ignore"
expect yes "HandleLidSwitch = ignore with spaces" "[Login]
HandleLidSwitch = ignore"
expect yes "trailing spaces and CRLF line ends" "[Login]"$'\r'"
HandleLidSwitch=ignore  "$'\r'
expect yes "HandleLidSwitchExternalPower= (empty) after ignore values" "$PREP_DROPIN
# /etc/systemd/logind.conf.d/90-local.conf
[Login]
HandleLidSwitchExternalPower="

# Not ignored: external power still suspends, or a later drop-in wins.
expect no "HandleLidSwitch=ignore + HandleLidSwitchExternalPower=suspend" "[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=suspend"
expect no "later drop-in sets HandleLidSwitch=suspend" "$PREP_DROPIN
# /etc/systemd/logind.conf.d/90-local.conf
[Login]
HandleLidSwitch=suspend"
expect no "HandleLidSwitchDocked=ignore alone" "[Login]
HandleLidSwitchDocked=ignore"

# Not ignored: commented lines never count.
expect no "#HandleLidSwitch=ignore" "[Login]
#HandleLidSwitch=ignore"
expect no ";HandleLidSwitch=ignore" "[Login]
;HandleLidSwitch=ignore"

printf 'ok: all lid_ignored cases\n'
