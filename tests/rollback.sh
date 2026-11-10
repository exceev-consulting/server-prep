#!/usr/bin/env bash
# shellcheck disable=SC2034
# Tests the rollback.sh that write_rollback writes after a real run (issue #71), on fake run data:
# it is valid bash, it warns to run it from the console and says what it does not undo before any
# change, and before SSH restarts on its old port it stops Endlessh, allows that port in UFW,
# deletes the Endlessh rule and checks the restored files with sshd -t. The generated script only
# runs with fake cp, rm, mkdir, sshd, systemctl, sysctl and ufw, plus the real grep, sed and sort
# that read ufw's output: its PATH holds nothing else, so it can never touch /etc. No root needed.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Stop before any path is built if mktemp fails: an empty $tmp would put the fakes and backups in /.
if ! tmp="$(mktemp -d)" || [[ -z $tmp || ! -d $tmp ]]; then
    printf 'not ok: mktemp -d failed, no temporary directory for rollback.sh\n'
    exit 1
fi
trap 'rm -rf "$tmp"' EXIT

# Load the real functions without starting a run (see tests/exit-status.sh).
# shellcheck disable=SC1091
. "$SCRIPT_DIR/server-prep.sh" --yes

fail() {
    printf 'not ok: %s\n' "$*"
    [[ -f ${rb:-} ]] && { printf -- '--- rollback.sh:\n'; cat "$rb"; } >&2
    [[ -f $tmp/calls ]] && { printf -- '--- commands:\n'; cat "$tmp/calls"; } >&2
    [[ -f $tmp/stdout ]] && { printf -- '--- output:\n'; cat "$tmp/stdout"; } >&2
    exit 1
}
pass() { printf 'ok: %s\n' "$*"; }

# One fake for every command rollback.sh runs: it records "NAME ARGS" in $CALLS and succeeds.
# "systemctl is-enabled --quiet ssh.socket" succeeds only with SOCKET=1 (sshd started by ssh.socket),
# "systemctl is-active/is-enabled --quiet endlessh" only with ENDLESSH=1, "sshd -t" fails with
# SSHD_BAD=1, and "ufw status numbered" prints $UFW_STATUS.
cat > "$tmp/fake" <<'EOF'
#!/bin/sh
printf '%s\n' "${0##*/} $*" >> "$CALLS"
case "${0##*/} $*" in
    "systemctl is-enabled --quiet ssh.socket") [ "${SOCKET:-0}" = 1 ]; exit ;;
    "systemctl is-active --quiet endlessh"|"systemctl is-enabled --quiet endlessh") [ "${ENDLESSH:-0}" = 1 ]; exit ;;
    "sshd -t") [ "${SSHD_BAD:-0}" != 1 ]; exit ;;
    "ufw status numbered") printf '%s\n' "${UFW_STATUS:-}" ;;
esac
exit 0
EOF
chmod 755 "$tmp/fake"
mkdir -p "$tmp/bin" "$tmp/bin-no-ufw"
for c in cp rm mkdir sshd systemctl sysctl ufw; do ln -s "$tmp/fake" "$tmp/bin/$c"; done
for c in cp rm mkdir sshd systemctl sysctl; do ln -s "$tmp/fake" "$tmp/bin-no-ufw/$c"; done
# The real read-only tools that pick the Endlessh rule numbers out of "ufw status numbered"
for c in grep sed sort; do
    p="$(command -v "$c")" || { printf 'not ok: no %s for rollback.sh\n' "$c"; exit 1; }
    ln -s "$p" "$tmp/bin/$c"; ln -s "$p" "$tmp/bin-no-ufw/$c"
done

# "ufw status numbered" after a run with Endlessh: its rule is number 2, and 4 for IPv6
UFW_ENDLESSH='Status: active

     To                         Action      From
     --                         ------      ----
