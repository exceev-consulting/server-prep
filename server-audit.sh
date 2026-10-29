#!/usr/bin/env bash
# =============================================================================
# server-audit.sh - Security & deploy-panel readiness audit for Debian/Ubuntu servers (VPS or dedicated)
#
# Reworked from "VPS Security Audit Tool" v0.2.0 (https://github.com/nuver-labs/vps-audit),
# Copyright (c) 2024 Israel Abebe Kokiso, MIT License - see THIRD_PARTY_NOTICES.md.
# Main differences with the original:
#   - SSH checks use sshd's *effective* config (sshd -T), so drop-ins and
#     Match blocks (e.g. root allowed only from the panel / tunnel) are understood
#   - Port exposure looks at the bind address AND the firewall, instead of
#     counting every listening socket (localhost-only ports are not "public")
#   - Detects the Docker-bypasses-UFW problem
#   - Separates security updates from regular updates
#   - New checks: CrowdSec, fail2ban jail, kernel (sysctl) settings, AppArmor, auditd,
#     rkhunter, AIDE, UID 0 accounts, empty passwords, world-writable /etc
#     files, Docker hygiene, and a panel-readiness section (Coolify, Dokploy...)
#   - Outputs: console, text report, Markdown (--md), JSON (--json), TSV (--tsv)
#
# Usage: sudo ./server-audit.sh [options]      (./server-audit.sh --help)
# Exit code: 0 = no FAIL, 1 = at least one FAIL, 2 = usage error
# =============================================================================

set -u   # no pipefail: "cmd | grep -q" would report SIGPIPE as failure

AUDIT_VERSION="1.0.0"
PROJECT_URL="https://github.com/exceev-consulting/server-prep"

# ----------------------------------------------------------------------------
# Configuration (override with environment variables)
# ----------------------------------------------------------------------------
RESOURCE_WARN=${RESOURCE_WARN:-70}     # % disk/memory usage for WARN
RESOURCE_FAIL=${RESOURCE_FAIL:-90}     # % disk/memory usage for FAIL
SERVICES_WARN=${SERVICES_WARN:-30}     # running services for WARN
SERVICES_FAIL=${SERVICES_FAIL:-45}     # running services for FAIL
LOGINS_WARN=${LOGINS_WARN:-20}         # failed SSH logins in 24h for WARN
LOGINS_FAIL=${LOGINS_FAIL:-200}        # failed SSH logins in 24h for FAIL
EXPOSED_WARN=${EXPOSED_WARN:-4}        # internet-exposed TCP ports for WARN
EXPOSED_FAIL=${EXPOSED_FAIL:-6}        # internet-exposed TCP ports for FAIL
PASSWORD_MINLEN=${PASSWORD_MINLEN:-12}
UNNEEDED_SERVICES=${UNNEEDED_SERVICES:-"avahi-daemon cups cups-browsed bluetooth ModemManager rpcbind telnet.socket vsftpd"}

OUT_DIR="."
JSON_OUT=""
MD_OUT=""
TSV_OUT=""
TXT_OUT=""
QUIET=0
COLOR=1
NETWORK=1

usage() {
    cat <<EOF
server-audit.sh v${AUDIT_VERSION} - security & deploy-panel readiness audit (Debian/Ubuntu)

Usage: sudo $0 [options]

  --out DIR        directory for the text report (default: current directory)
  --txt FILE       text report path (default: DIR/server-audit-<host>-<timestamp>.txt)
  --md FILE        also write a Markdown report
  --json FILE      also write a JSON report
  --tsv FILE       also write a TSV (id, status, title) - used by server-prep.sh
  --no-txt         do not write the text report
  --quiet          no console output (reports only)
  --no-color       disable colors
  --no-network     do not query the public IP
  -h, --help       this help

Run as root for complete results (sshd -T, firewall, shadow, docker...).
EOF
}

NO_TXT=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --out) OUT_DIR="$2"; shift 2 ;;
        --txt) TXT_OUT="$2"; shift 2 ;;
        --md) MD_OUT="$2"; shift 2 ;;
        --json) JSON_OUT="$2"; shift 2 ;;
        --tsv) TSV_OUT="$2"; shift 2 ;;
        --no-txt) NO_TXT=1; shift ;;
        --quiet) QUIET=1; shift ;;
        --no-color) COLOR=0; shift ;;
        --no-network) NETWORK=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ -t 1 ]] || COLOR=0
if [[ $COLOR -eq 1 ]]; then
    C_GREEN=$'\033[0;32m'; C_RED=$'\033[0;31m'; C_YELLOW=$'\033[1;33m'
    C_BLUE=$'\033[0;34m'; C_GRAY=$'\033[0;90m'; C_BOLD=$'\033[1m'; C_0=$'\033[0m'
else
    C_GREEN=""; C_RED=""; C_YELLOW=""; C_BLUE=""; C_GRAY=""; C_BOLD=""; C_0=""
fi

IS_ROOT=0; [[ $EUID -eq 0 ]] && IS_ROOT=1
HOST=$(hostname)
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
STARTED_AT=$(date -Is)
[[ -z "$TXT_OUT" ]] && TXT_OUT="${OUT_DIR}/server-audit-${HOST}-${TIMESTAMP}.txt"

# ----------------------------------------------------------------------------
# Result storage
# ----------------------------------------------------------------------------
R_ID=(); R_CAT=(); R_STATUS=(); R_TITLE=(); R_MSG=(); R_FIX=()
CURRENT_CAT="general"

out() { [[ $QUIET -eq 1 ]] || printf '%s\n' "$*"; }

section() {
    CURRENT_CAT="$1"
    out ""
    out "${C_BLUE}${C_BOLD}== $2 ==${C_0}"
}

# result ID STATUS TITLE MESSAGE [FIX]
result() {
    local id="$1" status="$2" title="$3" msg="$4" fix="${5:-}" color
    R_ID+=("$id"); R_CAT+=("$CURRENT_CAT"); R_STATUS+=("$status")
    R_TITLE+=("$title"); R_MSG+=("$msg"); R_FIX+=("$fix")
    case "$status" in
        PASS) color=$C_GREEN ;; WARN) color=$C_YELLOW ;; FAIL) color=$C_RED ;; *) color=$C_GRAY ;;
    esac
    out "${color}[${status}]${C_0} ${title} ${C_GRAY}- ${msg}${C_0}"
    if [[ -n "$fix" && "$status" != "PASS" && "$status" != "INFO" ]]; then
        out "       ${C_GRAY}fix: ${fix}${C_0}"
    fi
}

have() { command -v "$1" >/dev/null 2>&1; }
need_root_note() { [[ $IS_ROOT -eq 1 ]] || echo " (run as root for an exact result)"; }

# ----------------------------------------------------------------------------
# Header / system info
# ----------------------------------------------------------------------------
# shellcheck disable=SC1091
. /etc/os-release 2>/dev/null || true
OS_PRETTY="${PRETTY_NAME:-unknown}"
KERNEL=$(uname -r)
PUBLIC_IP="skipped"
if [[ $NETWORK -eq 1 ]] && have curl; then
    PUBLIC_IP=$(curl -fsS -m 5 https://api.ipify.org 2>/dev/null || echo "unknown")
fi

out "${C_BLUE}${C_BOLD}server-audit v${AUDIT_VERSION}${C_0} ${C_GRAY}- $(date)${C_0}"
[[ $IS_ROOT -eq 1 ]] || out "${C_YELLOW}Not running as root: some checks will be partial.${C_0}"

section system "System"
result sys.info INFO "System" "${HOST} - ${OS_PRETTY} - kernel ${KERNEL} - public IP ${PUBLIC_IP}"

case "${ID:-}" in
    debian|ubuntu) result sys.os PASS "Operating system" "${OS_PRETTY} is supported" ;;
    *) if [[ "${ID_LIKE:-}" == *debian* ]]; then
           result sys.os WARN "Operating system" "${OS_PRETTY} is Debian-based but not tested"
       else
           result sys.os WARN "Operating system" "${OS_PRETTY} is not Debian/Ubuntu - many checks will not apply"
       fi ;;
