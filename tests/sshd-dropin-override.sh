#!/usr/bin/env bash
# shellcheck disable=SC2034   # ADMIN_USER, SSH_PORT... are read by the sourced functions
# Tests sshd_dropin_overrides and sshd_override_text (issue #204), which the audit (ssh.dropin_override,
# ssh.root_login) and the SSH step use to find a line sshd reads before 00-server-prep.conf and keeps
# instead of server-prep's value, such as the 00-dokploy.conf that Dokploy's server Security dialog
# writes. Both scripts have their own copy: they must match. Then the cases run on sample files in a
# temporary folder, and the SSH step's report (ssh_report_overrides) on one of them. No root needed,
# nothing on the host changes.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok: %s\n' "$*"; exit 1; }
pass() { printf 'ok: %s\n' "$*"; }

if ! tmp="$(mktemp -d)" || [[ -z $tmp || ! -d $tmp ]]; then
    fail 'mktemp -d failed, no temporary directory for the sshd drop-in tests'
fi
trap 'rm -rf "$tmp"' EXIT

# server-audit.sh runs its checks on load, so it cannot be sourced: take the two functions only.
fns() { sed -n '/^sshd_dropin_overrides() {/,/^}/p; /^sshd_override_text() {/,/^}/p' "$1"; }
audit_fns="$(fns "$SCRIPT_DIR/server-audit.sh")"
prep_fns="$(fns "$SCRIPT_DIR/server-prep.sh")"
[[ -n $audit_fns ]] || fail 'sshd_dropin_overrides or sshd_override_text not found in server-audit.sh'
[[ $audit_fns == "$prep_fns" ]] || fail 'server-prep.sh and server-audit.sh have different copies of sshd_dropin_overrides and sshd_override_text'
pass 'server-prep.sh and server-audit.sh have the same sshd_dropin_overrides and sshd_override_text'
eval "$audit_fns"

