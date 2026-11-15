#!/usr/bin/env bash
# shellcheck disable=SC2034   # UFW_*, DOCKER_*, IS_ROOT and EXPOSED_* are read by the eval'd functions
# Tests the audit's UFW port matcher (ufw_port_access in server-audit.sh) on sample
# `ufw status verbose` / `ufw status` output. Issue #78: a port opened through a UFW application
# profile (`ufw allow OpenSSH`) must count as open. Issue #162: a rule to one of the server's own
# addresses (`ufw allow to 203.0.113.10 port 80 proto tcp`) counts like a rule to Anywhere for the
# sockets that listen on that address or on all addresses of its family; a rule to an address the
# server does not have opens nothing. No root needed and nothing on the host changes: `ufw`, `ip`,
# `ss` and `docker` are shell functions that print canned output.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# server-audit.sh runs its checks on load, so it cannot be sourced: load only the matcher and its helpers.
for fn in ufw_rule_fields ufw_spec_match ufw_app_lookup ufw_cache_apps addr_hex hex_prefix_eq \
    ufw_cache_addrs ufw_dst_open ufw_port_access classify_addr; do
    eval "$(sed -n "/^${fn}() {/,/^}/p" "$SCRIPT_DIR/server-audit.sh")"
    if ! declare -F "$fn" >/dev/null; then
        printf 'not ok: %s not found in server-audit.sh\n' "$fn"
        exit 1
    fi
done
# The "Exposed TCP ports" block is not a function: load it as one, from `if have ss; then` to the
# first `fi` at the start of a line.
exposure_src=$(sed -n '/^if have ss; then$/,/^fi$/p' "$SCRIPT_DIR/server-audit.sh")
[[ "$exposure_src" == *'result net.exposure'* ]] || { printf 'not ok: exposure block not found in server-audit.sh\n'; exit 1; }
eval "exposure_check() {
$exposure_src
}"

declare -A UFW_APP_PORTS=()
UFW_ACTIVE=1
UFW_STATUS=""
UFW_OWN_ADDRS=" "
HAVE_IP=1
DOCKER_ACTIVE=0; DOCKER_PROTECTED=1; IS_ROOT=0; EXPOSED_WARN=4; EXPOSED_FAIL=6

# server-audit.sh's one-line have() is not loaded: only `ip` and `ss` are looked for, and HAVE_IP=0
# hides ip.
have() { [[ ( "$1" == ip && $HAVE_IP -eq 1 ) || "$1" == ss ]]; }

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

# The real ip never runs. `ip -o addr show` prints canned addresses in the real format, one call
# logged per run to a file, so the test can count the calls. Any other use of ip is logged as
# unexpected. The server: public 203.0.113.10 and 2001:db8::1 (plus fe80::1) on eth0, LAN
# 192.168.1.50 on eth1, the Docker bridge 10.17.0.1, a point-to-point 10.8.0.1 (printed before
# "peer", without a prefix) and the tailnet addresses on tailscale0. Tailscale's own resolver
# addresses, 100.100.100.100 and fd7a:115c:a1e0::53, stand for the node's: scripts/check-files.sh
# allows no other address in 100.64.0.0/10, and that one only without the /32 that ip prints after
# it. Loopback is left out by ufw_cache_addrs.
ip() {
    if [[ "$*" != '-o addr show' ]]; then
        printf 'unexpected ip %s\n' "$*" | tee -a "$tmp/ip-unexpected" >&2
        return 1
    fi
    printf 'call\n' >>"$tmp/ip-calls"
    cat <<'IP'
1: lo    inet 127.0.0.1/8 scope host lo\       valid_lft forever preferred_lft forever
1: lo    inet6 ::1/128 scope host noprefixroute \       valid_lft forever preferred_lft forever
2: eth0    inet 203.0.113.10/24 brd 203.0.113.255 scope global eth0\       valid_lft forever preferred_lft forever
2: eth0    inet6 2001:db8::1/64 scope global \       valid_lft forever preferred_lft forever
2: eth0    inet6 fe80::1/64 scope link \       valid_lft forever preferred_lft forever
3: eth1    inet 192.168.1.50/24 brd 192.168.1.255 scope global eth1\       valid_lft forever preferred_lft forever
4: docker0    inet 10.17.0.1/16 brd 10.17.255.255 scope global docker0\       valid_lft forever preferred_lft forever
5: wg0    inet 10.8.0.1 peer 10.8.0.2/32 scope global wg0\       valid_lft forever preferred_lft forever
6: tailscale0    inet 100.100.100.100 scope global tailscale0\       valid_lft forever preferred_lft forever
6: tailscale0    inet6 fd7a:115c:a1e0::53/128 scope global \       valid_lft forever preferred_lft forever
IP
}

