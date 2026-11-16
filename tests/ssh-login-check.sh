#!/usr/bin/env bash
# shellcheck disable=SC2034   # ASSUME_YES, FORCE, LOG_FILE... are read by the sourced functions
# Tests what --yes and --yes --force answer (issue #65): confirm() returns each question's own default
# under --yes, and yes only with --force; the Docker restart and the SSH step's no-key guard follow it.
# Then the automatic login check that replaces the operator's test in a run with --yes: the sshd -T
# matcher (AllowUsers, DenyUsers, the groups, PubkeyAuthentication, AuthenticationMethods) and the
# AuthorizedKeysFile paths on sample text, ssh_login_check with fake sshd, ss and ssh-keyscan, and
# step_ssh's choice: phase B and the timer stopped when the check passes; the old port, its temporary
# UFW rules and the rollback timer kept when it fails; with --yes --force and no admin key, the check
# skips only its key check. Only a temporary folder is written: no root needed, nothing on the host is
# touched.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! tmp="$(mktemp -d)" || [[ -z $tmp || ! -d $tmp ]]; then
    printf 'not ok: mktemp -d failed, no temporary directory for the SSH login check tests\n'
    exit 1
fi
trap 'rm -rf "$tmp"' EXIT

# Load the real functions without starting a run (see tests/exit-status.sh).
# shellcheck disable=SC1091
. "$SCRIPT_DIR/server-prep.sh" --yes

fail() { printf 'not ok: %s\n' "$*"; exit 1; }
pass() { printf 'ok: %s\n' "$*"; }
LOG_FILE="$tmp/run.log"
: > "$LOG_FILE"

# --- confirm: --yes gives the default, --yes --force gives yes ---------------------------------------
[[ $ASSUME_YES -eq 1 && $INTERACTIVE -eq 0 && $FORCE -eq 0 ]] || fail "--yes gave ASSUME_YES=$ASSUME_YES INTERACTIVE=$INTERACTIVE FORCE=$FORCE"
confirm 'Restart now?' no > /dev/null && fail 'confirm: --yes answered yes to a default-no question'
confirm 'Proceed?' yes > /dev/null || fail 'confirm: --yes answered no to a default-yes question'
out="$(confirm 'Restart now?' no)"
[[ $out == *'Restart now? no (--yes keeps the default)'* ]] || fail "confirm: --yes does not say what it answered: '$out'"
FORCE=1
confirm 'Restart now?' no > /dev/null || fail 'confirm: --yes --force answered no to a default-no question'
confirm 'Proceed?' yes > /dev/null || fail 'confirm: --yes --force answered no to a default-yes question'
FORCE=0
st=0
out="$( (confirm 'No default?') 2>&1)" || st=$?
[[ $st -eq 1 && $out == *'confirm: no default'* ]] || fail "confirm without a default gave status $st: '$out'"
pass 'confirm: --yes answers each default, --yes --force answers yes, and a question without a default stops the run'

# The flags as parsed from the command line, in a fresh shell
got="$(bash -c '. "$1" --yes --force; echo "$ASSUME_YES $INTERACTIVE $FORCE"' _ "$SCRIPT_DIR/server-prep.sh" 2>&1)"
[[ $got == '1 0 1' ]] || fail "--yes --force gave '$got', want ASSUME_YES=1 INTERACTIVE=0 FORCE=1"
pass '--yes --force sets ASSUME_YES and FORCE'

