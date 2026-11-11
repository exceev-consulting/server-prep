#!/usr/bin/env bash
# server-preconfig.sh - first setup of a fresh Debian/Ubuntu server (VPS or dedicated), BEFORE server-prep.sh:
# SSH + sudo, hostname, network saved for reboots, never sleep, Tailscale - then checks that
# the server comes back on its own (network, SSH, Tailscale) after a reboot or a power cut.
#
#   sudo ./server-preconfig.sh                          # interactive, Enter = default
#   sudo ./server-preconfig.sh --hostname web-01 --static-ip current --yes
#   sudo ./server-preconfig.sh --check                  # checks only, changes nothing
#
# Guide: server-preconfig.md
set -uo pipefail

HOSTNAME_NEW=""; STATIC_IP=""; GATEWAY=""; IFACE=""; ADMIN=""; GH_KEYS=""
DO_TAILSCALE=""; CHECK_ONLY=0; DRY_RUN=0; ASSUME_YES=0; JSON=0
TS_AUTHKEY="${TS_AUTHKEY:-}"
APT_OPTS=(-y -q -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
BACKUP_DIR="/var/lib/server-prep/backups/preconfig-$(date +%Y%m%d_%H%M%S)"
NETFILE=""; NET_TOUCHED=(); WARNS=0; FAILS=0
P_ID=(); P_STATUS=(); P_MSG=(); P_FIX=()   # check results (chk), printed by --check --json
# What the hostname step reads and writes. Never taken from the environment: only tests change them.
# The drop-in's name sorts after the usual cloud.cfg.d files (99-installer.cfg, 99_<provider>.cfg,
# curtin-*.cfg): cloud-init reads them in name order and the last one wins.
HOSTS_FILE=/etc/hosts; CLOUD_DIR=/etc/cloud; CLOUD_DROPIN=$CLOUD_DIR/cloud.cfg.d/zz-server-preconfig.cfg
PROC_CMDLINE=/proc/cmdline

usage() {
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'EOF'
Options:
  --hostname NAME      new hostname (a-z, 0-9, hyphens)
  --static-ip VALUE    network saved for reboots (Debian ifupdown):
                         192.168.1.50/24  fixed IP (CIDR)
                         current            save the IP the server has now as fixed
                         dhcp               save DHCP
                         keep               leave the network config as is
  --gateway IP         default gateway for a fixed IP (default: the current one)
  --iface NAME         network interface (default: the one with the default route)
  --user NAME          admin user to put in the sudo group (default: the sudo caller / first user)
  --github-keys LOGIN  add the public SSH keys of github.com/LOGIN to that user
  --no-tailscale       do not install / log in Tailscale
  --check              only run the checks
  --json               with --check: print the results as one JSON object on stdout (lines for people go to stderr)
  --dry-run            show what would change, change nothing
  --yes                no questions: given options + defaults
Env: TS_AUTHKEY=tskey-...  log Tailscale in without opening the login URL
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hostname) HOSTNAME_NEW="$2"; shift 2 ;;
        --static-ip) STATIC_IP="$2"; shift 2 ;;
        --gateway) GATEWAY="$2"; shift 2 ;;
        --iface) IFACE="$2"; shift 2 ;;
        --user) ADMIN="$2"; shift 2 ;;
        --github-keys) GH_KEYS="$2"; shift 2 ;;
        --no-tailscale) DO_TAILSCALE=no; shift ;;
        --check) CHECK_ONLY=1; shift ;;
        --json) JSON=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --yes|-y) ASSUME_YES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
done
if (( JSON && ! CHECK_ONLY )); then echo "--json works only with --check (see --help)" >&2; exit 2; fi
# --json: stdout is for the JSON only. fd 3 keeps it, and every line for people goes to stderr.
if (( JSON )); then exec 3>&1 1>&2; fi

if [[ -t 1 ]]; then G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; B=$'\e[1m'; N=$'\e[0m'; else G=""; Y=""; R=""; C=""; B=""; N=""; fi
ok()    { printf '  %sOK%s    %s\n' "$G" "$N" "$*"; }
warn()  { printf '  %sWARN%s  %s\n' "$Y" "$N" "$*"; WARNS=$((WARNS + 1)); }
fail()  { printf '  %sFAIL%s  %s\n' "$R" "$N" "$*"; FAILS=$((FAILS + 1)); }
info()  { printf '  %s->%s    %s\n' "$C" "$N" "$*"; }

chk() {   # chk ID PASS|WARN|FAIL|INFO "message" ["fix"]: records the result for --json, prints it for people
    local id=$1 st=$2 msg=$3 fix=${4:-}
    P_ID+=("$id"); P_STATUS+=("$st"); P_MSG+=("$msg"); P_FIX+=("$fix")
    case $st in
        PASS) ok "$msg" ;;
        WARN) warn "$msg" ;;
        FAIL) fail "$msg" ;;
        *)    info "$msg" ;;
    esac
    if [[ -n $fix && ( $st == WARN || $st == FAIL ) ]]; then printf '        fix: %s\n' "$fix"; fi
}

# Copied from server-audit.sh (this script stays standalone).
json_esc() {
    local s="$1"
    s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}; s=${s//$'\r'/}
    printf '%s' "$s"
}

