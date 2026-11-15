#!/usr/bin/env bash
# shellcheck disable=SC2034   # LOG_FILE, DRY_RUN, ADMIN_IPS... are read by the sourced functions
# Tests how the firewall step tells its own UFW rules from the others and deletes those of earlier
# answers (issue #67), on sample "ufw show added" output: the tag, the comments and shapes of the
# versions before it, ufw's way of writing addresses, the wanted rules of a set of answers, the stale
# ones (the temporary SSH rules stay while a move of the SSH port is pending), then step_firewall and
# the plan with a fake ufw that keeps its rules in memory: failed or silent deletes, and a rule of the
# operator in the place of a wanted one. No root needed, nothing on the host is touched.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! tmp="$(mktemp -d)" || [[ -z $tmp || ! -d $tmp ]]; then
    printf 'not ok: mktemp -d failed, no temporary directory for the UFW rule tests\n'
    exit 1
fi
trap 'rm -rf "$tmp"' EXIT

# Load the real functions without starting a run (see tests/exit-status.sh).
# shellcheck disable=SC1091
. "$SCRIPT_DIR/server-prep.sh" --yes

fail() { printf 'not ok: %s\n' "$*"; exit 1; }
pass() { printf 'ok: %s\n' "$*"; }

# --- ufw_rule_split: one line of "ufw show added" ------------------------------------------------------
ufw_rule_split "ufw allow from 192.168.1.50 to any port 822 proto tcp comment 'server-prep: ssh admin'" ||
    fail 'ufw_rule_split: refused a rule with a comment'
[[ $UFW_R_SPEC == 'allow from 192.168.1.50 to any port 822 proto tcp' && $UFW_R_COMMENT == 'server-prep: ssh admin' ]] ||
    fail "ufw_rule_split: got '$UFW_R_SPEC' and '$UFW_R_COMMENT'"
ufw_rule_split 'ufw route allow 80/tcp' || fail 'ufw_rule_split: refused a rule without a comment'
[[ $UFW_R_SPEC == 'route allow 80/tcp' && -z $UFW_R_COMMENT ]] ||
    fail "ufw_rule_split: a rule without a comment gave '$UFW_R_SPEC' and '$UFW_R_COMMENT'"
for line in "Added user rules (see 'ufw status' for running firewall):" '(None)' ''; do
    ufw_rule_split "$line" && fail "ufw_rule_split: took '$line' for a rule"
done
pass 'ufw_rule_split reads the rule and its comment, and skips the header and "(None)"'

# --- ufw_rule_key: ufw keeps one rule per key ----------------------------------------------------------
check_key() {   # check_key SPEC WANT
    local got
    got="$(ufw_rule_key "$1")"
    [[ $got == "$2" ]] || fail "ufw_rule_key '$1': got '$got', want '$2'"
}
check_key 'limit 822/tcp' '822/tcp'
check_key 'allow 822/tcp' '822/tcp'
check_key 'allow log 80/tcp' '80/tcp'
check_key 'deny log-all 80/tcp' '80/tcp'
check_key 'route allow 80/tcp' 'route 80/tcp'
check_key 'allow from 192.168.1.50 to any port 822 proto tcp' 'from 192.168.1.50 to any port 822 proto tcp'
check_key 'allow in on tailscale0 to any port 822 proto tcp' 'in on tailscale0 to any port 822 proto tcp'
pass 'ufw_rule_key drops the action and the log option, and keeps route apart'

# --- ufw_fw_owned: the tag, or a comment of a version before it on the shape it added -------------------
owned() {   # owned yes|no SPEC COMMENT
    local got=no
    ufw_fw_owned "$2" "$3" && got=yes
    [[ $got == "$1" ]] || fail "ufw_fw_owned '$2' # '$3': got $got, want $1"
}
# tagged: every comment the firewall step writes, whatever the shape
for c in ssh 'ssh admin' 'ssh panel' 'ssh tailscale' server-prep-temp 'server-prep-temp admin' \
    'server-prep-temp panel' 'server-prep-temp tailscale' http https http3 'docker http' 'docker https' \
    'docker http3' extra 'docker extra'; do
    owned yes 'allow 9999/tcp' "server-prep: $c"