esac

if [[ -f /var/run/reboot-required ]]; then
    pkgs=$(tr '\n' ' ' < /var/run/reboot-required.pkgs 2>/dev/null)
    result sys.reboot WARN "Reboot required" "A reboot is pending to apply updates ${pkgs:+($pkgs)}" "sudo reboot"
else
    result sys.reboot PASS "Reboot required" "No reboot pending"
fi

if have timedatectl; then
    if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]]; then
        result sys.time PASS "Time sync" "Clock is NTP-synchronized"
    else
        result sys.time WARN "Time sync" "Clock is not NTP-synchronized (TLS, logs and 2FA depend on it)" "apt install chrony"
    fi
fi

# ----------------------------------------------------------------------------
# Updates
# ----------------------------------------------------------------------------
section updates "Updates"
if have apt-get; then
    SIM=$(apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null | grep '^Inst ' || true)
    TOTAL_UPD=0; SEC_UPD=0
    if [[ -n "$SIM" ]]; then
        TOTAL_UPD=$(printf '%s\n' "$SIM" | wc -l)
        SEC_UPD=$(printf '%s\n' "$SIM" | grep -ci 'security' || true)
    fi
    LISTS_AGE=""
    if [[ -d /var/lib/apt/lists ]]; then
        newest=$(find /var/lib/apt/lists -maxdepth 1 -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1)
        [[ -n "$newest" ]] && LISTS_AGE=$(( ( $(date +%s) - ${newest%.*} ) / 3600 ))
    fi
    age_note=""; [[ -n "$LISTS_AGE" ]] && age_note=" (package lists ${LISTS_AGE}h old)"
    if [[ $SEC_UPD -gt 0 ]]; then
        result upd.security FAIL "Security updates" "${SEC_UPD} security update(s) pending, ${TOTAL_UPD} total${age_note}" "sudo apt update && sudo apt full-upgrade"
    elif [[ $TOTAL_UPD -gt 0 ]]; then
        result upd.security WARN "Security updates" "No security update pending, but ${TOTAL_UPD} regular update(s)${age_note}" "sudo apt update && sudo apt full-upgrade"
    else
        result upd.security PASS "Security updates" "System is up to date${age_note}"
    fi

    if dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null | grep -q "ok installed"; then
        if apt-config dump 2>/dev/null | grep -q 'APT::Periodic::Unattended-Upgrade "1"'; then
            result upd.unattended PASS "Automatic security updates" "unattended-upgrades is installed and enabled"
        else
            result upd.unattended WARN "Automatic security updates" "unattended-upgrades is installed but not enabled" "sudo dpkg-reconfigure -plow unattended-upgrades"
        fi
    else
        result upd.unattended FAIL "Automatic security updates" "unattended-upgrades is not installed" "sudo apt install unattended-upgrades"
    fi
fi

# ----------------------------------------------------------------------------
# SSH
# ----------------------------------------------------------------------------
section ssh "SSH"

SSHD_T=""
if have sshd && [[ $IS_ROOT -eq 1 ]]; then
    SSHD_T=$(sshd -T 2>/dev/null || true)