json_report() {   # one JSON object on fd 3 (the real stdout): facts, summary and every chk result
    local i st n_pass=0 n_warn=0 n_fail=0 n_info=0 os virt admin
    for st in "${P_STATUS[@]}"; do
        case $st in
            PASS) n_pass=$((n_pass + 1)) ;;
            WARN) n_warn=$((n_warn + 1)) ;;
            FAIL) n_fail=$((n_fail + 1)) ;;
            *)    n_info=$((n_info + 1)) ;;
        esac
    done
    os=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")
    virt=$(systemd-detect-virt 2>/dev/null || true)   # "none" (exit 1) on bare metal
    [[ -n $virt ]] || virt=unknown
    admin=${ADMIN:-$(default_admin)}
    {
        printf '{"tool":"server-preconfig","schema_version":1,"date":"%s","root":%s,' \
            "$(date -Is)" "$([[ $EUID -eq 0 ]] && echo true || echo false)"
        printf '"facts":{"os":"%s","virt":"%s","net_manager":"%s","iface":"%s","cidr":"%s","gateway":"%s","tailscale_state":"%s","tailscale_ip":"%s","admin":"%s"},' \
            "$(json_esc "$os")" "$(json_esc "$virt")" "$(json_esc "${NET_MANAGER:-}")" "$(json_esc "${IFACE:-}")" \
            "$(json_esc "${CUR_CIDR:-}")" "$(json_esc "${DEF_GW:-}")" "$(json_esc "${TS_STATE:-}")" \
            "$(json_esc "${TS_IP:-}")" "$(json_esc "$admin")"
        printf '"summary":{"pass":%d,"warn":%d,"fail":%d,"info":%d},"checks":[' "$n_pass" "$n_warn" "$n_fail" "$n_info"
        for i in "${!P_ID[@]}"; do
            [[ $i -gt 0 ]] && printf ','
            printf '{"id":"%s","status":"%s","message":"%s","fix":"%s"}' \
                "$(json_esc "${P_ID[$i]}")" "$(json_esc "${P_STATUS[$i]}")" "$(json_esc "${P_MSG[$i]}")" "$(json_esc "${P_FIX[$i]}")"
        done
        printf ']}\n'
    } >&3
}

title() { printf '\n%s== %s ==%s\n' "$B" "$*" "$N"; }
die()   { printf '%sxx %s%s\n' "$R" "$*" "$N" >&2; exit 1; }
have()  { command -v "$1" >/dev/null 2>&1; }
run()   { if (( DRY_RUN )); then printf '  [dry-run] %s\n' "$*"; else "$@"; fi; }

ask() {   # ask VAR "question" "default"
    local __var=$1 q=$2 d=${3:-} a
    if (( ASSUME_YES )) || [[ ! -t 0 ]]; then printf -v "$__var" '%s' "$d"; return; fi
    read -rp "  $q${d:+ [$d]}: " a
    printf -v "$__var" '%s' "${a:-$d}"
}

backup() {   # copy a file into the backup dir before changing it
    [[ -e $1 ]] && (( ! DRY_RUN )) || return 0
    [[ -e $BACKUP_DIR$1 ]] && return 0      # keep the original, not an intermediate version
    mkdir -p "$BACKUP_DIR" && cp -a --parents "$1" "$BACKUP_DIR/"
}

write_file() {   # write_file PATH MODE < content ; returns 1 when the file is already identical
    local path=$1 mode=$2 content
    content=$(cat)
    [[ -f $path && "$(cat "$path")" == "$content" ]] && return 1
    if (( DRY_RUN )); then
        printf '  [dry-run] write %s:\n' "$path"; sed 's/^/            | /' <<<"$content"; return 0
    fi
    backup "$path"; mkdir -p "$(dirname "$path")"
    # In place, not a temp file + mv: the inode stays, so a bind-mounted file (a container's /etc/hosts)
    # keeps working. The cost: a reader can see the file empty for an instant while it is rewritten.
    printf '%s\n' "$content" > "$path" && chmod "$mode" "$path"
}

pkg_ok() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "ok installed"; }

# ---------------------------------------------------------------------------- detection
detect() {
    local route
    route=$(ip -4 route show default 2>/dev/null | head -1)
    DEF_GW=$(awk '{print $3}' <<<"$route")
    [[ -n $IFACE ]] || IFACE=$(awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}' <<<"$route")
    CUR_CIDR=$(ip -4 -o addr show dev "${IFACE:-lo}" scope global 2>/dev/null | awk '{print $4; exit}')
    if compgen -G "/etc/netplan/*.yaml" >/dev/null; then NET_MANAGER=netplan
    elif systemctl is-active -q NetworkManager 2>/dev/null; then NET_MANAGER=NetworkManager
    elif systemctl is-active -q systemd-networkd 2>/dev/null; then NET_MANAGER=systemd-networkd
    elif [[ -f /etc/network/interfaces ]] && have ifquery; then NET_MANAGER=ifupdown
    else NET_MANAGER=unknown; fi
    TS_STATE=""; TS_IP=""
    if have tailscale; then
        TS_STATE=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty' 2>/dev/null)
        TS_IP=$(tailscale ip -4 2>/dev/null | head -1)
    fi
}

