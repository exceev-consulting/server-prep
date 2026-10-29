#!/usr/bin/env bash
# Tests the audit's "Docker vs firewall" matcher (docker_user_filtered in server-audit.sh) on
# sample `iptables -S DOCKER-USER` output. No root needed and nothing on the host changes.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# server-audit.sh runs its checks on load, so it cannot be sourced: load only the matcher.
eval "$(sed -n '/^docker_user_filtered() {/,/^}/p' "$SCRIPT_DIR/server-audit.sh")"
if ! declare -F docker_user_filtered >/dev/null; then
    printf 'not ok: docker_user_filtered not found in server-audit.sh\n'
    exit 1
fi

expect() {   # expect PASS|no LABEL INPUT ("" = missing chain, no output at all)
    local want="$1" label="$2" input="$3" got=no
    if [[ -z "$input" ]]; then
        printf '' | docker_user_filtered && got=PASS
    else
        printf '%s\n' "$input" | docker_user_filtered && got=PASS
    fi
    if [[ "$got" != "$want" ]]; then
        printf 'not ok: %s gives %s, want %s\n' "$label" "$got" "$want"
        exit 1
    fi
    printf 'ok: %s gives %s\n' "$label" "$got"
}

# What ufw-docker 251123 loads into DOCKER-USER, as `iptables -S` prints it.
UFW_DOCKER='-A DOCKER-USER -j ufw-user-forward
-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-A DOCKER-USER -m conntrack --ctstate INVALID -j DROP
-A DOCKER-USER -i docker0 -o docker0 -j ACCEPT
-A DOCKER-USER -s 10.0.0.0/8 -j RETURN
-A DOCKER-USER -s 172.16.0.0/12 -j RETURN
-A DOCKER-USER -s 192.168.0.0/16 -j RETURN
-A DOCKER-USER -d 10.0.0.0/8 -m conntrack --ctstate NEW -j ufw-docker-logging-deny
-A DOCKER-USER -d 172.16.0.0/12 -m conntrack --ctstate NEW -j ufw-docker-logging-deny
-A DOCKER-USER -d 192.168.0.0/16 -m conntrack --ctstate NEW -j ufw-docker-logging-deny
-A DOCKER-USER -j RETURN'
CROWDSEC_OLD='-A DOCKER-USER -m set --match-set crowdsec-blacklists src -j DROP'
CROWDSEC_NEW='-A DOCKER-USER -j CROWDSEC_CHAIN'

# PASS: the ufw-docker rules are loaded, with or without CrowdSec rules next to them.
expect PASS "ufw-docker rules" "-N DOCKER-USER
$UFW_DOCKER"
expect PASS "CrowdSec (old style) + ufw-docker rules" "-N DOCKER-USER
$CROWDSEC_OLD
$UFW_DOCKER"
expect PASS "CrowdSec (new style) + ufw-docker rules" "-N DOCKER-USER
$CROWDSEC_NEW
$UFW_DOCKER"

# Not PASS: only part of the ufw-docker block. ufw-docker loads both jumps together, and with one
# of them alone the ports that UFW does not allow still reach the containers.
expect no "only a jump to ufw-docker-logging-deny" "-N DOCKER-USER
-A DOCKER-USER -d 172.16.0.0/12 -m conntrack --ctstate NEW -j ufw-docker-logging-deny
-A DOCKER-USER -j RETURN"
expect no "only a jump to ufw-user-forward" "-N DOCKER-USER
-A DOCKER-USER -j ufw-user-forward
-A DOCKER-USER -j RETURN"

# Not PASS: published container ports still bypass UFW.
expect no "CrowdSec only (old style)" "-N DOCKER-USER
$CROWDSEC_OLD
-A DOCKER-USER -j RETURN"
expect no "CrowdSec only (new style)" "-N DOCKER-USER
$CROWDSEC_NEW
-A DOCKER-USER -j RETURN"
expect no "manual DROP ban only" "-N DOCKER-USER
-A DOCKER-USER -s 203.0.113.7/32 -j DROP
-A DOCKER-USER -j RETURN"
expect no "empty chain" "-N DOCKER-USER
-A DOCKER-USER -j RETURN"
expect no "missing chain" ""

# Not PASS: the names must be jump targets, not substrings. Each case has one real jump, so only
# the fake one decides the result.
DENY_JUMP='-A DOCKER-USER -d 10.0.0.0/8 -m conntrack --ctstate NEW -j ufw-docker-logging-deny'
expect no "ipset named ufw-user-forward with -j DROP" "-N DOCKER-USER
-A DOCKER-USER -m set --match-set ufw-user-forward src -j DROP
$DENY_JUMP"
expect no "jump to ufw-user-forward-custom" "-N DOCKER-USER
-A DOCKER-USER -j ufw-user-forward-custom
$DENY_JUMP"
expect no "jump to ufw-docker-logging-deny-custom" "-N DOCKER-USER
-A DOCKER-USER -j ufw-user-forward
-A DOCKER-USER -d 10.0.0.0/8 -j ufw-docker-logging-deny-custom"
expect no "comment that looks like a jump" "-N DOCKER-USER
-A DOCKER-USER -s 203.0.113.7/32 -m comment --comment \"-j ufw-user-forward\" -j DROP
$DENY_JUMP"

printf 'ok: all docker_user_filtered cases\n'
