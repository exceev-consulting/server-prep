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
DO_TAILSCALE=""; CHECK_ONLY=0; DRY_RUN=0; ASSUME_YES=0
TS_AUTHKEY="${TS_AUTHKEY:-}"
APT_OPTS=(-y -q -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
BACKUP_DIR="/var/lib/server-prep/backups/preconfig-$(date +%Y%m%d_%H%M%S)"
NETFILE=""; NET_TOUCHED=(); WARNS=0; FAILS=0

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
        --dry-run) DRY_RUN=1; shift ;;
        --yes|-y) ASSUME_YES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
done

if [[ -t 1 ]]; then G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; B=$'\e[1m'; N=$'\e[0m'; else G=""; Y=""; R=""; C=""; B=""; N=""; fi
ok()    { printf '  %sOK%s    %s\n' "$G" "$N" "$*"; }
warn()  { printf '  %sWARN%s  %s\n' "$Y" "$N" "$*"; WARNS=$((WARNS + 1)); }
fail()  { printf '  %sFAIL%s  %s\n' "$R" "$N" "$*"; FAILS=$((FAILS + 1)); }
info()  { printf '  %s->%s    %s\n' "$C" "$N" "$*"; }
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
    ask HOSTNAME_NEW "Hostname" "${HOSTNAME_NEW:-$(hostname)}"
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
    cat <<EOF
  Packages ...... openssh-server sudo curl ca-certificates jq iputils-ping (missing ones only)
  Admin ......... ${ADMIN:-none} -> sudo group${GH_KEYS:+, SSH keys from github.com/$GH_KEYS}
  Hostname ...... $(hostname) -> $HOSTNAME_NEW (+ /etc/hosts)
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
    run systemctl enable --now -q ssh && ok "ssh started and enabled at boot"
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