fi
# sshd_get KEY [connection spec for -C]
sshd_get() {
    local key="$1" spec="${2:-}"
    if [[ -n "$spec" ]]; then
        sshd -T -C "$spec" 2>/dev/null | awk -v k="$key" '$1==k {print $2; exit}'
    else
        printf '%s\n' "$SSHD_T" | awk -v k="$key" '$1==k {print $2; exit}'
    fi
}
# Fallback for non-root: first matching line in drop-ins then main config
sshd_grep() {
    local key="$1"
    grep -hiE "^[[:space:]]*${key}[[:space:]]" /etc/ssh/sshd_config.d/*.conf /etc/ssh/sshd_config 2>/dev/null \
        | head -1 | awk '{print $2}'
}

if ! have sshd && [[ ! -f /etc/ssh/sshd_config ]]; then
    result ssh.installed INFO "SSH server" "OpenSSH server is not installed"
else
    EXT_SPEC="user=root,host=audit.example,addr=198.51.100.7"
    LO_SPEC="user=root,host=localhost,addr=127.0.0.1"
    if [[ -n "$SSHD_T" ]]; then
        ROOT_GLOBAL=$(sshd_get permitrootlogin)
        ROOT_EXT=$(sshd_get permitrootlogin "$EXT_SPEC")
        ROOT_LO=$(sshd_get permitrootlogin "$LO_SPEC")
        PASS_EXT=$(sshd_get passwordauthentication "user=audituser,host=audit.example,addr=198.51.100.7")
        KBD=$(sshd_get kbdinteractiveauthentication)
        USEPAM=$(sshd_get usepam)
        SSH_PORTS=$(printf '%s\n' "$SSHD_T" | awk '$1=="port"{print $2}' | sort -un | tr '\n' ' ' | sed 's/ $//')
        MAXAUTH=$(sshd_get maxauthtries)
        X11=$(sshd_get x11forwarding)
        ALLOWU=$(printf '%s\n' "$SSHD_T" | awk '$1=="allowusers" || $1=="allowgroups"' | head -1)
    else
        ROOT_GLOBAL=$(sshd_grep PermitRootLogin); ROOT_GLOBAL=${ROOT_GLOBAL:-prohibit-password}
        ROOT_EXT=$ROOT_GLOBAL; ROOT_LO=$ROOT_GLOBAL
        PASS_EXT=$(sshd_grep PasswordAuthentication); PASS_EXT=${PASS_EXT:-yes}
        KBD=$(sshd_grep KbdInteractiveAuthentication); KBD=${KBD:-no}
        USEPAM=yes
        SSH_PORTS=$(sshd_grep Port); SSH_PORTS=${SSH_PORTS:-22}
        MAXAUTH=$(sshd_grep MaxAuthTries); MAXAUTH=${MAXAUTH:-6}
        X11=$(sshd_grep X11Forwarding); X11=${X11:-no}
        ALLOWU=$(sshd_grep AllowUsers)
    fi
    ROOT_GLOBAL=${ROOT_GLOBAL,,}; ROOT_EXT=${ROOT_EXT,,}; ROOT_LO=${ROOT_LO,,}

    if [[ "$ROOT_EXT" == "no" ]]; then
        if [[ -n "$ROOT_LO" && "$ROOT_LO" != "no" ]]; then
            result ssh.root_login PASS "SSH root login" "Disabled from the internet; key-only root allowed from trusted addresses (panel/tunnel)"
        else
            result ssh.root_login PASS "SSH root login" "Root login is disabled"
        fi
    elif [[ "$ROOT_EXT" == "prohibit-password" || "$ROOT_EXT" == "without-password" || "$ROOT_EXT" == "forced-commands-only" ]]; then
        result ssh.root_login WARN "SSH root login" "Root can log in with a key from any address (PermitRootLogin ${ROOT_EXT})$(need_root_note)" \
            "PermitRootLogin no + a 'Match Address <trusted>' block allowing prohibit-password"
    else
        result ssh.root_login FAIL "SSH root login" "Root login with password is allowed (PermitRootLogin ${ROOT_EXT:-yes})" \
            "Set PermitRootLogin no in /etc/ssh/sshd_config.d/00-hardening.conf"
    fi

    if [[ "${PASS_EXT,,}" == "no" ]]; then
        result ssh.password_auth PASS "SSH password authentication" "Disabled - key-based authentication only"
    else
        result ssh.password_auth FAIL "SSH password authentication" "Password authentication is enabled - brute-force target" \
            "PasswordAuthentication no (after installing your SSH key)"
    fi

    if [[ "${KBD,,}" == "yes" && "${USEPAM,,}" == "yes" ]]; then
        result ssh.kbd_interactive WARN "SSH keyboard-interactive" "Enabled with PAM - may still allow password prompts" "KbdInteractiveAuthentication no"
    else
        result ssh.kbd_interactive PASS "SSH keyboard-interactive" "Disabled"
    fi

    if [[ " $SSH_PORTS " == *" 22 "* ]]; then
        result ssh.port WARN "SSH port" "SSH listens on 22 (${SSH_PORTS}) - receives all automated scans" "Port <other> in sshd config + firewall rule"
    else
        result ssh.port PASS "SSH port" "SSH listens on non-default port(s): ${SSH_PORTS}"
    fi

    if [[ "${MAXAUTH:-6}" =~ ^[0-9]+$ && ${MAXAUTH:-6} -le 4 ]]; then
        result ssh.max_auth PASS "SSH MaxAuthTries" "MaxAuthTries=${MAXAUTH}"
    else
        result ssh.max_auth WARN "SSH MaxAuthTries" "MaxAuthTries=${MAXAUTH:-6} (recommended <= 4)" "MaxAuthTries 3"
    fi

    if [[ "${X11,,}" == "yes" ]]; then
        result ssh.x11 WARN "SSH X11 forwarding" "X11Forwarding is enabled" "X11Forwarding no"
    else
        result ssh.x11 PASS "SSH X11 forwarding" "Disabled"
    fi

    if [[ -n "$ALLOWU" ]]; then
        result ssh.allow_users PASS "SSH user allow-list" "Only listed users can log in ($(echo "$ALLOWU" | cut -c1-120))"
    else
        result ssh.allow_users WARN "SSH user allow-list" "No AllowUsers/AllowGroups - every account with a key can log in" "AllowUsers <admin> root@<trusted-ip>"
    fi

    if [[ $IS_ROOT -eq 1 && -s /root/.ssh/authorized_keys ]]; then
        nkeys=$(grep -cE '^[^#[:space:]]' /root/.ssh/authorized_keys || true)
        nfrom=$(grep -cE '^[^#]*from="' /root/.ssh/authorized_keys || true)
        if [[ "$ROOT_EXT" != "no" && $nfrom -lt $nkeys ]]; then
            result ssh.root_keys WARN "Root authorized_keys" "${nkeys} key(s), $((nkeys-nfrom)) without from= restriction" 'Prefix keys with from="<panel-ip>"'
        else
            result ssh.root_keys PASS "Root authorized_keys" "${nkeys} key(s) (${nfrom} restricted with from=)"
        fi
    fi
fi

# ----------------------------------------------------------------------------
# Firewall & network exposure
# ----------------------------------------------------------------------------
section firewall "Firewall & network exposure"

UFW_ACTIVE=0
UFW_STATUS=""
if have ufw && [[ $IS_ROOT -eq 1 ]]; then
    UFW_STATUS=$(ufw status verbose 2>/dev/null || true)
    if grep -q "^Status: active" <<<"$UFW_STATUS"; then
        UFW_ACTIVE=1
        if grep -qE "^Default:.*deny \(incoming\)|^Default:.*reject \(incoming\)" <<<"$UFW_STATUS"; then
            result fw.status PASS "Firewall (UFW)" "Active, incoming traffic denied by default"
        else
            result fw.status WARN "Firewall (UFW)" "Active but the default incoming policy is not deny" "sudo ufw default deny incoming"
        fi
    else
        result fw.status FAIL "Firewall (UFW)" "UFW is installed but inactive - every listening port is reachable" "sudo ufw enable (allow your SSH port first!)"
    fi
elif have ufw; then
    result fw.status WARN "Firewall (UFW)" "Cannot read UFW status without root"
elif have nft && [[ $IS_ROOT -eq 1 ]] && nft list ruleset 2>/dev/null | grep -qE 'hook input .*policy drop'; then
    UFW_ACTIVE=1
    result fw.status PASS "Firewall (nftables)" "nftables input chain with drop policy found"
else
    result fw.status FAIL "Firewall" "No active firewall detected" "sudo apt install ufw && sudo ufw enable"
fi

# Is Docker prevented from bypassing the firewall?
DOCKER_ACTIVE=0
DOCKER_PROTECTED=1
if have docker && systemctl is-active --quiet docker 2>/dev/null; then
    DOCKER_ACTIVE=1
    if [[ $IS_ROOT -eq 1 ]]; then
        if [[ -f /etc/docker/daemon.json ]] && grep -qE '"iptables"[[:space:]]*:[[:space:]]*false' /etc/docker/daemon.json; then
            result fw.docker_bypass PASS "Docker vs firewall" "Docker iptables management disabled (iptables=false)"
        elif iptables -S DOCKER-USER 2>/dev/null | grep -qE 'ufw-user-forward|ufw-docker|DROP'; then
            result fw.docker_bypass PASS "Docker vs firewall" "DOCKER-USER chain filters published container ports"
        else
            DOCKER_PROTECTED=0
            if [[ $UFW_ACTIVE -eq 1 ]]; then
                result fw.docker_bypass FAIL "Docker vs firewall" "Published container ports bypass UFW (no DOCKER-USER filtering)" \
                    "sudo ./server-prep.sh --config /etc/server-prep/server-prep.conf --only firewall --yes (installs the ufw-docker rules)"
            else
                result fw.docker_bypass WARN "Docker vs firewall" "No DOCKER-USER filtering (and no active firewall)"
            fi
        fi
    else
        result fw.docker_bypass WARN "Docker vs firewall" "Cannot inspect iptables without root"
    fi
fi

# UFW port matching: is PORT/PROTO allowed from "Anywhere"? echo any|restricted|none
ufw_port_access() {
    local port="$1" proto="$2" line to from spec p best="none"
    [[ $UFW_ACTIVE -eq 1 && -n "$UFW_STATUS" ]] || { echo "nofw"; return; }
    while IFS= read -r line; do
        [[ "$line" =~ ^(.+[^[:space:]])[[:space:]]{2,}(ALLOW|LIMIT)[[:space:]]+(IN[[:space:]]+)?(.+)$ ]] || continue
        to="${BASH_REMATCH[1]}"; from="${BASH_REMATCH[4]}"
        [[ "$line" == *"FWD"* ]] && continue
        to="${to% (v6)}"; from="${from% (v6)}"
        local iface=""
        if [[ "$to" == *" on "* ]]; then iface="${to##* on }"; to="${to%% on *}"; fi
        local matched=0
        if [[ "$to" == "Anywhere" ]]; then
            matched=1
        else
            spec="${to%%/*}"; p="${to#*/}"; [[ "$to" == */* ]] || p="any"
            [[ "$p" == "any" || "$p" == "$proto" ]] || continue
            local IFS_OLD=$IFS; IFS=','
            for s in $spec; do
                if [[ "$s" == *:* ]]; then
                    [[ $port -ge ${s%%:*} && $port -le ${s##*:} ]] && matched=1
                elif [[ "$s" == "$port" ]]; then matched=1
                fi
            done
            IFS=$IFS_OLD
        fi
        [[ $matched -eq 1 ]] || continue
        if [[ -z "$iface" && "$from" == Anywhere* ]]; then echo "any"; return; fi
        best="restricted"
    done < <(sed -n '/^--/,$p' <<<"$UFW_STATUS" | tail -n +2)
    echo "$best"
}

classify_addr() {
    local a="$1"
    a="${a#[}"; a="${a%]}"; a="${a%%%*}"
    case "$a" in
        0.0.0.0|::|'*') echo all ;;
        127.*|::1) echo local ;;
        100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*|fd7a:115c:a1e0:*) echo tailnet ;;
        10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|fe80:*|fd*|fc*) echo private ;;
        *) echo specific ;;
    esac
}