# --- step_docker: running containers restart only with --yes --force --------------------------------
if command -v jq > /dev/null 2>&1; then
    real_have="$(declare -f have)"
    have() { [[ $1 == docker || $1 == jq ]]; }
    docker() { [[ "$*" == 'ps -q' ]] && printf 'c1\nc2\n'; return 0; }
    pkg_install() { :; }
    pkg_from() { return 1; }        # Docker not from download.docker.com: its repository is left as it is
    docker_repo() { fail 'step_docker set up the Docker repository'; }
    OS_ID=debian; OS_CODENAME=trixie
    write_file() { cat > /dev/null; changed; }
    run() { printf '%s\n' "$*" >> "$tmp/calls"; }
    # this host's daemon.json, if any, reads as {}: the step always has log rotation to add
    cat() { if [[ "$*" == /etc/docker/daemon.json ]]; then echo '{}'; else command cat "$@"; fi; }
    INSTALL_DOCKER=yes; DRY_RUN=0
    expect_docker_restart() {   # expect_docker_restart FORCE yes|no
        FORCE="$1"; STEP_NOTES=''; MANUAL_TODO=(); : > "$tmp/calls"
        step_docker > "$tmp/docker-out" 2>&1 || fail "step_docker failed with FORCE=$1: $(cat "$tmp/docker-out")"
        if [[ $2 == yes ]]; then
            grep -qx 'systemctl restart docker' "$tmp/calls" || fail "--yes --force did not restart Docker: $(paste -sd';' "$tmp/calls")"
        else
            grep -q 'restart docker' "$tmp/calls" && fail '--yes restarted Docker with running containers'
            [[ ${MANUAL_TODO[*]} == *'Restart Docker when convenient'* ]] || fail "--yes left no todo to restart Docker: ${MANUAL_TODO[*]}"
        fi
    }
    expect_docker_restart 0 no
    expect_docker_restart 1 yes
    pass 'step_docker: --yes keeps running containers up and adds a todo, --yes --force restarts Docker'
    FORCE=0
    eval "$real_have"
    unset -f docker pkg_install pkg_from docker_repo write_file run cat
else
    printf 'skip: step_docker restart (jq not found)\n'
fi

# --- ssh_glob, ssh_host_match, ssh_user_match: OpenSSH's patterns -----------------------------------
yes_() { "$@" || fail "want a match: $*"; }
no_() { "$@" && fail "want no match: $*"; return 0; }
yes_ ssh_glob admin admin
yes_ ssh_glob admin 'adm*'
yes_ ssh_glob admin 'a?min'
no_ ssh_glob admin '[ab]dmin'          # [ is literal in OpenSSH
yes_ ssh_glob '[ab]dmin' '[ab]dmin'
no_ ssh_glob admin Admin               # user names compare as they are
yes_ ssh_host_match localhost 127.0.0.1 '127.0.0.0/8'
yes_ ssh_host_match localhost 127.0.0.1 '0.0.0.0/0'
yes_ ssh_host_match localhost 127.0.0.1 '127.0.0.1/32'
yes_ ssh_host_match localhost 127.0.0.1 '127.0.0.*'
yes_ ssh_host_match localhost 127.0.0.1 'LOCALHOST'
yes_ ssh_host_match localhost 127.0.0.1 '192.0.2.1,*'
no_ ssh_host_match localhost 127.0.0.1 '198.51.100.2,100.64.0.0/10'
no_ ssh_host_match localhost 127.0.0.1 '10.0.0.0/8'
no_ ssh_host_match localhost 127.0.0.1 '::1/128'
no_ ssh_host_match localhost 127.0.0.1 '!127.0.0.1,*'
no_ ssh_host_match localhost 127.0.0.1 '*,!localhost'
yes_ ssh_user_match admin localhost 127.0.0.1 admin
yes_ ssh_user_match admin localhost 127.0.0.1 'admin@127.0.0.0/8'
yes_ ssh_user_match admin localhost 127.0.0.1 '*@localhost'
no_ ssh_user_match admin localhost 127.0.0.1 'admin@192.168.1.0/24'
no_ ssh_user_match admin localhost 127.0.0.1 'root@127.0.0.1'
pass 'ssh_glob, ssh_host_match and ssh_user_match read wildcards, CIDRs, negations and user@host like OpenSSH'