[ 1] 822/tcp                    ALLOW IN    192.168.1.50               # ssh admin
[ 2] 22/tcp                     ALLOW IN    Anywhere                   # endlessh tarpit
[ 3] 822/tcp (v6)               ALLOW IN    Anywhere (v6)              # ssh tailscale
[ 4] 22/tcp (v6)                ALLOW IN    Anywhere (v6)              # endlessh tarpit'

LOG_FILE="$tmp/run.log"
TS=20260101_000000
SSH_PORT=822
rb=""

setup() {   # a fresh applied run that moved SSH from 22 to 822 and installed Endlessh
    DRY_RUN=0
    BACKUP_DIR="$tmp/backups"
    rm -rf "$BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    rb="$BACKUP_DIR/rollback.sh"
    CURRENT_SSH_PORTS='22 '   # as preflight reads it from sshd -T, with its trailing space
    ADMIN_IPS=192.168.1.50
    PANEL=coolify
    PANEL_ACCESS=tailscale,public
    PANEL_IP=203.0.113.10
    set_panel_label
    CHANGED_FILES=(/etc/ssh/sshd_config)
    NEW_FILES=(/etc/ssh/sshd_config.d/00-server-prep.conf /etc/endlessh/config
        /etc/systemd/system/endlessh.service.d/server-prep.conf)
    STEP_IDS=(); STEP_RESULTS=(); STEP_DETAILS=(); MANUAL_TODO=()
    CROWDSEC_ENROLL_KEY=''
    ENDLESSH=0
    UFW_STATUS="$UFW_ENDLESSH"
    rm -f "$tmp/calls" "$tmp/stdout"
}

generate() {   # generate LABEL: write rollback.sh, which must be valid bash
    write_rollback > "$tmp/out" 2>&1 || fail "$1: write_rollback failed: $(cat "$tmp/out")"
    [[ -f $rb ]] || fail "$1: no rollback.sh written"
    bash -n "$rb" 2> "$tmp/syntax" || fail "$1: rollback.sh is not valid bash: $(cat "$tmp/syntax")"
}

run_rb() {   # run_rb LABEL [BIN] [SOCKET]: run rollback.sh with only the fakes of BIN on PATH
    local status=0
    : > "$tmp/calls"
    CALLS="$tmp/calls" SOCKET="${3:-0}" ENDLESSH="$ENDLESSH" UFW_STATUS="$UFW_STATUS" PATH="${2:-$tmp/bin}" \
        "$BASH" "$rb" < /dev/null > "$tmp/stdout" 2> "$tmp/stderr" || status=$?
    [[ $status -eq 0 ]] || fail "$1: rollback.sh exited $status: $(cat "$tmp/stderr")"
    grep -qF 'Rollback done' "$tmp/stdout" || fail "$1: rollback.sh did not reach its end"
}

first() {   # first FILE REGEX: number of the first matching line, 0 when none
    local n
    n="$(grep -nE -m1 -- "$2" "$1" | cut -d: -f1)"
    printf '%s' "${n:-0}"
}
last() {   # last FILE REGEX: number of the last matching line, 0 when none
    local n
    n="$(grep -nE -- "$2" "$1" | tail -n 1 | cut -d: -f1)"
    printf '%s' "${n:-0}"
}
called() { grep -qxF -- "$1" "$tmp/calls"; }   # called COMMAND: the exact command ran
rules() { grep -E '^ufw (allow|limit) ' "$tmp/calls"; }

# --- SSH moved from 22 to 822, Endlessh on 22, admin, panel and Tailscale sources -------------------
setup
generate 'moved SSH'
[[ -s $tmp/out ]] && fail "write_rollback printed something: $(cat "$tmp/out")"
pass 'write_rollback writes a valid rollback.sh and prints nothing'

