#!/usr/bin/env bash
# shellcheck disable=SC2034   # LOG_FILE, SSH_SOCKET, DRY_RUN... are read by the sourced functions
# Tests the helpers the SSH step uses for sshd's Port lines (issue #72) on sample text: sshd listens
# on every Port line it reads, so the step comments out the ones outside 00-server-prep.conf (in the
# file a symlinked drop-in points to), keeps each port once, and after the move reads "sshd -T" and
# the listeners for any port left besides the new one. Then ssh_close_old_ports and ssh_finish_move,
# the re-run that finishes a move whose phase B failed, run with fake systemctl, ss, sshd, ufw and
# restart_ssh. Only stdin and a temporary folder are read: no root needed, nothing on the host is touched.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! tmp="$(mktemp -d)" || [[ -z $tmp || ! -d $tmp ]]; then
    printf 'not ok: mktemp -d failed, no temporary directory for the sshd Port tests\n'
    exit 1
fi
trap 'rm -rf "$tmp"' EXIT

# Load the real functions without starting a run (see tests/exit-status.sh).
# shellcheck disable=SC1091
. "$SCRIPT_DIR/server-prep.sh" --yes

fail() { printf 'not ok: %s\n' "$*"; exit 1; }
pass() { printf 'ok: %s\n' "$*"; }

# An sshd_config with every way to write Port, comments, and keywords that only start like it
sample='Include /etc/ssh/sshd_config.d/*.conf
#Port 22
# Port 2200
Port 22
  port 2222
Port=2201
PORT = 2202
Port	2203
GatewayPorts no
Ports 9
PortX 5
ListenAddress 0.0.0.0
PermitRootLogin no'
# The same text with the five active Port lines commented out, and nothing else changed
want_commented='Include /etc/ssh/sshd_config.d/*.conf
#Port 22
# Port 2200
# server-prep: Port 22
# server-prep:   port 2222
# server-prep: Port=2201
# server-prep: PORT = 2202
# server-prep: Port	2203
GatewayPorts no
Ports 9
PortX 5
ListenAddress 0.0.0.0
PermitRootLogin no'

# --- sshd_ports_in: one port per active Port line ---------------------------------------------------
got="$(printf '%s\n' "$sample" | sshd_ports_in | paste -sd' ' -)"
[[ $got == '22 2222 2201 2202 2203' ]] || fail "sshd_ports_in: got '$got', want '22 2222 2201 2202 2203'"
got="$(printf '#Port 22\nGatewayPorts yes\n' | sshd_ports_in)"
[[ -z $got ]] || fail "sshd_ports_in: a comment or GatewayPorts gave '$got'"
pass 'sshd_ports_in reads Port in any case, with spaces, a tab or "=", and skips comments, GatewayPorts and Ports'
got="$(printf 'Port abc\nPort *\nPort 22abc\nPort 2204 # old port\nPort 2205\r\n' | sshd_ports_in | paste -sd' ' -)"
[[ $got == '2204 2205' ]] || fail "sshd_ports_in: values that are not numbers gave '$got', want '2204 2205'"
pass 'sshd_ports_in keeps only numbers, with a trailing comment or a CRLF ending'

# --- sshd_comment_ports: those five lines commented out, every other byte kept ------------------------
printf '%s\n' "$sample" | sshd_comment_ports > "$tmp/once"
printf '%s\n' "$want_commented" > "$tmp/want"
cmp -s "$tmp/once" "$tmp/want" || fail "sshd_comment_ports: $(diff "$tmp/want" "$tmp/once")"
sshd_comment_ports < "$tmp/once" > "$tmp/twice"
cmp -s "$tmp/once" "$tmp/twice" || fail "sshd_comment_ports: a second pass changed the text: $(diff "$tmp/once" "$tmp/twice")"
got="$(sshd_ports_in < "$tmp/once")"
[[ -z $got ]] || fail "sshd_comment_ports: active Port lines left: '$got'"
pass 'sshd_comment_ports comments out exactly the active Port lines, and a second pass changes nothing'