# --- sshd_login_refused: "sshd -T -C user=admin,..." output, as OpenSSH 10 prints it ------------------
# what 00-server-prep.conf gives with a panel on Tailscale and a public IP
T_PREP='port 822
permitrootlogin no
pubkeyauthentication yes
authorizedkeysfile .ssh/authorized_keys .ssh/authorized_keys2
allowusers admin
allowusers root@198.51.100.2,100.64.0.0/10
authenticationmethods publickey'
refused() {   # refused LABEL WANT ("" = allowed) EXTRA_SSHD_T [GROUPS]
    local got
    got="$(printf '%s\n%s\n' "$T_PREP" "$3" | sshd_login_refused admin "${4:-admin sudo}" localhost 127.0.0.1)"
    if [[ -z $2 ]]; then
        [[ -z $got ]] || fail "sshd_login_refused $1: refused with '$got', want allowed"
    else
        [[ $got == *"$2"* ]] || fail "sshd_login_refused $1: gave '$got', want '$2'"
    fi
}
refused "server-prep's config" '' ''
got="$(printf 'port 822\nallowusers root@198.51.100.2\n' | sshd_login_refused admin 'admin sudo' localhost 127.0.0.1)"
[[ $got == 'AllowUsers does not list admin for 127.0.0.1' ]] || fail "sshd_login_refused, root only in AllowUsers: gave '$got'"
refused 'AllowUsers admin@ the loopback' '' 'allowusers admin@127.0.0.0/8'
refused 'DenyUsers adm*' 'DenyUsers has adm*' 'denyusers adm*'
refused 'DenyUsers for another user' '' 'denyusers bob'
refused 'AllowGroups wheel' 'AllowGroups lists no group of admin' 'allowgroups wheel'
refused 'AllowGroups sudo' '' 'allowgroups sudo'
refused 'AllowGroups and a user with no group' 'AllowGroups lists no group of admin' 'allowgroups sudo' ' '
refused 'DenyGroups su*' 'DenyGroups has su* (group sudo)' 'denygroups su*'
refused 'PubkeyAuthentication no' 'PubkeyAuthentication is no' 'pubkeyauthentication no'
refused 'AuthenticationMethods with a password' 'asks for more than a key' 'authenticationmethods publickey,password'
refused 'AuthenticationMethods with a key-only list' '' 'authenticationmethods publickey,password publickey'
refused 'AuthenticationMethods any' '' 'authenticationmethods any'
pass 'sshd_login_refused names the AllowUsers, DenyUsers, group, PubkeyAuthentication or AuthenticationMethods line that refuses the admin, and nothing for server-prep'"'"'s config'

# --- authorized_keys_paths: the AuthorizedKeysFile files of the admin --------------------------------
got="$(authorized_keys_paths admin /home/admin 1001 <<<"$T_PREP" | paste -sd' ' -)"
[[ $got == '/home/admin/.ssh/authorized_keys /home/admin/.ssh/authorized_keys2' ]] ||
    fail "authorized_keys_paths: the default gave '$got'"
got="$(printf 'authorizedkeysfile %%h/k /etc/ssh/keys/%%u /k/%%U/%%%%h none\n' |
    authorized_keys_paths admin '/home/a&b' 1001 | paste -sd' ' -)"
[[ $got == '/home/a&b/k /etc/ssh/keys/admin /k/1001/%h' ]] || fail "authorized_keys_paths: tokens gave '$got'"
got="$(authorized_keys_paths admin /home/admin 1001 <<<'authorizedkeysfile none')"
[[ -z $got ]] || fail "authorized_keys_paths: none gave '$got'"
pass 'authorized_keys_paths expands %h, %u, %U and %%, puts a relative path under the home and skips none'