iface_mode() {   # static|dhcp|manual|... for $IFACE in ifupdown files, empty if not configured
    grep -hsE "^[[:space:]]*iface[[:space:]]+${IFACE}[[:space:]]+inet[[:space:]]" \
        /etc/network/interfaces /etc/network/interfaces.d/* 2>/dev/null | awk '{print $4; exit}'
}

iface_static_ip() {   # address saved for $IFACE (first one)
    ifquery "$IFACE" 2>/dev/null | awk -F': ' '$1 == "address" {print $2; exit}'
}

sources_dir() { grep -qE '^[[:space:]]*source(-directory)?[[:space:]]+/etc/network/interfaces\.d' /etc/network/interfaces 2>/dev/null; }

valid_cidr() { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]; }
valid_ip()   { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

# ---------------------------------------------------------------------------- questions
default_admin() {
    local u=${SUDO_USER:-}
    [[ $u == root ]] && u=""
    [[ -n $u ]] || u=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}')
    printf '%s' "$u"
}

questions() {
    title "Questions (Enter = default)"
    [[ -n $ADMIN ]] || ADMIN=$(default_admin)
    ask ADMIN "Admin user (gets sudo)" "$ADMIN"
    ask GH_KEYS "GitHub login whose public SSH keys to add (Enter = skip)" "$GH_KEYS"
    if [[ -z $HOSTNAME_NEW ]]; then
        # The default must pass step_hostname's check: 'Web-01' or 'vps123.example.net' would FAIL as they are.
        local hn; hn=$(hostname)
        HOSTNAME_NEW=$(short_hostname "$hn")
        if ! valid_hostname "$HOSTNAME_NEW"; then
            # 'Web_01' or '-edge' have no valid short form: no default, so the operator types one.
            info "current hostname '$hn' is not a valid name (a-z, 0-9, -): type one (--hostname with --yes)"
            HOSTNAME_NEW=""
        elif [[ $HOSTNAME_NEW != "$hn" ]]; then
            info "current hostname '$hn': the default is '$HOSTNAME_NEW' (short name, lowercase)"
        fi
    fi
    ask HOSTNAME_NEW "Hostname" "$HOSTNAME_NEW"
    if [[ $NET_MANAGER == ifupdown ]]; then
        local mode def=keep
        mode=$(iface_mode)
        if [[ -z $mode ]]; then
            info "${Y}!!${N} $IFACE ($CUR_CIDR) is not saved in /etc/network/interfaces*: its IP is lost at reboot"
            def=current
        fi
        info "$IFACE: now ${CUR_CIDR:-no IP}, gateway ${DEF_GW:-none}, saved as: ${mode:-nothing}"
        ask STATIC_IP "Network to save: CIDR (e.g. 192.168.1.50/24) | current | dhcp | keep" "${STATIC_IP:-$def}"
        [[ $STATIC_IP == current ]] && STATIC_IP=$CUR_CIDR
        if valid_cidr "$STATIC_IP"; then ask GATEWAY "Gateway" "${GATEWAY:-$DEF_GW}"; fi
    else
        STATIC_IP=keep
    fi
    ask DO_TAILSCALE "Install / log in Tailscale (yes/no)" "${DO_TAILSCALE:-yes}"
}

plan_and_confirm() {
    title "Plan"
    # The same tests as step_hostname, so the plan only shows what the step changes.
    local hosts hd hl cl="" over
    hosts=$(cat "$HOSTS_FILE" 2>/dev/null)
    hd=$(hosts_domain "$(hostname)" <<<"$hosts")
    if hosts_is_set "$HOSTNAME_NEW" "$hd" <<<"$hosts"; then hl="/etc/hosts unchanged"
    else hl="+ /etc/hosts: 127.0.1.1 ${hd:+$HOSTNAME_NEW.$hd }$HOSTNAME_NEW"; fi
    if [[ -n $(cloud_init_undo) ]]; then
        over=$(cloud_init_undo "$CLOUD_DROPIN")
        if [[ -z $over ]]; then cl="; cloud-init drop-in keeps them at boot"
        else cl="; cloud-init drop-in, but a file read after it still wins: $over"; fi
    fi
    cat <<EOF
  Packages ...... openssh-server sudo curl ca-certificates jq iputils-ping (missing ones only)
  Admin ......... ${ADMIN:-none} -> sudo group${GH_KEYS:+, SSH keys from github.com/$GH_KEYS}
  Hostname ...... $(hostname) -> $HOSTNAME_NEW ($hl$cl)
  Network ....... $IFACE: $([[ $STATIC_IP == keep ]] && echo "unchanged ($NET_MANAGER)" || echo "$STATIC_IP${GATEWAY:+ via $GATEWAY}")
  Power ......... sleep/suspend/hibernate masked, logind ignores idle
  Tailscale ..... $DO_TAILSCALE
EOF
    (( ASSUME_YES || DRY_RUN )) && return 0
    local a; read -rp "  Apply? [Y/n]: " a
    [[ ${a,,} =~ ^(|y|yes)$ ]] || die "Cancelled, nothing changed."
}

# ---------------------------------------------------------------------------- steps
step_packages() {
    title "Packages"
    local need=() p
    for p in openssh-server sudo curl ca-certificates jq iputils-ping; do pkg_ok "$p" || need+=("$p"); done
    if (( ${#need[@]} )); then
        run apt-get update -q -o DPkg::Lock::Timeout=600 >/dev/null || { fail "apt-get update failed"; return; }
        if run env DEBIAN_FRONTEND=noninteractive apt-get install "${APT_OPTS[@]}" "${need[@]}" >/dev/null; then
            ok "installed: ${need[*]}"
        else fail "apt-get install ${need[*]} failed"; return; fi
    else
        ok "openssh-server sudo curl jq already installed"
    fi
    # Ubuntu 22.10+ starts sshd from ssh.socket. Enabling ssh.service next to it makes later
    # port changes (server-prep's ssh step) fail with "Address already in use".
    if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
        run systemctl enable --now -q ssh.socket && ok "ssh.socket started and enabled at boot (socket-activated sshd)"
    else
        run systemctl enable --now -q ssh && ok "ssh started and enabled at boot"
    fi
}

add_github_keys() {
    local home grp keys k added=0
    home=$(getent passwd "$ADMIN" | cut -d: -f6); grp=$(id -gn "$ADMIN")
    keys=$(curl -fsSL --max-time 15 "https://github.com/${GH_KEYS}.keys") || { fail "cannot download github.com/${GH_KEYS}.keys"; return; }
    [[ -n $keys ]] || { warn "github.com/${GH_KEYS} has no public SSH key"; return; }
    if (( DRY_RUN )); then info "[dry-run] add $(grep -c . <<<"$keys") key(s) to $home/.ssh/authorized_keys"; return; fi
    install -d -m 700 -o "$ADMIN" -g "$grp" "$home/.ssh"
    touch "$home/.ssh/authorized_keys"
    while IFS= read -r k; do
        [[ -n $k ]] && ssh-keygen -l -f /dev/stdin <<<"$k" >/dev/null 2>&1 || continue
        grep -qxF "$k" "$home/.ssh/authorized_keys" || { printf '%s\n' "$k" >> "$home/.ssh/authorized_keys"; added=$((added + 1)); }
    done <<<"$keys"
    chown "$ADMIN:$grp" "$home/.ssh/authorized_keys"; chmod 600 "$home/.ssh/authorized_keys"
    ok "$added new SSH key(s) from github.com/${GH_KEYS} for $ADMIN"
}

step_user() {
    title "Admin user"
    [[ -n $ADMIN ]] || { warn "no admin user: create one with 'adduser <name>' and re-run"; return; }
    id "$ADMIN" >/dev/null 2>&1 || { fail "user '$ADMIN' does not exist: adduser $ADMIN"; return; }
    if id -nG "$ADMIN" | tr ' ' '\n' | grep -qx sudo; then ok "$ADMIN is in the sudo group"
    else run usermod -aG sudo "$ADMIN" && ok "$ADMIN added to the sudo group (log out and in again to use sudo)"; fi
    [[ -n $GH_KEYS ]] && add_github_keys
    return 0
}

# Hostname helpers. They only read (stdin, or the files under $CLOUD_DIR) and print, so tests run them
# on fixtures. POSIX awk only: Debian and Ubuntu use mawk by default.
short_hostname() {   # short_hostname NAME: the part before the first dot, lowercase (Web-01.example.com -> web-01)
    local h=${1%%.*}
    printf '%s\n' "${h,,}"
}

valid_hostname() {   # valid_hostname NAME: true when step_hostname accepts NAME (a-z, 0-9, -, 1 to 63, no - at either end)
    [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

hosts_has_name() {   # hosts_has_name NAME < hosts: true when NAME is one of the names of a 127.0.1.1 line
    awk -v n="$1" '
        { sub(/#.*/, "") }
        $1 == "127.0.1.1" { for (i = 2; i <= NF; i++) if ($i == n) f = 1 }
        END { exit !f }'
}

