#!/usr/bin/env bash
# Tests fail2ban's whitelist (ignoreip) handling of issue #204. A jail.d/*.local file read after
# jail.local, such as the dokploy.local that Dokploy's server Security dialog writes, can set its own
# [DEFAULT] ignoreip and drop server-prep's addresses. The ips step adds them back in
# jail.d/zz-server-prep.local (f2b_prep_local in server-prep.sh), and the audit's ips.f2b_ignoreip
# reads the list (jail_option_set, f2b_files_ignoreip), compares it with the saved answers
# (prep_conf_value) and names what is missing (f2b_missing, ip_bits). All on sample files in a
# temporary folder. When fail2ban is installed here, its own parser also reads server-prep's file.
# No root needed, nothing on the host changes.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok: %s\n' "$*"; exit 1; }
pass() { printf 'ok: %s\n' "$*"; }

if ! tmp="$(mktemp -d)" || [[ -z $tmp || ! -d $tmp ]]; then
    fail 'mktemp -d failed, no temporary directory for the fail2ban whitelist tests'
fi
trap 'rm -rf "$tmp"' EXIT

# server-audit.sh runs its checks on load, so it cannot be sourced: take the functions only.
for fn in jail_option_set get_jail_option f2b_files_ignoreip ip_bits f2b_missing prep_conf_value; do
    eval "$(sed -n "/^${fn}() {/,/^}/p" "$SCRIPT_DIR/server-audit.sh")"
    declare -F "$fn" >/dev/null || fail "$fn not found in server-audit.sh"
done

# --- f2b_missing: which wanted addresses the list does not hold --------------------------------------
missing() {   # missing LABEL WANT WANTED LIST
    local got
    got="$(f2b_missing "$3" "$4")"
    [[ $got == "$2" ]] || fail "f2b_missing: $1: got '$got', want '$2'"
    pass "f2b_missing: $1"
}
missing 'the same addresses and networks' '' '100.64.0.0/10 192.0.2.10' '127.0.0.1/8 ::1 100.64.0.0/10 192.0.2.10'
missing 'what fail2ban-client prints: 127.0.0.0/8 holds 127.0.0.1/8' '' '127.0.0.1/8' '127.0.0.0/8'
missing 'an address inside a listed network' '' '198.51.100.7' '198.51.100.0/24'
missing 'a network inside a larger listed network' '' '198.51.100.0/25' '198.51.100.0/24'
missing 'a larger network is not held by a smaller one' '198.51.100.0/23' '198.51.100.0/23' '198.51.100.0/24'
missing 'a network is not held by one of its addresses' '198.51.100.0/24' '198.51.100.0/24' '198.51.100.1'
missing "Dokploy's list drops the tailnet and the admin address" '100.64.0.0/10 192.0.2.10' \
    '100.64.0.0/10 192.0.2.10 203.0.113.5' '127.0.0.1/8 ::1 203.0.113.5'
missing 'commas and newlines separate entries too' '192.0.2.11' '192.0.2.10,192.0.2.11' $'127.0.0.1/8\n192.0.2.10'
missing 'IPv6: another spelling of the same address' '' '2001:0db8:0:0:0:0:0:1' '2001:db8::1'
missing 'IPv6: an address inside a /48' '' '2001:db8:1:2::5' '2001:db8:1::/48'
missing 'IPv6: an address outside it' '2001:db8:2::5' '2001:db8:2::5' '2001:db8:1::/48'
missing 'IPv4 and IPv6 never hold each other' '192.0.2.10' '192.0.2.10' '::/0'
missing '0.0.0.0/0 holds every IPv4 address' '' '192.0.2.10 100.64.0.0/10' '0.0.0.0/0'
missing 'a host name must be listed as written' 'web-02.example.com' 'web-01.example.com web-02.example.com' 'WEB-01.example.com'
missing 'an empty list misses everything' '192.0.2.10' '192.0.2.10' ''
missing 'nothing wanted, nothing missing' '' '' '127.0.0.1/8'
missing 'a bad prefix is compared as text' '192.0.2.0/33' '192.0.2.0/33' '192.0.2.0/24'
[[ "$(ip_bits 192.0.2.1)" == 11000000000000000000001000000001 ]] || fail "ip_bits 192.0.2.1: $(ip_bits 192.0.2.1)"
[[ "$(ip_bits ::1 | wc -c)" -eq 128 && -z "$(ip_bits 256.1.1.1)" && -z "$(ip_bits 1::2::3)" && -z "$(ip_bits web-01)" ]] ||
    fail 'ip_bits: IPv6 is 128 bits, and 256.1.1.1, 1::2::3 and a host name give nothing'
pass 'ip_bits: 32 or 128 bits, nothing for a value that is not an address'