console=$(first "$rb" 'from the console')
undo=$(first "$rb" 'does NOT undo')
trace=$(first "$rb" '^set -x$')
copy=$(first "$rb" '^cp -a ')
((console > 0 && undo > 0 && trace > 0 && copy > 0)) || fail 'the console warning, the not-undone list, set -x or cp -a is missing'
((console < trace && undo < trace)) || fail 'the console warning or the not-undone list comes after set -x'
((trace < copy)) || fail 'set -x comes after the first cp -a'
grep -q '^#' <<<"$(grep -F 'does NOT undo' "$rb")" && fail 'what rollback.sh does not undo is only a comment'
pass 'the console warning and what it does not undo come before set -x, set -x before any change'

run_rb 'moved SSH'
head -n 2 "$tmp/stdout" | grep -qF 'Run this from the console' || fail 'the output does not start with the console warning'
grep -qF 'does NOT undo' "$tmp/stdout" || fail 'the output does not say what the rollback does not undo'
grep -qF 'installed packages, and services it turned on or off' "$tmp/stdout" || fail 'the output does not list the packages and services'
grep -qF 'the Endlessh rule that allows port 22 from anywhere' "$tmp/stdout" && fail 'the Endlessh rule is listed as not undone, but rollback.sh deletes it'
grep -qF 'deletes the Endlessh rule (endlessh tarpit), which allowed port 22 from anywhere' "$tmp/stdout" ||
    fail 'the output does not say that the Endlessh rule is deleted'
grep -qF 'Endlessh stops first' "$tmp/stdout" || fail 'the output does not say that Endlessh stops'
grep -qxF 'SSH goes back to port(s) 22.' "$tmp/stdout" || fail 'the output does not name the restored SSH port'
grep -qF 'Coolify loses its SSH access' "$tmp/stdout" || fail 'the output does not say that the panel loses SSH'
[[ "$(tail -n 1 "$tmp/stdout")" == 'Rollback done.'* ]] || fail 'the output does not end with "Rollback done"'
pass 'the output starts with the console warning, lists what is not undone and ends with "Rollback done"'

called "cp -a $BACKUP_DIR/etc/ssh/sshd_config /etc/ssh/sshd_config" || fail 'sshd_config is not copied back'
called 'rm -f /etc/ssh/sshd_config.d/00-server-prep.conf' || fail 'the created sshd drop-in is not deleted'
called 'systemctl disable --now endlessh' || fail 'Endlessh is not stopped'
want='ufw allow from 192.168.1.50 to any port 22 proto tcp comment server-prep-temp admin
ufw allow from 203.0.113.10 to any port 22 proto tcp comment server-prep-temp panel
ufw allow in on tailscale0 to any port 22 proto tcp comment server-prep-temp tailscale'
[[ "$(rules)" == "$want" ]] || fail "UFW rules for port 22: got '$(rules)', want '$want'"
grep -E '^ufw (allow|limit) ' "$tmp/calls" | grep -q 822 && fail 'rollback.sh adds a rule for the new port 822'
pass 'UFW allows port 22 from the admin, the panel and Tailscale, with the comment phase B deletes, and nothing for 822'

[[ "$(grep '^ufw --force delete ' "$tmp/calls")" == $'ufw --force delete 4\nufw --force delete 2' ]] ||
    fail "the Endlessh rules 4 and 2 are not deleted, highest first: got '$(grep '^ufw --force delete ' "$tmp/calls")'"
pass 'the Endlessh rules (IPv4 and IPv6) are deleted, highest number first, and no other rule'