# What the SSH step writes (sshd_prep_conf), with the panel reaching root over Tailscale and its IP
OWN='# Managed by server-prep.sh
Port 822
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
AuthenticationMethods publickey
UsePAM yes
X11Forwarding no
MaxAuthTries 3
LogLevel VERBOSE
AllowUsers admin root@100.64.0.0/10 root@fd7a:115c:a1e0::/48 root@192.0.2.10'
# The main file of Debian and Ubuntu: comments, then the Include, then the rest (read after the drop-ins)
MAIN='# This is the sshd server system-wide configuration file.
Include /etc/ssh/sshd_config.d/*.conf
#Port 22
KbdInteractiveAuthentication no
UsePAM yes
X11Forwarding yes
PrintMotd no
Subsystem sftp /usr/lib/openssh/sftp-server

# BEGIN server-prep root access
Match Address 100.64.0.0/10,fd7a:115c:a1e0::/48,192.0.2.10
    PermitRootLogin prohibit-password
# END server-prep root access'
# What Dokploy 0.31 writes to 00-dokploy.conf when its SSH tab is saved on a prepared server
DOKPLOY='# Managed by Dokploy
PasswordAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin prohibit-password
MaxAuthTries 3'

n=0
setup() {   # setup: a fresh /etc/ssh copy in the temporary folder, server-prep's file and the main file
    n=$((n + 1))
    ssh="$tmp/$n/ssh"
    mkdir -p "$ssh/sshd_config.d"
    printf '%s\n' "$MAIN" > "$ssh/sshd_config"
    printf '%s\n' "$OWN" > "$ssh/sshd_config.d/00-server-prep.conf"
}
put() { printf '%s\n' "$2" > "$ssh/$1"; }   # put PATH-UNDER-ssh TEXT
expect() {   # expect LABEL WANT [OWN-FILE]: the phrase of sshd_override_text ("" = nothing found)
    local got
    got="$(sshd_dropin_overrides "$ssh/sshd_config.d" ${3:+"$3"} | sshd_override_text)"
    [[ $got == "$2" ]] || fail "$1: got '$got', want '$2'"
    pass "$1"
}
# What sshd does with the values: it keeps the first value of most keywords, and adds up Port and AllowUsers
KEEP=': sshd keeps these values, not those of 00-server-prep.conf'
ADDS=': sshd uses these values as well as those of 00-server-prep.conf'

setup
expect 'only server-prep and the stock main file' ''

setup; put sshd_config.d/00-dokploy.conf "$DOKPLOY"
expect "Dokploy's 00-dokploy.conf sorts before 00-server-prep.conf and changes PermitRootLogin" \
    "00-dokploy.conf is read first and sets PermitRootLogin prohibit-password$KEEP"
got="$(sshd_dropin_overrides "$ssh/sshd_config.d")"
[[ $got == "$ssh/sshd_config.d/00-dokploy.conf"$'\t'PermitRootLogin$'\t'prohibit-password ]] ||
    fail "the raw line is FILE<TAB>Keyword<TAB>value, got '$got'"
pass 'the raw line is FILE<TAB>Keyword<TAB>value, with the full path'

setup; put sshd_config.d/00-dokploy.conf '# Managed by Dokploy
PasswordAuthentication yes
ChallengeResponseAuthentication yes
PermitRootLogin prohibit-password
MaxAuthTries 6'
expect 'every setting Dokploy changes is named, in file order (ChallengeResponseAuthentication is the old name of KbdInteractiveAuthentication)' \
    "00-dokploy.conf is read first and sets PasswordAuthentication yes, ChallengeResponseAuthentication yes, PermitRootLogin prohibit-password, MaxAuthTries 6$KEEP"

setup; put sshd_config.d/50-cloud-init.conf 'PasswordAuthentication yes
PermitRootLogin yes'
expect 'a drop-in that sorts after 00-server-prep.conf changes nothing (sshd keeps the first value)' ''

setup; put sshd_config.d/00-Zed.conf 'PermitRootLogin yes'
expect 'byte order, whatever the locale: 00-Zed.conf sorts before 00-server-prep.conf' \
    "00-Zed.conf is read first and sets PermitRootLogin yes$KEEP"

setup; put sshd_config.d/00-a.conf 'PermitRootLogin no'; put sshd_config.d/00-dokploy.conf "$DOKPLOY"
expect "an earlier file with server-prep's own value wins over Dokploy's: nothing changes" ''

setup; put sshd_config.d/00-dokploy.conf 'permitrootlogin=No
PasswordAuthentication   NO
MaxAuthTries = 3
#PermitRootLogin yes
   # PasswordAuthentication yes'
expect "the same values in another case or with '=', and comments, change nothing" ''

setup; put sshd_config.d/00-a.conf "PermitRootLogin yes"$'\r'"
MaxAuthTries 3 # a comment"
expect 'a CRLF line end and a trailing comment are not part of the value' "00-a.conf is read first and sets PermitRootLogin yes$KEEP"

setup; put sshd_config.d/00-a.conf 'X11Forwarding yes
PrintMotd yes
UsePAM no'
expect 'keywords server-prep does not check are left out' ''

setup; put sshd_config.d/00-a.conf 'Match Address 192.0.2.0/24
    PermitRootLogin yes
    PasswordAuthentication yes'
expect 'lines after a Match are conditional, not global' ''

setup; put sshd_config.d/00-a.conf 'Port 822
Port 2222
AllowUsers admin
AllowUsers deploy'
expect "Port and AllowUsers add up: only the values server-prep does not set count, and server-prep's still apply" \
    "00-a.conf is read first and adds Port 2222, AllowUsers deploy$ADDS"

setup; put sshd_config.d/00-ops.conf 'AllowUsers deploy'
expect "AllowUsers alone: sshd allows deploy too, server-prep's users stay allowed" \
    "00-ops.conf is read first and adds AllowUsers deploy$ADDS"

setup; put sshd_config.d/00-a.conf 'AllowUsers deploy
PermitRootLogin yes'
expect 'a value set and a value added: each one said as it is' \
    '00-a.conf is read first and sets PermitRootLogin yes and adds AllowUsers deploy: sshd keeps the values set instead of those of 00-server-prep.conf, and uses the values added along with them'

setup; put sshd_config.d/00-a.conf 'AuthenticationMethods any'
expect 'AuthenticationMethods any instead of publickey' "00-a.conf is read first and sets AuthenticationMethods any$KEEP"

setup; put sshd_config "# the main file
PermitRootLogin yes
Include /etc/ssh/sshd_config.d/*.conf
PasswordAuthentication yes"
expect 'in the main file, the lines before the Include count, the ones after it do not' \
    "sshd_config sets PermitRootLogin yes before its Include line$KEEP"

setup; put sshd_config "PermitRootLogin yes
Include /etc/ssh/sshd_config.d/*.conf"; put sshd_config.d/00-dokploy.conf "$DOKPLOY"
expect 'the main file comes first, then the drop-ins, each file once' \
    "sshd_config sets PermitRootLogin yes before its Include line$KEEP"
put sshd_config.d/00-dokploy.conf "${DOKPLOY/MaxAuthTries 3/MaxAuthTries 9}"
expect 'two files: one phrase each, joined with "; "' \
    "sshd_config sets PermitRootLogin yes before its Include line; 00-dokploy.conf is read first and sets MaxAuthTries 9$KEEP"

NOINC='sshd_config has no Include line for sshd_config.d: sshd reads none of its files, 00-server-prep.conf included'
setup; put sshd_config 'PermitRootLogin yes
PasswordAuthentication yes'; put sshd_config.d/00-dokploy.conf "$DOKPLOY"
expect 'a main file without an Include: sshd reads no drop-in, so that is all there is to say' "$NOINC"
got="$(sshd_dropin_overrides "$ssh/sshd_config.d")"
[[ $got == "$ssh/sshd_config"$'\t'Include$'\t' ]] || fail "no Include: the raw line is MAIN<TAB>Include<TAB>, got '$got'"
pass 'no Include: the raw line is MAIN<TAB>Include<TAB>, and no line of the main file or of a drop-in'
setup; : > "$ssh/sshd_config"
expect 'an empty main file has no Include either' "$NOINC"
setup; put sshd_config 'Include sshd_config.d/*.conf'
expect 'an Include with a path relative to /etc/ssh counts' ''

setup; rm "$ssh/sshd_config.d/00-server-prep.conf"; put sshd_config.d/00-dokploy.conf "$DOKPLOY"
expect 'no 00-server-prep.conf: nothing to compare with' ''
printf '%s\n' "$OWN" > "$tmp/own.conf"
expect "OWN as an argument (the step's text, before its first write): the drop-ins that would sort first count" \
    "00-dokploy.conf is read first and sets PermitRootLogin prohibit-password$KEEP" "$tmp/own.conf"

setup; ln -s 00-server-prep.conf "$ssh/sshd_config.d/00-link.conf"
expect "a link to server-prep's own file changes nothing" ''

# --- the SSH step's report: a warning, a note and a to-do that name the file ------------------------
# Load the real functions without starting a run (see tests/exit-status.sh).
# shellcheck disable=SC1091
. "$SCRIPT_DIR/server-prep.sh" --yes
LOG_FILE=/dev/null ADMIN_USER=admin SSH_PORT=822 PANEL_PUBKEY="ssh-ed25519 AAAA panel" PANEL_ACCESS=tailscale,public PANEL_IP=192.0.2.10
compute_root_sources
setup; put sshd_config.d/00-dokploy.conf "$DOKPLOY"
STEP_NOTES="" MANUAL_TODO=()
ssh_report_overrides "$ssh/sshd_config.d" > "$tmp/warn.out" 2>&1 || fail 'ssh_report_overrides finds nothing with 00-dokploy.conf'
grep -qF '00-dokploy.conf is read first and sets PermitRootLogin prohibit-password' "$tmp/warn.out" ||
    fail "ssh_report_overrides prints no warning naming 00-dokploy.conf: $(cat "$tmp/warn.out")"
[[ $STEP_NOTES == *'00-dokploy.conf is read first and sets PermitRootLogin prohibit-password'* ]] ||
    fail "the step's note does not name 00-dokploy.conf: $STEP_NOTES"
[[ ${#MANUAL_TODO[@]} -eq 1 && ${MANUAL_TODO[0]} == *00-dokploy.conf*'sudo sshd -t'* ]] ||
    fail "the step's to-do does not name 00-dokploy.conf and the sshd -t check: ${MANUAL_TODO[*]}"
[[ $SSH_OVERRIDE_FILES == 00-dokploy.conf ]] || fail "SSH_OVERRIDE_FILES is '$SSH_OVERRIDE_FILES', want 00-dokploy.conf"
pass "the SSH step warns, notes and adds a to-do naming 00-dokploy.conf, compared with the text it writes (sshd_prep_conf)"
[[ ${MANUAL_TODO[0]} != *"Dokploy's server Security dialog"* ]] ||
    fail "PANEL=${PANEL}: the to-do names Dokploy's dialog on another panel: ${MANUAL_TODO[0]}"
STEP_NOTES="" MANUAL_TODO=()
PANEL=dokploy ssh_report_overrides "$ssh/sshd_config.d" > /dev/null 2>&1
[[ ${MANUAL_TODO[0]:-} == *"Dokploy's server Security dialog writes 00-dokploy.conf"* ]] ||
    fail "PANEL=dokploy: the to-do does not say which Dokploy dialog writes 00-dokploy.conf: ${MANUAL_TODO[*]}"
pass "the to-do names Dokploy's Security dialog only when the panel is Dokploy"
# SSH_OVERRIDE_FILES, for the to-do of a failed login check of --yes: each file once, in sshd's read order
setup; put sshd_config.d/00-dokploy.conf "$DOKPLOY"; put sshd_config.d/00-a.conf $'MaxAuthTries 6\nAllowUsers deploy'
ssh_report_overrides "$ssh/sshd_config.d" > /dev/null 2>&1
[[ $SSH_OVERRIDE_FILES == '00-a.conf, 00-dokploy.conf' ]] ||
    fail "two files read first: SSH_OVERRIDE_FILES is '$SSH_OVERRIDE_FILES', want '00-a.conf, 00-dokploy.conf'"
pass 'SSH_OVERRIDE_FILES names each file read first once, in the order sshd reads them'
setup
STEP_NOTES="" MANUAL_TODO=()
if ssh_report_overrides "$ssh/sshd_config.d" > /dev/null 2>&1 || [[ -n $STEP_NOTES || ${#MANUAL_TODO[@]} -gt 0 || -n $SSH_OVERRIDE_FILES ]]; then
    fail "ssh_report_overrides reports something without another file: $STEP_NOTES ${MANUAL_TODO[*]} files '$SSH_OVERRIDE_FILES'"
fi
pass 'the SSH step says nothing when no file is read first'
setup; put sshd_config.d/00-a.conf 'Port 22'
STEP_NOTES="" MANUAL_TODO=()
if ssh_report_overrides "$ssh/sshd_config.d" > /dev/null 2>&1 || [[ -n $STEP_NOTES || ${#MANUAL_TODO[@]} -gt 0 ]]; then
    fail "ssh_report_overrides reports a Port line, which the step comments out itself: $STEP_NOTES ${MANUAL_TODO[*]}"
fi
expect 'the audit still counts that Port line' "00-a.conf is read first and adds Port 22$ADDS"
pass 'the SSH step leaves out Port lines, which write_sshd_config comments out itself'
setup; put sshd_config 'PermitRootLogin no'
STEP_NOTES="" MANUAL_TODO=()
ssh_report_overrides "$ssh/sshd_config.d" > /dev/null 2>&1 || fail 'ssh_report_overrides says nothing about a main file without an Include'
[[ ${#MANUAL_TODO[@]} -eq 1 && ${MANUAL_TODO[0]} == *'no Include line'*"'Include /etc/ssh/sshd_config.d/*.conf'"*'sudo sshd -t'* ]] ||
    fail "no Include: the step's to-do does not say to add the Include line: ${MANUAL_TODO[*]}"
[[ $SSH_OVERRIDE_FILES == sshd_config ]] || fail "no Include: SSH_OVERRIDE_FILES is '$SSH_OVERRIDE_FILES', want sshd_config"
pass 'no Include: the SSH step says sshd reads none of the drop-ins and to add the Include line'

printf 'ok: all sshd drop-in override cases\n'