# --- the files, in fail2ban's read order -------------------------------------------------------------
F2B_DIR="$tmp/fail2ban"
mkdir -p "$F2B_DIR/jail.d"
# The stock files: no ignoreip in [DEFAULT] (commented out), and Debian's sshd jail
printf '[DEFAULT]\n#ignoreip = 127.0.0.1/8 ::1\nbantime = 10m\n\n[sshd]\nport = ssh\n' > "$F2B_DIR/jail.conf"
printf '[sshd]\nenabled = true\n' > "$F2B_DIR/jail.d/defaults-debian.conf"
# What the ips step writes to jail.local (step_ips), with ci.cfg's answers
cat > "$F2B_DIR/jail.local" <<'EOF'
# Managed by server-prep.sh
[DEFAULT]
bantime = 1h
backend = systemd
ignoreip = 127.0.0.1/8 ::1 100.64.0.0/10 198.51.100.2 198.51.100.2

[sshd]
enabled = true
port = 822
mode = aggressive
EOF
# What Dokploy 0.31 writes when its Fail2ban tab is saved, with an example address for the Dokploy host
DOKPLOY='# Managed by Dokploy
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
ignoreip = 127.0.0.1/8 ::1 203.0.113.5
banaction = nftables
banaction_allports = nftables[type=allports]

[sshd]
enabled = true
port = 822

[dokploy-manual]
enabled = true
filter =
backend = polling
logpath = /dev/null
banaction = %(banaction_allports)s
bantime = -1'

files() {   # files LABEL WANT-FILE WANT-LIST: what f2b_files_ignoreip gives
    local got want
    got="$(f2b_files_ignoreip)"
    want="$2"$'\t'"$3"
    [[ $got == "$want" ]] || fail "f2b_files_ignoreip: $1: got '${got//$'\t'/<TAB>}', want '${want//$'\t'/<TAB>}'"
    pass "f2b_files_ignoreip: $1"
}
files 'jail.local alone' "$F2B_DIR/jail.local" '127.0.0.1/8 ::1 100.64.0.0/10 198.51.100.2 198.51.100.2'
[[ "$(get_jail_option sshd port)" == 822 && "$(get_jail_option sshd enabled)" == true && -z "$(get_jail_option sshd ignoreip)" ]] ||
    fail 'get_jail_option: [sshd] port 822 and enabled true from jail.local, no [sshd] ignoreip'
pass 'get_jail_option still gives the last value in read order, "" when no file sets it'

printf '%s\n' "$DOKPLOY" > "$F2B_DIR/jail.d/dokploy.local"
files "dokploy.local is read after jail.local and replaces the list" "$F2B_DIR/jail.d/dokploy.local" '127.0.0.1/8 ::1 203.0.113.5'

# Load server-prep.sh's functions without starting a run (see tests/exit-status.sh).
# shellcheck disable=SC1091
. "$SCRIPT_DIR/server-prep.sh" --yes
declare -F f2b_prep_local >/dev/null || fail 'f2b_prep_local not found in server-prep.sh'
f2b_prep_local '127.0.0.1/8 ::1 100.64.0.0/10 198.51.100.2 198.51.100.2 ' > "$F2B_DIR/jail.d/zz-server-prep.local"
grep -qxF 'ignoreip = %(known/ignoreip)s 127.0.0.1/8 ::1 100.64.0.0/10 198.51.100.2 198.51.100.2' "$F2B_DIR/jail.d/zz-server-prep.local" ||
    fail "f2b_prep_local: no 'ignoreip = %(known/ignoreip)s <addresses>' line: $(cat "$F2B_DIR/jail.d/zz-server-prep.local")"
awk '/^\[/ {s = $0} /^ignoreip/ {print s}' "$F2B_DIR/jail.d/zz-server-prep.local" | grep -qxF '[sshd]' ||
    fail 'f2b_prep_local: ignoreip must be in [sshd], not [DEFAULT], where %(known/ignoreip)s points back to itself'
pass 'f2b_prep_local: [sshd] ignoreip = %(known/ignoreip)s and the addresses, separated by single spaces'
files "zz-server-prep.local keeps Dokploy's list and adds server-prep's addresses" "$F2B_DIR/jail.d/dokploy.local" \
    '127.0.0.1/8 ::1 203.0.113.5 127.0.0.1/8 ::1 100.64.0.0/10 198.51.100.2 198.51.100.2'
[[ -z "$(f2b_missing '100.64.0.0/10 198.51.100.2' "$(f2b_files_ignoreip | cut -f2)")" ]] ||
    fail 'with zz-server-prep.local, the list still misses an address'
pass 'with zz-server-prep.local, nothing is missing'
rm "$F2B_DIR/jail.d/dokploy.local"
files 'without Dokploy, zz-server-prep.local extends the list of jail.local' "$F2B_DIR/jail.local" \
    '127.0.0.1/8 ::1 100.64.0.0/10 198.51.100.2 198.51.100.2 127.0.0.1/8 ::1 100.64.0.0/10 198.51.100.2 198.51.100.2'