endlessh=$(first "$tmp/calls" '^systemctl disable --now endlessh$')
allow1=$(first "$tmp/calls" '^ufw (allow|limit) ')
allowN=$(last "$tmp/calls" '^ufw (allow|limit) ')
drop1=$(first "$tmp/calls" '^ufw --force delete ')
dropN=$(last "$tmp/calls" '^ufw --force delete ')
rundir=$(first "$tmp/calls" '^mkdir -p -m 0755 /run/sshd$')
check=$(first "$tmp/calls" '^sshd -t$')
restart=$(first "$tmp/calls" '^systemctl restart ssh$')
reload=$(first "$tmp/calls" '^ufw reload$')
((endlessh > 0 && check > 0 && restart > 0 && reload > 0)) || fail 'the Endlessh stop, sshd -t, the SSH restart or the UFW reload did not run'
((rundir > 0 && rundir < check)) || fail 'sshd -t runs without making /run/sshd first'
((endlessh < allow1)) || fail 'Endlessh is stopped after the first UFW rule'
((allowN < drop1)) || fail 'the Endlessh rule is deleted before port 22 is allowed from the admin addresses'
((dropN < check)) || fail 'sshd -t runs before the Endlessh rule is deleted'
((check < restart)) || fail 'sshd -t runs after the SSH restart'
((restart < reload)) || fail 'UFW reloads before the SSH restart'
pass 'order: Endlessh stopped, port 22 allowed in UFW, the Endlessh rule deleted, sshd -t, SSH restarted, UFW reloaded'

# --- the same run where ssh.socket starts sshd (Ubuntu 22.10 and later) -----------------------------
run_rb 'ssh.socket' "$tmp/bin" 1
endlessh=$(first "$tmp/calls" '^systemctl disable --now endlessh$')
allowN=$(last "$tmp/calls" '^ufw (allow|limit) ')
check=$(first "$tmp/calls" '^sshd -t$')
stop=$(first "$tmp/calls" '^systemctl stop ssh\.service$')
socket=$(first "$tmp/calls" '^systemctl restart ssh\.socket$')
reload=$(first "$tmp/calls" '^ufw reload$')
((stop > 0 && socket > 0)) || fail 'ssh.socket: sshd is not stopped or the socket not restarted'
called 'systemctl restart ssh' && fail 'ssh.socket: ssh.service restarted instead of the socket'
((endlessh < stop && allowN < stop && check > 0 && check < stop && stop < socket && socket < reload)) ||
    fail 'ssh.socket: Endlessh stop, UFW rules and sshd -t must come before stop ssh.service, restart ssh.socket, then ufw reload'
pass 'ssh.socket: Endlessh stopped, port 22 allowed and sshd -t passed before sshd stops and the socket restarts'

# --- sshd -t rejects the restored files: SSH keeps running as it is ----------------------------------
: > "$tmp/calls"
status=0
CALLS="$tmp/calls" SSHD_BAD=1 UFW_STATUS="$UFW_STATUS" PATH="$tmp/bin" \
    "$BASH" "$rb" < /dev/null > "$tmp/stdout" 2> "$tmp/stderr" || status=$?
((status != 0)) || fail 'sshd -t fails: rollback.sh exits 0'
called 'sshd -t' || fail 'sshd -t fails: sshd -t did not run'
grep -qE '^systemctl (restart|stop|start) ssh' "$tmp/calls" && fail 'sshd -t fails: SSH is restarted anyway'
grep -qF 'sshd -t rejects the restored SSH configuration' "$tmp/stderr" || fail 'sshd -t fails: rollback.sh does not say why it stops'
grep -qF 'Rollback done' "$tmp/stdout" && fail 'sshd -t fails: rollback.sh says "Rollback done"'
pass 'sshd -t rejects the restored files: rollback.sh stops before SSH restarts and says why'

# --- no ufw command (the firewall step never ran) ----------------------------------------------------
run_rb 'no ufw' "$tmp/bin-no-ufw"
grep -q '^ufw ' "$tmp/calls" && fail 'no ufw: a ufw command was recorded'
called 'systemctl restart ssh' || fail 'no ufw: SSH is not restarted'
pass 'without ufw the script still restarts SSH and reaches its end'