# The real ss never runs: `ss -H -ltnp` prints the sockets in SS_SOCKETS, in the real format.
SS_SOCKETS=()
ss() {
    if [[ "$*" != '-H -ltnp' ]]; then
        printf 'unexpected ss %s\n' "$*" | tee -a "$tmp/ss-unexpected" >&2
        return 1
    fi
    [[ ${#SS_SOCKETS[@]} -eq 0 ]] || printf '%s\n' "${SS_SOCKETS[@]}"
}
sock() {   # sock LOCAL PROCESS: one line of `ss -H -ltnp`
    printf 'LISTEN 0      4096      %-24s 0.0.0.0:*    users:(("%s",pid=100,fd=3))' "$1" "$2"
}

# The real docker never runs: `docker ps --format {{.Ports}}` prints DOCKER_PS.
DOCKER_PS=""
docker() {
    if [[ "$*" != 'ps --format {{.Ports}}' ]]; then
        printf 'unexpected docker %s\n' "$*" | tee -a "$tmp/docker-unexpected" >&2
        return 1
    fi
    printf '%s\n' "$DOCKER_PS"
}

# result is server-audit.sh's report function: the exposure block calls it once, with its detail.
result() { RESULT_STATUS="$2"; RESULT_DETAIL="$4"; }

# expect_exposure LABEL STATUS DETAIL: runs the exposure block on the sockets in SS_SOCKETS and the
# rules in UFW_STATUS, and checks the status and the detail it reports.
EXPOSURE_RUNS=0
expect_exposure() {
    RESULT_STATUS=""; RESULT_DETAIL=""; EXPOSURE_RUNS=$((EXPOSURE_RUNS + 1))
    exposure_check 2>"$tmp/err"
    if [[ "$RESULT_STATUS" != "$2" || "$RESULT_DETAIL" != "$3" || -s "$tmp/err" ]]; then
        printf 'not ok: %s:\n  got  %s %s\n  want %s %s\n' "$1" "$RESULT_STATUS" "$RESULT_DETAIL" "$2" "$3"
        if [[ -s "$tmp/err" ]]; then
            printf 'stderr:\n'
            cat "$tmp/err"
        fi
        exit 1
    fi
    printf 'ok: %s: %s %s\n' "$1" "$RESULT_STATUS" "$RESULT_DETAIL"
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

# expect PORT PROTO WANT LABEL [LISTEN]: LISTEN is the address the socket listens on, as ss prints
# it. Without it, ufw_port_access gets no third argument, which means every address.
expect() {
    local port="$1" proto="$2" want="$3" label="$4" on="" got
    [[ -n "${5:-}" ]] && on=" on $5"
    got=$(ufw_port_access "$port" "$proto" ${5+"$5"} 2>"$tmp/err")
    if [[ "$got" != "$want" || -s "$tmp/err" ]]; then
        printf 'not ok: %s: %s/%s%s gives %s, want %s\n' "$label" "$port" "$proto" "$on" "$got" "$want"
        if [[ -s "$tmp/err" ]]; then
            printf 'stderr:\n'
            cat "$tmp/err"
        fi
        exit 1
    fi
    printf 'ok: %s: %s/%s%s gives %s\n' "$label" "$port" "$proto" "$on" "$got"
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
set_rules 'OpenSSH' 'ALLOW' 'OUTline'
expect 22 tcp restricted "bare OpenSSH from a source profile whose name starts with OUT"

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
UFW_ACTIVE=0
set_rules '3000/tcp' 'ALLOW IN' 'Anywhere'
expect 3000 tcp nofw "UFW inactive"
UFW_ACTIVE=1
UFW_STATUS=""
expect 3000 tcp nofw "UFW status not readable (no root, nftables only)"

# --- addr_hex: one spelling for each address ------------------------------------------------------
hex_is() {   # hex_is ADDR WANT: addr_hex ADDR gives WANT, or fails when WANT is "fail"
    if addr_hex "$1"; then
        [[ "$ADDR_HEX" == "$2" ]] || fail "addr_hex $1 gave $ADDR_HEX, want $2"
    else
        [[ "$2" == fail && -z "$ADDR_HEX" ]] || fail "addr_hex $1 failed (ADDR_HEX '$ADDR_HEX'), want $2"
    fi
    printf 'ok: addr_hex %s gives %s\n' "$1" "$2"
}
hex_is 203.0.113.10 cb00710a
hex_is 0.0.0.0 00000000
hex_is 192.168.255.255 c0a8ffff
hex_is 2001:db8::1 20010db8000000000000000000000001
hex_is 2001:0DB8:0:0:0:0:0:1 20010db8000000000000000000000001
hex_is :: 00000000000000000000000000000000
hex_is fe80:: fe800000000000000000000000000000
hex_is 1:2:3:4:5:6:7:8 00010002000300040005000600070008
hex_is ::ffff:203.0.113.10 00000000000000000000ffffcb00710a
for bad in 256.1.1.1 1.2.3 203.0.113.10/24 Anywhere 22/tcp 60000:61000 1:2:3 1::2::3 ::: \
    1:2:3:4:5:6:7:8:9 1:2:3:4:5:6:7::8 :1:2:3:4:5:6:7 1:2:3:4:5:6:7: 12345::1 203.0.113.10::1 ''; do
    hex_is "$bad" fail
done

# --- ufw_rule_fields: the destination address is split from the port spec -------------------------
fields_are() {   # fields_are TO WANT_DST WANT_TO [WANT_IFACE]
    ufw_rule_fields "$(rule "$1" 'ALLOW IN' 'Anywhere')" || fail "ufw_rule_fields rejected To '$1'"
    [[ "$UFW_R_DST" == "$2" && "$UFW_R_TO" == "$3" && "$UFW_R_IFACE" == "${4:-}" ]] ||
        fail "To '$1' gave dst '$UFW_R_DST', to '$UFW_R_TO', iface '$UFW_R_IFACE'; want '$2', '$3', '${4:-}'"
    printf "ok: To '%s' gives dst '%s' and to '%s'\n" "$1" "$2" "$3"
}
fields_are '203.0.113.10 80/tcp' 203.0.113.10 80/tcp
fields_are '203.0.113.10 80' 203.0.113.10 80
fields_are '192.168.1.50/tcp' 192.168.1.50 Anywhere/tcp
fields_are '192.168.1.50' 192.168.1.50 Anywhere
fields_are '2001:db8::1 2222/tcp' 2001:db8::1 2222/tcp
fields_are '2001:db8::1/tcp' 2001:db8::1 Anywhere/tcp
fields_are '203.0.113.0/24 80,443/tcp' 203.0.113.0/24 80,443/tcp
fields_are '203.0.113.0/24/tcp' 203.0.113.0/24 Anywhere/tcp
fields_are '2001:db8::/64 443/tcp' 2001:db8::/64 443/tcp
fields_are '203.0.113.10 22/tcp (OpenSSH)' 203.0.113.10 22/tcp
fields_are '203.0.113.10 OpenSSH' 203.0.113.10 OpenSSH
fields_are '203.0.113.10 22/tcp on eth0' 203.0.113.10 22/tcp eth0
fields_are '60000:61000/tcp' '' 60000:61000/tcp
fields_are '1000:2000,3000:4000/tcp' '' 1000:2000,3000:4000/tcp
fields_are 'Anywhere/tcp' '' Anywhere/tcp

# --- Rules to an address or a network (issue #162) ------------------------------------------------
# The server's addresses come from the ip stub. A rule to one of them counts like a rule to Anywhere
# for the sockets that receive that address: one bound to it, or one on all addresses of its family
# (0.0.0.0 for IPv4; :: and *, which can be dual-stack, for both). Private, tailnet and link-local
# addresses count too: behind 1:1 NAT or a port forward, the internet reaches the server on a private
# address.
HEADER=$VERBOSE_HEADER
set_rules '3000/tcp' 'ALLOW IN' 'Anywhere'
: >"$tmp/ip-calls"
ufw_cache_addrs
want=' cb00710a 20010db8000000000000000000000001 fe800000000000000000000000000001 c0a80132 0a110001 0a080001 64646464 fd7a115ca1e000000000000000000053 '
[[ "$UFW_OWN_ADDRS" == "$want" ]] || fail "ufw_cache_addrs gave '$UFW_OWN_ADDRS', want '$want'"
ufw_cache_addrs
[[ "$UFW_OWN_ADDRS" == "$want" ]] || fail "a second ufw_cache_addrs gave '$UFW_OWN_ADDRS', want '$want'"
printf 'ok: ufw_cache_addrs reads the server addresses, without loopback or prefix, and resets the list\n'

# The two cases that recorded the old behaviour (a rule to the server's own address was firewalled).
# `ufw allow proto tcp to 192.168.1.50` prints the address and the protocol in To, Anywhere in From.
set_rules '192.168.1.50/tcp' 'ALLOW IN' 'Anywhere'
expect 22 tcp any "whole protocol to one destination address"
expect 22 tcp any "whole protocol to one destination address" 0.0.0.0
expect 53 udp none "whole protocol to one destination address, other protocol"
set_rules '192.168.1.50/tcp' 'ALLOW IN' '192.168.1.50/tcp'
expect 22 tcp restricted "whole protocol to and from one address"
set_rules '2001:db8::1 2222/tcp' 'ALLOW IN' 'Anywhere (v6)'
expect 2222 tcp any "rule with an IPv6 destination address (issue #162)"
# Address family: an IPv6 rule reaches the sockets that receive IPv6, never one on 0.0.0.0.
expect 2222 tcp any "IPv6 destination address, socket on it" '[2001:db8::1]'
expect 2222 tcp any "IPv6 destination address, socket on all IPv6 addresses" '[::]'
expect 2222 tcp any "IPv6 destination address, dual-stack socket" '*'
expect 2222 tcp any "IPv6 destination address, socket on all IPv6 addresses of eth0" '[::]%eth0'
expect 2222 tcp none "IPv6 destination address, socket on all IPv4 addresses" 0.0.0.0
expect 2222 tcp none "IPv6 destination address, socket on an IPv4 address" 203.0.113.10
expect 2222 tcp none "IPv6 destination address, socket on another IPv6 address" '[fe80::1]%eth0'
set_rules '2001:DB8::1 2222/tcp' 'ALLOW IN' 'Anywhere (v6)'
expect 2222 tcp any "IPv6 destination address in upper case" '[2001:db8::1]'
set_rules '2001:0db8:0000:0000:0000:0000:0000:0001 2222/tcp' 'ALLOW IN' 'Anywhere (v6)'
expect 2222 tcp any "IPv6 destination address, not compressed" '[2001:db8::1]'
set_rules '203.0.113.10 80/tcp' 'ALLOW IN' 'Anywhere'
expect 80 tcp any "port to the server's address"
expect 80 tcp any "port to the server's address, socket on it" 203.0.113.10
expect 80 tcp any "port to the server's address, socket on all IPv4 addresses" 0.0.0.0
expect 80 tcp any "port to the server's address, socket on all IPv4 addresses of eth0" '0.0.0.0%eth0'
expect 80 tcp any "port to the server's address, socket on all IPv6 addresses (can be dual-stack)" '[::]'
expect 80 tcp any "port to the server's address, dual-stack socket" '*'
expect 80 tcp any "port to the server's address, IPv4-mapped socket on it" '[::ffff:203.0.113.10]'
expect 80 tcp any "port to the server's address, socket address that cannot be read (all)" 'bogus'
# Address family: an IPv4 rule never reaches a socket bound to an IPv6 address.
expect 80 tcp none "port to the server's address, socket on an IPv6 address" '[2001:db8::1]'
expect 80 tcp none "port to the server's address, socket on another IPv4 address" 198.51.100.7
expect 81 tcp none "port to the server's address, other port"
set_rules '203.0.113.10' 'ALLOW IN' 'Anywhere'
expect 5432 tcp any "everything to the server's address"
expect 5432 tcp none "everything to the server's address, socket on an IPv6 address" '[2001:db8::1]'
set_rules '203.0.113.10 22/tcp (OpenSSH)' 'ALLOW IN' 'Anywhere'
expect 22 tcp any "verbose profile to the server's address"
HEADER=$PLAIN_HEADER
: >"$tmp/ufw-calls"
set_rules '203.0.113.10 OpenSSH' 'ALLOW' 'Anywhere'
expect 22 tcp any "bare profile to the server's address"
[[ "$(tr '\n' '|' <"$tmp/ufw-calls")" == 'OpenSSH|' ]] ||
    fail "bare profile to an address called ufw app info with: $(tr '\n' ' ' <"$tmp/ufw-calls"), want OpenSSH only"
printf 'ok: a bare profile to an address looks up the profile name, never the address\n'
HEADER=$VERBOSE_HEADER
# An address the server does not have opens nothing, and the source and interface rules stay.
set_rules '198.51.100.7 80/tcp' 'ALLOW IN' 'Anywhere'
expect 80 tcp none "port to an address the server does not have"
expect 80 tcp none "port to an address the server does not have, socket on all addresses" '*'
set_rules '2001:db8:1::1 80/tcp' 'ALLOW IN' 'Anywhere (v6)'
expect 80 tcp none "port to an IPv6 address the server does not have"
set_rules '203.0.113.10 22/tcp' 'ALLOW IN' '198.51.100.7'
expect 22 tcp restricted "port to the server's address from one source"
expect 22 tcp none "port to the server's address from one source, socket on an IPv6 address" '[2001:db8::1]'
set_rules '203.0.113.10 22/tcp on eth0' 'ALLOW IN' 'Anywhere'
expect 22 tcp restricted "port to the server's address on an interface"
# Private, tailnet and link-local addresses of the server count like public ones (1:1 NAT, port
# forward), with no class of their own: any, restricted or none, as for every other rule.
set_rules '192.168.1.50 8080/tcp' 'ALLOW IN' 'Anywhere'
expect 8080 tcp any "port to the server's LAN address (1:1 NAT or port forward)"
expect 8080 tcp none "port to the server's LAN address, socket on the public address" 203.0.113.10
set_rules '192.168.1.50 8080/tcp' 'ALLOW IN' '192.168.1.0/24'
expect 8080 tcp restricted "port to the server's LAN address from the LAN"
set_rules '10.17.0.1 9100/tcp' 'ALLOW IN' 'Anywhere'
expect 9100 tcp any "port to the Docker bridge address"
set_rules '10.8.0.1 51820' 'ALLOW IN' 'Anywhere'
expect 51820 udp any "port to a point-to-point address (ip prints it before peer)"
set_rules 'fe80::1 22/tcp' 'ALLOW IN' 'Anywhere (v6)'
expect 22 tcp any "port to a link-local address"
set_rules '100.100.100.100 3000/tcp' 'ALLOW IN' 'Anywhere'
expect 3000 tcp any "port to the tailnet address"
expect 3000 tcp any "port to the tailnet address, socket on all IPv4 addresses" 0.0.0.0
expect 3000 tcp none "port to the tailnet address, socket on the public address" 203.0.113.10
set_rules 'fd7a:115c:a1e0::53 3000/tcp' 'ALLOW IN' 'Anywhere (v6)'
expect 3000 tcp any "port to the tailnet IPv6 address, socket on all IPv6 addresses" '[::]'
expect 3000 tcp none "port to the tailnet IPv6 address, socket on all IPv4 addresses" 0.0.0.0
set_rules '3000/tcp' 'ALLOW IN' '198.51.100.7' '100.100.100.100 3000/tcp' 'ALLOW IN' 'Anywhere'
expect 3000 tcp any "rule from one source before a rule to the tailnet address" 0.0.0.0
set_rules '100.64.0.0/10 3000/tcp' 'ALLOW IN' 'Anywhere'
expect 3000 tcp any "port to the whole tailnet range"
# Networks: ufw keeps the prefix (`ufw allow to 203.0.113.10/24` prints 203.0.113.0/24).
set_rules '203.0.113.0/24 80/tcp' 'ALLOW IN' 'Anywhere'
expect 80 tcp any "port to a network that holds the server's address"
expect 80 tcp any "port to a network that holds the server's address, socket on it" 203.0.113.10
expect 80 tcp none "port to a network that holds the server's address, socket outside it" '[2001:db8::1]'
set_rules '203.0.113.8/29 443/tcp' 'ALLOW IN' 'Anywhere'
expect 443 tcp any "port to a /29 that holds the server's address"
set_rules '203.0.113.16/29 443/tcp' 'ALLOW IN' 'Anywhere'
expect 443 tcp none "port to the /29 next to the server's address"
set_rules '198.51.100.0/24 80/tcp' 'ALLOW IN' 'Anywhere'
expect 80 tcp none "port to a network the server is not in"
set_rules '10.0.0.0/8 9100/tcp' 'ALLOW IN' 'Anywhere'
expect 9100 tcp any "port to a private network that holds the Docker bridge address"
set_rules '172.16.0.0/12 9100/tcp' 'ALLOW IN' 'Anywhere'
expect 9100 tcp none "port to a private network the server is not in"
set_rules '203.0.113.0/24 6379/tcp' 'ALLOW IN' '198.51.100.7'
expect 6379 tcp restricted "port to a network that holds the server's address, from one source"
set_rules '203.0.113.0/33 80/tcp' 'ALLOW IN' 'Anywhere'
expect 80 tcp none "port to a network with a prefix that is too long"
# ufw keeps a dotted netmask only when it is not a prefix: such a rule is not read and matches nothing.
set_rules '203.0.113.0/255.255.0.255 80/tcp' 'ALLOW IN' 'Anywhere'
expect 80 tcp none "port to a network with a netmask that is not a prefix (not read)"
set_rules '2001:db8::/64 443/tcp' 'ALLOW IN' 'Anywhere (v6)'
expect 443 tcp any "port to an IPv6 /64 that holds the server's address"
expect 443 tcp any "port to an IPv6 /64 that holds the server's address, socket on it" '[2001:db8::1]'
expect 443 tcp none "port to an IPv6 /64, socket on all IPv4 addresses" 0.0.0.0
set_rules '2001:db8:0:1::/63 443/tcp' 'ALLOW IN' 'Anywhere (v6)'
expect 443 tcp any "port to an IPv6 /63 that holds the server's address"
set_rules '2001:db8:0:2::/63 443/tcp' 'ALLOW IN' 'Anywhere (v6)'
expect 443 tcp none "port to an IPv6 /63 next to the server's address"
set_rules '2001:db8:1::/48 443/tcp' 'ALLOW IN' 'Anywhere (v6)'
expect 443 tcp none "port to an IPv6 network the server is not in"
set_rules '1000:2000,3000:4000/tcp' 'ALLOW IN' 'Anywhere'
expect 3500 tcp any "list of ranges, not taken for an IPv6 address"
# Several rules for one port: the most open rule that reaches the socket wins, in any order.
set_rules '198.51.100.7 80/tcp' 'ALLOW IN' 'Anywhere' '203.0.113.10 80/tcp' 'ALLOW IN' '198.51.100.0/24' \
    '2001:db8::1 80/tcp' 'ALLOW IN' 'Anywhere (v6)'
expect 80 tcp restricted "several rules, socket on all IPv4 addresses" 0.0.0.0
expect 80 tcp restricted "several rules, socket on the public IPv4 address" 203.0.113.10
expect 80 tcp any "several rules, socket on all IPv6 addresses" '[::]'
expect 80 tcp any "several rules, socket on the public IPv6 address" '[2001:db8::1]'
expect 80 tcp none "several rules, socket on the LAN address" 192.168.1.50
set_rules '203.0.113.10 80/tcp' 'ALLOW IN' 'Anywhere' '80/tcp' 'ALLOW IN' '198.51.100.0/24'
expect 80 tcp any "rule to the server's address before a rule from a network" 0.0.0.0
expect 80 tcp restricted "rule to the server's address before a rule from a network, IPv6 socket" '[2001:db8::1]'
set_rules '80/tcp' 'ALLOW IN' '198.51.100.0/24' '203.0.113.10 80/tcp' 'ALLOW IN' 'Anywhere'
expect 80 tcp any "rule from a network before a rule to the server's address" 0.0.0.0
expect 80 tcp restricted "rule from a network before a rule to the server's address, IPv6 socket" '[2001:db8::1]'
[[ $(wc -l <"$tmp/ip-calls") -eq 2 ]] || fail "ip ran $(wc -l <"$tmp/ip-calls") times, want 2 (one per ufw_cache_addrs)"
printf 'ok: ufw_port_access never runs ip: the addresses are read in the main shell\n'

HAVE_IP=0
ufw_cache_addrs
[[ "$UFW_OWN_ADDRS" == ' ' ]] || fail "without ip, ufw_cache_addrs left '$UFW_OWN_ADDRS', want ' '"
[[ $(wc -l <"$tmp/ip-calls") -eq 2 ]] || fail "ufw_cache_addrs ran ip although have ip fails"
set_rules '203.0.113.10 80/tcp' 'ALLOW IN' 'Anywhere'
expect 80 tcp none "port to the server's address, without ip, socket on all addresses"
expect 80 tcp any "port to the server's address, without ip, socket on it" 203.0.113.10
HAVE_IP=1
printf 'ok: without ip, a rule to an address only reaches a socket bound to it\n'

UFW_ACTIVE=0
ufw_cache_addrs
[[ $(wc -l <"$tmp/ip-calls") -eq 2 ]] || fail "ufw_cache_addrs ran ip while UFW is inactive"
UFW_ACTIVE=1
printf 'ok: ufw_cache_addrs makes no ip call while UFW is inactive\n'

# --- The exposure block: each socket is checked, each port listed once with its most open result --
: >"$tmp/ip-calls"
# sshd on all IPv4 and all IPv6 addresses, a rule to the server's IPv6 address: the IPv4 socket is
# firewalled, the IPv6 one is open, and ss lists the IPv4 socket first.
SS_SOCKETS=("$(sock 0.0.0.0:22 sshd)" "$(sock '[::]:22' sshd)")
set_rules '2001:db8::1 22/tcp' 'ALLOW IN' 'Anywhere (v6)'
expect_exposure "IPv6 rule, IPv4 and IPv6 sockets" PASS \
    '1 exposed - internet-exposed: 22(sshd); firewalled: none; tailnet/LAN only: none; localhost only: none'
set_rules '203.0.113.10 22/tcp' 'ALLOW IN' 'Anywhere'
expect_exposure "IPv4 rule, IPv4 and IPv6 sockets" PASS \
    '1 exposed - internet-exposed: 22(sshd); firewalled: none; tailnet/LAN only: none; localhost only: none'
set_rules '198.51.100.7 22/tcp' 'ALLOW IN' 'Anywhere'
expect_exposure "rule to an address the server does not have, IPv4 and IPv6 sockets" PASS \
    '0 exposed - internet-exposed: none; firewalled: 22(sshd); tailnet/LAN only: none; localhost only: none'
# The issue's own example: an app on all addresses, a port open to the server's public address.
SS_SOCKETS=("$(sock 0.0.0.0:8080 python3)")
set_rules '203.0.113.10 8080/tcp' 'ALLOW IN' 'Anywhere'
expect_exposure "port open to the server's public address" PASS \
    '1 exposed - internet-exposed: 8080(python3); firewalled: none; tailnet/LAN only: none; localhost only: none'
# nginx on its public IPv4 and IPv6 addresses: restricted on one socket, open on the other.
SS_SOCKETS=("$(sock 203.0.113.10:443 nginx)" "$(sock '[2001:db8::1]:443' nginx)")
set_rules '443/tcp' 'ALLOW IN' '198.51.100.0/24' '2001:db8::1 443/tcp' 'ALLOW IN' 'Anywhere (v6)'
expect_exposure "restricted on the IPv4 socket, open on the IPv6 one" PASS \
    '1 exposed - internet-exposed: 443(nginx); firewalled: none; tailnet/LAN only: none; localhost only: none'
SS_SOCKETS=("$(sock 203.0.113.10:443 nginx)" "$(sock '[2001:db8::1]:443' nginx)")
set_rules '443/tcp' 'ALLOW IN' '198.51.100.0/24' '2001:db8:1::1 443/tcp' 'ALLOW IN' 'Anywhere (v6)'
expect_exposure "restricted on the IPv4 socket, firewalled on the IPv6 one" PASS \
    '0 exposed - internet-exposed: none; firewalled: 443(nginx),restricted; tailnet/LAN only: none; localhost only: none'
# Every kind at once, in the order ss lists the ports. 5432 listens on the LAN address and on all
# addresses, with a rule to the LAN address: tailnet/LAN only for the socket bound to it, and exposed
# for the one on all addresses (1:1 NAT, port forward).
SS_SOCKETS=("$(sock 0.0.0.0:22 sshd)" "$(sock 192.168.1.50:5432 postgres)" "$(sock 0.0.0.0:5432 postgres)"
    "$(sock 127.0.0.1:631 cupsd)" "$(sock 0.0.0.0:9000 minio)" "$(sock 0.0.0.0:9100 node_exporter)"
    "$(sock '[::]:22' sshd)" "$(sock '[::]:9000' minio)")
set_rules '22/tcp' 'ALLOW IN' 'Anywhere' '192.168.1.50 5432/tcp' 'ALLOW IN' 'Anywhere' \
    '9100/tcp' 'ALLOW IN' '198.51.100.7'
expect_exposure "public, restricted, LAN, firewalled and localhost ports" PASS \
    '2 exposed - internet-exposed: 22(sshd) 5432(postgres); firewalled: 9000(minio) 9100(node_exporter),restricted; tailnet/LAN only: 5432(postgres); localhost only: 631'
# Docker ports keep their own labels and their place in the order of ss.
DOCKER_ACTIVE=1; IS_ROOT=1; DOCKER_PROTECTED=0
DOCKER_PS='0.0.0.0:8080->80/tcp, [::]:8080->80/tcp'
SS_SOCKETS=("$(sock 0.0.0.0:22 sshd)" "$(sock 0.0.0.0:8080 docker-proxy)" "$(sock 0.0.0.0:3000 node)"
    "$(sock '[::]:8080' docker-proxy)" "$(sock '[::]:22' sshd)")
set_rules '22/tcp' 'ALLOW IN' 'Anywhere'
expect_exposure "Docker port that bypasses the firewall" PASS \
    '2 exposed - internet-exposed: 22(sshd) 8080(docker,bypasses fw); firewalled: 3000(node); tailnet/LAN only: none; localhost only: none'
DOCKER_PROTECTED=1
expect_exposure "Docker port behind ufw-docker" PASS \
    '1 exposed - internet-exposed: 22(sshd); firewalled: 8080(docker) 3000(node); tailnet/LAN only: none; localhost only: none'
set_rules '22/tcp' 'ALLOW IN' 'Anywhere' '8080/tcp' 'ALLOW FWD' 'Anywhere'
expect_exposure "Docker port opened with a route rule" PASS \
    '2 exposed - internet-exposed: 22(sshd) 8080(docker); firewalled: 3000(node); tailnet/LAN only: none; localhost only: none'
DOCKER_ACTIVE=0; IS_ROOT=0; DOCKER_PROTECTED=1; DOCKER_PS=""
[[ $(wc -l <"$tmp/ip-calls") -eq $EXPOSURE_RUNS ]] ||
    fail "ip ran $(wc -l <"$tmp/ip-calls") times for $EXPOSURE_RUNS exposure runs, want once each"
printf 'ok: the exposure block reads the server addresses once per run, in the main shell\n'
UFW_OWN_ADDRS=" "; SS_SOCKETS=()

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

for cmd in ufw ip ss docker; do
    [[ -e "$tmp/$cmd-unexpected" ]] && fail "unexpected $cmd calls: $(tr '\n' ' ' <"$tmp/$cmd-unexpected")"
done

printf 'ok: all ufw_port_access cases\n'