if have ss; then
    EXPOSED=(); FILTERED=(); LOCALONLY=(); PRIVATE=()
    declare -A SEEN=()
    DOCKER_PORTS=" "
    if [[ $DOCKER_ACTIVE -eq 1 && $IS_ROOT -eq 1 ]]; then
        DOCKER_PORTS+=$(docker ps --format '{{.Ports}}' 2>/dev/null | grep -oE '(0\.0\.0\.0|\[::\]|::):[0-9]+->' | grep -oE ':[0-9]+->' | tr -d ':>-' | sort -un | tr '\n' ' ')
    fi
    while read -r local proc; do
        port="${local##*:}"; addr="${local%:*}"
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        cls=$(classify_addr "$addr")
        name=$(grep -oE '\("[^"]+"' <<<"$proc" | head -1 | tr -d '("')
        key="${port}"
        case "$cls" in
            local) [[ -n "${SEEN[l$key]:-}" ]] || LOCALONLY+=("$port"); SEEN[l$key]=1; continue ;;
            tailnet|private) [[ -n "${SEEN[p$key]:-}" ]] || PRIVATE+=("$port${name:+($name)}"); SEEN[p$key]=1; continue ;;
        esac
        [[ -n "${SEEN[x$key]:-}" ]] && continue
        SEEN[x$key]=1
        if [[ "$DOCKER_PORTS" == *" $port "* ]]; then
            if [[ $DOCKER_PROTECTED -eq 0 ]]; then EXPOSED+=("$port(docker,bypasses fw)")
            elif grep -qE "^${port}(/tcp)?[[:space:]].*ALLOW FWD[[:space:]]+Anywhere" <<<"$UFW_STATUS"; then EXPOSED+=("$port(docker)")
            else FILTERED+=("$port(docker)")
            fi
            continue
        fi
        case "$(ufw_port_access "$port" tcp)" in
            any|nofw) EXPOSED+=("$port${name:+($name)}") ;;
            restricted) FILTERED+=("$port${name:+($name)},restricted") ;;
            none) FILTERED+=("$port${name:+($name)}") ;;
        esac
    done < <(ss -H -ltnp 2>/dev/null | awk '{print $4, $6}')

    n=${#EXPOSED[@]}
    detail="internet-exposed: ${EXPOSED[*]:-none}; firewalled: ${FILTERED[*]:-none}; tailnet/LAN only: ${PRIVATE[*]:-none}; localhost only: ${LOCALONLY[*]:-none}"
    if [[ $n -lt $EXPOSED_WARN ]]; then
        result net.exposure PASS "Exposed TCP ports" "$n exposed - $detail"
    elif [[ $n -lt $EXPOSED_FAIL ]]; then
        result net.exposure WARN "Exposed TCP ports" "$n exposed - $detail" "Close unneeded ports or restrict them in UFW"
    else
        result net.exposure FAIL "Exposed TCP ports" "$n exposed - $detail" "Close unneeded ports or restrict them in UFW"
    fi
fi

# ----------------------------------------------------------------------------
# Intrusion prevention
# ----------------------------------------------------------------------------
section ips "Intrusion prevention"

F2B=0; CS=0
if have fail2ban-client || dpkg-query -W fail2ban >/dev/null 2>&1; then
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        F2B=2
        banned=""
        [[ $IS_ROOT -eq 1 ]] && banned=$(fail2ban-client status sshd 2>/dev/null | awk -F: '/Currently banned/{gsub(/ /,"",$2); print $2}')
        result ips.fail2ban PASS "fail2ban" "Running${banned:+ - ${banned} IP(s) currently banned in sshd jail}"
    else
        F2B=1
        result ips.fail2ban WARN "fail2ban" "Installed but not running" "sudo systemctl enable --now fail2ban"
    fi
fi
if have cscli || systemctl cat crowdsec >/dev/null 2>&1; then
    if systemctl is-active --quiet crowdsec 2>/dev/null; then
        CS=2
        dec=""
        [[ $IS_ROOT -eq 1 ]] && dec=$(cscli decisions list -o raw 2>/dev/null | tail -n +2 | wc -l)
        result ips.crowdsec PASS "CrowdSec" "Running${dec:+ - ${dec} active local decision(s)}"
        if systemctl list-units --type=service --state=running 2>/dev/null | grep -q 'crowdsec-firewall-bouncer'; then
            result ips.crowdsec_bouncer PASS "CrowdSec bouncer" "Firewall bouncer is running (bans are enforced)"
        else
            result ips.crowdsec_bouncer FAIL "CrowdSec bouncer" "No firewall bouncer running - CrowdSec detects but does not block" \
                "sudo apt install crowdsec-firewall-bouncer-iptables"
        fi
    else
        CS=1
        result ips.crowdsec WARN "CrowdSec" "Installed but not running" "sudo systemctl enable --now crowdsec"
    fi
fi
if [[ $F2B -eq 0 && $CS -eq 0 ]]; then
    result ips.any FAIL "Intrusion prevention" "Neither fail2ban nor CrowdSec is installed" "sudo apt install fail2ban (and/or CrowdSec)"
elif [[ $F2B -eq 2 || $CS -eq 2 ]]; then
    result ips.any PASS "Intrusion prevention" "At least one IPS is active"
else
    result ips.any WARN "Intrusion prevention" "IPS installed but not running"
fi

# fail2ban [sshd] jail must watch the port sshd really listens on
get_jail_option() {
    local section="$1" option="$2" file value result=""
    for file in /etc/fail2ban/jail.conf /etc/fail2ban/jail.d/*.conf /etc/fail2ban/jail.local /etc/fail2ban/jail.d/*.local; do
        [[ -f "$file" ]] || continue
        value=$(awk -v sect="$section" -v opt="$option" '
            /^[[:space:]]*\[/ { in_sect = ($0 ~ "^[[:space:]]*\\[" sect "\\][[:space:]]*$"); next }
            in_sect && $0 ~ "^[[:space:]]*" opt "[[:space:]]*=" { sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); val = $0 }
            END { if (val != "") print val }' "$file" 2>/dev/null)
        [[ -n "$value" ]] && result="$value"
    done
    echo "$result"
}
port_in_list() {
    local list="$1" target="$2" tok a b IFS=','
    for tok in $list; do
        tok="${tok//[[:space:]]/}"
        [[ -z "$tok" ]] && continue
        if [[ "$tok" == *:* ]]; then
            a=${tok%%:*}; b=${tok##*:}
            [[ "$a" =~ ^[0-9]+$ ]] || a=$(getent services "$a" | awk '{print $2}' | cut -d/ -f1)
            [[ "$b" =~ ^[0-9]+$ ]] || b=$(getent services "$b" | awk '{print $2}' | cut -d/ -f1)
            [[ -n "$a" && -n "$b" && $target -ge $a && $target -le $b ]] && return 0
        else
            [[ "$tok" =~ ^[0-9]+$ ]] || tok=$(getent services "$tok" | awk '{print $2}' | cut -d/ -f1)
            [[ "$tok" == "$target" ]] && return 0
        fi
    done
    return 1
}
if [[ $F2B -ge 1 && -d /etc/fail2ban ]]; then
    j_en=$(get_jail_option sshd enabled)
    j_port=$(get_jail_option sshd port); j_port=${j_port:-ssh}
    j_ban=$(get_jail_option sshd banaction); [[ -z "$j_ban" ]] && j_ban=$(get_jail_option DEFAULT banaction)
    if [[ "$j_en" != "true" ]]; then
        result ips.f2b_sshd_jail WARN "fail2ban sshd jail" "The [sshd] jail is not enabled" "[sshd] enabled = true in /etc/fail2ban/jail.local"
    elif [[ "$j_ban" == *allports* ]]; then
        result ips.f2b_sshd_jail PASS "fail2ban sshd jail" "Enabled, bans all ports"
    else
        missing=""
        for p in ${SSH_PORTS:-22}; do port_in_list "$j_port" "$p" || missing+="$p "; done
        if [[ -z "$missing" ]]; then
            result ips.f2b_sshd_jail PASS "fail2ban sshd jail" "Enabled and covers SSH port(s) ${SSH_PORTS:-22}"
        else
            result ips.f2b_sshd_jail FAIL "fail2ban sshd jail" "Jail blocks port '${j_port}' but SSH listens on ${missing}- bans are ineffective" \
                "port = ${SSH_PORTS// /,} in the [sshd] section of /etc/fail2ban/jail.local"
        fi
    fi
fi

# Failed SSH logins (last 24h)
FAILED=0
if have journalctl; then
    FAILED=$(journalctl --since "24 hours ago" SYSLOG_IDENTIFIER=sshd SYSLOG_IDENTIFIER=sshd-session 2>/dev/null \
        | grep -cE 'Failed password|Invalid user|authentication failure|Connection closed by authenticating user' || true)
elif [[ -r /var/log/auth.log ]]; then
    FAILED=$(grep -cE 'Failed password|Invalid user' /var/log/auth.log || true)
fi
FAILED=${FAILED:-0}
if [[ $FAILED -lt $LOGINS_WARN ]]; then
    result ips.failed_logins PASS "Failed SSH logins (24h)" "${FAILED} failed attempt(s)$(need_root_note)"
elif [[ $FAILED -lt $LOGINS_FAIL ]]; then
    result ips.failed_logins WARN "Failed SSH logins (24h)" "${FAILED} failed attempts - you are being scanned"
else
    result ips.failed_logins FAIL "Failed SSH logins (24h)" "${FAILED} failed attempts - brute force in progress" "Enable fail2ban/CrowdSec, key-only auth"
fi

# ----------------------------------------------------------------------------
# Accounts & authentication
# ----------------------------------------------------------------------------
section accounts "Accounts & authentication"

if sudo --version 2>/dev/null | head -1 | grep -qi 'sudo-rs'; then
    result acc.sudo_log PASS "Sudo logging" "sudo-rs logs every command to the journal (journalctl _COMM=sudo)"
elif grep -qsE '^[[:space:]]*Defaults.*logfile' /etc/sudoers /etc/sudoers.d/* 2>/dev/null; then
    result acc.sudo_log PASS "Sudo logging" "Sudo commands are written to a dedicated log file"
elif [[ $IS_ROOT -eq 0 ]]; then
    result acc.sudo_log WARN "Sudo logging" "Cannot read /etc/sudoers without root"
else
    result acc.sudo_log WARN "Sudo logging" "Sudo only logs to syslog/journal (default) - no dedicated log file" \
        'Add Defaults logfile="/var/log/sudo.log" to /etc/sudoers (visudo)'
fi

MINLEN=$(cat /etc/security/pwquality.conf /etc/security/pwquality.conf.d/*.conf 2>/dev/null \
    | grep -E '^[[:space:]]*minlen[[:space:]]*=' | tail -1 | cut -d= -f2 | tr -d '[:space:]')
PAM_PWQ=0; grep -qs 'pam_pwquality' /etc/pam.d/common-password && PAM_PWQ=1
if [[ -z "$MINLEN" ]]; then
    result acc.password_policy FAIL "Password policy" "No minlen in pwquality.conf - weak passwords accepted" \
        "apt install libpam-pwquality; minlen = ${PASSWORD_MINLEN} in /etc/security/pwquality.conf"
elif [[ ! "$MINLEN" =~ ^[0-9]+$ ]]; then
    result acc.password_policy WARN "Password policy" "Cannot parse minlen='${MINLEN}'"
elif [[ $MINLEN -lt $PASSWORD_MINLEN ]]; then
    result acc.password_policy FAIL "Password policy" "minlen=${MINLEN} is below ${PASSWORD_MINLEN}" "minlen = ${PASSWORD_MINLEN}"
elif [[ $PAM_PWQ -eq 0 ]]; then
    result acc.password_policy WARN "Password policy" "minlen=${MINLEN} but pam_pwquality is not in /etc/pam.d/common-password" "apt install libpam-pwquality"
else
    result acc.password_policy PASS "Password policy" "minlen=${MINLEN}, enforced by pam_pwquality"
fi

if [[ $PAM_PWQ -eq 1 ]]; then
    if [[ -f /var/cache/cracklib/cracklib_dict.pwd ]]; then
        result acc.password_dict PASS "Password dictionary" "cracklib dictionary present: password changes work"
    elif cat /etc/security/pwquality.conf /etc/security/pwquality.conf.d/*.conf 2>/dev/null \
            | grep -qE '^[[:space:]]*dictcheck[[:space:]]*=[[:space:]]*0'; then
        result acc.password_dict INFO "Password dictionary" "cracklib dictionary missing, dictionary check off (dictcheck = 0)" \
            "apt install --reinstall cracklib-runtime && update-cracklib"
    else
        result acc.password_dict FAIL "Password dictionary" "cracklib dictionary missing: every password change fails (error loading dictionary)" \
            "apt install --reinstall cracklib-runtime && update-cracklib"
    fi
fi

UID0=$(awk -F: '$3==0 && $1!="root"{print $1}' /etc/passwd | tr '\n' ' ')
if [[ -n "$UID0" ]]; then
    result acc.uid0 FAIL "UID 0 accounts" "Accounts other than root with UID 0: ${UID0}" "Remove or re-number them"
else
    result acc.uid0 PASS "UID 0 accounts" "Only root has UID 0"
fi

if [[ $IS_ROOT -eq 1 ]]; then
    EMPTY=$(awk -F: '$2==""{print $1}' /etc/shadow | tr '\n' ' ')
    if [[ -n "$EMPTY" ]]; then
        result acc.empty_passwords FAIL "Empty passwords" "Accounts with an empty password: ${EMPTY}" "passwd -l <user>"
    else
        result acc.empty_passwords PASS "Empty passwords" "No account has an empty password"
    fi
    NOPW=$(grep -hsE '^[^#].*NOPASSWD' /etc/sudoers /etc/sudoers.d/* | awk '{print $1}' | sort -u | tr '\n' ' ')
    [[ -n "$NOPW" ]] && result acc.nopasswd INFO "Passwordless sudo" "NOPASSWD rules for: ${NOPW}"
fi

# ----------------------------------------------------------------------------
# Kernel & system settings
# ----------------------------------------------------------------------------
section kernel "Kernel & system settings"

# key expected (">=N" means numeric minimum, "a|b" means any of)
SYSCTL_EXPECT=(
    "net.ipv4.tcp_syncookies 1"
    "net.ipv4.conf.all.rp_filter 1|2"
    "net.ipv4.conf.all.accept_redirects 0"
    "net.ipv4.conf.default.accept_redirects 0"
    "net.ipv6.conf.all.accept_redirects 0"
    "net.ipv4.conf.all.send_redirects 0"
    "net.ipv4.conf.all.accept_source_route 0"
    "net.ipv4.conf.all.log_martians 1"
    "net.ipv4.icmp_echo_ignore_broadcasts 1"
    "kernel.randomize_va_space 2"
    "kernel.kptr_restrict >=1"
    "kernel.dmesg_restrict 1"
    "kernel.yama.ptrace_scope >=1"
    "kernel.unprivileged_bpf_disabled >=1"
    "fs.suid_dumpable 0"
    "fs.protected_symlinks 1"
    "fs.protected_hardlinks 1"
)
BAD=()
for e in "${SYSCTL_EXPECT[@]}"; do
    k=${e%% *}; want=${e#* }
    v=$(sysctl -n "$k" 2>/dev/null) || continue
    ok=0
    if [[ "$want" == ">="* ]]; then
        [[ "$v" =~ ^[0-9]+$ && $v -ge ${want#>=} ]] && ok=1
    else
        [[ "|$want|" == *"|$v|"* ]] && ok=1
    fi
    [[ $ok -eq 1 ]] || BAD+=("$k=$v")
done
if [[ ${#BAD[@]} -eq 0 ]]; then
    result kern.sysctl PASS "Kernel parameters" "All ${#SYSCTL_EXPECT[@]} security parameters are set"
elif [[ ${#BAD[@]} -le 4 ]]; then
    result kern.sysctl WARN "Kernel parameters" "${#BAD[@]} not at the safe value: ${BAD[*]}" "/etc/sysctl.d/99-hardening.conf"
else
    result kern.sysctl FAIL "Kernel parameters" "${#BAD[@]} not at the safe value: ${BAD[*]}" "/etc/sysctl.d/99-hardening.conf"
fi

if have aa-enabled && [[ "$(aa-enabled 2>/dev/null)" == "Yes" ]]; then
    result kern.apparmor PASS "AppArmor" "Enabled"
elif [[ -r /sys/module/apparmor/parameters/enabled && "$(cat /sys/module/apparmor/parameters/enabled)" == "Y" ]]; then
    result kern.apparmor PASS "AppArmor" "Enabled"
else
    result kern.apparmor WARN "AppArmor" "Not enabled" "apt install apparmor"
fi

if [[ $IS_ROOT -eq 1 ]]; then
    WW=$(find /etc -xdev -type f -perm -0002 2>/dev/null | head -10 | tr '\n' ' ')
    if [[ -n "$WW" ]]; then
        result kern.world_writable FAIL "World-writable files in /etc" "$WW" "chmod o-w <file>"
    else
        result kern.world_writable PASS "World-writable files in /etc" "None"
    fi

    COMMON_SUID='^/usr/bin/|^/bin/|^/sbin/|^/usr/sbin/|^/usr/lib|^/usr/libexec'
    mapfile -t SUIDS < <(find / -xdev \( -path /var/lib/docker -o -path /var/lib/containerd \) -prune -o -type f -perm -4000 -print 2>/dev/null | grep -vE "$COMMON_SUID")
    UNOWNED=()
    for f in "${SUIDS[@]}"; do
        dpkg -S "$f" >/dev/null 2>&1 || UNOWNED+=("$f")
    done
    if [[ ${#UNOWNED[@]} -gt 0 ]]; then
        result kern.suid WARN "SUID files" "${#SUIDS[@]} outside standard paths, ${#UNOWNED[@]} not owned by any package: ${UNOWNED[*]:0:8}" \
            "Verify each file; chmod u-s if not needed"
    else
        result kern.suid PASS "SUID files" "${#SUIDS[@]} outside standard paths, all owned by packages"
    fi
fi

# ----------------------------------------------------------------------------
# Logging & monitoring
# ----------------------------------------------------------------------------
section monitoring "Logging & monitoring"

if systemctl is-active --quiet auditd 2>/dev/null; then
    rules=""
    [[ $IS_ROOT -eq 1 ]] && rules=$(auditctl -l 2>/dev/null | grep -vc '^No rules' || true)
    result mon.auditd PASS "auditd" "Running${rules:+ with ${rules} rule(s)}"
else
    result mon.auditd WARN "auditd" "Not running - no audit trail of sensitive changes" "apt install auditd"
fi

if have rkhunter; then
    result mon.rkhunter PASS "rkhunter" "Installed"
else
    result mon.rkhunter WARN "rkhunter" "Not installed (rootkit scanner)" "apt install rkhunter"
fi

if ls /var/lib/aide/aide.db* >/dev/null 2>&1; then
    result mon.aide PASS "AIDE" "File-integrity database present"
elif have aide; then
    result mon.aide WARN "AIDE" "Installed but no database" "sudo aideinit"
else
    result mon.aide WARN "AIDE" "Not installed (file-integrity monitoring)" "apt install aide"
fi

if [[ -d /var/log/journal ]] || grep -qsE '^[[:space:]]*Storage=persistent' /etc/systemd/journald.conf /etc/systemd/journald.conf.d/*.conf; then
    result mon.journal PASS "Persistent logs" "journald keeps logs across reboots"
else
    result mon.journal WARN "Persistent logs" "journald logs are volatile (lost at reboot)" "mkdir /var/log/journal"
fi

# server-prep 1.1.1 and older: run logs readable by every local user (they can hold the Cloudflare
# tunnel token), and a server-prep-notify that puts the Telegram bot token on curl's command line
PREP_LOGS=/var/log/server-prep PREP_NOTIFY=/usr/local/sbin/server-prep-notify
if [[ -d "$PREP_LOGS" || -f "$PREP_NOTIFY" ]]; then
    prep_msg=""; prep_fix=""
    if [[ -d "$PREP_LOGS" ]]; then
        prep_mode=$(stat -c %a "$PREP_LOGS" 2>/dev/null)
        prep_open=0
        [[ $IS_ROOT -eq 1 ]] && prep_open=$(find "$PREP_LOGS" -maxdepth 1 -type f -perm /077 2>/dev/null | wc -l)
        if (( 8#${prep_mode:-700} & 8#077 )); then
            prep_msg="${PREP_LOGS} is ${prep_mode}: local users can read the run logs, and logs from 1.1.1 and older can hold the tunnel token (rotate it if a log left the server); "
        elif [[ $prep_open -gt 0 ]]; then
            prep_msg="${prep_open} file(s) in ${PREP_LOGS} are readable by others, and a copy keeps that mode; "
        fi
        [[ -n "$prep_msg" ]] && prep_fix="sudo chmod 700 ${PREP_LOGS} && sudo find ${PREP_LOGS} -type f -exec chmod 600 {} +; "
    fi
    # the literal text of the old script, not an expansion
    # shellcheck disable=SC2016
    if grep -qsF 'bot${TELEGRAM_BOT_TOKEN}' "$PREP_NOTIFY"; then
        prep_msg+="server-prep-notify puts the Telegram bot token on curl's command line, where ps shows it; "
        prep_fix+="sudo ./server-prep.sh --config /etc/server-prep/server-prep.conf --only telegram --yes; "
    fi
    if [[ -n "$prep_msg" ]]; then
        result mon.prep_secrets WARN "server-prep secrets" "${prep_msg%; }" "${prep_fix%; }"
    else
        result mon.prep_secrets PASS "server-prep secrets" "Run logs are root only and no bot token is on a command line$(need_root_note)"
    fi
fi

# metrics agent: informational only (optional component)
if have telegraf; then
    TG_VER=$(telegraf --version 2>/dev/null | awk '{print $2}')
    if systemctl is-active --quiet telegraf 2>/dev/null; then
        result mon.telegraf INFO "Telegraf" "${TG_VER} running - metrics are being shipped"
    else
        result mon.telegraf INFO "Telegraf" "${TG_VER} installed, service stopped (not configured yet)" \
            "Configure it from telegraf.conf.example (guide: ${PROJECT_URL}/blob/main/docs/monitoring.md), then: systemctl enable --now telegraf"
    fi
fi

# ----------------------------------------------------------------------------
# Services
# ----------------------------------------------------------------------------
section services "Services"

SERVICES=$(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | wc -l)
if [[ $SERVICES -lt $SERVICES_WARN ]]; then
    result svc.count PASS "Running services" "${SERVICES} running"
elif [[ $SERVICES -lt $SERVICES_FAIL ]]; then
    result svc.count WARN "Running services" "${SERVICES} running - review the list (systemctl list-units --type=service --state=running)"
else
    result svc.count FAIL "Running services" "${SERVICES} running - large attack surface"
fi

UNNEEDED=()
for s in $UNNEEDED_SERVICES; do
    systemctl is-active --quiet "$s" 2>/dev/null && UNNEEDED+=("$s")
done
if [[ ${#UNNEEDED[@]} -gt 0 ]]; then
    result svc.unneeded WARN "Unneeded services" "Running: ${UNNEEDED[*]}" "sudo systemctl disable --now ${UNNEEDED[*]}"
else
    result svc.unneeded PASS "Unneeded services" "None of the usual desktop/legacy services are running"
fi

if systemctl is-active --quiet endlessh 2>/dev/null || systemctl is-active --quiet endlessh-go 2>/dev/null; then
    result svc.endlessh INFO "Endlessh" "SSH tarpit is running"
fi

# ----------------------------------------------------------------------------
# Resources
# ----------------------------------------------------------------------------
section resources "Resources"

DISK_PCT=$(df -P / | awk 'NR==2 {print int($5)}')
DISK_TXT=$(df -h / | awk 'NR==2 {print $3" used of "$2", "$4" free"}')
if [[ $DISK_PCT -lt $RESOURCE_WARN ]]; then result res.disk PASS "Disk usage" "${DISK_PCT}% (${DISK_TXT})"
elif [[ $DISK_PCT -lt $RESOURCE_FAIL ]]; then result res.disk WARN "Disk usage" "${DISK_PCT}% (${DISK_TXT})" "docker system prune / clean logs"
else result res.disk FAIL "Disk usage" "${DISK_PCT}% (${DISK_TXT})" "docker system prune / clean logs"
fi

MEM_PCT=$(free | awk '/^Mem:/ {printf "%.0f", ($2-$7)/$2*100}')
MEM_TXT=$(free -h | awk '/^Mem:/ {print $7" available of "$2}')
if [[ $MEM_PCT -lt $RESOURCE_WARN ]]; then result res.memory PASS "Memory usage" "${MEM_PCT}% (${MEM_TXT})"
elif [[ $MEM_PCT -lt $RESOURCE_FAIL ]]; then result res.memory WARN "Memory usage" "${MEM_PCT}% (${MEM_TXT})"
else result res.memory FAIL "Memory usage" "${MEM_PCT}% (${MEM_TXT})"
fi

SWAP_TOTAL=$(free | awk '/^Swap:/ {print $2}')
if [[ ${SWAP_TOTAL:-0} -gt 0 ]]; then
    result res.swap PASS "Swap" "$(free -h | awk '/^Swap:/ {print $2}') configured"
else
    result res.swap WARN "Swap" "No swap - builds can be OOM-killed" "fallocate -l 2G /swapfile && mkswap/swapon + fstab"
fi

CORES=$(nproc)
LOAD1=$(awk '{print $1}' /proc/loadavg)
if awk -v l="$LOAD1" -v c="$CORES" 'BEGIN{exit !(l < c*0.7)}'; then
    result res.load PASS "CPU load" "load ${LOAD1} on ${CORES} cores"
elif awk -v l="$LOAD1" -v c="$CORES" 'BEGIN{exit !(l < c)}'; then
    result res.load WARN "CPU load" "load ${LOAD1} on ${CORES} cores"
else
    result res.load FAIL "CPU load" "load ${LOAD1} on ${CORES} cores"
fi

# ----------------------------------------------------------------------------
# Docker
# ----------------------------------------------------------------------------
if have docker; then
    section docker "Docker"
    if [[ $DOCKER_ACTIVE -eq 1 ]]; then
        dver=$(docker version --format '{{.Server.Version}}' 2>/dev/null | head -1)
        result dock.running PASS "Docker engine" "Running${dver:+ (v${dver})}"
    else
        result dock.running WARN "Docker engine" "Installed but not running"
    fi
    if [[ -f /etc/docker/daemon.json ]] && grep -q 'max-size' /etc/docker/daemon.json; then
        result dock.log_rotation PASS "Container log rotation" "max-size set in /etc/docker/daemon.json"
    else
        result dock.log_rotation WARN "Container log rotation" "Container logs grow without limit" \
            '"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"} in /etc/docker/daemon.json'
    fi
    if [[ $DOCKER_ACTIVE -eq 1 && $IS_ROOT -eq 1 ]]; then
        PRIV=()
        while read -r cid; do
            [[ -z "$cid" ]] && continue
            if [[ "$(docker inspect -f '{{.HostConfig.Privileged}}' "$cid" 2>/dev/null)" == "true" ]]; then
                PRIV+=("$(docker inspect -f '{{.Name}}' "$cid" | tr -d /)")
            fi
        done < <(docker ps -q)
        if [[ ${#PRIV[@]} -gt 0 ]]; then
            result dock.privileged WARN "Privileged containers" "${PRIV[*]}" "Avoid --privileged unless required"
        else
            result dock.privileged PASS "Privileged containers" "None"
        fi
    fi
    DG=$(getent group docker | cut -d: -f4)
    [[ -n "$DG" ]] && result dock.group INFO "docker group" "Members (= root-equivalent): ${DG}"
fi

# ----------------------------------------------------------------------------
# Deployment panel readiness (Coolify, Dokploy, Openship...)
# ----------------------------------------------------------------------------
section panel "Panel readiness (Coolify, Dokploy...)"

MISSING=()
for c in curl wget git jq openssl; do have "$c" || MISSING+=("$c"); done
if [[ ${#MISSING[@]} -eq 0 ]]; then
    result panel.tools PASS "Required tools" "curl wget git jq openssl present"
else
    result panel.tools WARN "Required tools" "Missing: ${MISSING[*]}" "apt install ${MISSING[*]}"
fi

if [[ $DOCKER_ACTIVE -eq 1 ]]; then
    if docker compose version >/dev/null 2>&1; then
        result panel.docker PASS "Docker + Compose" "Docker and the compose plugin are available"
    else
        result panel.docker WARN "Docker + Compose" "Compose plugin missing" "apt install docker-compose-plugin"
    fi
else
    result panel.docker INFO "Docker + Compose" "Docker not running - most panels install it when the server is added"
fi

if [[ $IS_ROOT -eq 1 ]]; then
    if [[ -s /root/.ssh/authorized_keys ]]; then
        result panel.root_key PASS "Panel SSH access" "root has authorized key(s) - use the matching private key in the panel"
    elif grep -hsE '^[^#].*NOPASSWD:[[:space:]]*ALL' /etc/sudoers.d/* >/dev/null; then
        result panel.root_key INFO "Panel SSH access" "No root key; a NOPASSWD sudo user exists (panel non-root mode)"
    else
        result panel.root_key WARN "Panel SSH access" "No key for root and no passwordless-sudo user - a panel cannot connect" \
            "Add the panel's public key to /root/.ssh/authorized_keys"
    fi
fi

[[ -d /data/coolify ]] && result panel.data_dir INFO "Panel data" "/data/coolify exists (Coolify manages or prepared this server)"
[[ -d /etc/dokploy ]] && result panel.data_dir INFO "Panel data" "/etc/dokploy exists (Dokploy manages this server)"
if [[ $DOCKER_ACTIVE -eq 1 && $IS_ROOT -eq 1 ]]; then
    PROXY=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -m1 -E '^(coolify-proxy|dokploy-traefik)$')
    [[ -n "$PROXY" ]] && result panel.proxy INFO "Panel proxy" "${PROXY} container is running"
fi

# ----------------------------------------------------------------------------
# Summary & reports
# ----------------------------------------------------------------------------
N_PASS=0; N_WARN=0; N_FAIL=0; N_INFO=0
for s in "${R_STATUS[@]}"; do
    case "$s" in PASS) ((N_PASS++)) ;; WARN) ((N_WARN++)) ;; FAIL) ((N_FAIL++)) ;; *) ((N_INFO++)) ;; esac
done
SCORED=$((N_PASS + N_WARN + N_FAIL))
SCORE=0
[[ $SCORED -gt 0 ]] && SCORE=$(( (N_PASS * 100 + N_WARN * 50) / SCORED ))

out ""
out "${C_BOLD}Score: ${SCORE}/100${C_0} - ${C_GREEN}${N_PASS} PASS${C_0}, ${C_YELLOW}${N_WARN} WARN${C_0}, ${C_RED}${N_FAIL} FAIL${C_0}, ${N_INFO} INFO"

json_esc() {
    local s="$1"
    s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}; s=${s//$'\r'/}
    printf '%s' "$s"
}

if [[ $NO_TXT -eq 0 ]]; then
    mkdir -p "$(dirname "$TXT_OUT")"
    {
        echo "server-audit v${AUDIT_VERSION}"
        echo "Host: ${HOST} | OS: ${OS_PRETTY} | Kernel: ${KERNEL} | Public IP: ${PUBLIC_IP}"
        echo "Date: ${STARTED_AT} | Run as root: $([[ $IS_ROOT -eq 1 ]] && echo yes || echo no)"
        echo "================================"
        last=""
        for i in "${!R_ID[@]}"; do
            if [[ "${R_CAT[$i]}" != "$last" ]]; then echo; echo "## ${R_CAT[$i]}"; last="${R_CAT[$i]}"; fi
            echo "[${R_STATUS[$i]}] ${R_TITLE[$i]} - ${R_MSG[$i]}"
            [[ -n "${R_FIX[$i]}" && "${R_STATUS[$i]}" =~ ^(WARN|FAIL)$ ]] && echo "       fix: ${R_FIX[$i]}"
        done
        echo
        echo "================================"
        echo "Score: ${SCORE}/100 - ${N_PASS} PASS, ${N_WARN} WARN, ${N_FAIL} FAIL, ${N_INFO} INFO"
    } > "$TXT_OUT"
    out "Text report: ${TXT_OUT}"
fi

if [[ -n "$TSV_OUT" ]]; then
    : > "$TSV_OUT"
    for i in "${!R_ID[@]}"; do
        printf '%s\t%s\t%s\t%s\n' "${R_ID[$i]}" "${R_STATUS[$i]}" "${R_TITLE[$i]}" "${R_MSG[$i]//$'\t'/ }" >> "$TSV_OUT"
    done
fi

if [[ -n "$MD_OUT" ]]; then
    {
        echo "# Server audit - ${HOST}"
        echo
        echo "| | |"; echo "|---|---|"
        echo "| Date | ${STARTED_AT} |"
        echo "| OS | ${OS_PRETTY} (kernel ${KERNEL}) |"
        echo "| Public IP | ${PUBLIC_IP} |"
        echo "| Score | **${SCORE}/100** - ${N_PASS} PASS, ${N_WARN} WARN, ${N_FAIL} FAIL |"
        last=""
        for i in "${!R_ID[@]}"; do
            if [[ "${R_CAT[$i]}" != "$last" ]]; then
                echo; echo "## ${R_CAT[$i]}"; echo
                echo "| Status | Check | Result | Fix |"; echo "|---|---|---|---|"
                last="${R_CAT[$i]}"
            fi
            fix=""; [[ "${R_STATUS[$i]}" =~ ^(WARN|FAIL)$ ]] && fix="${R_FIX[$i]}"
            printf '| %s | %s | %s | %s |\n' "${R_STATUS[$i]}" "${R_TITLE[$i]}" "${R_MSG[$i]//|/\\|}" "${fix//|/\\|}"
        done
    } > "$MD_OUT"
    out "Markdown report: ${MD_OUT}"
fi

if [[ -n "$JSON_OUT" ]]; then
    {
        printf '{"tool":"server-audit","version":"%s","host":"%s","os":"%s","kernel":"%s","public_ip":"%s","date":"%s","root":%s,' \
            "$AUDIT_VERSION" "$(json_esc "$HOST")" "$(json_esc "$OS_PRETTY")" "$KERNEL" "$(json_esc "$PUBLIC_IP")" "$STARTED_AT" \
            "$([[ $IS_ROOT -eq 1 ]] && echo true || echo false)"
        printf '"score":%d,"summary":{"pass":%d,"warn":%d,"fail":%d,"info":%d},"checks":[' \
            "$SCORE" "$N_PASS" "$N_WARN" "$N_FAIL" "$N_INFO"
        for i in "${!R_ID[@]}"; do
            [[ $i -gt 0 ]] && printf ','
            printf '{"id":"%s","category":"%s","status":"%s","title":"%s","message":"%s","fix":"%s"}' \
                "${R_ID[$i]}" "${R_CAT[$i]}" "${R_STATUS[$i]}" "$(json_esc "${R_TITLE[$i]}")" \
                "$(json_esc "${R_MSG[$i]}")" "$(json_esc "${R_FIX[$i]}")"
        done
        printf ']}\n'
    } > "$JSON_OUT"
    out "JSON report: ${JSON_OUT}"
fi

if [[ -n "${SUDO_USER:-}" && $IS_ROOT -eq 1 ]]; then
    for f in "$TXT_OUT" "$MD_OUT" "$JSON_OUT" "$TSV_OUT"; do
        [[ -n "$f" && -f "$f" ]] && chown "$SUDO_USER": "$f" 2>/dev/null
    done
fi

[[ $N_FAIL -eq 0 ]]