# --- ssh_login_check: each check, with fake sshd, ss and ssh-keyscan --------------------------------
test_home="$tmp/home/admin"   # not "home": the functions under test have a local of that name
mkdir -p "$test_home/.ssh"
ssh-keygen -q -t ed25519 -N '' -C admin@example.com -f "$tmp/admin-key" > /dev/null || fail 'ssh-keygen could not make a test key'
ADMIN_USER='admin'
SSH_PORT=822
getent() { [[ "$*" == 'passwd admin' ]] && printf 'admin:x:1001:1001::%s:/bin/bash\n' "$test_home"; }
id() {
    case "$*" in
        '-u admin') echo 1001 ;;
        '-Gn admin') echo 'admin sudo' ;;
        *) command id "$@" ;;
    esac
}
ssh_listen_ports() { printf '%s' "$LISTEN"; }
sshd() {
    case "$1" in
        -t) return "${SSHD_T_RC:-0}" ;;
        -T) [[ $* == *user=root* ]] && { printf 'permitrootlogin no\n'; return 0; }
            [[ -n $SSHD_T ]] && printf '%s\n' "$SSHD_T"; return "${SSHD_T_RC:-0}" ;;
    esac
}
timeout() { shift; "$@"; }
ssh-keyscan() {   # stdout gets the host keys after a key exchange; the banner comment goes to stderr
    [[ "$*" == "-T 10 -p $SSH_PORT 127.0.0.1" ]] || return 1
    printf '# 127.0.0.1:%s SSH-2.0-OpenSSH_10.0\n' "$SSH_PORT" >&2
    [[ $KEYSCAN -eq 1 ]] && printf '[127.0.0.1]:%s ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample\n' "$SSH_PORT"
    return 0
}
reset_check() {   # every check passes
    LISTEN='822 22 '; SSHD_T="$T_PREP"; SSHD_T_RC=0; KEYSCAN=1
    printf 'from="198.51.100.2" %s\n' "$(cat "$tmp/admin-key.pub")" > "$test_home/.ssh/authorized_keys"
}
expect_check() {   # expect_check LABEL ok|fail [TEXT in SSH_CHECK_FAILED, or in SSH_CHECK_PASSED when ok]
    local st=0
    ssh_login_check > "$tmp/check-out" 2>&1 || st=$?
    if [[ $2 == ok ]]; then
        [[ $st -eq 0 && -z $SSH_CHECK_FAILED && $SSH_CHECK_PASSED == *"${3:-}"* ]] ||
            fail "ssh_login_check $1: status $st, failed '$SSH_CHECK_FAILED', passed '$SSH_CHECK_PASSED'"
    else
        [[ $st -ne 0 && $SSH_CHECK_FAILED == *"$3"* ]] ||
            fail "ssh_login_check $1: status $st, failed '$SSH_CHECK_FAILED', want '$3'"
        local -a each=()
        local e
        mapfile -t each < <(sed 's/; /\n/g' <<<"$3")
        for e in "${each[@]}"; do
            grep -qF "login check: $e" "$tmp/check-out" || fail "ssh_login_check $1: the failed check '$e' is not shown: $(cat "$tmp/check-out")"
        done
    fi
}
reset_check
expect_check 'with everything in place' ok 'sshd listens on 822; sshd allows a key login of admin; admin has 1 SSH key(s); SSH handshake on 127.0.0.1:822'
for t in 'sshd listens on 822' 'sshd allows a key login of admin' 'admin has 1 SSH key(s)' 'SSH handshake on 127.0.0.1:822'; do
    grep -qF "login check: $t" "$tmp/check-out" || fail "ssh_login_check does not show the check '$t'"
    grep -qF "OK: login check: $t" "$LOG_FILE" || fail "ssh_login_check does not log the check '$t'"
done
reset_check; LISTEN='22 '
expect_check 'with sshd not on the new port' fail 'sshd does not listen on 822 (it listens on: 22)'
reset_check; SSHD_T="$(printf '%s\n' "$T_PREP" | grep -v '^allowusers admin$')"
expect_check 'with the admin missing from AllowUsers' fail 'sshd refuses a key login of admin: AllowUsers does not list admin'
reset_check; SSHD_T=''; SSHD_T_RC=255
expect_check 'with sshd -T failing' fail 'sshd -T could not read the configuration for admin'
[[ $SSH_CHECK_FAILED != *'SSH key'* && $SSH_CHECK_PASSED == *"admin has 1 SSH key(s) (OpenSSH's default AuthorizedKeysFile, as sshd -T failed)"* ]] ||
    fail "ssh_login_check with sshd -T failing: the keys are not counted in the default files: failed '$SSH_CHECK_FAILED', passed '$SSH_CHECK_PASSED'"