done
# tagged, but not the firewall step's: Endlessh's rule, an unknown comment, an app profile, no space
owned no 'allow 22/tcp' 'server-prep: endlessh tarpit'
owned no 'allow 22/tcp' 'server-prep: something else'
owned no "allow from any to any app 'Nginx Full'" 'server-prep: http'
owned no 'allow 80/tcp' 'server-prep:http'
# without the tag: each comment of a version before it, on the shape it added
owned yes 'limit 822/tcp' ssh
owned yes 'limit 22/tcp' server-prep-temp
owned yes 'allow from 192.168.1.50 to any port 822 proto tcp' 'ssh admin'
owned yes 'allow from 198.51.100.0/24 to any port 22 proto tcp' 'server-prep-temp admin'
owned yes 'allow from 2001:db8::7 to any port 822 proto tcp' 'ssh admin'
owned yes 'allow from 203.0.113.10 to any port 822 proto tcp' 'ssh panel'
owned yes 'allow from 203.0.113.10 to any port 822 proto tcp' 'ssh coolify'
owned yes 'allow from 203.0.113.10 to any port 22 proto tcp' 'server-prep-temp coolify'
owned yes 'allow in on tailscale0 to any port 822 proto tcp' 'ssh tailscale'
owned yes 'allow in on tailscale0 to any port 22 proto tcp' 'server-prep-temp tailscale'
owned yes 'allow 80/tcp' http
owned yes 'allow 443/tcp' https
owned yes 'allow 443/udp' http3
owned yes 'route allow 80/tcp' 'docker http'
owned yes 'route allow 443/tcp' 'docker https'
owned yes 'route allow 443/udp' 'docker http3'
owned yes 'allow 8080/tcp' extra
owned yes 'allow 6000:6007/udp' extra
owned yes 'route allow 8080/tcp' 'docker extra'
# without the tag, a look-alike: a comment of the step on another shape, or another comment
owned no 'allow 8443/tcp' http
owned no 'allow 80/udp' http
owned no 'allow log 80/tcp' http
owned no 'allow out 80/tcp' http
owned no 'deny 80/tcp' http
owned no 'allow 80/tcp' 'docker http'
owned no 'route allow 80/tcp' http
owned no 'allow 822/tcp' ssh
owned no 'limit 822/udp' ssh
owned no 'allow from 192.168.1.50 to any port 822 proto tcp' ssh
owned no 'allow from 192.168.1.50 to any port 822' 'ssh admin'
owned no 'allow from 192.168.1.50 to any port 822:830 proto tcp' 'ssh admin'
owned no 'allow from 192.168.1.50 port 5000 to any port 822 proto tcp' 'ssh admin'
owned no 'allow in on eth0 to any port 822 proto tcp' 'ssh tailscale'
owned no 'allow 822/tcp' 'ssh admin'
owned no 'allow 8080' extra
owned no 'allow 8080/tcp' 'my app'
owned no 'allow 22/tcp' 'endlessh tarpit'
owned no 'allow 80/tcp' ''
owned no 'allow 80/tcp' 'HTTP'
pass 'ufw_fw_owned takes the tag with a comment of the firewall step, or such a comment on its own shape only'

# --- ufw_addr: addresses as ufw writes them --------------------------------------------------------------
check_addr() {   # check_addr ADDR WANT (empty: refused)
    local got status=0
    got="$(ufw_addr "$1")" || status=1
    if [[ -z $2 ]]; then
        [[ $status -eq 1 ]] || fail "ufw_addr '$1': got '$got', want a refusal"
    else
        [[ $status -eq 0 && $got == "$2" ]] || fail "ufw_addr '$1': got '$got' (status $status), want '$2'"
    fi
}
check_addr 192.168.1.50 192.168.1.50
check_addr 192.168.1.50/32 192.168.1.50
check_addr 192.168.1.50/255.255.255.255 192.168.1.50
check_addr 10.1.7.9/22 10.1.4.0/22
check_addr 198.51.100.0/24 198.51.100.0/24
check_addr 10.0.0.1/255.255.0.0 10.0.0.0/16
check_addr 10.0.0.1/255.0.255.0 ''
check_addr 0.0.0.0/0 ''
check_addr 192.168.001.050 ''
check_addr 192.0.2.256 ''
check_addr 192.0.2.1/33 ''
check_addr 192.0.2.1/024 ''
check_addr web-01.example.com ''
check_addr '' ''
if command -v python3 >/dev/null 2>&1; then
    check_addr 2001:DB8:0:0::7 2001:db8::7
    check_addr 2001:db8:0:0:0:0:0:7/128 2001:db8::7
    check_addr 2001:db8::1/64 2001:db8::1/64
    check_addr 2001:db8::/32 2001:db8::/32
    check_addr ::/0 ''
    check_addr 2001:db8::/129 ''
    check_addr 2001:db8:::1 ''
    pass 'ufw_addr writes IPv4 and IPv6 addresses and networks as ufw does, and refuses the rest'