got="$(printf 'Port 22' | sshd_comment_ports | od -An -c | tr -s ' ' | sed 's/^ //')"
want="$(printf '# server-prep: Port 22' | od -An -c | tr -s ' ' | sed 's/^ //')"
[[ $got == "$want" ]] || fail "sshd_comment_ports: no final newline gave '$got', want '$want'"
pass 'sshd_comment_ports adds no newline to a file that ends without one'

# --- uniq_ports: each port once, first-seen order, "a b " ---------------------------------------------
got="$(printf '%s\n' '822 22 ' 22 822 2222 | uniq_ports)"
[[ $got == '822 22 2222 ' ]] || fail "uniq_ports: got '$got', want '822 22 2222 '"
got="$(uniq_ports <<<'822')"
[[ $got == '822 ' ]] || fail "uniq_ports: one port gave '$got', want '822 '"
got="$(uniq_ports <<<'')"
[[ -z $got ]] || fail "uniq_ports: no port gave '$got'"
pass "uniq_ports keeps each port once, in order, as 'a b '"

# --- sshd_ports_except: the ports of "sshd -T" other than the new one ----------------------------------
got="$(printf 'port 822\naddressfamily any\nport 22\nport 22\nlistenaddress 0.0.0.0:22\n' | sshd_ports_except 822)"
[[ $got == '22 ' ]] || fail "sshd_ports_except: got '$got', want '22 '"
got="$(printf 'port 822\naddressfamily any\n' | sshd_ports_except 822)"
[[ -z $got ]] || fail "sshd_ports_except: only the new port gave '$got'"
got="$(sshd_ports_except 822 < /dev/null)"
[[ -z $got ]] || fail "sshd_ports_except: empty input gave '$got'"
pass 'sshd_ports_except lists each other port once, and nothing for the new port alone or no input'

# --- sshd_port_dropins: the other *.conf drop-ins with an active Port line ---------------------------
p="$(readlink -f "$tmp")"   # sshd_port_dropins prints canonical paths
d="$p/sshd_config.d"
mkdir -p "$d" "$p/provider" "$p/a-dir.conf"
printf 'Port 22\n' > "$p/sshd_config"            # the main file: write_sshd_config edits it itself
printf 'Port 822\n' > "$d/00-server-prep.conf"
printf 'Port 22\n' > "$d/10-provider.conf"
printf 'PasswordAuthentication no\n' > "$d/50-cloud-init.conf"
printf '# server-prep: Port 22\n#Port 2222\n' > "$d/60-commented.conf"
printf 'Port 2222\n' > "$d/70-not-read"          # sshd reads only *.conf
printf '  port=2201\n' > "$d/80-lower.conf"
printf 'Port 2200\n' > "$p/provider/port.conf"
ln -s "$d/10-provider.conf" "$d/90-link.conf"       # the same file twice: listed once
ln -s ../provider/port.conf "$d/91-elsewhere.conf"   # sshd follows the link: its file is listed
ln -s "$p/nowhere.conf" "$d/92-dangling.conf"
ln -s 00-server-prep.conf "$d/93-own.conf"
ln -s ../sshd_config "$d/94-main.conf"
ln -s ../a-dir.conf "$d/95-dir.conf"
want="10-provider.conf 80-lower.conf $p/provider/port.conf"
got="$(sshd_port_dropins "$d" | sed "s|^$d/||" | paste -sd' ' -)"
[[ $got == "$want" ]] || fail "sshd_port_dropins: got '$got', want '$want'"
if [[ $EUID -ne 0 ]]; then
    printf 'Port 2202\n' > "$d/85-unreadable.conf"
    chmod 000 "$d/85-unreadable.conf"
    got="$(sshd_port_dropins "$d" 2>&1 | sed "s|^$d/||" | paste -sd' ' -)"
    [[ $got == "$want" ]] || fail "sshd_port_dropins: an unreadable drop-in gave '$got', want it skipped without a message"
fi
sshd_port_dropins "$tmp/missing" > "$tmp/out" 2>&1 || fail 'sshd_port_dropins: a missing folder fails'
[[ -s $tmp/out ]] && fail "sshd_port_dropins: a missing folder printed '$(cat "$tmp/out")'"
pass 'sshd_port_dropins lists the other *.conf files with an active Port line once each, a link as the file it points to, never 00-server-prep.conf, the main file, a dangling link or an unreadable file'