reset_check; SSHD_T=''; SSHD_T_RC=255; : > "$test_home/.ssh/authorized_keys"
expect_check 'with sshd -T failing and no key' fail "sshd -T could not read the configuration for admin; admin has no SSH key in its authorized_keys (OpenSSH's default AuthorizedKeysFile, as sshd -T failed)"
reset_check; printf '# no key yet\n' > "$test_home/.ssh/authorized_keys"
expect_check 'with no key for the admin' fail 'admin has no SSH key in its authorized_keys'
[[ $SSH_CHECK_FAILED != *AuthorizedKeysCommand* ]] || fail "ssh_login_check with no key: names an AuthorizedKeysCommand: '$SSH_CHECK_FAILED'"
reset_check; printf '# no key yet\n' > "$test_home/.ssh/authorized_keys"
SSHD_T="$(printf '%s\nauthorizedkeyscommand none\n' "$T_PREP")"
expect_check 'with no key and AuthorizedKeysCommand none' fail 'admin has no SSH key in its authorized_keys'
reset_check; printf '# no key yet\n' > "$test_home/.ssh/authorized_keys"
SSHD_T="$(printf '%s\nauthorizedkeyscommand /usr/local/bin/fetch-keys %%u\n' "$T_PREP")"
expect_check 'with keys from an AuthorizedKeysCommand' fail 'admin has no SSH key in its AuthorizedKeysFile (keys from AuthorizedKeysCommand are not checked)'
reset_check; rm -f "$test_home/.ssh/authorized_keys"; cp "$tmp/admin-key.pub" "$test_home/.ssh/authorized_keys2"
expect_check 'with the key in authorized_keys2' ok 'admin has 1 SSH key(s)'
rm -f "$test_home/.ssh/authorized_keys2"
reset_check; KEYSCAN=0
expect_check 'with no SSH handshake' fail 'no SSH handshake on 127.0.0.1:822'
reset_check; LISTEN=''; KEYSCAN=0
expect_check 'with two checks failing' fail 'sshd does not listen on 822 (it listens on: nothing); no SSH handshake on 127.0.0.1:822'
pass 'ssh_login_check logs each check and fails, naming it, when sshd is not on the new port, refuses the admin, the admin has no key or no handshake works'

# A ListenAddress without 0.0.0.0 or 127.0.0.1: the handshake failure says why
reset_check; KEYSCAN=0; SSHD_T="$(printf '%s\nlistenaddress 192.0.2.10:822\n' "$T_PREP")"
expect_check 'with sshd on another address only' fail "no SSH handshake on 127.0.0.1:822 (sshd's ListenAddress leaves out 127.0.0.1"
reset_check; KEYSCAN=0; SSHD_T="$(printf '%s\nlistenaddress [::]:822\nlistenaddress 0.0.0.0:822\n' "$T_PREP")"
expect_check 'with sshd on every address and no handshake' fail 'no SSH handshake on 127.0.0.1:822'
[[ $SSH_CHECK_FAILED != *ListenAddress* ]] || fail "ssh_login_check, sshd on 0.0.0.0: blames ListenAddress: '$SSH_CHECK_FAILED'"
pass 'ssh_login_check names ListenAddress when sshd listens on no address 127.0.0.1 can reach'