step_hostname() {
    title "Hostname"
    local cur; cur=$(hostname)
    [[ $HOSTNAME_NEW =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || { fail "invalid hostname '$HOSTNAME_NEW' (a-z, 0-9, -)"; HOSTNAME_NEW=$cur; return; }
    # /etc/hosts first, so sudo never warns "unable to resolve host"
    if ! grep -qE "^127\.0\.1\.1[[:space:]]+$HOSTNAME_NEW([[:space:]]|$)" /etc/hosts; then
        backup /etc/hosts
        if grep -q '^127\.0\.1\.1' /etc/hosts; then run sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$HOSTNAME_NEW/" /etc/hosts
        else run sh -c "printf '127.0.1.1\t%s\n' '$HOSTNAME_NEW' >> /etc/hosts"; fi
        ok "/etc/hosts: 127.0.1.1 $HOSTNAME_NEW"
    fi
    if [[ $cur != "$HOSTNAME_NEW" ]]; then run hostnamectl set-hostname "$HOSTNAME_NEW" && ok "hostname: $cur -> $HOSTNAME_NEW"
    else ok "hostname: $cur (unchanged)"; fi
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
run_checks() {
    title "Checks: will it come back on its own after a reboot?"
    local h; h=$(hostname)
    if grep -qE "^127\.0\.1\.1[[:space:]]+$h([[:space:]]|$)" /etc/hosts; then ok "hostname $h (in /etc/hosts)"
    else warn "hostname $h missing from /etc/hosts: sudo will warn 'unable to resolve host'"; fi

    if [[ $NET_MANAGER == ifupdown ]]; then
        local mode saved; mode=$(iface_mode)
        if [[ -z $mode ]]; then fail "$IFACE is not saved in /etc/network/interfaces*: no network after reboot (fix: --static-ip current or dhcp)"
        elif ! ifquery "$IFACE" >/dev/null 2>&1; then fail "ifupdown rejects the $IFACE config: ifquery $IFACE"
        else
            saved=$(iface_static_ip)
            ok "$IFACE saved as $mode${saved:+ ($saved)}"
            [[ $mode == static && -n $saved && $saved != "${CUR_CIDR}" && $saved != "${CUR_CIDR%/*}" ]] && warn "$IFACE now has $CUR_CIDR but $saved is saved: it changes at reboot"
        fi
        sources_dir || [[ $(grep -cE "^[[:space:]]*iface[[:space:]]+${IFACE}[[:space:]]" /etc/network/interfaces) -gt 0 ]] || fail "/etc/network/interfaces does not include interfaces.d"
        [[ "$(systemctl is-enabled networking 2>/dev/null)" == enabled ]] && ok "networking enabled at boot" || fail "networking not enabled: systemctl enable networking"
    else
        ok "network managed by $NET_MANAGER"
    fi

    if [[ -n $DEF_GW ]] && ping -c1 -W2 "$DEF_GW" >/dev/null 2>&1; then ok "gateway $DEF_GW reachable"; else warn "gateway ${DEF_GW:-none} does not answer ping"; fi
    if ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; then ok "internet reachable"; else fail "no internet (ping 1.1.1.1)"; fi
    if getent hosts debian.org >/dev/null 2>&1; then ok "DNS works"
    else fail "DNS does not resolve: check 'nameserver' in /etc/resolv.conf"; fi
    if grep -q "generated by tailscale" /etc/resolv.conf 2>/dev/null; then
        local up; up=$(awk '/^nameserver/ {printf "%s ", $2}' /etc/resolv.pre-tailscale-backup.conf 2>/dev/null)
        [[ -n $up ]] && ok "DNS via Tailscale, upstream: $up" || warn "DNS via Tailscale but no upstream in /etc/resolv.pre-tailscale-backup.conf"
    fi

    local s st
    for s in ssh tailscaled; do
        [[ $s == tailscaled ]] && ! have tailscale && continue
        st=$(systemctl is-enabled "$s" 2>/dev/null)
        [[ $st == enabled ]] && ok "$s enabled at boot" || fail "$s not enabled at boot ($st): systemctl enable --now $s"
    done

    local t bad=""
    for t in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
        [[ "$(systemctl is-enabled "$t" 2>/dev/null)" == masked ]] || bad+="$t "
    done
    [[ -z $bad ]] && ok "sleep/suspend/hibernate masked" || warn "not masked: $bad"

    if have tailscale; then
        if [[ $TS_STATE == Running ]]; then
            local exp; exp=$(tailscale status --json 2>/dev/null | jq -r '.Self.KeyExpiry // "none"' 2>/dev/null)
            ok "Tailscale connected: $TS_IP ($(tailscale status --json 2>/dev/null | jq -r '.Self.HostName' 2>/dev/null))"
            if [[ $exp == none ]]; then ok "Tailscale key expiry disabled"
            else warn "Tailscale key expires ${exp%%T*}: admin console -> Machines -> $(hostname) -> ... -> Disable key expiry"; fi
        else
            fail "Tailscale not connected (state: ${TS_STATE:-unknown}): sudo tailscale up"
        fi
    else
        warn "Tailscale not installed"
    fi

    local admin=${ADMIN:-$(default_admin)} home n
    if [[ -n $admin ]] && id "$admin" >/dev/null 2>&1; then
        id -nG "$admin" | tr ' ' '\n' | grep -qx sudo && ok "$admin in the sudo group" || fail "$admin not in the sudo group: usermod -aG sudo $admin"
        home=$(getent passwd "$admin" | cut -d: -f6)
        if [[ -r $home/.ssh/authorized_keys ]]; then
            n=$(grep -cE '^(ssh-|ecdsa-|sk-)' "$home/.ssh/authorized_keys" 2>/dev/null)
            (( n > 0 )) && ok "$admin has $n SSH key(s)" || warn "$admin has no SSH key: from your workstation run ssh-copy-id $admin@${TS_IP:-<ip>}"
        elif [[ $EUID -ne 0 ]]; then info "run as root to check $admin's SSH keys"
        else warn "$admin has no SSH key: from your workstation run ssh-copy-id $admin@${TS_IP:-<ip>}"; fi
    fi

    info "BIOS (cannot be checked from Linux): 'Restore on AC Power Loss' = Power On"
    [[ $NET_MANAGER == ifupdown && $(iface_mode) == static ]] && info "router: the fixed IP must be outside the DHCP range (or reserved)"

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

if (( CHECK_ONLY )); then run_checks; exit $(( FAILS > 0 )); fi

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