# --- the listeners of the running SSH: ss and ssh.socket output ----------------------------------------
# sshd (ssh.service, pid 1234) on 822 and 22; another sshd (a container with host networking) and
# Endlessh do not count, and pid=12345 must not match pid 1234
SS_STALE='LISTEN 0      128          0.0.0.0:822        0.0.0.0:*    users:(("sshd",pid=1234,fd=3))
LISTEN 0      128          0.0.0.0:22         0.0.0.0:*    users:(("sshd",pid=1234,fd=4))
LISTEN 0      128             [::]:822           [::]:*    users:(("sshd",pid=1234,fd=5),("systemd",pid=1,fd=60))
LISTEN 0      128             [::]:22            [::]:*    users:(("sshd",pid=1234,fd=6))
LISTEN 0      4096         0.0.0.0:2200       0.0.0.0:*    users:(("sshd",pid=12345,fd=3))
LISTEN 0      50     127.0.0.53%lo:2222       0.0.0.0:*    users:(("endlessh",pid=99,fd=3))'
SS_MOVED='LISTEN 0      128          0.0.0.0:822        0.0.0.0:*    users:(("sshd",pid=1300,fd=3))
LISTEN 0      128             [::]:822           [::]:*    users:(("sshd",pid=1300,fd=4))
LISTEN 0      4096         0.0.0.0:2200       0.0.0.0:*    users:(("sshd",pid=12345,fd=3))'
got="$(pid_listen_ports 1234 <<<"$SS_STALE" | paste -sd' ' -)"
[[ $got == '822 22 822 22' ]] || fail "pid_listen_ports: got '$got', want '822 22 822 22'"
got="$(printf '0.0.0.0:822 (Stream)\n[::]:22 (Stream)\n2201 (Stream)\n[::]:53 (Datagram)\n/run/x.sock (Stream)\n' | socket_listen_ports | paste -sd' ' -)"
[[ $got == '822 22 2201' ]] || fail "socket_listen_ports: got '$got', want '822 22 2201'"
got="$(printf '822 22 \n822\n2222 ' | ports_except 822)"
[[ $got == '22 2222 ' ]] || fail "ports_except: got '$got', want '22 2222 '"
got="$(ports_except 822 <<<'822 ')"
[[ -z $got ]] || fail "ports_except: the kept port alone gave '$got'"
pass 'pid_listen_ports, socket_listen_ports and ports_except read the listeners of one process, of a socket unit, and drop the kept port'

# Fakes for the commands the move helpers run: nothing reaches the host. "ss -Hltnp" prints $SS_OUT,
# restart_ssh records itself and swaps in $SS_AFTER and pid 1300, "run" only records.
LOG_FILE="$tmp/run.log"
SSH_PORT=822
systemctl() {
    case "$*" in
        'show -p MainPID --value ssh.service') printf '%s\n' "$MAINPID" ;;
        'show -p Listen --value ssh.socket') printf '%s\n' "$SOCKET_LISTEN" ;;
        *) printf 'systemctl %s\n' "$*" >> "$tmp/calls" ;;
    esac
}
ss() {
    case "$*" in
        -Hltnp) printf '%s\n' "$SS_OUT" ;;
        "-ltn sport = :$SSH_PORT") grep -E ":$SSH_PORT " <<<"$SS_OUT" ;;
    esac
}
sshd() { [[ $1 == -T ]] && printf '%s' "$SSHD_T"; }
ufw_status() { [[ $1 == numbered ]] && printf '%s\n' "$UFW_NUMBERED"; }
run() { printf '%s\n' "$*" >> "$tmp/calls"; }
restart_ssh() {
    printf 'restart_ssh\n' >> "$tmp/calls"
    [[ $RESTART_RC -eq 0 ]] || return "$RESTART_RC"
    SS_OUT="$SS_AFTER"; MAINPID=1300
}
sleep() { :; }
rb="$tmp/rollback-ssh.sh"
printf '#!/bin/bash\nprintf "rollback-ssh.sh\\n" >> %q\n' "$tmp/calls" > "$rb"
UFW_TEMP='Status: active

     To                         Action      From
     --                         ------      ----
