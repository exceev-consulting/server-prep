#!/usr/bin/env bash
# shellcheck disable=SC2034   # UFW_ACTIVE, UFW_STATUS and UFW_APP_PORTS are read by the eval'd functions
# Tests the audit's UFW port matcher (ufw_port_access in server-audit.sh) on sample
# `ufw status verbose` / `ufw status` output, issue #78: a port opened through a UFW application
# profile (`ufw allow OpenSSH`) must count as open. No root needed and nothing on the host changes:
# `ufw` is a shell function that prints canned profiles.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# server-audit.sh runs its checks on load, so it cannot be sourced: load only the matcher and its helpers.
for fn in ufw_rule_fields ufw_spec_match ufw_app_lookup ufw_cache_apps ufw_port_access; do
    eval "$(sed -n "/^${fn}() {/,/^}/p" "$SCRIPT_DIR/server-audit.sh")"
    if ! declare -F "$fn" >/dev/null; then
        printf 'not ok: %s not found in server-audit.sh\n' "$fn"
        exit 1
    fi
done

declare -A UFW_APP_PORTS=()
UFW_ACTIVE=1
UFW_STATUS=""

app_info() {   # app_info NAME LABEL PORT...: what `ufw app info NAME` prints
    local name="$1" label="$2"
    shift 2
    printf 'Profile: %s\nTitle: %s\nDescription: %s\n\n%s' "$name" "Example $name" "Example profile for the tests." "$label"
    printf '\n  %s' "$@"
    printf '\n'
}

# The real ufw never runs. Each `ufw app info NAME` is logged to a file, because the calls happen
# in subshells. Any other use of ufw is logged as unexpected and fails the test at the end.
ufw() {
    if [[ $# -ne 3 || "$1" != app || "$2" != info ]]; then
        printf 'unexpected ufw %s\n' "$*" | tee -a "$tmp/ufw-unexpected" >&2
        return 1
    fi
    printf '%s\n' "$3" >>"$tmp/ufw-calls"
    case "$3" in
        OpenSSH) app_info OpenSSH 'Port:' 22/tcp ;;
        'Nginx Full') app_info 'Nginx Full' 'Ports:' 80,443/tcp ;;
        Samba) app_info Samba 'Ports:' 137,138/udp 139,445/tcp ;;
        Custom) app_info Custom 'Port:' 8080 ;;
        *) printf "ERROR: Could not find profile '%s'\n" "$3" >&2; return 1 ;;
    esac
}

rule() {   # rule TO ACTION FROM [COMMENT]: one rule line, in the format ufw uses
    printf '%-26s %-12s%-26s%s\n' "$1" "$2" "$3" "${4:+ # $4}"
}

VERBOSE_HEADER='Status: active
Logging: on (low)
Default: deny (incoming), allow (outgoing), deny (routed)
New profiles: skip

To                         Action      From
--                         ------      ----'
PLAIN_HEADER='Status: active

To                         Action      From
--                         ------      ----'
HEADER=$VERBOSE_HEADER