# --- no source restriction: the rate-limited rule from anywhere, as step_firewall makes it ------------
setup
ADMIN_IPS='' PANEL_ACCESS=''
generate 'no sources'
[[ -s $tmp/out ]] && fail "no sources: write_rollback printed a warning: $(cat "$tmp/out")"
grep -qF 'no SSH source restriction' "$rb" && fail 'no sources: the firewall warning went into rollback.sh'
run_rb 'no sources'
[[ "$(rules)" == 'ufw limit 22/tcp comment server-prep-temp' ]] || fail "no sources: got '$(rules)'"
# without the Endlessh rule's plain allow, the rate limit applies
called 'ufw --force delete 4' && called 'ufw --force delete 2' || fail 'no sources: the Endlessh rule is not deleted'
pass 'no SSH sources: ufw limit 22/tcp, the Endlessh rule deleted, and no warning in the output or the script'

# --- cloudflared only: step_firewall allows nothing, the rollback neither (and writes no empty if) -----
setup
ADMIN_IPS='' PANEL_ACCESS=cloudflared
generate 'cloudflared only'
grep -qF 'command -v ufw' "$rb" && fail 'cloudflared only: an empty ufw block was written'
run_rb 'cloudflared only'
[[ -z "$(rules)" ]] || fail "cloudflared only: got UFW rules '$(rules)'"
grep -qE '^ufw (status|--force delete)' "$tmp/calls" && fail "cloudflared only: a UFW rule is looked up or deleted: $(grep '^ufw ' "$tmp/calls" | paste -sd';')"
grep -qxF 'SSH goes back to port(s) 22.' "$tmp/stdout" || fail 'cloudflared only: the restored port is not named'
grep -qF 'UFW allows it first' "$tmp/stdout" && fail 'cloudflared only: says UFW allows the port'
grep -qF 'allowed only the Cloudflare Tunnel' "$tmp/stdout" || fail 'cloudflared only: does not say UFW gets no rule'
grep -qF 'port 22 stays open to everyone' "$tmp/stdout" || fail 'cloudflared only: does not warn that the Endlessh rule keeps 22 open'
grep -qF 'Cloudflare Tunnel SSH hostname still sends SSH to port 822: point it to port 22' "$tmp/stdout" ||
    fail 'cloudflared only: does not say the tunnel still points to 822'
pass 'cloudflared only: no UFW rule and no empty block, the port named, the open Endlessh rule and the tunnel port told'

# --- several old ports and a list of admin sources ---------------------------------------------------
setup
CURRENT_SSH_PORTS='22 2222 '
ADMIN_IPS='192.168.1.50, 198.51.100.0/24'
PANEL_ACCESS=''
generate 'two old ports'
run_rb 'two old ports'
want='ufw allow from 192.168.1.50 to any port 22 proto tcp comment server-prep-temp admin
ufw allow from 198.51.100.0/24 to any port 22 proto tcp comment server-prep-temp admin
ufw allow from 192.168.1.50 to any port 2222 proto tcp comment server-prep-temp admin
ufw allow from 198.51.100.0/24 to any port 2222 proto tcp comment server-prep-temp admin'
[[ "$(rules)" == "$want" ]] || fail "two old ports: got '$(rules)', want '$want'"
grep -qxF 'SSH goes back to port(s) 22 2222.' "$tmp/stdout" || fail 'two old ports: the ports are not named'
pass 'two old ports and two admin sources: one rule per port and source'

# --- SSH was already on the run's port: nothing to allow ---------------------------------------------
setup
CURRENT_SSH_PORTS='822 '
generate 'port not moved'
run_rb 'port not moved'
[[ -z "$(rules)" ]] || fail "port not moved: got UFW rules '$(rules)'"
grep -qF 'SSH goes back' "$tmp/stdout" && fail 'port not moved: says SSH goes back to another port'
called 'systemctl disable --now endlessh' || fail 'port not moved: the Endlessh this run installed is not stopped'
grep -q '^ufw --force delete' "$tmp/calls" && fail 'port not moved: a UFW rule is deleted'
grep -qF 'the Endlessh rule that allows port 22 from anywhere' "$tmp/stdout" ||
    fail 'port not moved: the Endlessh rule, which stays, is not listed as not undone'