# nokey (--yes --force went past the no-key guard): only the key check is skipped, and the skip is logged
reset_check; : > "$test_home/.ssh/authorized_keys"
skip_text='key check skipped (--force): admin has no SSH key and can log in only on the console'
st=0; ssh_login_check nokey > "$tmp/check-out" 2>&1 || st=$?
[[ $st -eq 0 && -z $SSH_CHECK_FAILED && $SSH_CHECK_SKIPPED == "$skip_text" &&
    $SSH_CHECK_PASSED == 'sshd listens on 822; sshd allows a key login of admin; SSH handshake on 127.0.0.1:822' ]] ||
    fail "ssh_login_check nokey: status $st, failed '$SSH_CHECK_FAILED', skipped '$SSH_CHECK_SKIPPED', passed '$SSH_CHECK_PASSED'"
grep -qF "login check: $skip_text" "$tmp/check-out" || fail "ssh_login_check nokey: the skip is not shown: $(cat "$tmp/check-out")"
grep -qF "WARN: login check: $skip_text" "$LOG_FILE" || fail 'ssh_login_check nokey: the skip is not logged as a warning'
reset_check; : > "$test_home/.ssh/authorized_keys"; KEYSCAN=0
st=0; ssh_login_check nokey > "$tmp/check-out" 2>&1 || st=$?
[[ $st -ne 0 && $SSH_CHECK_FAILED == 'no SSH handshake on 127.0.0.1:822' && $SSH_CHECK_SKIPPED == "$skip_text" ]] ||
    fail "ssh_login_check nokey, no handshake: status $st, failed '$SSH_CHECK_FAILED', skipped '$SSH_CHECK_SKIPPED'"
reset_check
expect_check 'without nokey' ok 'admin has 1 SSH key(s)'
[[ -z $SSH_CHECK_SKIPPED ]] || fail "ssh_login_check without nokey skipped '$SSH_CHECK_SKIPPED'"
pass 'ssh_login_check nokey skips only the key check, logs the skip, and still fails on another check'

# --- step_ssh with --yes: the check decides between phase B and the rollback -------------------------
# Fakes for everything that would reach the host. write_sshd_config records the ports it writes; the
# old port is 22, the new one 822.
BACKUP_DIR="$tmp/backup"; mkdir -p "$BACKUP_DIR"
TS=20261115_120000
CURRENT_SSH_PORTS='22 '
DRY_RUN=0; SSH_SOCKET=0
compute_root_sources() { ROOT_SOURCES=(); }
sshd_port_dropins() { :; }
sshd_ports_in() { command cat > /dev/null; }   # this host's sshd_config adds no old port: only CURRENT_SSH_PORTS
backup_file() { :; }
write_sshd_config() { printf 'write_sshd_config %s\n' "$1" >> "$tmp/calls"; changed; }
run() { printf '%s\n' "$*" >> "$tmp/calls"; }
restart_ssh() { printf 'restart_ssh\n' >> "$tmp/calls"; }
ss() { printf 'LISTEN 0 128 0.0.0.0:822 0.0.0.0:*\n'; }
sleep() { :; }
ssh_close_old_ports() { printf 'ssh_close_old_ports\n' >> "$tmp/calls"; }
real_check="$(declare -f ssh_login_check)"
ssh_login_check() {
    SSH_CHECK_PASSED='sshd listens on 822'; SSH_CHECK_FAILED=''
    [[ $CHECK_RC -eq 0 ]] || SSH_CHECK_FAILED='no SSH handshake on 127.0.0.1:822'
    return "$CHECK_RC"
}
timer="server-prep-ssh-rollback-$TS.timer"
reset_step() {
    STEP_CHANGED=0; STEP_NOTES=''; MANUAL_TODO=(); FORCE=0; CHECK_RC=0
    : > "$tmp/calls"
    printf '%s\n' "$(cat "$tmp/admin-key.pub")" > "$test_home/.ssh/authorized_keys"
}
calls() { paste -sd';' - < "$tmp/calls"; }
no_yes() {   # as in tests/sshd-ports.sh: a todo for the SSH step has a dry run first and never --yes
    local t
    for t in "${MANUAL_TODO[@]}"; do
        [[ $t == *--yes* ]] && fail "$1: a todo proposes --yes for the SSH step: $t"
        [[ $t == *'--only ssh'* && $t != *--dry-run* ]] && fail "$1: a todo runs the SSH step without a dry run first: $t"
    done
    return 0
}