[ 1] 822/tcp                    ALLOW IN    192.168.1.50               # ssh admin
[ 2] 22/tcp                     ALLOW IN    192.168.1.50               # server-prep-temp admin
[ 3] 822/tcp (v6)               ALLOW IN    Anywhere (v6)              # ssh tailscale
[ 4] 22/tcp (v6)                ALLOW IN    Anywhere (v6)              # server-prep-temp tailscale'
UFW_CLEAN='Status: active

     To                         Action      From
     --                         ------      ----
[ 1] 822/tcp                    ALLOW IN    192.168.1.50               # ssh admin'

reset() {   # a host whose phase B failed: sshd still on 22, its temporary UFW rules kept; the cause is gone
    DRY_RUN=0; SSH_SOCKET=0; MAINPID=1234; SOCKET_LISTEN=''; RESTART_RC=0
    SS_OUT="$SS_STALE"; SS_AFTER="$SS_MOVED"
    SSHD_T=$'port 822\naddressfamily any\n'
    UFW_NUMBERED="$UFW_TEMP"
    STEP_CHANGED=0; STEP_NOTES=''; MANUAL_TODO=()
    : > "$tmp/calls"
}
calls() { paste -sd';' - < "$tmp/calls"; }
no_yes() {   # no_yes LABEL: every todo runs the SSH step with a dry run first and never with --yes
    local t
    for t in "${MANUAL_TODO[@]}"; do
        [[ $t == *--yes* ]] && fail "$1: a todo proposes --yes for the SSH step: $t"
        [[ $t == *'--only ssh'* && $t != *--dry-run* ]] && fail "$1: a todo runs the SSH step without a dry run first: $t"
    done
    return 0
}

reset
got="$(ssh_listen_ports)"
[[ $got == '822 22 ' ]] || fail "ssh_listen_ports: got '$got', want '822 22 '"
SSH_SOCKET=1; MAINPID=0; SOCKET_LISTEN=$'0.0.0.0:822 (Stream)\n[::]:22 (Stream)'
got="$(ssh_listen_ports)"
[[ $got == '822 22 ' ]] || fail "ssh_listen_ports: ssh.socket with no sshd running gave '$got', want '822 22 '"
pass "ssh_listen_ports reads the ports of ssh.service's sshd and of ssh.socket, not another sshd's"

# --- ssh_close_old_ports: deletes the temporary rules only when SSH has no old port left --------------
reset
SS_OUT="$SS_MOVED"; MAINPID=1300
ssh_close_old_ports || fail "ssh_close_old_ports: failed with SSH on 822 only: $STEP_NOTES"
[[ $(calls) == 'ufw --force delete 4;ufw --force delete 2' ]] ||
    fail "ssh_close_old_ports: got '$(calls)', want the temporary rules deleted, highest number first"
reset
SSHD_T=$'port 822\nport 22\n'; SS_OUT="$SS_MOVED"; MAINPID=1300
ssh_close_old_ports && fail 'ssh_close_old_ports: passed while sshd -T still lists port 22'
[[ -z $(calls) ]] || fail "ssh_close_old_ports: deleted rules while port 22 is left: $(calls)"
[[ ${MANUAL_TODO[*]} == *'port(s) 22:'* && ${MANUAL_TODO[*]} == *'grep -RniE'* ]] ||
    fail "ssh_close_old_ports: the todo does not name port 22 or follow symlinks: ${MANUAL_TODO[*]}"