hosts_domain() {   # hosts_domain CUR < hosts: the domain to keep on the 127.0.1.1 line, nothing when there is none
    # The first name with a dot on the first 127.0.1.1 line (127.0.1.1 web-01.example.com web-01), else
    # the current hostname CUR when it has one (vps123.example.net). When both have a domain and they
    # differ (127.0.1.1 old.lan old, hostname old.example.com), the hosts file wins: Debian keeps the FQDN
    # there, and hostname -f reads it for the short name the step sets.
    local d
    d=$(awk '
        { sub(/#.*/, "") }
        $1 == "127.0.1.1" {
            for (i = 2; i <= NF; i++) if (index($i, ".")) { print substr($i, index($i, ".") + 1); exit }
            exit
        }')
    [[ -z $d && $1 == *.* ]] && d=${1#*.}
    if [[ $d =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then printf '%s\n' "$d"; fi
    return 0
}

hosts_is_set() {   # hosts_is_set NAME [DOMAIN] < hosts: true when the 127.0.1.1 lines already have what hosts_set_name writes:
    # NAME, and NAME.DOMAIN when there is a DOMAIN. '127.0.1.1 web-01' is not enough when the domain is
    # example.com: the step would set the hostname to web-01 and the FQDN would be lost.
    local h; h=$(cat)
    hosts_has_name "$1" <<<"$h" || return 1
    [[ -z ${2:-} ]] || hosts_has_name "$1.$2" <<<"$h"
}

hosts_set_name() {   # hosts_set_name NAME [DOMAIN] < hosts: the same file, every 127.0.1.1 line set to "[NAME.DOMAIN ]NAME"
    # Other lines (127.0.0.1 localhost, ::1 ...) stay byte for byte; the line is added when there is none.
    # The 127.0.1.1 line is replaced whole: extra names and a trailing comment on it are not kept
    # (127.0.1.1 old.example.com old panel loses panel), as with the sed this replaced.
    # ENVIRON, not -v: awk would read backslashes in a -v value as escapes.
    HOSTS_LINE="127.0.1.1"$'\t'"${2:+$1.$2 }$1" awk '
        $1 == "127.0.1.1" { print ENVIRON["HOSTS_LINE"]; done = 1; next }
        { print }
        END { if (!done) print ENVIRON["HOSTS_LINE"] }'
}

cloud_cfg() {   # cloud_cfg KEY [AFTER]: "value<TAB>file" of a top-level KEY as cloud-init reads it, nothing when unset
    # cloud-init reads cloud.cfg, then cloud.cfg.d/*.cfg in name order (Python sorts by code point, like
    # LC_ALL=C sort): the last file that sets KEY wins. Only readable files: without root, the
    # installer's mode 600 file would stop awk before the files after it.
    # With AFTER (a cloud.cfg.d path), only the files read after it: what still wins over a drop-in there.
    local f files=() list
    list=$(printf '%s\n' "$CLOUD_DIR"/cloud.cfg.d/*.cfg | LC_ALL=C sort)
    if [[ -n ${2:-} ]]; then list=$(LC_ALL=C awk -v a="$2" '$0 > a' <<<"$list")
    else list="$CLOUD_DIR/cloud.cfg"$'\n'"$list"; fi
    while IFS= read -r f; do
        [[ -f $f && -r $f ]] && files+=("$f")
    done <<<"$list"
    (( ${#files[@]} )) || return 0
    awk -v k="$1:" -v q="'" '
        index($0, k) == 1 {
            v = substr($0, length(k) + 1)
            sub(/[ \t]+#.*/, "", v)
            gsub("[\"" q " \t\r]", "", v)
            val = tolower(v); file = FILENAME; found = 1
        }
        END { if (found) printf "%s\t%s\n", val, file }' "${files[@]}" 2>/dev/null
}

cloud_init_off() {   # cloud_init_off: why cloud-init does not run at boot, nothing when it runs
    # The same order as cloud-init's systemd generator: the last cloud-init= of the kernel command line
    # (=enabled wins over the file), then /etc/cloud/cloud-init.disabled. Ubuntu installed from the ISO
    # keeps the package and its stock cloud.cfg, but its installer creates that file.
    local toks=() t val=""
    { read -ra toks < "$PROC_CMDLINE"; } 2>/dev/null
    for t in "${toks[@]}"; do
        if [[ $t == cloud-init=* ]]; then val=${t#cloud-init=}; fi
    done
    case $val in
        disabled) printf '%s\n' "cloud-init=disabled on the kernel command line" ;;
        enabled) ;;
        *) if [[ -f $CLOUD_DIR/cloud-init.disabled ]]; then printf '%s\n' "$CLOUD_DIR/cloud-init.disabled exists"; fi ;;
    esac
    return 0
}

cloud_init_undo() {   # cloud_init_undo [AFTER]: why cloud-init can reset the hostname or /etc/hosts at the next boot, nothing when it can't
    # Nothing without cloud-init (no cloud.cfg) or when it is disabled. With AFTER (the drop-in's path),
    # only what the files read after it set: what a drop-in there would not fix.
    [[ -f $CLOUD_DIR/cloud.cfg && -z $(cloud_init_off) ]] || return 0
    local r v f why="" after=${1:-}
    r=$(cloud_cfg preserve_hostname "$after"); v=${r%%$'\t'*}; f=${r#*$'\t'}
    case $v in
        true|yes|on|1) ;;
        *) if [[ -n $r ]]; then why="preserve_hostname: ${v:-(empty)} in $f"
           elif [[ -z $after ]]; then why="preserve_hostname is not set (cloud-init's default: false)"; fi ;;
    esac
    r=$(cloud_cfg manage_etc_hosts "$after"); v=${r%%$'\t'*}; f=${r#*$'\t'}
    case $v in
        true|yes|on|1|template) why+="${why:+; }manage_etc_hosts: $v in $f" ;;
    esac
    if [[ -n $why ]]; then printf '%s\n' "$why"; fi
    return 0
}

step_hostname() {
    title "Hostname"
    local cur hosts domain; cur=$(hostname)
    valid_hostname "$HOSTNAME_NEW" || { fail "invalid hostname '$HOSTNAME_NEW' (a-z, 0-9, -)"; HOSTNAME_NEW=$cur; return; }
    # /etc/hosts first, so sudo never warns "unable to resolve host". The domain stays:
    # 127.0.1.1 web-01.example.com web-01, also when only the current hostname has it (vps123.example.net
    # with '127.0.1.1 vps123'). Left alone when that line is already there.
    hosts=$(cat "$HOSTS_FILE" 2>/dev/null)
    domain=$(hosts_domain "$cur" <<<"$hosts")
    if ! hosts_is_set "$HOSTNAME_NEW" "$domain" <<<"$hosts"; then
        printf '%s' "$hosts" | hosts_set_name "$HOSTNAME_NEW" "$domain" | write_file "$HOSTS_FILE" 644 \
            && ok "/etc/hosts: 127.0.1.1 ${domain:+$HOSTNAME_NEW.$domain }$HOSTNAME_NEW"
    fi
    if [[ $cur != "$HOSTNAME_NEW" ]]; then run hostnamectl set-hostname "$HOSTNAME_NEW" && ok "hostname: $cur -> $HOSTNAME_NEW"
    else ok "hostname: $cur (unchanged)"; fi
    # Cloud images: preserve_hostname: false or manage_etc_hosts: true make cloud-init put the
    # provider's name back at the next boot. Nothing to do when cloud-init is disabled (cloud_init_undo is
    # empty). The drop-in wins over the files read before it; one read after it still wins, so say so.
    if [[ -n $(cloud_init_undo) ]]; then
        local over left wrote=0
        over=$(cloud_init_undo "$CLOUD_DROPIN")
        printf '%s\n' "# Managed by server-preconfig.sh - cloud-init keeps the hostname and /etc/hosts set on this server" \
            "preserve_hostname: true" "manage_etc_hosts: false" | write_file "$CLOUD_DROPIN" 644 && wrote=1
        # A dry run writes nothing: what the files after the drop-in set is what would be left.
        if (( DRY_RUN )); then left=$over; else left=$(cloud_init_undo); fi
        if [[ -n $left ]]; then
            warn "cloud-init can still reset the hostname or /etc/hosts at the next boot: $left"
            if [[ -n $over ]]; then info "cloud-init reads that file after $CLOUD_DROPIN, so it wins: edit or remove the setting there"; fi
        elif (( wrote )); then
            ok "cloud-init keeps the hostname and /etc/hosts at boot ($CLOUD_DROPIN)"
        fi
    fi
    return 0
}

disable_other_stanzas() {   # comment out other ifupdown definitions of $IFACE (duplicates break ifup)
    local f tmp
    for f in /etc/network/interfaces /etc/network/interfaces.d/*; do
        [[ -f $f && $f != "$NETFILE" ]] || continue
        tmp=$(mktemp)
        awk -v ifc="$IFACE" '
            skip && /^[ \t]+[^ \t#]/ { print "#preconfig# " $0; next }
            { skip = 0 }
            ($1 == "allow-hotplug" || $1 == "auto") && $2 == ifc && NF == 2 { print "#preconfig# " $0; next }
            $1 == "iface" && $2 == ifc && $3 == "inet" { skip = 1; print "#preconfig# " $0; next }
            { print }' "$f" > "$tmp"
        if ! cmp -s "$f" "$tmp"; then
            if (( DRY_RUN )); then printf '  [dry-run] comment out %s in %s:\n' "$IFACE" "$f"; diff "$f" "$tmp" | sed 's/^/            /'
            else backup "$f"; cat "$tmp" > "$f"; NET_TOUCHED+=("$f"); info "old $IFACE config commented out in $f"; fi
        fi
        rm -f "$tmp"
    done
}

restore_network() {
    local f
    for f in "${NET_TOUCHED[@]}"; do
        if [[ -e "$BACKUP_DIR$f" ]]; then cp -a "$BACKUP_DIR$f" "$f"; else rm -f "$f"; fi
    done
}

step_network() {
    title "Network (must survive reboots)"
    [[ -n $IFACE ]] || { fail "no default route: is the network cable plugged in?"; return; }
    if [[ $NET_MANAGER != ifupdown ]]; then
        ok "network managed by $NET_MANAGER: left untouched"
        [[ $NET_MANAGER == netplan ]] && info "fixed IP on Ubuntu: edit /etc/netplan/*.yaml, then 'netplan try'"
        return
    fi
    case $STATIC_IP in
        keep|"") ok "$IFACE left as is (saved as: $(iface_mode || true))"; return ;;
        dhcp) ;;
        *) valid_cidr "$STATIC_IP" || { fail "invalid IP '$STATIC_IP' (expected e.g. 192.168.1.50/24)"; return; }
           [[ -n $GATEWAY ]] || GATEWAY=$DEF_GW
           valid_ip "$GATEWAY" || { fail "invalid gateway '$GATEWAY'"; return; } ;;
    esac
    NETFILE=/etc/network/interfaces.d/$IFACE
    if [[ $STATIC_IP == dhcp ]]; then
        printf 'auto %s\niface %s inet dhcp' "$IFACE" "$IFACE"
    else
        printf '# Managed by server-preconfig.sh\nauto %s\niface %s inet static\n    address %s\n    gateway %s' \
            "$IFACE" "$IFACE" "$STATIC_IP" "$GATEWAY"
    fi | write_file "$NETFILE" 644 && NET_TOUCHED+=("$NETFILE")
    sources_dir || {
        backup /etc/network/interfaces
        run sh -c 'printf "\nsource /etc/network/interfaces.d/*\n" >> /etc/network/interfaces'
        NET_TOUCHED+=(/etc/network/interfaces)
    }
    disable_other_stanzas
    (( DRY_RUN )) && return
    if ifquery "$IFACE" >/dev/null 2>&1; then
        ok "$IFACE saved: $STATIC_IP${GATEWAY:+ via $GATEWAY} ($NETFILE)"
    else
        restore_network; fail "ifupdown rejects the new config - previous files restored. Check: ifquery $IFACE"; return
    fi
    run systemctl enable -q networking
    if [[ $STATIC_IP != dhcp && $STATIC_IP != "$CUR_CIDR" ]]; then
        warn "new IP $STATIC_IP is used after the reboot (now: $CUR_CIDR) - reconnect with Tailscale or the new IP"
    fi
}

step_power() {
    title "Power: never sleep"
    local t
    for t in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
        [[ "$(systemctl is-enabled "$t" 2>/dev/null)" == masked ]] || run systemctl mask -q "$t"
    done
    write_file /etc/systemd/logind.conf.d/50-server-preconfig.conf 644 <<'EOF' || true
# Managed by server-preconfig.sh - a server never sleeps on its own
[Login]
IdleAction=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
EOF
    ok "sleep/suspend/hibernate masked, logind ignores idle and sleep keys (applies after reboot)"
}

step_tailscale() {
    title "Tailscale"
    [[ ${DO_TAILSCALE,,} =~ ^(y|yes)$ ]] || { info "skipped"; return; }
    if ! have tailscale; then
        run sh -c 'curl -fsSL https://tailscale.com/install.sh | sh' || { fail "Tailscale install failed"; return; }
    fi
    run systemctl enable --now -q tailscaled
    detect
    if [[ $TS_STATE == Running ]]; then
        run tailscale set --hostname="$HOSTNAME_NEW" && ok "logged in ($TS_IP), machine name: $HOSTNAME_NEW"
        return
    fi
    if [[ -n $TS_AUTHKEY ]]; then
        if (( DRY_RUN )); then info "[dry-run] tailscale up --hostname=$HOSTNAME_NEW --auth-key=***"
        else tailscale up --hostname="$HOSTNAME_NEW" --auth-key="$TS_AUTHKEY" || { fail "tailscale up failed"; return; }; fi
    else
        info "open the login URL below on your workstation and approve the machine (Ctrl+C to do it later)"
        run tailscale up --hostname="$HOSTNAME_NEW" || { fail "tailscale up failed: run 'sudo tailscale up' later"; return; }
    fi
    detect; [[ $TS_STATE == Running ]] && ok "logged in: $TS_IP ($HOSTNAME_NEW)"
}

# ---------------------------------------------------------------------------- checks
check_cloud_init() {   # check_cloud_init SHORT-NAME: pre.cloud_init_hostname, when cloud-init is installed
    # Never a FAIL: the server still boots, cloud-init only puts the provider's name back.
    [[ -f $CLOUD_DIR/cloud.cfg ]] || return 0
    local off undo over fix=""
    off=$(cloud_init_off)
    if [[ -n $off ]]; then
        chk pre.cloud_init_hostname INFO "cloud-init is disabled ($off): it leaves the hostname and /etc/hosts alone at boot"
        return 0
    fi
    undo=$(cloud_init_undo)
    if [[ -z $undo ]]; then chk pre.cloud_init_hostname PASS "cloud-init keeps the hostname and /etc/hosts at boot"; return 0; fi
    # A re-run writes the drop-in, which fixes what the files read before it set (undo differs from over).
    # What a file read after the drop-in sets, only an edit of that file fixes.
    over=$(cloud_init_undo "$CLOUD_DROPIN")
    [[ $undo == "$over" ]] || fix="sudo ./server-preconfig.sh --hostname $1 (writes $CLOUD_DROPIN)"
    [[ -z $over ]] || fix+="${fix:+, then }edit or remove $over: cloud-init reads it after $CLOUD_DROPIN, so it wins"
    chk pre.cloud_init_hostname WARN "cloud-init can reset the hostname and /etc/hosts at the next boot: $undo" "$fix"
}

run_checks() {
    title "Checks: will it come back on its own after a reboot?"
    local h hs; h=$(hostname); hs=$(short_hostname "$h")
    # The fix hints pass hs to --hostname: 'Web_01' has no valid short form, so they ask for a name.
    valid_hostname "$hs" || hs='<name>'
    if hosts_has_name "$h" <<<"$(cat "$HOSTS_FILE" 2>/dev/null)"; then chk pre.hostname PASS "hostname $h (in /etc/hosts)"
    else
        chk pre.hostname WARN "hostname $h missing from /etc/hosts: sudo will warn 'unable to resolve host'" \
            "sudo ./server-preconfig.sh --hostname $hs"
    fi
    check_cloud_init "$hs"

    if [[ $NET_MANAGER == ifupdown ]]; then
        local mode saved; mode=$(iface_mode)
        if [[ -z $mode ]]; then
            chk pre.net_saved FAIL "$IFACE is not saved in /etc/network/interfaces*: no network after reboot" \
                "sudo ./server-preconfig.sh --static-ip current (or dhcp)"
        elif ! ifquery "$IFACE" >/dev/null 2>&1; then
            chk pre.net_valid FAIL "ifupdown rejects the $IFACE config" "ifquery $IFACE (shows the error)"
        else
            saved=$(iface_static_ip)
            chk pre.net_saved PASS "$IFACE saved as $mode${saved:+ ($saved)}"
            if [[ $mode == static && -n $saved && $saved != "${CUR_CIDR}" && $saved != "${CUR_CIDR%/*}" ]]; then
                chk pre.net_ip_match WARN "$IFACE now has $CUR_CIDR but $saved is saved: it changes at reboot"
            fi
        fi
        if ! { sources_dir || [[ $(grep -cE "^[[:space:]]*iface[[:space:]]+${IFACE}[[:space:]]" /etc/network/interfaces) -gt 0 ]]; }; then
            chk pre.net_source FAIL "/etc/network/interfaces does not include interfaces.d" \
                "echo 'source /etc/network/interfaces.d/*' | sudo tee -a /etc/network/interfaces"
        fi
        if [[ "$(systemctl is-enabled networking 2>/dev/null)" == enabled ]]; then chk pre.net_boot PASS "networking enabled at boot"
        else chk pre.net_boot FAIL "networking not enabled" "sudo systemctl enable networking"; fi
    else
        chk pre.net_saved PASS "network managed by $NET_MANAGER"
    fi

    if [[ -n $DEF_GW ]] && ping -c1 -W2 "$DEF_GW" >/dev/null 2>&1; then chk pre.gateway PASS "gateway $DEF_GW reachable"
    else chk pre.gateway WARN "gateway ${DEF_GW:-none} does not answer ping"; fi
    if ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; then chk pre.internet PASS "internet reachable"
    else chk pre.internet FAIL "no internet (ping 1.1.1.1)"; fi
    if getent hosts debian.org >/dev/null 2>&1; then chk pre.dns PASS "DNS works"
    else chk pre.dns FAIL "DNS does not resolve" "check 'nameserver' in /etc/resolv.conf"; fi
    if grep -q "generated by tailscale" /etc/resolv.conf 2>/dev/null; then
        local up; up=$(awk '/^nameserver/ {printf "%s ", $2}' /etc/resolv.pre-tailscale-backup.conf 2>/dev/null)
        if [[ -n $up ]]; then chk pre.dns_upstream PASS "DNS via Tailscale, upstream: ${up% }"
        else chk pre.dns_upstream WARN "DNS via Tailscale but no upstream in /etc/resolv.pre-tailscale-backup.conf"; fi
    fi

    local s st
    local ssh_unit=ssh
    systemctl is-enabled --quiet ssh.socket 2>/dev/null && ssh_unit=ssh.socket
    for s in "$ssh_unit" tailscaled; do
        [[ $s == tailscaled ]] && ! have tailscale && continue
        st=$(systemctl is-enabled "$s" 2>/dev/null)
        if [[ $st == enabled ]]; then chk "pre.${s}_boot" PASS "$s enabled at boot"
        else chk "pre.${s}_boot" FAIL "$s not enabled at boot ($st)" "sudo systemctl enable --now $s"; fi
    done

    local t bad=""
    for t in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
        [[ "$(systemctl is-enabled "$t" 2>/dev/null)" == masked ]] || bad+="$t "
    done
    if [[ -z $bad ]]; then chk pre.sleep PASS "sleep/suspend/hibernate masked"
    else chk pre.sleep WARN "not masked: ${bad% }" "sudo systemctl mask ${bad% }"; fi

    if have tailscale; then
        if [[ $TS_STATE == Running ]]; then
            local exp; exp=$(tailscale status --json 2>/dev/null | jq -r '.Self.KeyExpiry // "none"' 2>/dev/null)
            chk pre.tailscale PASS "Tailscale connected: $TS_IP ($(tailscale status --json 2>/dev/null | jq -r '.Self.HostName' 2>/dev/null))"
            if [[ $exp == none ]]; then chk pre.tailscale_expiry PASS "Tailscale key expiry disabled"
            else
                chk pre.tailscale_expiry WARN "Tailscale key expires ${exp%%T*}" \
                    "Tailscale admin console -> Machines -> $(hostname) -> ... -> Disable key expiry"
            fi
        else
            chk pre.tailscale FAIL "Tailscale not connected (state: ${TS_STATE:-unknown})" "sudo tailscale up"
        fi
    else
        chk pre.tailscale WARN "Tailscale not installed" "sudo ./server-preconfig.sh (answer yes to Tailscale)"
    fi

    local admin=${ADMIN:-$(default_admin)} home n
    if [[ -n $admin ]] && id "$admin" >/dev/null 2>&1; then
        if id -nG "$admin" | tr ' ' '\n' | grep -qx sudo; then chk pre.admin_sudo PASS "$admin in the sudo group"
        else chk pre.admin_sudo FAIL "$admin not in the sudo group" "sudo usermod -aG sudo $admin"; fi
        home=$(getent passwd "$admin" | cut -d: -f6)
        if [[ -r $home/.ssh/authorized_keys ]]; then
            n=$(grep -cE '^(ssh-|ecdsa-|sk-)' "$home/.ssh/authorized_keys" 2>/dev/null)
            if (( n > 0 )); then chk pre.admin_keys PASS "$admin has $n SSH key(s)"
            else chk pre.admin_keys WARN "$admin has no SSH key" "from your workstation: ssh-copy-id $admin@${TS_IP:-<ip>}"; fi
        elif [[ $EUID -ne 0 ]]; then chk pre.admin_keys INFO "run as root to check $admin's SSH keys"
        else chk pre.admin_keys WARN "$admin has no SSH key" "from your workstation: ssh-copy-id $admin@${TS_IP:-<ip>}"; fi
    fi

    chk pre.bios INFO "BIOS (cannot be checked from Linux): 'Restore on AC Power Loss' = Power On"
    if [[ $NET_MANAGER == ifupdown && $(iface_mode) == static ]]; then
        chk pre.router INFO "router: the fixed IP must be outside the DHCP range (or reserved)"
    fi

    title "Result"
    printf '  %s FAIL, %s WARN\n' "$FAILS" "$WARNS"
    if (( FAILS == 0 )); then
        cat <<EOF
  Reboot test:  sudo reboot
  then, after ~2 min, from your workstation:
    ssh ${admin:-<user>}@${TS_IP:-<tailscale-ip>} 'hostname; ip -br a show ${IFACE}; ping -c2 debian.org'
  Next: server-prep.sh (see https://github.com/exceev-consulting/server-prep#quick-start)
EOF
    fi
}

# ---------------------------------------------------------------------------- main
OS_INFO=$(. /etc/os-release 2>/dev/null; echo "${ID:-} ${ID_LIKE:-}")
[[ " $OS_INFO " == *" debian "* || " $OS_INFO " == *" ubuntu "* ]] || die "Debian/Ubuntu only (found: $OS_INFO)"
if [[ $EUID -ne 0 ]]; then
    (( CHECK_ONLY || DRY_RUN )) || die "Run as root: sudo $0   (no sudo yet? su - -c '$(realpath "$0")')"
    info "not root: some checks are approximate"
fi
have ip || die "'ip' command missing (package iproute2)"
detect

if (( CHECK_ONLY )); then
    run_checks
    if (( JSON )); then json_report; fi
    exit $(( FAILS > 0 ))
fi

(( DRY_RUN )) && info "dry-run: nothing will be changed"
questions
plan_and_confirm
step_packages
step_user
step_hostname
step_network
step_power
step_tailscale
detect
run_checks
[[ -d $BACKUP_DIR ]] && info "backups of changed files: $BACKUP_DIR"
exit $(( FAILS > 0 ))