else
    pass 'ufw_addr writes IPv4 addresses and networks as ufw does, and refuses the rest (no python3: IPv6 not checked)'
fi

# --- ufw_wanted_rules: the rules a set of answers asks for ------------------------------------------------
wanted() { printf '%s\n' "${UFW_WANT[@]}" | tr '\t' '#'; }
SSH_PORT=822; CURRENT_SSH_PORTS='822 '
ADMIN_IPS='192.168.1.50, 198.51.100.7/32'; PANEL_ACCESS=tailscale,public; PANEL_IP=192.168.1.50
EXPOSE_WEB=yes; EXTRA_PORTS='8080 51820/udp'
ufw_wanted_rules
want='allow from 192.168.1.50 to any port 822 proto tcp#server-prep: ssh admin
allow from 198.51.100.7 to any port 822 proto tcp#server-prep: ssh admin
allow in on tailscale0 to any port 822 proto tcp#server-prep: ssh tailscale
allow 80/tcp#server-prep: http
allow 443/tcp#server-prep: https
allow 443/udp#server-prep: http3
route allow 80/tcp#server-prep: docker http
route allow 443/tcp#server-prep: docker https
route allow 443/udp#server-prep: docker http3
allow 8080/tcp#server-prep: extra
route allow 8080/tcp#server-prep: docker extra
allow 51820/udp#server-prep: extra
route allow 51820/udp#server-prep: docker extra'
[[ $(wanted) == "$want" && $UFW_WANT_EXACT -eq 1 ]] ||
    fail "ufw_wanted_rules: got (exact $UFW_WANT_EXACT):"$'\n'"$(wanted)"$'\n'"want:"$'\n'"$want"
pass 'ufw_wanted_rules: tagged rules as ufw writes them, the panel IP once when it is an admin IP too'
# a move to 2222 keeps 22 open, rate-limited from anywhere without sources; the tunnel needs no rule
SSH_PORT=2222; CURRENT_SSH_PORTS='22 '; ADMIN_IPS=''; PANEL_ACCESS=''; PANEL_IP=''; EXPOSE_WEB=no; EXTRA_PORTS=''
ufw_wanted_rules
[[ $(wanted) == $'limit 2222/tcp#server-prep: ssh\nlimit 22/tcp#server-prep: server-prep-temp' ]] ||
    fail "ufw_wanted_rules: a move without sources gave:"$'\n'"$(wanted)"