pass 'SSH not moved: no UFW rule added or deleted, Endlessh stopped, its rule listed as not undone'

# --- a run that touched no SSH file (a re-run of other steps) -----------------------------------------
setup
CHANGED_FILES=(/etc/sysctl.d/99-server-prep.conf)
NEW_FILES=()
generate 'no SSH file'
run_rb 'no SSH file'
[[ -z "$(rules)" ]] || fail "no SSH file: got UFW rules '$(rules)'"
grep -q 'endlessh' "$tmp/calls" && fail 'no SSH file: Endlessh is stopped although this run did not install it'
grep -qF 'SSH goes back' "$tmp/stdout" && fail 'no SSH file: says SSH goes back to another port'
grep -qF 'loses its SSH access' "$tmp/stdout" && fail 'no SSH file: says the panel loses SSH'
grep -qF 'Endlessh rule' "$tmp/stdout" && fail 'no SSH file: lists an Endlessh rule'
pass 'a run that touched no SSH file: no UFW rule, no Endlessh stop, no panel warning'

# --- Endlessh not installed by this run (package missing, INSTALL_ENDLESSH=no, or --only ssh) ----------
# Another run can put Endlessh on 22 later: rollback.sh looks at run time and stops it when it is on.
setup
NEW_FILES=(/etc/ssh/sshd_config.d/00-server-prep.conf)
UFW_STATUS=''
generate 'no Endlessh'
grep -qF 'If Endlessh is on' "$rb" || fail 'no Endlessh: the output does not say Endlessh stops if it is on'
run_rb 'no Endlessh'
called 'systemctl is-active --quiet endlessh' || fail 'no Endlessh: rollback.sh does not check whether Endlessh is on'
called 'systemctl disable --now endlessh' && fail 'no Endlessh: Endlessh is stopped although it is off'
[[ -n "$(rules)" ]] || fail 'no Endlessh: port 22 is not allowed in UFW'
grep -q '^ufw --force delete' "$tmp/calls" && fail 'no Endlessh: a UFW rule is deleted although none is the Endlessh rule'
pass 'Endlessh off and not from this run: checked, not stopped, port 22 still allowed'

# --- ... and the same rollback.sh when a later run installed Endlessh on 22 (--only ssh, then endlessh) --
ENDLESSH=1
UFW_STATUS="$UFW_ENDLESSH"
run_rb 'Endlessh from a later run'
endlessh=$(first "$tmp/calls" '^systemctl disable --now endlessh$')
dropN=$(last "$tmp/calls" '^ufw --force delete ')
restart=$(first "$tmp/calls" '^systemctl restart ssh$')
((endlessh > 0)) || fail 'Endlessh from a later run: Endlessh is not stopped, so SSH cannot bind port 22'
((dropN > 0)) || fail 'Endlessh from a later run: its UFW rule is not deleted'
((endlessh < restart && dropN < restart)) || fail 'Endlessh from a later run: stopped or its rule deleted after the SSH restart'
pass 'Endlessh from a later run: stopped and its rule deleted before SSH goes back to 22'

# --- old port 2222, not 22: no Endlessh check, its rule (if any) is not this rollback's business -------
setup
CURRENT_SSH_PORTS='2222 '
NEW_FILES=(/etc/ssh/sshd_config.d/00-server-prep.conf)
ENDLESSH=1
generate 'old port 2222'
run_rb 'old port 2222'
grep -q 'endlessh' "$tmp/calls" && fail 'old port 2222: Endlessh, which holds 22, is checked or stopped'
grep -q '^ufw --force delete' "$tmp/calls" && fail 'old port 2222: the Endlessh rule is deleted'
pass 'SSH back on 2222: Endlessh on 22 and its rule left alone'