no_yes 'ssh_close_old_ports, sshd -T'
reset
ssh_close_old_ports && fail 'ssh_close_old_ports: passed while sshd still listens on 22'
[[ -z $(calls) ]] || fail "ssh_close_old_ports: deleted rules while sshd listens on 22: $(calls)"
reset
SSH_SOCKET=1; SS_OUT="$SS_MOVED"; MAINPID=1300; SOCKET_LISTEN=$'0.0.0.0:822 (Stream)\n0.0.0.0:22 (Stream)'
ssh_close_old_ports && fail 'ssh_close_old_ports: passed while ssh.socket still listens on 22'
reset
SSHD_T=''
ssh_close_old_ports && fail 'ssh_close_old_ports: passed while sshd -T failed'
[[ -z $(calls) ]] || fail "ssh_close_old_ports: deleted rules while sshd -T failed: $(calls)"
no_yes 'ssh_close_old_ports, sshd -T failed'
pass 'ssh_close_old_ports deletes the temporary rules once sshd -T and the listeners show only the new port, and keeps them otherwise with a todo'

# --- ssh_finish_move: a re-run finishes a move whose phase B failed --------------------------------
reset
ssh_finish_move "$rb" || fail "ssh_finish_move: the re-run failed: $STEP_NOTES"
[[ $(calls) == 'restart_ssh;ufw --force delete 4;ufw --force delete 2' ]] ||
    fail "ssh_finish_move: got '$(calls)', want SSH restarted, then the temporary rules deleted"
[[ $STEP_CHANGED -eq 1 && $STEP_NOTES == *'old port(s) 22 closed'* && $STEP_NOTES != *'already secured'* ]] ||
    fail "ssh_finish_move: the re-run reports '$STEP_NOTES' (changed=$STEP_CHANGED)"
pass 'ssh_finish_move restarts SSH still on the old port, then deletes its temporary rules, and reports a change'

reset
SS_OUT="$SS_MOVED"; MAINPID=1300; UFW_NUMBERED="$UFW_CLEAN"
ssh_finish_move "$rb" || fail "ssh_finish_move: a finished move failed: $STEP_NOTES"
[[ -z $(calls) && $STEP_CHANGED -eq 0 && $STEP_NOTES == 'SSH already secured' ]] ||
    fail "ssh_finish_move: a finished move gave calls '$(calls)', notes '$STEP_NOTES', changed=$STEP_CHANGED"
reset
SS_OUT="$SS_MOVED"; MAINPID=1300
ssh_finish_move "$rb" || fail "ssh_finish_move: only the temporary rules left failed: $STEP_NOTES"
[[ $(calls) == 'ufw --force delete 4;ufw --force delete 2' && $STEP_CHANGED -eq 1 ]] ||
    fail "ssh_finish_move: only the temporary rules left gave '$(calls)', changed=$STEP_CHANGED"
pass 'ssh_finish_move changes nothing on a finished move, and deletes leftover temporary rules without a restart'

reset
DRY_RUN=1
ssh_finish_move "$rb" || fail 'ssh_finish_move: the dry run failed'
[[ -z $(calls) && $STEP_CHANGED -eq 1 && $STEP_NOTES == 'would finish an earlier move to 822:'* ]] ||
    fail "ssh_finish_move: the dry run gave calls '$(calls)', notes '$STEP_NOTES', changed=$STEP_CHANGED"
reset
SS_OUT='LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1234,fd=3))'
ssh_finish_move "$rb" && fail 'ssh_finish_move: restarted although sshd never listened on 822'
[[ -z $(calls) ]] || fail "ssh_finish_move: sshd not on 822 yet gave '$(calls)', want no restart and no delete"
no_yes 'ssh_finish_move, sshd not on 822'
reset
RESTART_RC=1
ssh_finish_move "$rb" 2>/dev/null && fail 'ssh_finish_move: passed although the restart failed'
[[ $(calls) == 'restart_ssh;rollback-ssh.sh' ]] || fail "ssh_finish_move: a failed restart gave '$(calls)'"
reset
SS_AFTER=''
ssh_finish_move "$rb" 2>/dev/null && fail 'ssh_finish_move: passed although sshd left 822 after the restart'
[[ $(calls) == 'restart_ssh;rollback-ssh.sh' ]] || fail "ssh_finish_move: no listener after the restart gave '$(calls)'"
pass 'ssh_finish_move only says what it would do in a dry run, never restarts SSH that is not on the new port yet, and rolls back a failed restart'