set_rules() {   # set_rules TO ACTION FROM [TO ACTION FROM]...: UFW_STATUS with these rules
    UFW_STATUS=$HEADER
    while [[ $# -ge 3 ]]; do
        UFW_STATUS+=$'\n'"$(rule "$1" "$2" "$3")"
        shift 3
    done
}

expect() {   # expect PORT PROTO WANT LABEL
    local port="$1" proto="$2" want="$3" label="$4" got
    got=$(ufw_port_access "$port" "$proto" 2>"$tmp/err")
    if [[ "$got" != "$want" || -s "$tmp/err" ]]; then
        printf 'not ok: %s: %s/%s gives %s, want %s\n' "$label" "$port" "$proto" "$got" "$want"
        if [[ -s "$tmp/err" ]]; then
            printf 'stderr:\n'
            cat "$tmp/err"
        fi
        exit 1
    fi
    printf 'ok: %s: %s/%s gives %s\n' "$label" "$port" "$proto" "$got"
}

fail() {
    printf 'not ok: %s\n' "$1"
    exit 1
}

# The format itself: a To value of 26 characters or more has one space before the action.
[[ "$(rule '80,443/tcp (Nginx Full (v6))' 'ALLOW IN' 'Anywhere (v6)')" == '80,443/tcp (Nginx Full (v6)) ALLOW IN '* ]] ||
    fail 'rule() does not print a long To value with one space, like ufw'

# --- Profile rules as `ufw status verbose` prints them (what the audit reads) ----------------------
HEADER=$VERBOSE_HEADER
: >"$tmp/ufw-calls"
set_rules '22/tcp (OpenSSH)' 'ALLOW IN' 'Anywhere' '22/tcp (OpenSSH (v6))' 'ALLOW IN' 'Anywhere (v6)'
expect 22 tcp any "OpenSSH profile, v4 and v6"
expect 22 udp none "OpenSSH profile, v4 and v6"
expect 2222 tcp none "OpenSSH profile, v4 and v6"
set_rules '22/tcp (OpenSSH (v6))' 'ALLOW IN' 'Anywhere (v6)'
expect 22 tcp any "OpenSSH profile, v6 only"
set_rules '80,443/tcp (Nginx Full)' 'ALLOW IN' 'Anywhere' '80,443/tcp (Nginx Full (v6))' 'ALLOW IN' 'Anywhere (v6)'
expect 80 tcp any "Nginx Full profile"
expect 443 tcp any "Nginx Full profile"
expect 444 tcp none "Nginx Full profile"
set_rules '80,443/tcp (Nginx Full (v6))' 'ALLOW IN' 'Anywhere (v6)'
expect 443 tcp any "Nginx Full profile, v6 only (28 characters, one space)"
set_rules '8000:8100/tcp (Example Application)' 'ALLOW IN' 'Anywhere'
expect 8050 tcp any "long profile name with a range (one space)"
expect 8101 tcp none "long profile name with a range (one space)"
set_rules '8080 (Custom)' 'ALLOW IN' 'Anywhere'
expect 8080 tcp any "profile without a protocol"
expect 8080 udp any "profile without a protocol"
set_rules '137,138/udp (Samba)' 'ALLOW IN' 'Anywhere' '139,445/tcp (Samba)' 'ALLOW IN' 'Anywhere'
expect 445 tcp any "Samba profile, two protocols"
expect 137 tcp none "Samba profile, two protocols"
expect 137 udp any "Samba profile, two protocols"
set_rules '22/tcp (OpenSSH)' 'ALLOW IN' '192.168.1.0/24'
expect 22 tcp restricted "OpenSSH profile from a LAN"
set_rules '22/tcp (OpenSSH) on eth0' 'ALLOW IN' 'Anywhere'
expect 22 tcp restricted "OpenSSH profile on an interface"
set_rules '22/tcp (OpenSSH (v6)) on eth0' 'ALLOW IN' 'Anywhere (v6)'
expect 22 tcp restricted "OpenSSH profile, v6, on an interface"
set_rules '22/tcp (OpenSSH)' 'LIMIT IN' 'Anywhere'
expect 22 tcp any "OpenSSH profile with limit"
UFW_STATUS=$HEADER$'\n'"$(rule '22/tcp (OpenSSH)' 'ALLOW IN' 'Anywhere' 'ALLOW web, not FWD')"
expect 22 tcp any "rule comment with ALLOW and FWD in it"
set_rules '8080/tcp (FWD Proxy)' 'ALLOW IN' 'Anywhere'
expect 8080 tcp any "profile label with FWD in it"
UFW_STATUS=$HEADER$'\n'"$(rule '23/tcp' 'DENY IN' 'Anywhere' 'ALLOW later')"
expect 23 tcp none "DENY rule with ALLOW in its comment"
[[ -s "$tmp/ufw-calls" ]] && fail "verbose profile rules called ufw app info: $(tr '\n' ' ' <"$tmp/ufw-calls")"
printf 'ok: verbose profile rules make no ufw app info call\n'

# --- Bare profile names, as plain `ufw status` prints them ---------------------------------------
HEADER=$PLAIN_HEADER
set_rules 'OpenSSH' 'ALLOW' 'Anywhere' 'OpenSSH (v6)' 'ALLOW' 'Anywhere (v6)'
expect 22 tcp any "bare OpenSSH, v4 and v6"
expect 23 tcp none "bare OpenSSH, v4 and v6"
set_rules 'Nginx Full' 'ALLOW' 'Anywhere'
expect 443 tcp any "bare Nginx Full"
expect 80 tcp any "bare Nginx Full"
expect 8080 tcp none "bare Nginx Full"
set_rules 'Samba' 'ALLOW' 'Anywhere'
expect 139 tcp any "bare Samba"
expect 137 tcp none "bare Samba (137 is udp only)"
expect 137 udp any "bare Samba"
set_rules 'Custom' 'ALLOW' 'Anywhere'
expect 8080 tcp any "bare profile without a protocol"
set_rules 'Gone' 'ALLOW' 'Anywhere'
expect 22 tcp none "bare name of a deleted profile"
set_rules 'OpenSSH on eth0' 'ALLOW' 'Anywhere'
expect 22 tcp restricted "bare OpenSSH on an interface"
set_rules 'OpenSSH' 'ALLOW' '192.168.1.0/24'
expect 22 tcp restricted "bare OpenSSH from a LAN"

# --- Port rules: what worked before must keep working --------------------------------------------
HEADER=$VERBOSE_HEADER
set_rules '3000/tcp' 'ALLOW IN' 'Anywhere'
expect 3000 tcp any "single port"
expect 3001 tcp none "single port"
set_rules '25,465,587/tcp' 'ALLOW IN' 'Anywhere'
expect 465 tcp any "comma list"
expect 466 tcp none "comma list"
set_rules '60000:61000/tcp' 'ALLOW IN' 'Anywhere'
expect 60500 tcp any "range"
expect 61000 tcp any "range, last port"
expect 59999 tcp none "range"
set_rules '9000' 'ALLOW IN' 'Anywhere'
expect 9000 tcp any "port without a protocol"
set_rules '53/udp' 'ALLOW IN' 'Anywhere'
expect 53 tcp none "udp rule asked as tcp"
set_rules 'Anywhere' 'ALLOW IN' 'Anywhere'
expect 5432 tcp any "everything from Anywhere"
set_rules 'Anywhere' 'ALLOW IN' '192.168.1.50'
expect 22 tcp restricted "everything from one address"
set_rules 'Anywhere on tailscale0' 'ALLOW IN' 'Anywhere'
expect 22 tcp restricted "everything on an interface"
# `ufw allow proto tcp from any to any`: ufw adds the protocol to To and From.
set_rules 'Anywhere/tcp' 'ALLOW IN' 'Anywhere/tcp' 'Anywhere/tcp (v6)' 'ALLOW IN' 'Anywhere/tcp (v6)'
expect 22 tcp any "whole protocol from Anywhere"
expect 5432 tcp any "whole protocol from Anywhere"
expect 53 udp none "whole protocol from Anywhere, other protocol"
set_rules 'Anywhere/udp (v6)' 'ALLOW IN' 'Anywhere/udp (v6)'
expect 53 udp any "whole protocol from Anywhere, v6 only"
expect 53 tcp none "whole protocol from Anywhere, v6 only"
set_rules 'Anywhere/tcp on eth0' 'ALLOW IN' 'Anywhere/tcp'
expect 22 tcp restricted "whole protocol on an interface"
set_rules 'Anywhere/tcp (v6) on eth0' 'ALLOW IN' 'Anywhere/tcp (v6)'
expect 22 tcp restricted "whole protocol, v6, on an interface"
# Destination-address rules are not resolved yet (issue #162): a rule to the server's own public
# address shows as firewalled. This case and the IPv6 one below record today's behaviour.
set_rules '192.168.1.50/tcp' 'ALLOW IN' '192.168.1.50/tcp'
expect 22 tcp none "whole protocol to one destination address"
set_rules '22/tcp' 'ALLOW IN' '203.0.113.0/24'
expect 22 tcp restricted "port from a network"
set_rules '22/tcp' 'ALLOW IN' '203.0.113.0/24' '22/tcp' 'ALLOW IN' 'Anywhere'
expect 22 tcp any "restricted rule before an open one"
set_rules '22/tcp (v6) on eth0' 'ALLOW IN' 'Anywhere (v6)'
expect 22 tcp restricted "v6 port rule on an interface"
set_rules '9000/tcp' 'ALLOW FWD' 'Anywhere'
expect 9000 tcp none "route (FWD) rule"
set_rules '3000/tcp' 'ALLOW OUT' 'Anywhere'
expect 3000 tcp none "outgoing (OUT) rule"
set_rules '23/tcp' 'DENY IN' 'Anywhere'
expect 23 tcp none "deny rule"
set_rules '2001:db8::1 2222/tcp' 'ALLOW IN' 'Anywhere'
expect 2222 tcp none "rule with an IPv6 destination address (issue #162)"
UFW_ACTIVE=0
set_rules '3000/tcp' 'ALLOW IN' 'Anywhere'
expect 3000 tcp nofw "UFW inactive"
UFW_ACTIVE=1
UFW_STATUS=""
expect 3000 tcp nofw "UFW status not readable (no root, nftables only)"

# --- Cache: each bare profile name is looked up once per run, in the main shell -------------------
HEADER=$PLAIN_HEADER
set_rules 'OpenSSH' 'ALLOW' 'Anywhere' 'OpenSSH (v6)' 'ALLOW' 'Anywhere (v6)' \
    'Nginx Full' 'ALLOW' 'Anywhere' 'Nginx Full (v6)' 'ALLOW' 'Anywhere (v6)' \
    'Gone' 'ALLOW' 'Anywhere' '3000/tcp' 'ALLOW' 'Anywhere'
: >"$tmp/ufw-calls"
UFW_APP_PORTS=()
ufw_cache_apps
expect 22 tcp any "cached OpenSSH"
expect 443 tcp any "cached Nginx Full"
expect 3000 tcp any "port rule next to cached names"
expect 8080 tcp none "cached names, other port"
ufw_cache_apps
calls=$(sort "$tmp/ufw-calls" | tr '\n' '|')
[[ "$calls" == 'Gone|Nginx Full|OpenSSH|' ]] ||
    fail "ufw app info calls with the cache: '$calls', want each of Gone, Nginx Full and OpenSSH once"
printf 'ok: ufw_cache_apps looks up each profile name once\n'

: >"$tmp/ufw-calls"
UFW_APP_PORTS=()
HEADER=$VERBOSE_HEADER
set_rules '22/tcp (OpenSSH)' 'ALLOW IN' 'Anywhere' '80,443/tcp (Nginx Full)' 'ALLOW IN' 'Anywhere' \
    '8080 (Custom)' 'ALLOW IN' 'Anywhere' '3000/tcp' 'ALLOW IN' 'Anywhere' '192.168.1.50' 'ALLOW IN' 'Anywhere'
ufw_cache_apps
[[ -s "$tmp/ufw-calls" ]] && fail "ufw_cache_apps called ufw app info on verbose rules: $(tr '\n' ' ' <"$tmp/ufw-calls")"
printf 'ok: ufw_cache_apps makes no ufw call on verbose rules\n'

UFW_ACTIVE=0
ufw_cache_apps
[[ -s "$tmp/ufw-calls" ]] && fail "ufw_cache_apps called ufw while UFW is inactive"
UFW_ACTIVE=1
printf 'ok: ufw_cache_apps makes no ufw call while UFW is inactive\n'

[[ -e "$tmp/ufw-unexpected" ]] && fail "unexpected ufw calls: $(tr '\n' ' ' <"$tmp/ufw-unexpected")"

printf 'ok: all ufw_port_access cases\n'