# --- what a run changes outside its files: listed only for the steps that changed something ------------
setup
generate 'no step results'
run_rb 'no step results'
for t in 'sudo group' 'the timezone' 'Ctrl-Alt-Del' 'without the desktop' 'sleep, suspend' 'swap file' \
    'kernel settings' 'auditd rules' 'AIDE and rkhunter' 'CrowdSec console' 'cloudflared tunnel service' 'Cloudflare Tunnel'; do
    grep -qF -- "$t" "$tmp/stdout" && fail "no step results: lists '$t'"
done
pass 'no step results: none of the step items is listed'

setup
STEP_IDS=(update users firewall ssh ips sysctl services laptop logging auditd rkhunter aide endlessh cloudflared)
STEP_RESULTS=(CHANGED CHANGED CHANGED CHANGED 'OK (already)' CHANGED CHANGED CHANGED CHANGED CHANGED FAILED
    'OK (already)' CHANGED CHANGED)
STEP_DETAILS=('3 package(s) upgraded; timezone Europe/Paris' - - - - - - - - - - - - -)
MANUAL_TODO=('Reboot to switch to headless mode (graphical desktop off). Undo: sudo systemctl set-default graphical.target')
CHANGED_FILES+=(/etc/fstab)
CROWDSEC_ENROLL_KEY=enroll-key-for-tests
PANEL_ACCESS=tailscale,cloudflared
generate 'every step'
grep -qF 'enroll-key-for-tests' "$rb" && fail 'every step: the CrowdSec enroll key went into rollback.sh'
run_rb 'every step'
for t in 'users it created or added to the sudo group' 'the timezone' 'Ctrl-Alt-Del turned off' \
    'the boot without the desktop' 'sleep, suspend and hibernate turned off' 'the swap file /swapfile' \
    'kernel settings (sysctl)' 'the auditd rules' 'the AIDE and rkhunter baselines' \
    'the CrowdSec console enrollment' 'the cloudflared tunnel service it installed'; do
    grep -qF -- "  - $t" "$tmp/stdout" || fail "every step: does not list '$t'"
done
grep -qF 'Cloudflare Tunnel SSH hostname still sends SSH to port 822' "$tmp/stdout" ||
    fail 'every step: does not say the tunnel still points to 822'
pass 'every step changed: users, timezone, boot, sleep, swap, kernel, auditd, baselines, CrowdSec and tunnel listed'

STEP_DETAILS[0]='3 package(s) upgraded'
STEP_RESULTS[4]=SKIPPED
MANUAL_TODO=()
generate 'timezone kept'
run_rb 'timezone kept'
grep -qF '  - the timezone' "$tmp/stdout" && fail 'timezone kept: lists the timezone'
grep -qF 'CrowdSec console' "$tmp/stdout" && fail 'ips skipped: lists the CrowdSec enrollment'
grep -qF 'without the desktop' "$tmp/stdout" && fail 'no headless todo: lists the boot target'
pass 'timezone kept, CrowdSec skipped, desktop kept: none of them is listed'

# --- a panel name with a quote cannot break the script -------------------------------------------------
setup
PANEL="web'panel"
set_panel_label
generate 'quote in PANEL'
run_rb 'quote in PANEL'
grep -qF "web'panel loses its SSH access" "$tmp/stdout" || fail 'quote in PANEL: the label is not printed as is'
pass 'a quote in the panel name keeps rollback.sh valid and is printed as is'

setup
PANEL=none
set_panel_label
generate 'no panel'
run_rb 'no panel'
grep -qF 'loses its SSH access' "$tmp/stdout" && fail 'PANEL=none: says a panel loses SSH'
pass 'PANEL=none: no panel warning'

# --- a dry run writes no rollback.sh -------------------------------------------------------------------
setup
DRY_RUN=1
BACKUP_DIR="$tmp/dry-backups"
mkdir -p "$BACKUP_DIR"
write_rollback > "$tmp/out" 2>&1 || fail 'dry run: write_rollback failed'
[[ -e $BACKUP_DIR/rollback.sh ]] && fail 'dry run: rollback.sh written'
pass 'a dry run writes no rollback.sh'