PANEL_ACCESS=cloudflared
ufw_wanted_rules
[[ ${#UFW_WANT[@]} -eq 0 ]] || fail "ufw_wanted_rules: the tunnel alone gave:"$'\n'"$(wanted)"
ADMIN_IPS='192.168.1.50 office'
ufw_wanted_rules
[[ $UFW_WANT_EXACT -eq 0 && $UFW_WANT_BAD == 'office is not an IP address or network' ]] ||
    fail "ufw_wanted_rules: an ADMIN_IPS entry that is not an address gave exact $UFW_WANT_EXACT, '$UFW_WANT_BAD'"
# every address: ufw writes it "allow 822/tcp", for one IP version only, so it cannot be compared
ADMIN_IPS='0.0.0.0/0, ::/0'; PANEL_ACCESS=public; PANEL_IP=10.0.0.0/0.0.0.0
ufw_wanted_rules
want='0.0.0.0/0 is every address (leave ADMIN_IPS empty to open SSH to everyone, rate-limited); ::/0 is every address (leave ADMIN_IPS empty to open SSH to everyone, rate-limited); 10.0.0.0/0.0.0.0 is every address (leave ADMIN_IPS empty to open SSH to everyone, rate-limited)'
[[ $UFW_WANT_EXACT -eq 0 && $UFW_WANT_BAD == "$want" ]] ||
    fail "ufw_wanted_rules: /0 entries gave exact $UFW_WANT_EXACT, '$UFW_WANT_BAD'"
# an entry with a glob character goes to ufw as it is (the old loops let the shell expand it)
mkdir -p "$tmp/glob/web-01/tcp"
cd "$tmp/glob" || fail "cannot enter $tmp/glob"
ADMIN_IPS=''; PANEL_ACCESS=''; PANEL_IP=''; EXTRA_PORTS='*'
ufw_wanted_rules
cd "$SCRIPT_DIR" || fail "cannot enter $SCRIPT_DIR"
[[ $(wanted) == *$'\nallow */tcp#server-prep: extra\nroute allow */tcp#server-prep: docker extra' ]] ||
    fail "ufw_wanted_rules: EXTRA_PORTS='*' gave:"$'\n'"$(wanted)"
EXTRA_PORTS=''
pass 'ufw_wanted_rules: the temporary rules of the old port, the limit rule without sources, nothing for the tunnel, no compare for a name or /0, no globbing'

# --- ufw_stale_rules: the rules of earlier answers ---------------------------------------------------------
# A server prepared by a version before the tag, then by this one, with rules of the operator
ADDED="Added user rules (see 'ufw status' for running firewall):
ufw limit 822/tcp comment 'ssh'
ufw allow from 203.0.113.4 to any port 822 proto tcp comment 'ssh admin'
ufw allow from 192.168.1.50 to any port 822 proto tcp comment 'server-prep: ssh admin'
ufw allow from 192.168.1.50 to any port 22 proto tcp comment 'server-prep: server-prep-temp admin'
ufw allow in on tailscale0 to any port 22 proto tcp comment 'server-prep-temp tailscale'
ufw allow 80/tcp comment 'http'
ufw route allow 80/tcp comment 'server-prep: docker http'
ufw allow 8443/tcp comment 'http'
ufw allow from 192.0.2.10 to any port 9100 proto tcp comment 'node exporter'
ufw allow 9000/tcp
ufw allow 22/tcp comment 'server-prep: endlessh tarpit'
ufw allow 8080/tcp comment 'server-prep: extra'"
SSH_PORT=822; CURRENT_SSH_PORTS='822 '; ADMIN_IPS=192.168.1.50; PANEL_ACCESS=''; PANEL_IP=''
EXPOSE_WEB=no; EXTRA_PORTS=8080/tcp
ufw_wanted_rules
got="$(ufw_stale_rules 0 <<<"$ADDED" | tr '\t' '#')"
want='limit 822/tcp#ssh
allow from 203.0.113.4 to any port 822 proto tcp#ssh admin
allow from 192.168.1.50 to any port 22 proto tcp#server-prep: server-prep-temp admin
allow in on tailscale0 to any port 22 proto tcp#server-prep-temp tailscale
allow 80/tcp#http
route allow 80/tcp#server-prep: docker http'
[[ $got == "$want" ]] || fail "ufw_stale_rules: got:"$'\n'"$got"$'\n'"want:"$'\n'"$want"
pass 'ufw_stale_rules: the old limit and admin rules, 80 and its route rule, the leftover temporary rules; never the operator, the look-alike or Endlessh'
got="$(ufw_stale_rules 1 <<<"$ADDED" | tr '\t' '#')"
want='limit 822/tcp#ssh
allow from 203.0.113.4 to any port 822 proto tcp#ssh admin
allow 80/tcp#http
route allow 80/tcp#server-prep: docker http'
[[ $got == "$want" ]] || fail "ufw_stale_rules: with a move pending, got:"$'\n'"$got"$'\n'"want:"$'\n'"$want"
pass 'ufw_stale_rules: while a move is pending, the temporary SSH rules stay, tagged or not'
# the same rule with another action (limit -> allow): the add replaces it, so it is not deleted
ADMIN_IPS=''; EXTRA_PORTS=''
ufw_wanted_rules
got="$(ufw_stale_rules 0 <<<"ufw allow 822/tcp comment 'server-prep: ssh'" | tr '\t' '#')"
[[ -z $got ]] || fail "ufw_stale_rules: a rule the add replaces (same key) was listed: $got"
got="$(ufw_stale_rules 0 <<<'(None)')"
[[ -z $got ]] || fail "ufw_stale_rules: no rule gave '$got'"
pass 'ufw_stale_rules: a rule with the key of a wanted one is replaced by the add, not deleted'

# --- ssh_move_pending: when the SSH step still needs the temporary rules -------------------------------------
ssh_listen_ports() { printf '%s' "$LISTEN"; }
systemctl() { [[ $* == *server-prep-ssh-rollback-* ]] && printf '%s' "$TIMERS"; return 0; }
pending() {   # pending yes|no LABEL
    local got=no
    ssh_move_pending && got=yes
    [[ $got == "$1" ]] || fail "ssh_move_pending $2: got $got, want $1"
}
SSH_PORT=822; CURRENT_SSH_PORTS='822 '; LISTEN='822 '; TIMERS=''
pending no 'with SSH on 822 only'
CURRENT_SSH_PORTS='22 '; pending yes 'when sshd is still set to 22 (a move this run starts)'
CURRENT_SSH_PORTS='22 822 '; pending yes 'in phase A (both ports)'
CURRENT_SSH_PORTS='822 '; LISTEN='822 22 '; pending yes 'when sshd still listens on 22 (an unfinished move)'
LISTEN='822 '; TIMERS='server-prep-ssh-rollback-20260101_000000.timer loaded active waiting'
pending yes 'while the SSH rollback timer is armed'
unset -f ssh_listen_ports systemctl
pass 'ssh_move_pending: an old port in the config or the listeners, or an armed rollback timer'

# --- step_firewall with a fake ufw that keeps its rules in memory ------------------------------------------
# FAKE_RULES holds the rules as "ufw show added" writes them (without "ufw "). An add replaces the rule
# with the same key, as ufw does; a delete needs the same words and comment; "BAD" in a rule fails it.
LOG_FILE="$tmp/run.log"
HAS_DOCKER=0
pkg_install() { :; }
backup_file() { :; }
crowdsec_in_docker_user() { return 0; }
ufw_state() { printf '%s\n' "${FAKE_RULES[@]}" | sha256sum; }
PENDING=1
ssh_move_pending() { [[ $PENDING -eq 1 ]]; }
fake_words() {   # fake_words WORDS...: FAKE_SPEC and FAKE_COMMENT from ufw's arguments
    FAKE_SPEC=""; FAKE_COMMENT=""
    while [[ $# -gt 0 ]]; do
        if [[ $1 == comment ]]; then FAKE_COMMENT="$2"; break; fi
        FAKE_SPEC+="${FAKE_SPEC:+ }$1"; shift
    done
}
fake_line() { printf '%s%s' "$FAKE_SPEC" "${FAKE_COMMENT:+ comment '$FAKE_COMMENT'}"; }
ufw() {
    local i key
    [[ $1 == --force ]] && shift
    CALLS+=("$*")
    case $1 in
        status)
            echo "Status: active"
            [[ ${2:-} == verbose ]] && echo "Default: deny (incoming), allow (outgoing), disabled (routed)"
            return 0 ;;
        show)
            echo "Added user rules (see 'ufw status' for running firewall):"
            [[ ${#FAKE_RULES[@]} -gt 0 ]] && printf 'ufw %s\n' "${FAKE_RULES[@]}" || echo '(None)'
            return 0 ;;
        reload|enable|default) return 0 ;;
        delete|route)
            if [[ $1 == route && $2 == delete ]]; then fake_words route "${@:3}"
            elif [[ $1 == delete ]]; then fake_words "${@:2}"
            else fake_add "$@"; return; fi
            for i in "${!FAKE_RULES[@]}"; do
                [[ ${FAKE_RULES[$i]} == "$(fake_line)" ]] || continue
                unset 'FAKE_RULES[i]'; FAKE_RULES=("${FAKE_RULES[@]}"); return 0
            done
            echo 'Could not delete non-existent rule'; return 0 ;;
        *) fake_add "$@" ;;
    esac
}
fake_add() {
    local i
    fake_words "$@"
    [[ $FAKE_SPEC == *BAD* ]] && { echo 'ERROR: Bad port'; return 1; }
    key="$(ufw_rule_key "$FAKE_SPEC")"
    for i in "${!FAKE_RULES[@]}"; do
        ufw_rule_split "ufw ${FAKE_RULES[$i]}"
        [[ $(ufw_rule_key "$UFW_R_SPEC") == "$key" ]] || continue
        FAKE_RULES[i]="$(fake_line)"; return 0
    done
    FAKE_RULES+=("$(fake_line)")
}
rules() { printf '%s\n' "${FAKE_RULES[@]}"; }
fw() {   # fw LABEL WANT_STATUS: run step_firewall on FAKE_RULES
    local status=0
    STEP_CHANGED=0; STEP_NOTES=""; MANUAL_TODO=(); CALLS=(); UFW_RULES_RESTORE=0
    step_firewall > "$tmp/out" 2>&1 || status=$?
    [[ $status -eq $2 ]] || fail "step_firewall $1: status $status, want $2; notes: $STEP_NOTES"$'\n'"$(cat "$tmp/out")"
}
# The server of ufw_stale_rules, plus an operator rule with the key of a wanted one (8080/tcp)
mapfile -t FAKE_RULES < <(sed -n 's/^ufw //p' <<<"$ADDED" | grep -v '8080/tcp')
FAKE_RULES+=("allow 8080/tcp comment 'my app'")
DRY_RUN=0; PENDING=0
SSH_PORT=822; CURRENT_SSH_PORTS='822 '; ADMIN_IPS='192.168.1.50 198.51.100.7'; PANEL_ACCESS=tailscale; PANEL_IP=''
EXPOSE_WEB=no; EXTRA_PORTS=8080/tcp

DRY_RUN=1
before="$(rules)"
fw 'dry run' 0
[[ $(rules) == "$before" ]] || fail "step_firewall: the dry run changed the rules:"$'\n'"$(rules)"
for want in '[dry-run] ufw --force delete limit 822/tcp comment ssh' \
    '[dry-run] ufw --force route delete allow 80/tcp comment server-prep: docker http' \
    '[dry-run] ufw --force delete allow from 203.0.113.4 to any port 822 proto tcp comment ssh admin'; do
    grep -qxF -- "  $want" "$tmp/out" || fail "step_firewall: the dry run does not print '$want':"$'\n'"$(cat "$tmp/out")"
done
[[ $STEP_NOTES == *'would delete 6 UFW rule(s) of earlier answers: limit 822/tcp (ssh);'* ]] ||
    fail "step_firewall: the dry run notes do not list what it would delete: $STEP_NOTES"
pass 'step_firewall: a dry run prints the deletes and lists them in its notes, and changes no rule'

DRY_RUN=0
fw 'real run' 0
want="allow from 192.0.2.10 to any port 9100 proto tcp comment 'node exporter'
allow 8443/tcp comment 'http'
allow 9000/tcp
allow 22/tcp comment 'server-prep: endlessh tarpit'
allow 8080/tcp comment 'my app'
allow from 192.168.1.50 to any port 822 proto tcp comment 'server-prep: ssh admin'
allow from 198.51.100.7 to any port 822 proto tcp comment 'server-prep: ssh admin'
allow in on tailscale0 to any port 822 proto tcp comment 'server-prep: ssh tailscale'
route allow 8080/tcp comment 'server-prep: docker extra'"
[[ $(sort <<<"$(rules)") == "$(sort <<<"$want")" ]] ||
    fail "step_firewall: after the run, the rules are:"$'\n'"$(rules)"$'\n'"want:"$'\n'"$want"
[[ $STEP_CHANGED -eq 1 ]] || fail 'step_firewall: a run that deleted rules is not CHANGED'
# every add comes before the first delete
first_delete=-1; last_add=-1
for i in "${!CALLS[@]}"; do
    case ${CALLS[$i]} in
        delete*|'route delete'*) [[ $first_delete -lt 0 ]] && first_delete=$i ;;
        allow*|limit*|'route allow'*) last_add=$i ;;
    esac
done
[[ $first_delete -gt $last_add ]] || fail "step_firewall: a delete came before an add: $(printf '%s; ' "${CALLS[@]}")"
for c in "${CALLS[@]}"; do
    [[ $c != 'allow 8080/tcp comment '* ]] || fail "step_firewall: replaced the operator's own 8080/tcp rule: $c"
done
[[ $STEP_NOTES == *"left as it is: allow 8080/tcp # my app"* ]] ||
    fail "step_firewall: the notes do not say the operator's 8080/tcp rule was left: $STEP_NOTES"
[[ $UFW_RULES_RESTORE -eq 1 ]] || fail 'step_firewall: UFW was on, but rollback.sh would not restore its rule files'
pass "step_firewall: adds first, then deletes only server-prep's rules of earlier answers; the operator's rules stay"

fw 're-run' 0
[[ $STEP_CHANGED -eq 0 ]] || fail "step_firewall: a re-run with the same answers is CHANGED: $STEP_NOTES"
[[ " ${CALLS[*]} " != *' delete '* ]] || fail "step_firewall: a re-run deleted rules: $(printf '%s; ' "${CALLS[@]}")"
pass 'step_firewall: a re-run with the same answers deletes nothing and is OK (already)'

# A move of the SSH port pending: the temporary rules of a later answer stay too
FAKE_RULES+=("allow from 203.0.113.9 to any port 22 proto tcp comment 'server-prep: server-prep-temp admin'")
PENDING=1
fw 'with a move pending' 0
rules | grep -qF '203.0.113.9 to any port 22' || fail 'step_firewall: deleted a temporary SSH rule while a move is pending'
PENDING=0
fw 'once the move is done' 0
! rules | grep -qF '203.0.113.9' || fail 'step_firewall: kept a temporary SSH rule once the move is done'
pass 'step_firewall: the temporary SSH rules stay while the move is pending, and go once it is done'

# An add that fails: nothing is deleted, the step fails and says why
FAKE_RULES+=("allow 9443/tcp comment 'server-prep: extra'")
EXTRA_PORTS='8080/tcp BAD/tcp'
fw 'with an add that fails' 1
rules | grep -qF '9443/tcp' || fail 'step_firewall: deleted rules although an add failed'
[[ $STEP_NOTES == *'rules of earlier answers kept: no new rule for BAD/tcp, route BAD/tcp'* && ${#MANUAL_TODO[@]} -gt 0 ]] ||
    fail "step_firewall: a failed add gave notes '$STEP_NOTES' and no todo"
# An ADMIN_IPS entry that is not an address: the comparison cannot hold, nothing is deleted
EXTRA_PORTS=8080/tcp; ADMIN_IPS='192.168.1.50 office'
fw 'with a name in ADMIN_IPS' 1
rules | grep -qF '9443/tcp' || fail 'step_firewall: deleted rules although an ADMIN_IPS entry is not an address'
[[ $STEP_NOTES == *'not an IP address or network'* ]] || fail "step_firewall: notes '$STEP_NOTES'"
pass 'step_firewall: when an add fails or an address cannot be compared, it deletes nothing and fails'

# A delete that fails: the step fails and the todo names the rule
ADMIN_IPS=192.168.1.50
real_run="$(declare -f run)"
run() { [[ $* == *' delete '* ]] && return 1; "$@" >> "$LOG_FILE" 2>&1; }
fw 'with a delete that fails' 1
[[ ${MANUAL_TODO[*]} == *'allow 9443/tcp'* ]] || fail "step_firewall: the todo of a failed delete is '${MANUAL_TODO[*]}'"
# ufw exits 0 on a delete that matches no rule ("Could not delete non-existent rule"): the rule is still
# there when the step reads the rules again
run() { [[ $* == *' delete '* ]] && return 0; "$@" >> "$LOG_FILE" 2>&1; }
fw 'with a delete that removes nothing' 1
[[ ${MANUAL_TODO[*]} == *'allow 9443/tcp'* && $STEP_NOTES != *'deleted '* ]] ||
    fail "step_firewall: a delete that removed nothing gave notes '$STEP_NOTES' and todo '${MANUAL_TODO[*]}'"
eval "$real_run"
pass 'step_firewall: a failed delete, or one that removes nothing, fails the step, and the todo names the rule'

# UFW off before the run: rollback.sh keeps the run's rules (old files restored on a UFW that stays
# on could block SSH)
ufw_status() { echo 'Status: inactive'; }
fw 'with UFW off' 0
[[ $UFW_RULES_RESTORE -eq 0 ]] || fail 'step_firewall: UFW was off, but rollback.sh would restore its rule files'
unset -f ufw_status
pass 'step_firewall: with UFW off before the run, rollback.sh does not restore the rule files'

# A rule that is not the firewall step's holds the place of a wanted one: it stays. With the same action
# the answer holds (a note that says whose rule it is); with another one (the operator's deny where the
# answers open 80), a warning and a to-do with the command that applies the answers.
FAKE_RULES=("allow from 192.168.1.50 to any port 822 proto tcp comment 'server-prep: ssh admin'" 'deny 80/tcp'
    "allow 22/tcp comment 'server-prep: endlessh tarpit'")
ADMIN_IPS=192.168.1.50; PANEL_ACCESS=''; PANEL_IP=''; EXPOSE_WEB=yes; EXTRA_PORTS=22/tcp; PENDING=0
fw 'with the operator deny rule on 80/tcp' 0
rules | grep -qx 'deny 80/tcp' || fail "step_firewall: changed the operator's deny 80/tcp:"$'\n'"$(rules)"
rules | grep -qx "allow 22/tcp comment 'server-prep: endlessh tarpit'" || fail "step_firewall: changed the Endlessh rule:"$'\n'"$(rules)"
for c in "${CALLS[@]}"; do
    [[ $c != 'allow 80/tcp '* && $c != 'allow 22/tcp '* ]] || fail "step_firewall: replaced a rule that is not its own: $c"
done
grep -qF "the answers ask for 'allow 80/tcp', but a UFW rule without the server-prep tag is in its place and stays: deny 80/tcp" "$tmp/out" ||
    fail "step_firewall: no warning for the deny rule on 80/tcp:"$'\n'"$(cat "$tmp/out")"
[[ ${MANUAL_TODO[*]} == *"sudo ufw allow 80/tcp comment 'server-prep: http'"* ]] ||
    fail "step_firewall: the todo does not give the command that applies the answers: ${MANUAL_TODO[*]}"
[[ $STEP_NOTES == *'not applied: allow 80/tcp'* && $STEP_NOTES != *'80/443 open'* ]] ||
    fail "step_firewall: the notes of a 80/tcp held by a deny rule are '$STEP_NOTES'"
[[ $STEP_NOTES == *"the endlessh step's UFW rule left as it is: allow 22/tcp # server-prep: endlessh tarpit"* &&
    $STEP_NOTES == *'extra port 22/tcp'* && $STEP_NOTES != *'without the server-prep tag left as it is: allow 22/tcp'* ]] ||
    fail "step_firewall: the notes of the Endlessh rule on an extra port are '$STEP_NOTES'"
[[ ${#MANUAL_TODO[@]} -eq 2 ]] || fail "step_firewall: want the deny rule's todo and Docker's, got: $(printf '%s | ' "${MANUAL_TODO[@]}")"
EXPOSE_WEB=no
pass "step_firewall: a rule in the place of a wanted one stays; one that contradicts the answers gets a warning and a to-do"

# --- the plan: what the firewall step will delete ------------------------------------------------------------
mapfile -t FAKE_RULES < <(sed -n 's/^ufw //p' <<<"$ADDED")
ADMIN_IPS=192.168.1.50; EXTRA_PORTS=8080/tcp; PANEL_ACCESS=''; PENDING=0
out="$(ufw_plan_cleanup 2>&1)"
for want in '  Firewall cleanup .. deletes the UFW rules server-prep added for earlier answers:' \
    '                        limit 822/tcp  # ssh' \
    '                        route allow 80/tcp  # server-prep: docker http' \
    'SSH rules among them'; do
    [[ $out == *"$want"* ]] || fail "ufw_plan_cleanup: no '$want' in:"$'\n'"$out"
done
[[ $out != *8443* && $out != *9100* && $out != *endlessh* ]] || fail "ufw_plan_cleanup: lists a rule that is not server-prep's:"$'\n'"$out"
FAKE_RULES=("allow from 192.168.1.50 to any port 822 proto tcp comment 'server-prep: ssh admin'")
[[ -z $(ufw_plan_cleanup 2>&1) ]] || fail "ufw_plan_cleanup: printed lines with nothing to delete: $(ufw_plan_cleanup 2>&1)"
pass 'ufw_plan_cleanup lists the rules to delete, warns about SSH rules, and prints nothing otherwise'