rm "$F2B_DIR/jail.d/zz-server-prep.local"

printf '[DEFAULT]\nignoreip = 127.0.0.1/8 ; the loopback\n           192.0.2.0/24\n\n[sshd]\nport = 822\n' > "$F2B_DIR/jail.d/other.local"
files 'a value over two lines, with a " ;" comment' "$F2B_DIR/jail.d/other.local" '127.0.0.1/8 192.0.2.0/24'
printf '[sshd]\nignoreip = 192.0.2.7\n' > "$F2B_DIR/jail.d/other.local"
files '[sshd] ignoreip wins over [DEFAULT], without known/ it replaces it' "$F2B_DIR/jail.d/other.local" '192.0.2.7'
rm "$F2B_DIR/jail.d/other.local"

# --- prep_conf_value: the saved answers, read and never sourced ---------------------------------------
PREP_CONF="$tmp/server-prep.conf"
# save_answers writes printf %q; a hand-edited file can have quotes and comments
cat > "$PREP_CONF" <<'EOF'
# server-prep answers
PANEL_ACCESS=tailscale\,public
PANEL_IP=192.0.2.10
ADMIN_IPS=198.51.100.0/24\ 203.0.113.7
COOLIFY_IP=192.0.2.99
INSTALL_FAIL2BAN="yes" # a comment
TIMEZONE='Europe/Paris'
EXTRA_PORTS=$'8080 8443'
SSH_PORT=22
SSH_PORT=822
EOF
conf() {   # conf KEY WANT
    local got
    got="$(prep_conf_value "$1")"
    [[ $got == "$2" ]] || fail "prep_conf_value $1: got '$got', want '$2'"
}
conf PANEL_ACCESS tailscale,public
conf PANEL_IP 192.0.2.10
conf ADMIN_IPS '198.51.100.0/24 203.0.113.7'
conf INSTALL_FAIL2BAN yes
conf TIMEZONE Europe/Paris
conf EXTRA_PORTS '8080 8443'
conf SSH_PORT 822
conf MISSING ''
pass 'prep_conf_value: printf %q, quotes, a comment, the last line, and nothing for a missing key'
printf 'ADMIN_IPS=$(touch %s/pwned)\n' "$tmp" > "$PREP_CONF"
prep_conf_value ADMIN_IPS > /dev/null
[[ ! -e "$tmp/pwned" ]] || fail 'prep_conf_value ran a command from the file'
pass 'prep_conf_value never runs what the file holds'

# --- fail2ban's own parser, when it is installed here --------------------------------------------------
if command -v fail2ban-client >/dev/null 2>&1 && [[ -r /etc/fail2ban/jail.conf && -d /etc/fail2ban/filter.d ]]; then
    real="$tmp/real"
    mkdir -p "$real/jail.d"
    cp -r /etc/fail2ban/jail.conf /etc/fail2ban/fail2ban.conf /etc/fail2ban/filter.d /etc/fail2ban/action.d "$real/"
    cp /etc/fail2ban/paths-*.conf "$real/" 2>/dev/null
    cp "$F2B_DIR/jail.local" "$real/jail.local"
    printf '%s\n' "$DOKPLOY" > "$real/jail.d/dokploy.local"
    f2b_prep_local '127.0.0.1/8 ::1 100.64.0.0/10 198.51.100.2' > "$real/jail.d/zz-server-prep.local"
    got="$(fail2ban-client -c "$real" -d 2>&1 | grep -F "['set', 'sshd', 'addignoreip'")"
    for ip in 203.0.113.5 100.64.0.0/10 198.51.100.2; do
        [[ $got == *"'$ip'"* ]] || fail "fail2ban $(fail2ban-client --version 2>/dev/null | head -1): the sshd jail does not ignore $ip with dokploy.local and zz-server-prep.local: ${got:0:300}"
    done
    pass "fail2ban's own parser: the sshd jail keeps Dokploy's address and gets server-prep's back"
    # The form in [DEFAULT] that does not work, and why the file uses [sshd]: only a note either way
    printf '[DEFAULT]\nignoreip = %%(known/ignoreip)s 100.64.0.0/10\n' > "$real/jail.d/zz-server-prep.local"
    if fail2ban-client -c "$real" -d > /dev/null 2>&1; then
        printf 'note: this fail2ban accepts %%(known/ignoreip)s in [DEFAULT]; f2b_prep_local still uses [sshd], which works on every version\n'
    else
        pass "fail2ban's own parser refuses %(known/ignoreip)s in [DEFAULT], as f2b_prep_local explains"
    fi
else
    printf 'skip: fail2ban is not installed here, its own parser is not checked\n'
fi

printf 'ok: all fail2ban whitelist cases\n'