reset_step
st=0; step_ssh > "$tmp/step-out" 2>&1 || st=$?
[[ $st -eq 0 ]] || fail "step_ssh, check passed: status $st, notes '$STEP_NOTES'"
c="$(calls)"
[[ $c == *"systemd-run --on-active=600 --unit=server-prep-ssh-rollback-$TS"* && $c == *"systemctl stop $timer"* ]] ||
    fail "step_ssh, check passed: the timer is not armed then stopped: $c"
[[ $c == *'write_sshd_config 822;'* && $c == *'ssh_close_old_ports'* ]] || fail "step_ssh, check passed: no phase B: $c"
[[ $STEP_NOTES == *'automatic login check passed (sshd listens on 822)'* && $STEP_NOTES == *'old SSH port(s) 22 closed'* ]] ||
    fail "step_ssh, check passed: notes '$STEP_NOTES'"
[[ ${#MANUAL_TODO[@]} -eq 0 ]] || fail "step_ssh, check passed: todo '${MANUAL_TODO[*]}'"
pass 'step_ssh with --yes: a passed login check runs phase B and stops the rollback timer'

reset_step; CHECK_RC=1
st=0; step_ssh > "$tmp/step-out" 2>&1 || st=$?
[[ $st -eq 1 ]] || fail "step_ssh, check failed: status $st, want 1"
c="$(calls)"
[[ $c == *"systemd-run --on-active=600 --unit=server-prep-ssh-rollback-$TS"* ]] || fail "step_ssh, check failed: no timer: $c"
[[ $c == *"stop $timer"* ]] && fail "step_ssh, check failed: the timer is stopped: $c"
[[ $c == *'write_sshd_config 822;'* || $c == *ssh_close_old_ports* ]] && fail "step_ssh, check failed: phase B ran: $c"
[[ $c =~ write_sshd_config\ 22\ +822\; ]] || fail "step_ssh, check failed: phase A did not keep port 22: $c"
[[ $STEP_NOTES == *'automatic login check failed (no SSH handshake on 127.0.0.1:822): old SSH port(s) 22 and their temporary UFW rules kept'* ]] ||
    fail "step_ssh, check failed: notes '$STEP_NOTES'"
[[ ${MANUAL_TODO[*]} == *'no SSH handshake'* && ${MANUAL_TODO[*]} == *"$timer"* && ${MANUAL_TODO[*]} == *"$SSH_AGAIN --dry-run"* ]] ||
    fail "step_ssh, check failed: the todo does not say which check failed, the timer and how to finish: ${MANUAL_TODO[*]}"
no_yes 'step_ssh, check failed'
pass 'step_ssh with --yes: a failed login check keeps the old port and its UFW rules, leaves the rollback timer armed and says how to finish'

reset_step; : > "$test_home/.ssh/authorized_keys"
st=0; step_ssh > "$tmp/step-out" 2>&1 || st=$?
[[ $st -eq $SKIP_RC && $STEP_NOTES == *'aborted: no SSH key for admin'* && -z $(calls) ]] ||
    fail "step_ssh, no key, --yes: status $st, notes '$STEP_NOTES', calls '$(calls)'"
grep -qF 'Continue anyway (I have console/physical access)? no (--yes keeps the default)' "$tmp/step-out" ||
    fail "step_ssh, no key, --yes: the answer is not shown: $(cat "$tmp/step-out")"
pass 'step_ssh with --yes and no admin key: the guard keeps its default (no) and the step changes nothing'

# --yes --force goes past the guard; the real login check then skips only its key check
eval "$real_check"
run_forced() {   # run_forced: step_ssh with --yes --force, no admin key and the real login check
    reset_step; : > "$test_home/.ssh/authorized_keys"; FORCE=1
    LISTEN='822 22 '; SSHD_T="$T_PREP"; SSHD_T_RC=0; KEYSCAN="$1"
    st=0; step_ssh > "$tmp/step-out" 2>&1 || st=$?
    c="$(calls)"
}
run_forced 1
[[ $st -eq 0 && $c =~ write_sshd_config\ 22\ +822\; && $c == *systemd-run* && $c == *"systemctl stop $timer"* &&
    $c == *'write_sshd_config 822;'* && $c == *ssh_close_old_ports* ]] ||
    fail "step_ssh, no key, --yes --force: status $st, calls '$c', notes '$STEP_NOTES'"
grep -qF 'Continue anyway (I have console/physical access)? yes (--force)' "$tmp/step-out" ||
    fail "step_ssh, no key, --yes --force: the forced answer is not shown: $(cat "$tmp/step-out")"
grep -qF "login check: $skip_text" "$tmp/step-out" || fail "step_ssh, no key, --yes --force: the skip is not shown: $(cat "$tmp/step-out")"
[[ $STEP_NOTES == *'WARNING: admin has no SSH key'* &&
    $STEP_NOTES == *"automatic login check passed (sshd listens on 822; sshd allows a key login of admin; SSH handshake on 127.0.0.1:822); $skip_text"* &&
    $STEP_NOTES == *'old SSH port(s) 22 closed'* ]] ||
    fail "step_ssh, no key, --yes --force: notes '$STEP_NOTES'"
[[ ${#MANUAL_TODO[@]} -eq 1 && ${MANUAL_TODO[0]} == *'admin has no SSH key (--force skipped the key check'* && ${MANUAL_TODO[0]} == *'--only users --dry-run'* ]] ||
    fail "step_ssh, no key, --yes --force: todo '${MANUAL_TODO[*]}'"
no_yes 'step_ssh, no key, --yes --force'
pass 'step_ssh with --yes --force and no admin key: the login check skips only its key check and logs it, phase B runs and the timer stops'

run_forced 0
[[ $st -eq 1 && $c =~ write_sshd_config\ 22\ +822\; && $c == *systemd-run* && $c != *"stop $timer"* &&
    $c != *'write_sshd_config 822;'* && $c != *ssh_close_old_ports* ]] ||
    fail "step_ssh, no key, no handshake, --yes --force: status $st, calls '$c'"
[[ $STEP_NOTES == *"automatic login check failed (no SSH handshake on 127.0.0.1:822); $skip_text: old SSH port(s) 22 and their temporary UFW rules kept"* ]] ||
    fail "step_ssh, no key, no handshake, --yes --force: notes '$STEP_NOTES'"
[[ ${MANUAL_TODO[*]} == *'no SSH handshake'* && ${MANUAL_TODO[*]} != *'SSH key'* ]] ||
    fail "step_ssh, no key, no handshake, --yes --force: todo '${MANUAL_TODO[*]}'"
no_yes 'step_ssh, no key, no handshake, --yes --force'
pass 'step_ssh with --yes --force and no admin key: another failed check still keeps the old port and the rollback timer'

# --yes --force with a key: nothing is skipped, the key is counted
reset_step; FORCE=1
LISTEN='822 22 '; SSHD_T="$T_PREP"; SSHD_T_RC=0; KEYSCAN=1
st=0; step_ssh > "$tmp/step-out" 2>&1 || st=$?
[[ $st -eq 0 && $STEP_NOTES == *'admin has 1 SSH key(s)'* && $STEP_NOTES != *'key check skipped'* && ${#MANUAL_TODO[@]} -eq 0 ]] ||
    fail "step_ssh, key, --yes --force: status $st, notes '$STEP_NOTES', todo '${MANUAL_TODO[*]}'"
pass 'step_ssh with --yes --force and an admin key: the login check counts the key'
FORCE=0
