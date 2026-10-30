#!/usr/bin/env bash
# =============================================================================
# server-prep.sh - Secure a Debian/Ubuntu server (VPS or dedicated) and prepare it
#                 for a self-hosted PaaS panel (Coolify, Dokploy, Openship...)
#
#   Interactive:      sudo ./server-prep.sh
#   From a config:    sudo ./server-prep.sh --config server-prep.conf --yes
#   Preview only:     sudo ./server-prep.sh --dry-run
#   Some steps only:  sudo ./server-prep.sh --only ssh,firewall
#
# Every step is idempotent (safe to re-run), backs up files before changing
# them and is recorded in a Markdown report together with a before/after run
# of server-audit.sh.
# =============================================================================

set -u   # no pipefail: "cmd | grep -q" would turn SIGPIPE into false negatives
shopt -s lastpipe   # "... | write_file" must run in this shell to record changes

PREP_VERSION="1.1.1"
# Only look for a sibling audit when running from a file, not stdin or bash -c.
SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
TS="$(date +%Y%m%d_%H%M%S)"
HOST_SHORT="$(hostname -s)"

STATE_DIR=/var/lib/server-prep
BACKUP_DIR="$STATE_DIR/backups/$TS"
LOG_DIR=/var/log/server-prep
LOG_FILE="$LOG_DIR/run-$TS.log"
REPORT_DIR=/root/server-prep-reports
REPORT_FILE="$REPORT_DIR/server-prep-report-${HOST_SHORT}-${TS}.md"
CONF_DIR=/etc/server-prep

ALL_STEPS="update users docker firewall ssh ips unattended sysctl auth services laptop logging auditd rkhunter aide endlessh telegraf telegram cloudflared suid"

# ----------------------------------------------------------------------------
# Settings (all can come from --config FILE or environment variables)
# ----------------------------------------------------------------------------
ADMIN_USER="${ADMIN_USER:-}"
ADMIN_PUBKEY="${ADMIN_PUBKEY:-}"
PANEL="${PANEL:-}"                            # coolify, dokploy, openship... (used in messages; empty = none)
PANEL_PUBKEY="${PANEL_PUBKEY:-}"
PANEL_ACCESS="${PANEL_ACCESS:-}"              # cloudflared,tailscale,public (comma list)
PANEL_IP="${PANEL_IP:-}"                      # public IP of the panel server (public mode)
CLOUDFLARED_TOKEN="${CLOUDFLARED_TOKEN:-}"
SSH_PORT="${SSH_PORT:-822}"
ADMIN_IPS="${ADMIN_IPS:-}"                    # IPs/CIDRs allowed to SSH (space/comma list)
EXPOSE_WEB="${EXPOSE_WEB:-}"                  # yes/no: open 80/443 to the internet
EXTRA_PORTS="${EXTRA_PORTS:-}"                # e.g. "8000/tcp 6001/tcp"
TIMEZONE="${TIMEZONE:-}"
INSTALL_FAIL2BAN="${INSTALL_FAIL2BAN:-yes}"
INSTALL_CROWDSEC="${INSTALL_CROWDSEC:-yes}"
CROWDSEC_ENROLL_KEY="${CROWDSEC_ENROLL_KEY:-}"
CROWDSEC_LAPI_PORT="${CROWDSEC_LAPI_PORT:-8091}"   # 8080 is used by Traefik dashboards (Coolify, Dokploy)
INSTALL_DOCKER="${INSTALL_DOCKER:-yes}"
DOCKER_AUTO_UPDATE="${DOCKER_AUTO_UPDATE:-yes}"
AUTO_REBOOT="${AUTO_REBOOT:-no}"
AUTO_REBOOT_TIME="${AUTO_REBOOT_TIME:-04:00}"
DISABLE_SERVICES="${DISABLE_SERVICES:-}"      # filled interactively; default = all candidates
HEADLESS="${HEADLESS:-no}"
LAPTOP_MODE="${LAPTOP_MODE:-auto}"
INSTALL_AUDITD="${INSTALL_AUDITD:-yes}"
INSTALL_RKHUNTER="${INSTALL_RKHUNTER:-yes}"
INSTALL_AIDE="${INSTALL_AIDE:-yes}"
INSTALL_ENDLESSH="${INSTALL_ENDLESSH:-yes}"
INSTALL_TELEGRAF="${INSTALL_TELEGRAF:-yes}"   # metrics agent (InfluxData repo), installed but left unconfigured
TELEGRAM_ENABLE="${TELEGRAM_ENABLE:-no}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
TELEGRAM_IGNORE_USERS="${TELEGRAM_IGNORE_USERS:-root}"   # the panel logs in as root constantly
SWAP_SIZE="${SWAP_SIZE:-2G}"
PTRACE_SCOPE="${PTRACE_SCOPE:-2}"
AUDIT_SCRIPT="${AUDIT_SCRIPT:-}"
AUDIT_URL="${AUDIT_URL:-}"                    # raw URL of server-audit.sh (single-file installs)
PROJECT_URL="https://github.com/exceev-consulting/server-prep"   # guides linked from messages (release downloads have no docs/)

SERVICE_CANDIDATES="avahi-daemon cups cups-browsed bluetooth ModemManager apport"

DRY_RUN=0
INTERACTIVE=1
ASSUME_YES=0
ONLY=""
SKIP=""
CONFIG_FILE=""

usage() {
    cat <<EOF
server-prep.sh v${PREP_VERSION} - secure a Debian/Ubuntu server (VPS or dedicated) for a self-hosted PaaS panel

Usage: sudo $0 [options]

  --config FILE        read settings from FILE (see server-prep.conf.example)
  --yes                non-interactive: use config/env values and defaults
  --dry-run            show what would change, change nothing
  --only a,b,c         run only these steps
  --skip a,b,c         skip these steps
  --list-steps         print the step names
  -h, --help           this help

Exit codes:
  0  every selected step completed (or was skipped)
  1  a step failed, or the run stopped early (not root, unsupported OS, aborted, invalid settings)
  2  command-line usage error, including an unknown --only or --skip name

Steps: ${ALL_STEPS}
EOF
}

invalid_steps() {   # invalid_steps NAMES...: print names not in ALL_STEPS
    local name
    for name in "$@"; do
        [[ " $ALL_STEPS " == *" $name "* ]] || printf '%s\n' "$name"
    done
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) [[ $# -ge 2 ]] || { echo "--config needs a value" >&2; exit 2; }; CONFIG_FILE="$2"; shift 2 ;;
        --yes|-y) ASSUME_YES=1; INTERACTIVE=0; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --only) [[ $# -ge 2 ]] || { echo "--only needs a value" >&2; exit 2; }; ONLY="${2//,/ }"; shift 2 ;;
        --skip) [[ $# -ge 2 ]] || { echo "--skip needs a value" >&2; exit 2; }; SKIP="${2//,/ }"; shift 2 ;;
        --list-steps) echo "$ALL_STEPS"; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

check_step_names() {   # check_step_names NAMES...
    local bad_steps
    bad_steps="$(invalid_steps "$@" | paste -sd ' ' -)"
    if [[ -n "$bad_steps" ]]; then
        echo "Unknown step: ${bad_steps}" >&2
        echo "Valid steps: ${ALL_STEPS}" >&2
        exit 2
    fi
}

read -ra parsed_only <<< "$ONLY"
read -ra parsed_skip <<< "$SKIP"
check_step_names "${parsed_only[@]}" "${parsed_skip[@]}"

if [[ -n "$CONFIG_FILE" ]]; then
    [[ -r "$CONFIG_FILE" ]] || { echo "Cannot read $CONFIG_FILE" >&2; exit 2; }
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
fi
# Configs written before 1.1 used COOLIFY_* names
PANEL_PUBKEY="${PANEL_PUBKEY:-${COOLIFY_PUBKEY:-}}"
PANEL_ACCESS="${PANEL_ACCESS:-${COOLIFY_ACCESS:-}}"
PANEL_IP="${PANEL_IP:-${COOLIFY_IP:-}}"
read -ra parsed_only <<< "$ONLY"
read -ra parsed_skip <<< "$SKIP"
check_step_names "${parsed_only[@]}" "${parsed_skip[@]}"
[[ -z "$PANEL" && -n "${COOLIFY_PUBKEY:-}${COOLIFY_ACCESS:-}" ]] && PANEL=coolify
set_panel_label() {   # display name used in questions, notes and the report
    case "${PANEL,,}" in
        coolify) PANEL_LABEL="Coolify" ;;
        dokploy) PANEL_LABEL="Dokploy" ;;
        openship) PANEL_LABEL="Openship" ;;
        ""|none) PANEL_LABEL="your panel" ;;
        *) PANEL_LABEL="$PANEL" ;;
    esac
}
set_panel_label
# /dev/tty can have readable permissions without a controlling terminal.
if [[ $INTERACTIVE -eq 1 ]] && ! { true < /dev/tty; } 2>/dev/null; then
    echo "No terminal: use --yes with --config" >&2
    exit 2
fi

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_Y=$'\033[1;33m'; C_B=$'\033[0;34m'
    C_C=$'\033[0;36m'; C_D=$'\033[0;90m'; C_BOLD=$'\033[1m'; C_0=$'\033[0m'
else
    C_R=""; C_G=""; C_Y=""; C_B=""; C_C=""; C_D=""; C_BOLD=""; C_0=""
fi

log()   { printf '%s\n' "$*" >> "$LOG_FILE" 2>/dev/null || true; }
info()  { printf '%s\n' "${C_C}  ->${C_0} $*"; log "INFO: $*"; }
ok()    { printf '%s\n' "${C_G}  ok${C_0} $*"; log "OK: $*"; }
warn()  { printf '%s\n' "${C_Y}  !!${C_0} $*"; log "WARN: $*"; }
err()   { printf '%s\n' "${C_R}  xx${C_0} $*" >&2; log "ERROR: $*"; }
title() { printf '\n%s\n' "${C_B}${C_BOLD}=== $* ===${C_0}"; log "=== $* ==="; }
die()   { err "$*"; exit 1; }

# run CMD... : execute (or print in dry-run), output goes to the log
run() {
    log "+ $*"
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '%s\n' "${C_D}  [dry-run] $*${C_0}"
        return 0
    fi
    "$@" >> "$LOG_FILE" 2>&1
}

# run_secret SECRET CMD... : like run, but SECRET (a token or key) shows as *** in the log and on screen
run_secret() {
    local secret="$1" shown
    shift
    shown="$*"
    [[ -n "$secret" ]] && shown="${shown//"$secret"/***}"
    log "+ $shown"
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '%s\n' "${C_D}  [dry-run] ${shown}${C_0}"
        return 0
    fi
    "$@" >> "$LOG_FILE" 2>&1
}

have() { command -v "$1" >/dev/null 2>&1; }
yes_() { [[ "${1,,}" =~ ^(y|yes|true|1)$ ]]; }

# ----------------------------------------------------------------------------
# Interactive prompts (read from /dev/tty so "curl | bash" also works)
# ----------------------------------------------------------------------------
ask() {   # ask VAR "question" "default"
    local __var="$1" q="$2" def="${!1:-${3:-}}" ans=""
    if [[ $INTERACTIVE -eq 1 ]]; then
        read -r -p "${C_BOLD}?${C_0} ${q} ${C_D}[${def}]${C_0}: " ans < /dev/tty || true
        printf -v "$__var" '%s' "${ans:-$def}"
    else
        printf -v "$__var" '%s' "$def"
    fi
}
ask_yn() {   # ask_yn VAR "question" yes|no
    local __var="$1" q="$2" def="${!1:-${3:-no}}" ans=""
    yes_ "$def" && def=yes || def=no
    if [[ $INTERACTIVE -eq 1 ]]; then
        while true; do
            read -r -p "${C_BOLD}?${C_0} ${q} ${C_D}[$([[ $def == yes ]] && echo Y/n || echo y/N)]${C_0}: " ans < /dev/tty || true
            ans="${ans:-$def}"
            case "${ans,,}" in y|yes) printf -v "$__var" yes; return ;; n|no) printf -v "$__var" no; return ;; esac
        done
    else
        printf -v "$__var" '%s' "$def"
    fi
}
ask_secret() {   # ask_secret VAR "question"
    local __var="$1" q="$2" ans=""
    if [[ $INTERACTIVE -eq 1 ]]; then
        local hint=""; [[ -n "${!1:-}" ]] && hint=" ${C_D}[keep current]${C_0}"
        read -r -s -p "${C_BOLD}?${C_0} ${q}${hint}: " ans < /dev/tty || true
        echo
        [[ -n "$ans" ]] && printf -v "$__var" '%s' "$ans"
    fi
    return 0
}
confirm() {   # confirm "question" -> 0 yes / 1 no
    [[ $ASSUME_YES -eq 1 ]] && return 0
    local a; ask_yn a "$1" "${2:-no}"; [[ $a == yes ]]
}

valid_pubkey() { [[ -n "$1" ]] && ssh-keygen -l -f /dev/stdin <<<"$1" >/dev/null 2>&1; }

# ----------------------------------------------------------------------------
# Step bookkeeping & file helpers
# ----------------------------------------------------------------------------
STEP_NAMES=(); STEP_RESULTS=(); STEP_DETAILS=()
CHANGED_FILES=(); NEW_FILES=(); MANUAL_TODO=()
STEP_CHANGED=0
STEP_NOTES=""

note()    { STEP_NOTES+="${STEP_NOTES:+; }$*"; log "NOTE: $*"; }
changed() { STEP_CHANGED=1; }
todo()    { MANUAL_TODO+=("$*"); }

backup_file() {   # copy a file into the backup dir (once per run)
    local f="$1"
    [[ -e "$f" ]] || return 0
    [[ -e "$BACKUP_DIR$f" ]] && return 0
    [[ $DRY_RUN -eq 1 ]] && return 0
    mkdir -p "$BACKUP_DIR$(dirname "$f")"
    cp -a "$f" "$BACKUP_DIR$f"
}

# write_file PATH MODE  (content on stdin) - only writes when content differs
write_file() {
    local path="$1" mode="${2:-644}" tmp
    tmp="$(mktemp)"
    cat > "$tmp"
    if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then
        rm -f "$tmp"; return 0
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '%s\n' "${C_D}  [dry-run] would write ${path}${C_0}"
        rm -f "$tmp"; changed; return 0
    fi
    if [[ -e "$path" ]]; then backup_file "$path"; CHANGED_FILES+=("$path"); else NEW_FILES+=("$path"); fi
    mkdir -p "$(dirname "$path")"
    install -m "$mode" "$tmp" "$path"
    rm -f "$tmp"
    log "wrote $path"
    changed
}

# set_kv FILE KEY VALUE [SEP] - set "key<SEP>value", replacing commented/uncommented lines
set_kv() {
    local file="$1" key="$2" value="$3" sep="${4:- = }" content
    if [[ -f "$file" ]]; then content="$(cat "$file")"; else content=""; fi
    if grep -qE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*(=|[[:space:]])" <<<"$content"; then
        content="$(sed -E "0,/^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*(=|[[:space:]]).*/s||${key}${sep}${value}|" <<<"$content")"
    else
        content+=$'\n'"${key}${sep}${value}"
    fi
    printf '%s\n' "$content" | write_file "$file" "$(stat -c %a "$file" 2>/dev/null || echo 644)"
}

# apt helpers
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
APT_OPTS=(-y -q -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "ok installed"; }
pkg_install() {   # install missing packages only
    local missing=() p
    for p in "$@"; do pkg_installed "$p" || missing+=("$p"); done
    [[ ${#missing[@]} -eq 0 ]] && return 0
    info "installing: ${missing[*]}"
    run apt-get install "${APT_OPTS[@]}" --no-install-recommends "${missing[@]}" || return 1
    changed
}
pkg_available() { apt-cache show "$1" >/dev/null 2>&1; }

svc_disable() {
    local u
    for u in "$@"; do
        systemctl list-unit-files "$u" >/dev/null 2>&1 || continue
        systemctl cat "$u" >/dev/null 2>&1 || continue
        if systemctl is-enabled --quiet "$u" 2>/dev/null || systemctl is-active --quiet "$u" 2>/dev/null; then
            run systemctl disable --now "$u" && changed
        fi
    done
}

step_selected() {
    local s="$1"
    if [[ -n "$ONLY" ]]; then [[ " $ONLY " == *" $s "* ]] || return 1; fi
    [[ " $SKIP " == *" $s "* ]] && return 1
    return 0
}

# run_step NAME "Title" function
run_step() {
    local name="$1" label="$2" fn="$3" rc
    step_selected "$name" || return 0
    title "$label"
    STEP_CHANGED=0; STEP_NOTES=""
    "$fn"; rc=$?
    local res
    case $rc in
        0)  [[ $STEP_CHANGED -eq 1 ]] && res="CHANGED" || res="OK (already)" ;;
        20) res="SKIPPED" ;;
        *)  res="FAILED" ;;
    esac
    [[ $DRY_RUN -eq 1 && "$res" == "CHANGED" ]] && res="WOULD CHANGE"
    STEP_NAMES+=("$label"); STEP_RESULTS+=("$res"); STEP_DETAILS+=("${STEP_NOTES:--}")
    case "$res" in
        FAILED) err "$label: FAILED - ${STEP_NOTES}" ;;
        SKIPPED) warn "$label: skipped${STEP_NOTES:+ - $STEP_NOTES}" ;;
        *) ok "$label: $res" ;;
    esac
}
SKIP_RC=20

# ----------------------------------------------------------------------------
# Pre-flight
# ----------------------------------------------------------------------------
preflight() {
    if [[ $EUID -ne 0 ]]; then
        if [[ $DRY_RUN -eq 1 ]]; then
            LOG_DIR="$(mktemp -d)"; LOG_FILE="$LOG_DIR/run.log"
            REPORT_DIR="$PWD"; REPORT_FILE="$REPORT_DIR/server-prep-report-${HOST_SHORT}-${TS}-dryrun.md"
            BACKUP_DIR="$LOG_DIR/backups"
            echo "${C_Y}Not root: dry-run with partial detection.${C_0}"
        else
            die "Run as root: sudo $0"
        fi
    fi
    mkdir -p "$LOG_DIR" "$REPORT_DIR" 2>/dev/null
    chmod 700 "$LOG_DIR"   # root only, also when an older version created it as 755
    # logs from 1.1.1 and older are 644 and can hold the tunnel token: make every file root only
    find "$LOG_DIR" -maxdepth 1 -type f -perm /077 -exec chmod 600 {} + 2>/dev/null
    [[ $DRY_RUN -eq 1 ]] || { mkdir -p "$BACKUP_DIR" "$STATE_DIR" "$CONF_DIR"; chmod 700 "$STATE_DIR" "$REPORT_DIR" "$CONF_DIR"; }
    (umask 077; : >> "$LOG_FILE")
    chmod 600 "$LOG_FILE"

    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="$ID"; OS_CODENAME="${VERSION_CODENAME:-}"; OS_PRETTY="$PRETTY_NAME"
    case "$OS_ID" in
        debian|ubuntu) ;;
        *) [[ "${ID_LIKE:-}" == *debian* ]] || die "Unsupported OS: $OS_PRETTY (Debian/Ubuntu only)"
           warn "$OS_PRETTY is Debian-based but untested" ;;
    esac

    IS_LAPTOP=0
    ls /sys/class/power_supply/BAT* >/dev/null 2>&1 && IS_LAPTOP=1
    [[ "$LAPTOP_MODE" == "yes" ]] && IS_LAPTOP=1
    [[ "$LAPTOP_MODE" == "no" ]] && IS_LAPTOP=0
    HAS_DESKTOP=0
    systemctl is-active --quiet display-manager 2>/dev/null && HAS_DESKTOP=1
    HAS_DOCKER=0; have docker && HAS_DOCKER=1
    HAS_TAILSCALE=0; have tailscale && ip link show tailscale0 >/dev/null 2>&1 && HAS_TAILSCALE=1
    HAS_CLOUDFLARED=0; have cloudflared && HAS_CLOUDFLARED=1
    SSH_SOCKET=0; systemctl is-enabled --quiet ssh.socket 2>/dev/null && SSH_SOCKET=1

    DEFAULT_IFACE="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
    LAN_CIDR="$(ip -4 route show dev "$DEFAULT_IFACE" scope link 2>/dev/null | awk '$1 ~ /\// {print $1; exit}')"
    LOCAL_IP="$(ip -4 -o addr show dev "$DEFAULT_IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
    CURRENT_SSH_PORTS="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | tr '\n' ' ')"
    CURRENT_SSH_PORTS="${CURRENT_SSH_PORTS:-22 }"

    if [[ -z "$ADMIN_USER" ]]; then
        ADMIN_USER="${SUDO_USER:-}"
        [[ -z "$ADMIN_USER" || "$ADMIN_USER" == "root" ]] && ADMIN_USER="$(awk -F: '$3>=1000 && $3<60000 {print $1; exit}' /etc/passwd)"
        ADMIN_USER="${ADMIN_USER:-admin}"
    fi
    [[ -z "$TIMEZONE" ]] && TIMEZONE="$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)"

    if [[ -z "$AUDIT_SCRIPT" ]]; then
        for c in ${SCRIPT_DIR:+"$SCRIPT_DIR/server-audit.sh"} /usr/local/sbin/server-audit; do
            [[ -f "$c" ]] && { AUDIT_SCRIPT="$c"; break; }
        done
    fi
}

intro() {
    [[ $INTERACTIVE -eq 1 ]] || return 0
    cat <<EOF

${C_BOLD}What is this script? (the 5W)${C_0}

  ${C_BOLD}WHAT${C_0}   It secures this server and prepares it so a self-hosted PaaS panel
         (Coolify, Dokploy, Openship...) can deploy apps on it:
         SSH locked down (keys only, new port), firewall, brute-force protection
         (fail2ban/CrowdSec), automatic security updates, safer kernel settings, logging,
         and root access reserved to the panel. It ends with a report of everything done.

  ${C_BOLD}WHY${C_0}    A fresh server is scanned and attacked within minutes of going online.
         Default settings (password SSH on port 22, no firewall, Docker bypassing it)
         are the usual way servers get compromised.

  ${C_BOLD}WHO${C_0}    Run it as an administrator (sudo) of THIS server. Afterwards:
         - you log in with your own admin account and SSH key,
         - the panel logs in as root, with its key, only from its own access route,
         - nobody else can log in.

  ${C_BOLD}WHEN${C_0}   Right after installing a new server, before deploying apps.
         It can be re-run anytime (it only changes what is not already done),
         e.g. after an OS upgrade or to change a setting.

  ${C_BOLD}WHERE${C_0}  On this machine only (${HOST_SHORT}). Settings go in /etc, backups in
         ${STATE_DIR}/backups, the log in ${LOG_DIR}, the report in ${REPORT_DIR}.

  ${C_BOLD}HOW${C_0}    1) you answer a few questions (each one is explained, Enter = default),
         2) you review the plan and confirm - nothing changes before that,
         3) each step runs, then the audit runs again to show before/after.
         Safety: SSH changes roll back automatically after 10 minutes unless you
         confirm that a new login works. Use --dry-run to only preview.

EOF
    confirm "Continue?" yes || die "Aborted by user"
}

# ----------------------------------------------------------------------------
# Questions
# ----------------------------------------------------------------------------
# explain "line" "line"... : help text shown before a question
explain() {
    local l
    echo
    for l in "$@"; do printf '%s\n' "  ${C_D}${l}${C_0}"; done
}

service_help() {
    case "$1" in
        avahi-daemon) echo "Avahi: announces this machine on the local network (printers, .local names). Useless on a server, and it listens on UDP 5353." ;;
        cups) echo "CUPS: printing service. A server does not print." ;;
        cups-browsed) echo "cups-browsed: discovers network printers automatically; it has had remote vulnerabilities." ;;
        bluetooth) echo "Bluetooth: wireless devices (mouse, headset). Not needed to serve apps." ;;
        ModemManager) echo "ModemManager: 3G/4G modems. Not needed unless the machine uses a SIM card for internet." ;;
        apport) echo "Apport: Ubuntu crash reporter. It forces fs.suid_dumpable=2 (crash dumps of privileged programs), which server-prep sets back to 0." ;;
        *) echo "$1" ;;
    esac
}

questions() {
    [[ $INTERACTIVE -eq 1 ]] || return 0
    title "Server preparation - questions"
    echo "  Host: ${HOST_SHORT} | ${OS_PRETTY} | laptop: $([[ $IS_LAPTOP == 1 ]] && echo yes || echo no) | docker: $([[ $HAS_DOCKER == 1 ]] && echo yes || echo no) | tailscale: $([[ $HAS_TAILSCALE == 1 ]] && echo yes || echo no) | cloudflared: $([[ $HAS_CLOUDFLARED == 1 ]] && echo yes || echo no)"
    echo "  Press Enter to accept the [default]. Nothing changes until you confirm the plan at the end."

    # ---------------------------------------------------------------- 1
    echo; echo "${C_BOLD}1. Admin account${C_0}"
    explain "This is the personal account YOU use to manage the server (not the panel's)." \
            "It gets sudo rights and logs in over SSH with a key. Root login from the internet" \
            "will be disabled, so this account is your way in. It is created if it does not exist."
    ask ADMIN_USER "Admin user" "$ADMIN_USER"
    local home; home="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
    local nkeys=0
    [[ -n "$home" && -s "$home/.ssh/authorized_keys" ]] && nkeys=$(grep -cE '^(ssh-|ecdsa-|sk-)' "$home/.ssh/authorized_keys")
    explain "Password login over SSH will be turned OFF. Without a key here, ${ADMIN_USER} can only log in" \
            "on the physical console / provider console. ${ADMIN_USER} currently has ${nkeys} SSH key(s)." \
            "Get your PUBLIC key on the computer you connect FROM:  cat ~/.ssh/id_ed25519.pub" \
            "(no key yet? create one there with:  ssh-keygen -t ed25519). Paste the whole line." \
            "Never paste the private key (the file without .pub)."
    while true; do
        ask ADMIN_PUBKEY "Admin SSH public key (empty = keep current keys)" "${ADMIN_PUBKEY:-}"
        [[ -z "$ADMIN_PUBKEY" ]] || valid_pubkey "$ADMIN_PUBKEY" && break
        warn "That is not a valid public key (expected one line like: ssh-ed25519 AAAA... comment)"
        ADMIN_PUBKEY=""
    done

    # ---------------------------------------------------------------- 2
    echo; echo "${C_BOLD}2. Deployment panel${C_0}"
    explain "A self-hosted PaaS panel (Coolify, Dokploy, Openship...) running on another server deploys" \
            "apps here by connecting over SSH as root with its own key. The name is only used in messages."
    ask PANEL "Panel (coolify, dokploy, openship, other name; empty = none)" "${PANEL:-}"
    set_panel_label
    explain "${PANEL_LABEL^}'s SSH public key: open the SSH key the panel uses for servers and copy its" \
            "public part (Coolify: Keys & Tokens -> Private Keys -> the key -> Public Key)." \
            "It is installed in /root/.ssh/authorized_keys and only accepted from the sources chosen below." \
            "Leave empty if this server will not be managed by a panel."
    while true; do
        ask PANEL_PUBKEY "${PANEL_LABEL^} SSH public key (empty = skip)" "${PANEL_PUBKEY:-}"
        [[ -z "$PANEL_PUBKEY" ]] || valid_pubkey "$PANEL_PUBKEY" && break
        warn "Invalid public key"; PANEL_PUBKEY=""
    done
    local def_access="public"
    [[ $HAS_CLOUDFLARED -eq 1 || $IS_LAPTOP -eq 1 ]] && def_access="cloudflared"
    [[ $HAS_TAILSCALE -eq 1 && $def_access == "cloudflared" ]] && def_access="cloudflared,tailscale"
    explain "How does the ${PANEL_LABEL} server reach this server over SSH? (you can combine them, comma-separated)" \
            "  cloudflared : through a Cloudflare Tunnel. No port is opened on the router/firewall," \
            "                works behind a home box/NAT. Best for a laptop or home server." \
            "  tailscale   : through your Tailscale network (the panel server must join the same tailnet)." \
            "  public      : straight to this server's public IP - typical for a VPS. Only the panel" \
            "                server's IP will be allowed to log in as root." \
            "Root login is refused from every other address, even with the right key."
    ask PANEL_ACCESS "Access methods" "${PANEL_ACCESS:-$def_access}"
    if [[ "$PANEL_ACCESS" == *public* ]]; then
        explain "The public IPv4 of the server running ${PANEL_LABEL}. On that server run:  curl -4 ifconfig.me"
        ask PANEL_IP "${PANEL_LABEL^} server public IP" "$PANEL_IP"
    fi
    if [[ "$PANEL_ACCESS" == *cloudflared* ]] && ! systemctl is-active --quiet cloudflared 2>/dev/null; then
        explain "The tunnel connector runs on THIS server and links it to Cloudflare." \
                "Cloudflare dashboard -> Zero Trust -> Networks -> Tunnels -> Create a tunnel (Cloudflared)" \
                "-> copy the token from the install command (the long string after 'service install')." \
                "The token is not saved in the answers file. Leave empty to install the tunnel later."
        ask_secret CLOUDFLARED_TOKEN "Cloudflare tunnel token (input hidden)"
    fi

    # ---------------------------------------------------------------- 3
    echo; echo "${C_BOLD}3. SSH & firewall${C_0}"
    explain "SSH moves away from port 22, which bots scan all day long." \
            "A port below 1024 can only be opened by root (safer, and required to pass the audit)." \
            "You will then connect with:  ssh -p <port> ${ADMIN_USER}@<server>  - and use this port in ${PANEL_LABEL}." \
            "Current SSH port(s): ${CURRENT_SSH_PORTS}"
    ask SSH_PORT "New SSH port" "$SSH_PORT"
    local def_ips="${ADMIN_IPS:-$LAN_CIDR}"
    explain "Addresses allowed to reach the SSH port directly (space-separated IPs or networks)." \
            "Suggested: your local network ${LAN_CIDR:-?} and your office/home public IP if it is fixed." \
            "The tunnel, Tailscale and the panel IP chosen above are allowed automatically." \
            "Empty + no tunnel/tailscale/panel IP = SSH open to everyone (rate-limited, keys only)."
    ask ADMIN_IPS "Allowed SSH sources" "$def_ips"
    local def_web=no; [[ "$PANEL_ACCESS" == *public* ]] && def_web=yes
    explain "Ports 80/443 are where your deployed apps answer (the panel's reverse proxy, e.g. Traefik or Caddy)." \
            "  yes : visitors reach the apps directly on this server's IP (normal for a VPS)." \
            "  no  : apps are only reachable through the Cloudflare Tunnel (hostname -> http://localhost:80)." \
            "        Nothing is exposed on the internet - recommended behind a home box."
    ask_yn EXPOSE_WEB "Open 80/443 to the internet?" "${EXPOSE_WEB:-$def_web}"
    explain "Other ports to open to everyone, e.g. a database you must reach from outside (5432/tcp)." \
            "Format: port/proto separated by spaces. Most setups need none - keep it empty unless sure."
    ask EXTRA_PORTS "Extra ports" "$EXTRA_PORTS"

    # ---------------------------------------------------------------- 4
    echo; echo "${C_BOLD}4. Protection${C_0}"
    explain "fail2ban reads the SSH logs and bans an IP for 1h (longer each time) after 5 failed logins." \
            "Free, local, no web interface (command: fail2ban-client status sshd)."
    ask_yn INSTALL_FAIL2BAN "Install fail2ban" "$INSTALL_FAIL2BAN"
    explain "CrowdSec does the same detection and also blocks IPs reported by its community" \
            "(known attackers are banned before they even try). Its 'bouncer' enforces the bans in the" \
            "firewall, including for Docker containers. Free; optional web dashboard at app.crowdsec.net." \
            "Both together are fine: fail2ban guards SSH, CrowdSec adds the shared blocklist."
    ask_yn INSTALL_CROWDSEC "Install CrowdSec" "$INSTALL_CROWDSEC"
    if yes_ "$INSTALL_CROWDSEC"; then
        explain "Optional: link this server to the free CrowdSec web console to see alerts and bans." \
                "app.crowdsec.net -> Security Engines -> Add -> copy the enroll key. Empty = skip (can do later" \
                "with: sudo cscli console enroll <key>). The key is not saved in the answers file."
        ask_secret CROWDSEC_ENROLL_KEY "CrowdSec enroll key (input hidden)"
    fi
    explain "Self-hosted panels run every app in Docker. If Docker is missing it is installed from Docker's" \
            "official repository. In all cases: container logs are capped (10 MB x 3 per container)" \
            "so they cannot fill the disk, and container ports are made to obey the firewall" \
            "(by default Docker silently bypasses UFW)."
    ask_yn INSTALL_DOCKER "Install / configure Docker" "$INSTALL_DOCKER"
    explain "Security updates are installed automatically every night. Including Docker means the" \
            "Docker engine is updated too; containers restart briefly when that happens."
    ask_yn DOCKER_AUTO_UPDATE "Include Docker in automatic updates" "$DOCKER_AUTO_UPDATE"
    explain "Some updates (kernel) only apply after a reboot. 'yes' reboots automatically at ${AUTO_REBOOT_TIME}" \
            "when needed (apps go down ~1 min). 'no' = you reboot yourself; the audit/report tells you when."
    ask_yn AUTO_REBOOT "Automatic reboot when required" "$AUTO_REBOOT"

    # ---------------------------------------------------------------- 5
    echo; echo "${C_BOLD}5. Services${C_0}"
    explain "Every running service is something that can be attacked. These are desktop services" \
            "a server does not need. Disabling is reversible: sudo systemctl enable --now <name>"
    local s sel="" a
    for s in $SERVICE_CANDIDATES; do
        systemctl cat "$s" >/dev/null 2>&1 || continue
        local def=yes
        [[ -n "$DISABLE_SERVICES" && " $DISABLE_SERVICES " != *" $s "* ]] && def=no
        echo "  ${C_D}- $(service_help "$s")${C_0}"
        a=$def; ask_yn a "  Disable ${s}" "$def"
        [[ $a == yes ]] && sel+="$s "
    done
    DISABLE_SERVICES="${sel% }"
    if [[ $IS_LAPTOP -eq 1 ]]; then
        explain "Laptop detected: closing the lid and idle sleep will be disabled so the apps stay online." \
                "Tip: keep it plugged in, and if the BIOS allows it, limit battery charge to ~80%."
        if [[ $HAS_DESKTOP -eq 1 ]]; then
            explain "The graphical desktop (GNOME) runs ~20 services and uses 1-2 GB of RAM." \
                    "'yes' = after the next reboot the machine starts in text mode only (you can still log in" \
                    "on the screen, and start the desktop with: sudo systemctl start gdm)." \
                    "Undo anytime: sudo systemctl set-default graphical.target"
            ask_yn HEADLESS "Boot without the graphical desktop" "$HEADLESS"
        fi
    fi

    # ---------------------------------------------------------------- 6
    echo; echo "${C_BOLD}6. Monitoring extras${C_0}"
    explain "auditd records who changed sensitive things: users, passwords, sudo rules, SSH config," \
            "firewall, cron jobs, Docker config. Lets you investigate after an incident (ausearch -k <key>)."
    ask_yn INSTALL_AUDITD "Install auditd" "$INSTALL_AUDITD"
    explain "rkhunter scans daily for rootkits/backdoors (hidden files, modified system commands)." \
            "Results in /var/log/rkhunter.log and in the Telegram daily report."
    ask_yn INSTALL_RKHUNTER "Install rkhunter" "$INSTALL_RKHUNTER"
    explain "AIDE takes a fingerprint of every system file now, then checks daily that none was" \
            "modified. Docker/app data is excluded. First fingerprint takes a few minutes (in background)."
    ask_yn INSTALL_AIDE "Install AIDE" "$INSTALL_AIDE"
    explain "Endlessh is a trap on port 22 (free once SSH has moved): bots that connect get stuck for" \
            "hours receiving an endless fake banner, wasting their time instead of attacking."
    ask_yn INSTALL_ENDLESSH "Install Endlessh" "$INSTALL_ENDLESSH"
    explain "Telegraf is the metrics agent of InfluxDB: it collects CPU, memory, disk, network, Docker" \
            "stats and sends them to an InfluxDB server (then shown in Grafana / InfluxDB UI)." \
            "It is only installed here, from InfluxData's official repository, and left stopped:" \
            "configure it later with telegraf.conf.example, then enable it. Guide:" \
            "${PROJECT_URL}/blob/main/docs/monitoring.md"
    ask_yn INSTALL_TELEGRAF "Install Telegraf" "$INSTALL_TELEGRAF"
    explain "Telegram alerts: a message on your phone at every SSH login, plus a daily report at 09:00" \
            "(disk, memory, updates, bans, rootkit/integrity results, containers)."
    ask_yn TELEGRAM_ENABLE "Enable Telegram alerts" "$TELEGRAM_ENABLE"
    if yes_ "$TELEGRAM_ENABLE"; then
        explain "1) In Telegram, talk to @BotFather -> /newbot -> copy the token (123456:ABC...)." \
                "2) Send any message to your new bot." \
                "3) Open https://api.telegram.org/bot<TOKEN>/getUpdates and copy \"chat\":{\"id\": <number>}." \
                "On a re-run, leave the token empty to keep the one already installed."
        ask_secret TELEGRAM_BOT_TOKEN "Telegram bot token (input hidden)"
        ask TELEGRAM_CHAT_ID "Telegram chat id" "$TELEGRAM_CHAT_ID"
        explain "${PANEL_LABEL^} logs in as root every few minutes; alerting on those would spam you." \
                "Users listed here never trigger a login alert (space-separated)."
        ask TELEGRAM_IGNORE_USERS "Users without login alerts" "$TELEGRAM_IGNORE_USERS"
    fi
    explain "Timezone used for logs, scheduled reboots and reports (e.g. Europe/Paris, UTC)."
    ask TIMEZONE "Timezone" "$TIMEZONE"
}

summary_and_confirm() {
    [[ -z "$EXPOSE_WEB" && "$PANEL_ACCESS" == *public* ]] && EXPOSE_WEB=yes
    yes_ "$EXPOSE_WEB" && EXPOSE_WEB=yes || EXPOSE_WEB=no
    if [[ -n "$PANEL_PUBKEY" && -z "$PANEL_ACCESS" ]]; then
        warn "PANEL_ACCESS is empty: root login will be refused everywhere, ${PANEL_LABEL} will not connect"
    fi
    if [[ "$PANEL_ACCESS" == *public* && -z "$PANEL_IP" ]]; then
        die "PANEL_ACCESS contains 'public' but PANEL_IP is empty"
    fi
    [[ -z "$DISABLE_SERVICES" && $INTERACTIVE -eq 0 ]] && DISABLE_SERVICES="$SERVICE_CANDIDATES"
    title "Plan"
    cat <<EOF
  Admin user ........ ${ADMIN_USER} $([[ -n "$ADMIN_PUBKEY" ]] && echo "(+1 key)")
  Panel ............. ${PANEL:-none} | root key: $([[ -n "$PANEL_PUBKEY" ]] && echo yes || echo no) | access: ${PANEL_ACCESS:-none} ${PANEL_IP:+| server IP ${PANEL_IP}}
  SSH ............... port ${SSH_PORT} (now: ${CURRENT_SSH_PORTS}) | keys only | root only from trusted sources
  SSH allowed from .. ${ADMIN_IPS:-"(none)"} $([[ "$PANEL_ACCESS" == *tailscale* ]] && echo "+ tailscale0") $([[ "$PANEL_ACCESS" == *cloudflared* ]] && echo "+ tunnel (localhost)")
  Web 80/443 ........ $([[ $EXPOSE_WEB == yes ]] && echo "open to the internet" || echo "closed (tunnel/localhost only)") ${EXTRA_PORTS:+| extra: $EXTRA_PORTS}
  IPS ............... fail2ban: ${INSTALL_FAIL2BAN} | CrowdSec: ${INSTALL_CROWDSEC} (LAPI 127.0.0.1:${CROWDSEC_LAPI_PORT})
  Docker ............ ${INSTALL_DOCKER} | auto-update: ${DOCKER_AUTO_UPDATE} | auto-reboot: ${AUTO_REBOOT}
  Disable services .. ${DISABLE_SERVICES:-none}
  Laptop mode ....... $([[ $IS_LAPTOP == 1 ]] && echo "yes (lid/sleep off) | headless: ${HEADLESS}" || echo no)
  Extras ............ auditd: ${INSTALL_AUDITD} | rkhunter: ${INSTALL_RKHUNTER} | AIDE: ${INSTALL_AIDE} | endlessh: ${INSTALL_ENDLESSH} | telegraf: ${INSTALL_TELEGRAF} | telegram: ${TELEGRAM_ENABLE}
  Steps ............. ${ONLY:-all}${SKIP:+ (skip: $SKIP)}
  Mode .............. $([[ $DRY_RUN == 1 ]] && echo "DRY-RUN (nothing will change)" || echo "APPLY")
EOF
    confirm "Proceed?" yes || die "Aborted by user"
}

save_answers() {
    [[ $DRY_RUN -eq 1 ]] && return 0
    local f="$CONF_DIR/server-prep.conf"
    {
        echo "# server-prep answers - ${TS} - reuse with: --config $f --yes"
        local v
        for v in ADMIN_USER ADMIN_PUBKEY PANEL PANEL_PUBKEY PANEL_ACCESS PANEL_IP SSH_PORT ADMIN_IPS EXPOSE_WEB EXTRA_PORTS \
                 TIMEZONE INSTALL_FAIL2BAN INSTALL_CROWDSEC CROWDSEC_LAPI_PORT INSTALL_DOCKER DOCKER_AUTO_UPDATE AUTO_REBOOT \
                 AUTO_REBOOT_TIME DISABLE_SERVICES HEADLESS INSTALL_AUDITD INSTALL_RKHUNTER INSTALL_AIDE INSTALL_ENDLESSH INSTALL_TELEGRAF \
                 TELEGRAM_ENABLE TELEGRAM_CHAT_ID TELEGRAM_IGNORE_USERS SWAP_SIZE PTRACE_SCOPE; do
            printf '%s=%q\n' "$v" "${!v}"
        done
        echo "# secrets (CLOUDFLARED_TOKEN, TELEGRAM_BOT_TOKEN, CROWDSEC_ENROLL_KEY) are not saved here"
    } > "$f"
    chmod 600 "$f"
}

# ----------------------------------------------------------------------------
# Audit before / after
# ----------------------------------------------------------------------------
AUDIT_BEFORE=""; AUDIT_AFTER=""
run_audit() {   # run_audit before|after
    local which="$1" out="$STATE_DIR/audit-$TS-$1"
    [[ $DRY_RUN -eq 1 ]] && out="$LOG_DIR/audit-$1"
    if [[ -z "$AUDIT_SCRIPT" && -n "$AUDIT_URL" ]] && have curl; then
        AUDIT_SCRIPT="$STATE_DIR/server-audit.sh"
        [[ $DRY_RUN -eq 1 ]] && AUDIT_SCRIPT="$LOG_DIR/server-audit.sh"
        (umask 077; curl -fsSL "$AUDIT_URL" -o "$AUDIT_SCRIPT") || AUDIT_SCRIPT=""
    fi
    if [[ -z "$AUDIT_SCRIPT" ]]; then
        warn "server-audit.sh not found - skipping the ${which} audit"
        return 0
    fi
    info "running audit (${which})..."
    # umask 077: in a dry-run these files land in $LOG_DIR, which preflight made root only (600 files),
    # and the audit check mon.prep_secrets counts any file there that others can read
    (umask 077; bash "$AUDIT_SCRIPT" --quiet --no-color --no-network --no-txt --tsv "$out.tsv" --md "$out.md") >/dev/null 2>&1 || true
    [[ -s "$out.tsv" ]] || { warn "audit produced no output"; return 0; }
    if [[ "$which" == before ]]; then AUDIT_BEFORE="$out.tsv"; else AUDIT_AFTER="$out.tsv"; fi
    local p w f
    p=$(awk -F'\t' '$2=="PASS"' "$out.tsv" | wc -l); w=$(awk -F'\t' '$2=="WARN"' "$out.tsv" | wc -l); f=$(awk -F'\t' '$2=="FAIL"' "$out.tsv" | wc -l)
    ok "audit ${which}: ${p} PASS, ${w} WARN, ${f} FAIL"
}

# ============================================================================
# STEPS
# ============================================================================

step_update() {
    run apt-get -o DPkg::Lock::Timeout=600 update -q || { note "apt-get update failed"; return 1; }
    local n
    n=$(apt-get -s dist-upgrade 2>/dev/null | grep -c '^Inst ' || true)
    if [[ $n -gt 0 ]]; then
        info "upgrading ${n} package(s)"
        run apt-get "${APT_OPTS[@]}" full-upgrade || { note "full-upgrade failed"; return 1; }
        note "${n} package(s) upgraded"; changed
    else
        note "already up to date"
    fi
    pkg_install sudo curl wget git jq openssl ca-certificates gnupg ufw unattended-upgrades apt-listchanges \
        libpam-pwquality cracklib-runtime chrony lsof vim || return 1
    if [[ "$(timedatectl show -p Timezone --value 2>/dev/null)" != "$TIMEZONE" ]]; then
        run timedatectl set-timezone "$TIMEZONE" && { changed; note "timezone ${TIMEZONE}"; }
    fi
    [[ -f /var/run/reboot-required ]] && todo "Reboot to finish updates: sudo reboot"
    return 0
}

ROOT_SOURCES=()
compute_root_sources() {
    ROOT_SOURCES=()
    [[ "$PANEL_ACCESS" == *cloudflared* ]] && ROOT_SOURCES+=(127.0.0.1 ::1)
    [[ "$PANEL_ACCESS" == *tailscale* ]] && ROOT_SOURCES+=(100.64.0.0/10 fd7a:115c:a1e0::/48)
    [[ "$PANEL_ACCESS" == *public* && -n "$PANEL_IP" ]] && ROOT_SOURCES+=("$PANEL_IP")
    return 0
}

add_key() {   # add_key USER FILE KEY [OPTIONS]
    local user="$1" file="$2" key="$3" opts="${4:-}" blob line
    blob="$(awk '{print $2}' <<<"$key")"
    line="${opts:+$opts }$key"
    if [[ -f "$file" ]] && grep -qF "$blob" "$file"; then
        # key already present - replace the line if options changed
        if ! grep -qxF "$line" "$file"; then
            { grep -vF "$blob" "$file"; echo "$line"; } | write_file "$file" 600
            note "updated options of an existing key in $file"
        fi
    else
        { [[ -f "$file" ]] && cat "$file"; echo "$line"; } | write_file "$file" 600
        note "key added to $file"
    fi
    [[ $DRY_RUN -eq 1 ]] && return 0
    chown "$user": "$(dirname "$file")" "$file"
    chmod 700 "$(dirname "$file")"
}

step_users() {
    if ! id "$ADMIN_USER" >/dev/null 2>&1; then
        info "creating user ${ADMIN_USER}"
        run useradd --create-home --shell /bin/bash --groups sudo "$ADMIN_USER" || return 1
        changed; note "user ${ADMIN_USER} created"
        if [[ $DRY_RUN -eq 0 ]]; then
            if [[ $INTERACTIVE -eq 1 ]]; then
                echo "  Set a sudo password for ${ADMIN_USER} (12+ chars):"
                until passwd "$ADMIN_USER" < /dev/tty; do :; done
            else
                local pw; pw="$(openssl rand -base64 18)"
                echo "${ADMIN_USER}:${pw}" | chpasswd
                printf '%s\n' "$pw" > "$CONF_DIR/${ADMIN_USER}.initial-password"; chmod 600 "$CONF_DIR/${ADMIN_USER}.initial-password"
                todo "Initial sudo password of ${ADMIN_USER} is in $CONF_DIR/${ADMIN_USER}.initial-password - change it (passwd) and delete the file"
            fi
        fi
    fi
    if ! id -nG "$ADMIN_USER" 2>/dev/null | grep -qw sudo; then
        run usermod -aG sudo "$ADMIN_USER" && { changed; note "${ADMIN_USER} added to sudo group"; }
    fi
    local home; home="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
    [[ -z "$home" ]] && home="/home/$ADMIN_USER"
    if [[ -n "$ADMIN_PUBKEY" ]]; then
        valid_pubkey "$ADMIN_PUBKEY" || { note "ADMIN_PUBKEY is invalid"; return 1; }
        add_key "$ADMIN_USER" "$home/.ssh/authorized_keys" "$ADMIN_PUBKEY"
    fi

    compute_root_sources
    if [[ -n "$PANEL_PUBKEY" ]]; then
        valid_pubkey "$PANEL_PUBKEY" || { note "PANEL_PUBKEY is invalid"; return 1; }
        local from=""
        if [[ ${#ROOT_SOURCES[@]} -gt 0 ]]; then
            from="from=\"$(IFS=,; echo "${ROOT_SOURCES[*]}")\""
        fi
        add_key root /root/.ssh/authorized_keys "$PANEL_PUBKEY" "$from"
        note "${PANEL_LABEL^} key installed for root${from:+ (restricted: ${ROOT_SOURCES[*]})}"
    fi
    if [[ ${PANEL,,} == coolify && ! -d /data/coolify ]]; then
        run mkdir -p /data/coolify && changed
    fi
    return 0
}

step_docker() {
    if ! yes_ "$INSTALL_DOCKER"; then return $SKIP_RC; fi
    pkg_install jq curl ca-certificates || return 1
    if ! have docker; then
        info "installing Docker CE from download.docker.com"
        local distro="$OS_ID"; [[ "$distro" == ubuntu || "$distro" == debian ]] || distro=debian
        run install -m 0755 -d /etc/apt/keyrings
        run curl -fsSL "https://download.docker.com/linux/${distro}/gpg" -o /etc/apt/keyrings/docker.asc || { note "cannot download Docker GPG key"; return 1; }
        run chmod a+r /etc/apt/keyrings/docker.asc
        write_file /etc/apt/sources.list.d/docker.sources 644 <<EOF
Types: deb
URIs: https://download.docker.com/linux/${distro}
Suites: ${OS_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
        run apt-get -o DPkg::Lock::Timeout=600 update -q
        run apt-get install "${APT_OPTS[@]}" docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
            || { note "Docker install failed (is ${OS_CODENAME} supported by download.docker.com?)"; return 1; }
        run systemctl enable --now docker
        HAS_DOCKER=1; changed; note "Docker CE installed"
    else
        note "Docker already installed"
        if ! docker compose version >/dev/null 2>&1; then pkg_install docker-compose-plugin || true; fi
    fi

    # Log rotation (merge into existing daemon.json)
    local cur='{}' new
    [[ -s /etc/docker/daemon.json ]] && cur="$(cat /etc/docker/daemon.json)"
    if ! jq -e . >/dev/null 2>&1 <<<"$cur"; then
        note "/etc/docker/daemon.json is not valid JSON - left untouched"; return 1
    fi
    new="$(jq '. + {"log-driver": (.["log-driver"] // "json-file"),
                   "log-opts": ((.["log-opts"] // {}) + {"max-size": (.["log-opts"]["max-size"] // "10m"),
                                                         "max-file": (.["log-opts"]["max-file"] // "3")})}' <<<"$cur")"
    if [[ "$(jq -S . <<<"$cur")" != "$(jq -S . <<<"$new")" ]]; then
        printf '%s\n' "$new" | write_file /etc/docker/daemon.json 644
        note "container log rotation set (10m x 3)"
        if [[ $DRY_RUN -eq 0 ]]; then
            local running; running=$(docker ps -q 2>/dev/null | wc -l)
            if [[ $running -eq 0 ]] || confirm "Restart Docker now to apply log rotation? (${running} container(s) will restart)" no; then
                run systemctl restart docker && note "docker restarted"
            else
                todo "Restart Docker when convenient to apply log rotation: sudo systemctl restart docker"
            fi
        fi
    fi
    return 0
}

# ufw-docker (https://github.com/chaifeng/ufw-docker, GPL-3.0) is downloaded at runtime, never bundled.
# Pinned release + checksum: update both together after reading the upstream diff.
UFW_DOCKER_VERSION="251123"
UFW_DOCKER_SHA256="c3e5f0bf6061a3a2e7d7ac06abc80665707d2f4c91e90d76f22e4168863fb472"

ufw_docker_rules() {   # make published container ports obey UFW (DOCKER-USER chain), Docker networking intact
    local bin=/usr/local/bin/ufw-docker tmp
    if [[ ! -x $bin ]] || ! sha256sum "$bin" 2>/dev/null | grep -q "^$UFW_DOCKER_SHA256 "; then
        if [[ $DRY_RUN -eq 1 ]]; then
            info "[dry-run] download ufw-docker $UFW_DOCKER_VERSION to $bin (sha256 checked)"
        else
            have curl || pkg_install curl || return 1
            tmp=$(mktemp)
            if ! curl -fsSL --max-time 30 -o "$tmp" "https://raw.githubusercontent.com/chaifeng/ufw-docker/${UFW_DOCKER_VERSION}/ufw-docker"; then
                rm -f "$tmp"; warn "cannot download ufw-docker: Docker can still bypass UFW"; return 1
            fi
            if ! sha256sum "$tmp" | grep -q "^$UFW_DOCKER_SHA256 "; then
                rm -f "$tmp"; err "ufw-docker checksum mismatch: not installed"; return 1
            fi
            write_file "$bin" 755 < "$tmp"; rm -f "$tmp"
            # write_file leaves an identical file as it is, so restore a lost exec bit here
            [[ -x $bin ]] || { run chmod 755 "$bin" && changed; }
            note "ufw-docker $UFW_DOCKER_VERSION installed (checksum verified)"
        fi
    fi
    if [[ $DRY_RUN -eq 1 ]]; then info "[dry-run] ufw-docker install && systemctl restart ufw"; return 0; fi
    # Don't use 'ufw-docker check': it exits 0 even when the rules are missing. 'install' only
    # rewrites the files when they differ, so compare them before and after, and check the live chain.
    local before after
    before=$(cat /etc/ufw/after.rules /etc/ufw/after6.rules 2>/dev/null | sha256sum)
    backup_file /etc/ufw/after.rules; backup_file /etc/ufw/after6.rules
    if ! "$bin" install >>"$LOG_FILE" 2>&1; then warn "ufw-docker install failed (see $LOG_FILE)"; return 1; fi
    after=$(cat /etc/ufw/after.rules /etc/ufw/after6.rules 2>/dev/null | sha256sum)
    if [[ $before == "$after" ]] && iptables -S DOCKER-USER 2>/dev/null | grep -q -- '-j ufw-user-forward'; then
        return 0                                        # rules written and loaded
    fi
    run systemctl restart ufw
    if iptables -S DOCKER-USER 2>/dev/null | grep -q -- '-j ufw-user-forward'; then
        changed
        note "DOCKER-USER rules installed by ufw-docker: published container ports now obey UFW"
    else
        warn "ufw-docker rules written but not loaded"
        todo "Docker ports still bypass UFW: run 'sudo systemctl restart ufw', then 'sudo iptables -S DOCKER-USER' must show ufw-user-forward"
        return 1
    fi
}

# 'ufw allow/limit/route/default' exit 0 even when the rule or policy already exists, so compare the rule files instead.
ufw_state() { cat /etc/ufw/user.rules /etc/ufw/user6.rules /etc/default/ufw 2>/dev/null | sha256sum; }

ufw_allow_ssh() {   # ufw_allow_ssh PORT COMMENT
    local port="$1" c="$2" ip any=1
    for ip in ${ADMIN_IPS//,/ }; do
        run ufw allow from "$ip" to any port "$port" proto tcp comment "$c admin"; any=0
    done
    if [[ "$PANEL_ACCESS" == *public* && -n "$PANEL_IP" ]]; then
        run ufw allow from "$PANEL_IP" to any port "$port" proto tcp comment "$c panel"; any=0
    fi
    if [[ "$PANEL_ACCESS" == *tailscale* ]]; then
        run ufw allow in on tailscale0 to any port "$port" proto tcp comment "$c tailscale"; any=0
    fi
    [[ "$PANEL_ACCESS" == *cloudflared* ]] && any=0   # tunnel arrives on loopback (always allowed)
    if [[ $any -eq 1 ]]; then
        warn "no SSH source restriction given: allowing port ${port} from anywhere (rate-limited)"
        run ufw limit "${port}/tcp" comment "$c"
    fi
}

step_firewall() {
    pkg_install ufw || return 1
    local before=""
    before="$(ufw_state)"
    run ufw default deny incoming
    run ufw default allow outgoing
    ufw_allow_ssh "$SSH_PORT" "ssh"
    # keep the current SSH port(s) reachable until the new port is confirmed
    local p
    for p in $CURRENT_SSH_PORTS; do
        [[ "$p" == "$SSH_PORT" ]] || ufw_allow_ssh "$p" "server-prep-temp"
    done
    if yes_ "$EXPOSE_WEB"; then
        run ufw allow 80/tcp comment "http"
        run ufw allow 443/tcp comment "https"
        run ufw allow 443/udp comment "http3"
        run ufw route allow proto tcp from any to any port 80 comment "docker http"
        run ufw route allow proto tcp from any to any port 443 comment "docker https"
        run ufw route allow proto udp from any to any port 443 comment "docker http3"
        note "80/443 open"
    fi
    local e
    for e in ${EXTRA_PORTS//,/ }; do
        [[ "$e" == */* ]] || e="$e/tcp"
        run ufw allow "$e" comment "extra"
        run ufw route allow proto "${e#*/}" from any to any port "${e%/*}" comment "docker extra"
        note "extra port $e"
    done
    # A rule or policy counts as a change only if the rule files differ. A dry run executes
    # nothing, so it keeps showing what it would do.
    if [[ $DRY_RUN -eq 1 || "$(ufw_state)" != "$before" ]]; then changed; fi

    if ! ufw status 2>/dev/null | grep -q "Status: active"; then
        run ufw --force enable && { changed; note "UFW enabled"; }
    else
        run ufw reload
    fi

    # Stop Docker from bypassing UFW. ufw-docker needs UFW active, so this runs after enable
    if [[ $HAS_DOCKER -eq 1 ]]; then
        if ! ufw_docker_rules; then
            # a failed download or update can leave the rules of an earlier run in place
            if iptables -S DOCKER-USER 2>/dev/null | grep -q -- '-j ufw-user-forward'; then
                note "ufw-docker could not be updated (see the log): the rules of an earlier run are still loaded"
            else
                note "ufw-docker rules not loaded: Docker ports still bypass UFW (see the log)"
            fi
            return 1
        fi
    else
        todo "Docker is not installed yet. If your panel installs it later, run: sudo ./server-prep.sh --config /etc/server-prep/server-prep.conf --only firewall --yes (so container ports obey UFW)"
    fi
    return 0
}

restart_ssh() {
    if [[ $SSH_SOCKET -eq 1 ]]; then
        run systemctl daemon-reload
        run systemctl restart ssh.socket || return 1
        run systemctl restart ssh.service 2>/dev/null || true
    else
        run systemctl restart ssh 2>/dev/null || run systemctl restart sshd || return 1
    fi
}

write_sshd_config() {   # write_sshd_config "PORTS"
    local ports="$1" p allow="AllowUsers ${ADMIN_USER}" src
    if [[ -n "$PANEL_PUBKEY" || -s /root/.ssh/authorized_keys ]]; then
        for src in "${ROOT_SOURCES[@]}"; do allow+=" root@${src}"; done
    fi
    {
        echo "# Managed by server-prep.sh"
        for p in $ports; do echo "Port $p"; done
        cat <<EOF
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
AuthenticationMethods publickey
UsePAM yes
GSSAPIAuthentication no
HostbasedAuthentication no
IgnoreRhosts yes
X11Forwarding no
AllowAgentForwarding no
PermitTunnel no
PermitUserEnvironment no
MaxAuthTries 3
MaxStartups 10:30:60
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
LogLevel VERBOSE
${allow}
EOF
    } | write_file /etc/ssh/sshd_config.d/00-server-prep.conf 644

    # Root (the panel) allowed with a key, only from trusted sources. Match blocks
    # must be at the end of the main file.
    local cur match=""
    cur="$(sed '/^# BEGIN server-prep root access/,/^# END server-prep root access/d' /etc/ssh/sshd_config)"
    if [[ ${#ROOT_SOURCES[@]} -gt 0 ]]; then
        match="# BEGIN server-prep root access
Match Address $(IFS=,; echo "${ROOT_SOURCES[*]}")
    PermitRootLogin prohibit-password
# END server-prep root access"
        printf '%s\n\n%s\n' "$cur" "$match" | write_file /etc/ssh/sshd_config 644
    else
        printf '%s\n' "$cur" | write_file /etc/ssh/sshd_config 644
    fi
}

step_ssh() {
    compute_root_sources
    local home nkeys=0
    home="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
    [[ -s "$home/.ssh/authorized_keys" ]] && nkeys=$(grep -cE '^[^#[:space:]]' "$home/.ssh/authorized_keys")
    if [[ $nkeys -eq 0 && $DRY_RUN -eq 0 ]]; then
        warn "${ADMIN_USER} has NO SSH key: after this step ${ADMIN_USER} can only log in on the console."
        if ! confirm "Continue anyway (I have console/physical access)?" no; then
            note "aborted: no SSH key for ${ADMIN_USER}"; return $SKIP_RC
        fi
        note "WARNING: ${ADMIN_USER} has no SSH key"
    fi
    local others=() f
    for f in /etc/ssh/sshd_config.d/*; do
        [[ -e $f && ${f##*/} != 00-server-prep.conf ]] && others+=("${f##*/}")
    done
    if [[ ${#others[@]} -gt 0 ]]; then
        note "other drop-ins present (${others[*]}) - 00-server-prep.conf is read first and wins"
    fi

    local need_two=0 p
    for p in $CURRENT_SSH_PORTS; do [[ "$p" != "$SSH_PORT" ]] && need_two=1; done

    # rollback script for the safety timer
    local rb="$BACKUP_DIR/rollback-ssh.sh"
    if [[ $DRY_RUN -eq 0 ]]; then
        backup_file /etc/ssh/sshd_config
        backup_file /etc/ssh/sshd_config.d/00-server-prep.conf
        cat > "$rb" <<EOF
#!/bin/bash
# Restores the SSH configuration from before server-prep ($TS)
if [ -f "$BACKUP_DIR/etc/ssh/sshd_config" ]; then cp -a "$BACKUP_DIR/etc/ssh/sshd_config" /etc/ssh/sshd_config; fi
if [ -f "$BACKUP_DIR/etc/ssh/sshd_config.d/00-server-prep.conf" ]; then
    cp -a "$BACKUP_DIR/etc/ssh/sshd_config.d/00-server-prep.conf" /etc/ssh/sshd_config.d/00-server-prep.conf
else
    rm -f /etc/ssh/sshd_config.d/00-server-prep.conf
fi
systemctl daemon-reload
systemctl restart ssh.socket 2>/dev/null; systemctl restart ssh 2>/dev/null || systemctl restart sshd
logger -t server-prep "SSH configuration rolled back"
EOF
        chmod 700 "$rb"
    fi

    # Phase A: new secure config, old port(s) still open
    local phase_ports="$SSH_PORT"
    [[ $need_two -eq 1 ]] && phase_ports="$CURRENT_SSH_PORTS $SSH_PORT"
    write_sshd_config "$phase_ports"
    if [[ $DRY_RUN -eq 1 ]]; then note "would set port ${SSH_PORT}, keys only, root via Match"; return 0; fi
    if ! sshd -t 2>>"$LOG_FILE"; then
        err "sshd -t rejected the new configuration - restoring"
        bash "$rb" >/dev/null 2>&1
        note "invalid sshd configuration, rolled back (see $LOG_FILE)"; return 1
    fi
    if [[ $STEP_CHANGED -eq 0 ]]; then note "SSH already secured"; return 0; fi

    run systemd-run --on-active=600 --unit="server-prep-ssh-rollback-$TS" /bin/bash "$rb"
    restart_ssh || { bash "$rb"; note "ssh restart failed, rolled back"; return 1; }
    sleep 2
    if ! ss -ltn "sport = :$SSH_PORT" | grep -q LISTEN; then
        err "sshd is not listening on ${SSH_PORT} - rolling back"
        bash "$rb"; run systemctl stop "server-prep-ssh-rollback-$TS.timer"
        note "sshd did not listen on ${SSH_PORT}, rolled back"; return 1
    fi

    # Verify the effective root policy
    local ext lo
    ext=$(sshd -T -C user=root,host=x,addr=198.51.100.7 2>/dev/null | awk '$1=="permitrootlogin"{print $2}')
    lo=$(sshd -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null | awk '$1=="permitrootlogin"{print $2}')
    note "root login: internet=${ext}, localhost=${lo}"

    # Confirmation from a second terminal
    local answer="y"
    if [[ $INTERACTIVE -eq 1 ]]; then
        echo
        echo "${C_Y}${C_BOLD}  SSH SAFETY CHECK${C_0} - an automatic rollback runs in 10 minutes unless you confirm."
        echo "  Open a NEW terminal and test:  ssh -p ${SSH_PORT} ${ADMIN_USER}@${LOCAL_IP:-<server-ip>}"
        echo "  y = it works   n = roll back now   s = skip test (I have console access)"
        while true; do
            read -r -p "  Result [y/n/s]: " answer < /dev/tty || answer=s
            case "${answer,,}" in y|n|s) break ;; esac
        done
    fi
    if [[ "${answer,,}" == "n" ]]; then
        bash "$rb"; run systemctl stop "server-prep-ssh-rollback-$TS.timer"
        note "user reported failure - SSH configuration rolled back"; return 1
    fi
    run systemctl stop "server-prep-ssh-rollback-$TS.timer"

    # Phase B: only the new port
    if [[ $need_two -eq 1 ]]; then
        write_sshd_config "$SSH_PORT"
        sshd -t 2>>"$LOG_FILE" || { bash "$rb"; note "phase B config invalid, rolled back"; return 1; }
        restart_ssh
        local nums
        nums=$(ufw status numbered 2>/dev/null | grep 'server-prep-temp' | sed -E 's/^\[ *([0-9]+)\].*/\1/' | sort -rn)
        for p in $nums; do run ufw --force delete "$p"; done
        note "old SSH port(s) ${CURRENT_SSH_PORTS}closed"
    fi
    note "SSH on ${SSH_PORT}, key-only, AllowUsers set"
    return 0
}

step_ips() {
    local did=0 ignore="127.0.0.1/8 ::1"
    [[ "$PANEL_ACCESS" == *tailscale* ]] && ignore+=" 100.64.0.0/10"
    [[ -n "$PANEL_IP" ]] && ignore+=" $PANEL_IP"
    ignore+=" ${ADMIN_IPS//,/ }"

    if yes_ "$INSTALL_FAIL2BAN"; then
        did=1
        pkg_install fail2ban python3-systemd || { note "fail2ban install failed"; return 1; }
        write_file /etc/fail2ban/jail.local 644 <<EOF
# Managed by server-prep.sh
[DEFAULT]
bantime = 1h
bantime.increment = true
bantime.maxtime = 1w
findtime = 10m
maxretry = 5
backend = systemd
banaction = nftables-multiport
banaction_allports = nftables-allports
ignoreip = ${ignore}

[sshd]
enabled = true
port = ${SSH_PORT}
mode = aggressive
EOF
        run systemctl enable fail2ban
        run systemctl restart fail2ban || { note "fail2ban failed to start (journalctl -u fail2ban)"; return 1; }
        note "fail2ban sshd jail on port ${SSH_PORT}"
    fi

    if yes_ "$INSTALL_CROWDSEC"; then
        did=1
        # Prefer CrowdSec's own repository: Ubuntu Pro (ESM, priority 510) ships an outdated crowdsec
        write_file /etc/apt/preferences.d/crowdsec 644 <<'EOF'
Package: crowdsec*
Pin: origin packagecloud.io
Pin-Priority: 900
EOF
        if ! pkg_installed crowdsec; then
            info "adding the CrowdSec repository"
            if [[ $DRY_RUN -eq 0 ]]; then
                curl -fsSL https://install.crowdsec.net | sh >> "$LOG_FILE" 2>&1 || warn "CrowdSec repo setup failed, trying distro packages"
                apt-get -o DPkg::Lock::Timeout=600 update -q >> "$LOG_FILE" 2>&1
            fi
            # may report an error if 8080 is taken - fixed just below
            run apt-get install "${APT_OPTS[@]}" crowdsec || warn "crowdsec install reported an error, fixing the LAPI port and retrying"
            changed
        elif [[ -f /etc/apt/sources.list.d/crowdsec_crowdsec.list ]] \
             && dpkg-query -W -f='${Version}' crowdsec 2>/dev/null | grep -qE 'ubuntu|deb|esm'; then
            info "replacing the distro crowdsec ($(dpkg-query -W -f='${Version}' crowdsec)) with the official release"
            run apt-get -o DPkg::Lock::Timeout=600 update -q
            run apt-get install "${APT_OPTS[@]}" crowdsec || warn "crowdsec upgrade reported an error, fixing the LAPI port"
            changed
        fi
        # Move the local API away from 8080 (Traefik dashboards use it)
        if [[ -f /etc/crowdsec/config.yaml ]] && grep -q '127.0.0.1:8080' /etc/crowdsec/config.yaml; then
            sed "s/127.0.0.1:8080/127.0.0.1:${CROWDSEC_LAPI_PORT}/" /etc/crowdsec/config.yaml | write_file /etc/crowdsec/config.yaml 644
            note "CrowdSec LAPI moved to 127.0.0.1:${CROWDSEC_LAPI_PORT}"
        fi
        if [[ -f /etc/crowdsec/local_api_credentials.yaml ]] && grep -q '127.0.0.1:8080' /etc/crowdsec/local_api_credentials.yaml; then
            sed "s/127.0.0.1:8080/127.0.0.1:${CROWDSEC_LAPI_PORT}/" /etc/crowdsec/local_api_credentials.yaml | write_file /etc/crowdsec/local_api_credentials.yaml 600
        fi
        if [[ $DRY_RUN -eq 0 ]] && ! pkg_installed crowdsec; then dpkg --configure -a >> "$LOG_FILE" 2>&1; fi
        pkg_installed crowdsec || [[ $DRY_RUN -eq 1 ]] || { note "CrowdSec install failed (see $LOG_FILE)"; return 1; }

        local wl_ip="" wl_cidr="" ip
        for ip in $ignore; do
            if [[ "$ip" == */* ]]; then wl_cidr+="    - \"$ip\""$'\n'; else wl_ip+="    - \"$ip\""$'\n'; fi
        done
        {
            echo 'name: server-prep/whitelist'
            echo 'description: "Admin, panel and local addresses (server-prep)"'
            echo 'whitelist:'
            echo '  reason: "trusted source"'
            echo '  ip:'; printf '%s' "$wl_ip"
            echo '  cidr:'; printf '%s' "$wl_cidr"
        } | write_file /etc/crowdsec/parsers/s02-enrich/zz-server-prep-whitelist.yaml 644
        if [[ $DRY_RUN -eq 0 ]]; then
            cscli collections install crowdsecurity/linux crowdsecurity/sshd >> "$LOG_FILE" 2>&1 || true
            systemctl enable crowdsec >> "$LOG_FILE" 2>&1
            systemctl restart crowdsec >> "$LOG_FILE" 2>&1 || { note "crowdsec failed to start (journalctl -u crowdsec)"; return 1; }
        fi

        if ! pkg_installed crowdsec-firewall-bouncer-iptables && ! pkg_installed crowdsec-firewall-bouncer; then
            local bpkg=crowdsec-firewall-bouncer-iptables
            pkg_available "$bpkg" || bpkg=crowdsec-firewall-bouncer
            run apt-get install "${APT_OPTS[@]}" "$bpkg" || warn "bouncer install reported an error, fixing its config"
            changed
        fi
        local bc=/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml
        if [[ -f "$bc" ]]; then
            local new; new="$(sed -E "s#(api_url:.*127\.0\.0\.1:)8080#\1${CROWDSEC_LAPI_PORT}#" "$bc")"
            [[ $HAS_DOCKER -eq 1 ]] && new="$(sed -E 's/^#([[:space:]]*- DOCKER-USER)/\1/' <<<"$new")"
            printf '%s\n' "$new" | write_file "$bc" 600
            [[ $DRY_RUN -eq 0 ]] && dpkg --configure -a >> "$LOG_FILE" 2>&1
            run systemctl enable crowdsec-firewall-bouncer
            run systemctl restart crowdsec-firewall-bouncer || { note "firewall bouncer failed to start"; return 1; }
        elif [[ $DRY_RUN -eq 0 ]]; then
            note "firewall bouncer not installed"; return 1
        fi
        if [[ -n "$CROWDSEC_ENROLL_KEY" && $DRY_RUN -eq 0 ]]; then
            cscli console enroll -e context "$CROWDSEC_ENROLL_KEY" >> "$LOG_FILE" 2>&1 \
                && todo "Accept the enrollment of ${HOST_SHORT} in https://app.crowdsec.net" \
                || note "CrowdSec console enroll failed"
        fi
        note "CrowdSec + firewall bouncer$([[ $HAS_DOCKER -eq 1 ]] && echo ' (INPUT + DOCKER-USER)')"
    fi
    [[ $did -eq 1 ]] || return $SKIP_RC
    return 0
}

step_unattended() {
    pkg_install unattended-upgrades apt-listchanges || return 1
    write_file /etc/apt/apt.conf.d/20auto-upgrades 644 <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
    {
        echo "// Managed by server-prep.sh"
        if yes_ "$DOCKER_AUTO_UPDATE"; then
            echo 'Unattended-Upgrade::Origins-Pattern { "origin=Docker,label=Docker CE"; };'
        fi
        echo 'Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";'
        echo 'Unattended-Upgrade::Remove-Unused-Dependencies "true";'
        if yes_ "$AUTO_REBOOT"; then
            echo 'Unattended-Upgrade::Automatic-Reboot "true";'
            echo "Unattended-Upgrade::Automatic-Reboot-Time \"${AUTO_REBOOT_TIME}\";"
        else
            echo 'Unattended-Upgrade::Automatic-Reboot "false";'
        fi
    } | write_file /etc/apt/apt.conf.d/52server-prep-unattended 644
    run systemctl enable --now unattended-upgrades
    note "security updates daily$(yes_ "$DOCKER_AUTO_UPDATE" && echo ', Docker CE included')$(yes_ "$AUTO_REBOOT" && echo ", auto-reboot ${AUTO_REBOOT_TIME}")"
    return 0
}

step_sysctl() {
    local rp=1
    [[ $HAS_TAILSCALE -eq 1 || $HAS_DOCKER -eq 1 ]] && rp=2   # loose mode: tailscale/docker friendly
    write_file /etc/sysctl.d/99-server-prep.conf 644 <<EOF
# Managed by server-prep.sh
# --- network ---
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.conf.all.rp_filter = ${rp}
net.ipv4.conf.default.rp_filter = ${rp}
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
# Docker needs forwarding
net.ipv4.ip_forward = 1
# --- kernel ---
kernel.randomize_va_space = 2
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = ${PTRACE_SCOPE}
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
kernel.perf_event_paranoid = 3
kernel.sysrq = 0
# --- filesystem ---
fs.suid_dumpable = 0
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
EOF
    write_file /etc/modprobe.d/server-prep-blacklist.conf 644 <<'EOF'
# Managed by server-prep.sh - rarely used network protocols
install dccp /bin/false
install sctp /bin/false
install rds /bin/false
install tipc /bin/false
EOF
    # UFW re-applies its own sysctl file when it starts and turns log_martians back off
    if [[ -r /etc/ufw/sysctl.conf ]] && grep -q 'log_martians=0' /etc/ufw/sysctl.conf; then
        sed 's/log_martians=0/log_martians=1/' /etc/ufw/sysctl.conf | write_file /etc/ufw/sysctl.conf 644
    fi
    run sysctl --system
    note "kernel/network security settings applied (rp_filter=${rp}, ptrace_scope=${PTRACE_SCOPE})"
    return 0
}

step_auth() {
    # sudo log file - must be in /etc/sudoers itself, validated with visudo
    if [[ ! -r /etc/sudoers ]]; then note "cannot read /etc/sudoers (dry-run without root)"; return $SKIP_RC; fi
    local sudo_rs=0
    if sudo --version 2>/dev/null | head -1 | grep -qi 'sudo-rs'; then
        sudo_rs=1
        note "sudo-rs detected: no log file option, every command is logged to the journal (journalctl _COMM=sudo)"
    fi
    if [[ $sudo_rs -eq 0 ]] && ! grep -qE '^[[:space:]]*Defaults.*logfile' /etc/sudoers; then
        local tmp; tmp="$(mktemp)"
        cp /etc/sudoers "$tmp"
        if grep -q '^@includedir' "$tmp"; then
            sed -i '/^@includedir/i Defaults\tlogfile="/var/log/sudo.log"\n' "$tmp"
        else
            printf 'Defaults\tlogfile="/var/log/sudo.log"\n' >> "$tmp"
        fi
        if visudo -cf "$tmp" >> "$LOG_FILE" 2>&1; then
            write_file /etc/sudoers 440 < "$tmp"
            note "sudo commands logged to /var/log/sudo.log"
        else
            note "visudo rejected the change - /etc/sudoers untouched"; rm -f "$tmp"; return 1
        fi
        rm -f "$tmp"
    fi
    [[ $sudo_rs -eq 1 ]] || write_file /etc/logrotate.d/sudo-log 644 <<'EOF'
/var/log/sudo.log {
    weekly
    rotate 12
    compress
    missingok
    notifempty
    create 0600 root root
}
EOF
    pkg_install libpam-pwquality cracklib-runtime || return 1
    local f=/etc/security/pwquality.conf
    set_kv "$f" minlen 12
    set_kv "$f" dcredit -1
    set_kv "$f" ucredit -1
    set_kv "$f" lcredit -1
    set_kv "$f" ocredit -1
    set_kv "$f" maxrepeat 3
    set_kv "$f" difok 4
    set_kv "$f" usercheck 1
    note "password policy: 12+ chars, upper/lower/digit/symbol"
    # The dictionary check needs a built cracklib dictionary, otherwise every password
    # change fails with "BAD PASSWORD: ... error loading dictionary"
    local dict=/var/cache/cracklib/cracklib_dict.pwd
    if [[ ! -f $dict ]]; then
        run update-cracklib
        [[ -f $dict || $DRY_RUN -eq 1 ]] || run apt-get install "${APT_OPTS[@]}" --reinstall cracklib-runtime
        if [[ -f $dict || $DRY_RUN -eq 1 ]]; then
            changed; note "password dictionary built (update-cracklib)"
        else
            set_kv "$f" dictcheck 0
            note "password dictionary missing: dictionary check turned off so passwords can still be changed"
            todo "Build the password dictionary: sudo apt install --reinstall cracklib-runtime && sudo update-cracklib, then remove 'dictcheck = 0' from $f"
        fi
    fi
    return 0
}

step_services() {
    local before after
    before=$(systemctl list-units --type=service --state=running --no-legend | wc -l)
    local s
    for s in $DISABLE_SERVICES; do
        case "$s" in
            avahi-daemon) svc_disable avahi-daemon.socket avahi-daemon.service ;;
            cups) svc_disable cups.path cups.socket cups.service ;;
            apport) svc_disable apport.service; run sysctl -q -w fs.suid_dumpable=0 ;;
            *) svc_disable "$s.service" ;;
        esac
    done
    if [[ "$(systemctl is-enabled ctrl-alt-del.target 2>/dev/null)" != "masked" ]]; then
        run systemctl mask ctrl-alt-del.target && changed
    fi
    if yes_ "$HEADLESS" && [[ "$(systemctl get-default)" != "multi-user.target" ]]; then
        run systemctl set-default multi-user.target && { changed; todo "Reboot to switch to headless mode (graphical desktop off). Undo: sudo systemctl set-default graphical.target"; }
    fi
    after=$(systemctl list-units --type=service --state=running --no-legend | wc -l)
    note "disabled: ${DISABLE_SERVICES:-none}; running services ${before} -> ${after}"
    return 0
}

step_laptop() {
    [[ $IS_LAPTOP -eq 1 ]] || return $SKIP_RC
    write_file /etc/systemd/logind.conf.d/50-server-prep-lid.conf 644 <<'EOF'
# Managed by server-prep.sh - keep serving with the lid closed
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
IdleAction=ignore
EOF
    local t
    for t in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
        [[ "$(systemctl is-enabled "$t" 2>/dev/null)" == "masked" ]] || { run systemctl mask "$t" && changed; }
    done
    todo "Lid-close setting applies after the next reboot (restarting logind would close the desktop session)"
    note "lid close ignored, sleep/suspend/hibernate masked"
    return 0
}

step_logging() {
    write_file /etc/systemd/journald.conf.d/50-server-prep.conf 644 <<'EOF'
# Managed by server-prep.sh
[Journal]
Storage=persistent
SystemMaxUse=1G
MaxRetentionSec=3month
EOF
    run mkdir -p /var/log/journal
    run systemctl restart systemd-journald
    if [[ -z "$(swapon --show --noheadings 2>/dev/null)" && -n "$SWAP_SIZE" && "$SWAP_SIZE" != "0" ]]; then
        info "creating ${SWAP_SIZE} swap file"
        run fallocate -l "$SWAP_SIZE" /swapfile && run chmod 600 /swapfile && run mkswap /swapfile && run swapon /swapfile
        grep -q '^/swapfile' /etc/fstab || { { cat /etc/fstab; echo '/swapfile none swap sw 0 0'; } | write_file /etc/fstab 644; }
        changed; note "swap ${SWAP_SIZE} created"
    fi
    note "journald persistent, 1G max"
    return 0
}

step_auditd() {
    yes_ "$INSTALL_AUDITD" || return $SKIP_RC
    pkg_install auditd audispd-plugins 2>/dev/null || pkg_install auditd || return 1
    write_file /etc/audit/rules.d/50-server-prep.rules 640 <<'EOF'
## Managed by server-prep.sh
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers
-w /etc/ssh/sshd_config -p wa -k sshd
-w /etc/ssh/sshd_config.d/ -p wa -k sshd
-w /root/.ssh/ -p wa -k root_ssh
-w /etc/docker/ -p wa -k docker_cfg
-w /usr/bin/docker -p x -k docker_cli
-w /etc/crontab -p wa -k cron
-w /etc/cron.d/ -p wa -k cron
-w /var/spool/cron/ -p wa -k cron
-w /etc/hosts -p wa -k hosts
-w /etc/systemd/system/ -p wa -k systemd
-w /etc/ufw/ -p wa -k firewall
-w /sbin/insmod -p x -k modules
-w /sbin/modprobe -p x -k modules
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=unset -k admin_root_cmd
EOF
    run systemctl enable --now auditd
    run augenrules --load
    note "auditd rules: identity, sudoers, ssh, docker, cron, firewall, admin root commands (ausearch -k <key>)"
    return 0
}

step_rkhunter() {
    yes_ "$INSTALL_RKHUNTER" || return $SKIP_RC
    pkg_install rkhunter || return 1
    local f=/etc/default/rkhunter
    set_kv "$f" CRON_DAILY_RUN '"true"' '='
    set_kv "$f" CRON_DB_UPDATE '"false"' '='
    set_kv "$f" APT_AUTOGEN '"true"' '='
    write_file /etc/rkhunter.conf.local 644 <<'EOF'
# Managed by server-prep.sh
UPDATE_MIRRORS=0
MIRRORS_MODE=1
WEB_CMD=""
ALLOW_SSH_ROOT_USER=prohibit-password
PKGMGR=DPKG
EOF
    run rkhunter --propupd --nocolors
    note "rkhunter baseline created, daily scan via cron (/var/log/rkhunter.log)"
    return 0
}

step_aide() {
    yes_ "$INSTALL_AIDE" || return $SKIP_RC
    pkg_install aide aide-common || return 1
    write_file /etc/aide/aide.conf.d/99_server-prep 644 <<'EOF'
# Managed by server-prep.sh - exclude fast-changing container/app data
!/var/lib/docker
!/var/lib/containerd
!/data/coolify
!/etc/dokploy
!/var/lib/crowdsec
!/var/log
!/home
!/snap
!/var/snap
!/var/lib/snapd
!/swapfile
EOF
    if [[ ! -e /var/lib/aide/aide.db && $DRY_RUN -eq 0 ]]; then
        info "building the AIDE baseline in the background (takes a few minutes)"
        (umask 077; : > "$LOG_DIR/aideinit.log")   # 600 like the other logs (aideinit keeps its own umask)
        chmod 600 "$LOG_DIR/aideinit.log"
        nohup aideinit -y -f >> "$LOG_DIR/aideinit.log" 2>&1 &
        note "AIDE baseline started in background ($LOG_DIR/aideinit.log)"
        changed
    fi
    note "daily integrity check by aide-common"
    return 0
}

step_endlessh() {
    yes_ "$INSTALL_ENDLESSH" || return $SKIP_RC
    if [[ "$SSH_PORT" == "22" ]]; then note "SSH still uses 22"; return $SKIP_RC; fi
    if ss -Hltn "sport = :22" 2>/dev/null | grep -q .; then
        systemctl is-active --quiet endlessh 2>/dev/null && { note "endlessh already running"; return 0; }
        note "port 22 is still in use (SSH not moved yet?) - not installing"; return $SKIP_RC
    fi
    pkg_available endlessh || { note "endlessh package not available on this release"; return $SKIP_RC; }
    pkg_install endlessh || return 1
    write_file /etc/endlessh/config 644 <<'EOF'
Port 22
Delay 10000
MaxLineLength 32
MaxClients 4096
LogLevel 1
BindFamily 0
EOF
    write_file /etc/systemd/system/endlessh.service.d/server-prep.conf 644 <<'EOF'
[Service]
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
PrivateUsers=false
EOF
    run systemctl daemon-reload
    run systemctl enable endlessh
    run systemctl restart endlessh || { note "endlessh failed to start"; return 1; }
    run ufw allow 22/tcp comment "endlessh tarpit"
    note "tarpit on port 22 (journalctl -u endlessh)"
    return 0
}

step_telegraf() {
    yes_ "$INSTALL_TELEGRAF" || return $SKIP_RC
    pkg_install curl gnupg || return 1
    # official repository, key checked against InfluxData's published fingerprint
    local key=/etc/apt/keyrings/influxdata-archive.gpg fpr=24C975CBA61A024EE1B631787C3D57159FC2F927
    if [[ ! -s "$key" ]]; then
        info "adding the InfluxData repository"
        if [[ $DRY_RUN -eq 0 ]]; then
            local tmp; tmp="$(mktemp)"
            curl -fsSL https://repos.influxdata.com/influxdata-archive.key -o "$tmp" || { note "cannot download the InfluxData key"; rm -f "$tmp"; return 1; }
            if ! gpg --show-keys --with-fingerprint --with-colons "$tmp" 2>/dev/null | grep -q "^fpr:\+${fpr}:\$"; then
                note "InfluxData key fingerprint mismatch - not installing"; rm -f "$tmp"; return 1
            fi
            install -m 0755 -d /etc/apt/keyrings
            gpg --dearmor < "$tmp" > "$key"; chmod 644 "$key"; rm -f "$tmp"
        fi
        changed
    fi
    write_file /etc/apt/sources.list.d/influxdata.list 644 <<EOF
deb [signed-by=${key}] https://repos.influxdata.com/debian stable main
EOF
    # Ubuntu/ESM may ship an older telegraf: prefer the official one
    write_file /etc/apt/preferences.d/influxdata 644 <<'EOF'
Package: telegraf
Pin: origin repos.influxdata.com
Pin-Priority: 900
EOF
    if ! pkg_installed telegraf; then
        run apt-get -o DPkg::Lock::Timeout=600 update -q || { note "apt-get update failed"; return 1; }
        pkg_install telegraf || return 1
        # the package starts it with a sample config pointing to localhost:8086 - keep it off until configured
        run systemctl disable --now telegraf
        note "telegraf $(dpkg-query -W -f='${Version}' telegraf 2>/dev/null) installed, service left stopped"
        todo "Telegraf: configure it from telegraf.conf.example (in the release files, or extras/telegraf/ in the repo) and put its secrets in /etc/default/telegraf. The template reads Docker: run 'sudo usermod -aG docker telegraf' (root-equivalent access), or delete [[inputs.docker]] on a server without Docker, otherwise Telegraf does not start. Guide: ${PROJECT_URL}/blob/main/docs/monitoring.md. Test with: sudo -u telegraf bash -c \"set -a; . /etc/default/telegraf; telegraf --config /etc/telegraf/telegraf.conf --config-directory /etc/telegraf/telegraf.d --once --debug\" and look for 'Wrote batch' (the secrets are only loaded by the service, so a plain telegraf command would run with an empty token). Behind Cloudflare Access, 'Wrote batch' alone proves nothing: pass the guide's 204 test first, then check the data in the bucket. Then: sudo systemctl enable --now telegraf"
    else
        note "telegraf $(dpkg-query -W -f='${Version}' telegraf) already installed ($(systemctl is-active telegraf 2>/dev/null)) - configuration untouched"
    fi
    return 0
}

step_telegram() {
    yes_ "$TELEGRAM_ENABLE" || return $SKIP_RC
    # the answers file never holds the token: a re-run without one keeps the token already installed
    if [[ -z "$TELEGRAM_BOT_TOKEN" && -f "$CONF_DIR/telegram.env" ]]; then
        TELEGRAM_BOT_TOKEN="$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$CONF_DIR/telegram.env" 2>/dev/null | tail -n 1)"
    fi
    [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]] || { note "token/chat id missing"; return 1; }
    # the token goes into a curl config line (url = "..."), whose errors are silenced: catch a bad paste here
    [[ $TELEGRAM_BOT_TOKEN =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || { note "the bot token does not look like 123456:ABC-..."; return 1; }
    write_file "$CONF_DIR/telegram.env" 600 <<EOF
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID}
TELEGRAM_IGNORE_USERS="${TELEGRAM_IGNORE_USERS}"
EOF
    write_file /usr/local/sbin/server-prep-notify 755 <<'EOF'
#!/bin/bash
# Send a Telegram message: server-prep-notify "text"
# The bot URL holds the token: curl reads it on stdin (-K -), so it never shows in ps.
. /etc/server-prep/telegram.env || exit 0
printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TELEGRAM_BOT_TOKEN" |
    curl -fsS -m 10 -K - --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=$1" >/dev/null 2>&1
EOF
    write_file /usr/local/sbin/server-prep-ssh-alert 755 <<'EOF'
#!/bin/bash
# Called by pam_exec on SSH session open
[ "$PAM_TYPE" = "open_session" ] || exit 0
. /etc/server-prep/telegram.env 2>/dev/null || exit 0
for u in $TELEGRAM_IGNORE_USERS; do [ "$PAM_USER" = "$u" ] && exit 0; done
/usr/local/sbin/server-prep-notify "🔐 SSH login on $(hostname): ${PAM_USER} from ${PAM_RHOST:-?} at $(date '+%F %T %Z')" </dev/null >/dev/null 2>&1 &
exit 0
EOF
    if ! grep -q 'server-prep-ssh-alert' /etc/pam.d/sshd; then
        { cat /etc/pam.d/sshd; echo 'session optional pam_exec.so quiet /usr/local/sbin/server-prep-ssh-alert'; } | write_file /etc/pam.d/sshd 644
    fi
    write_file /usr/local/sbin/server-prep-daily-report 755 <<'EOF'
#!/bin/bash
# Daily security summary sent to Telegram
h=$(hostname)
up=$(uptime -p)
disk=$(df -h / | awk 'NR==2{print $5" used ("$4" free)"}')
mem=$(free -h | awk '/^Mem:/{print $7" available of "$2}')
upd=$(apt-get -s dist-upgrade 2>/dev/null | grep -c '^Inst ')
reboot=$([ -f /var/run/reboot-required ] && echo "YES" || echo "no")
f2b=$(fail2ban-client status sshd 2>/dev/null | awk -F: '/Total banned/{gsub(/ /,"",$2);print $2}')
cs=$(cscli decisions list -o raw 2>/dev/null | tail -n +2 | wc -l)
failed=$(systemctl --failed --no-legend | awk '{print $2}' | tr '\n' ' ')
rk=$([ -r /var/log/rkhunter.log ] && grep -c 'Warning:' /var/log/rkhunter.log || true)
aide=$(journalctl -u dailyaidecheck --since "24 hours ago" 2>/dev/null | grep -oE '(added|removed|changed) entries: [0-9]+' | tr '\n' ' ')
logins=$(journalctl --since "24 hours ago" SYSLOG_IDENTIFIER=sshd SYSLOG_IDENTIFIER=sshd-session 2>/dev/null | grep -c 'Accepted publickey')
ctr=$(docker ps -q 2>/dev/null | wc -l)
/usr/local/sbin/server-prep-notify "📊 Daily report - ${h}
uptime: ${up}
disk: ${disk} | mem: ${mem}
updates pending: ${upd} | reboot needed: ${reboot}
SSH logins (24h): ${logins}
fail2ban total bans: ${f2b:--} | CrowdSec decisions: ${cs}
rkhunter warnings: ${rk:--} | AIDE: ${aide:-no report}
containers running: ${ctr}
failed units: ${failed:-none}"
EOF
    write_file /etc/systemd/system/server-prep-daily-report.service 644 <<'EOF'
[Unit]
Description=server-prep daily Telegram report
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/server-prep-daily-report
EOF
    write_file /etc/systemd/system/server-prep-daily-report.timer 644 <<'EOF'
[Unit]
Description=server-prep daily Telegram report
[Timer]
OnCalendar=*-*-* 09:00:00
Persistent=true
[Install]
WantedBy=timers.target
EOF
    run systemctl daemon-reload
    run systemctl enable --now server-prep-daily-report.timer
    local sent="test message sent"
    if [[ $DRY_RUN -eq 0 ]] && ! /usr/local/sbin/server-prep-notify "✅ server-prep: Telegram alerts enabled on $(hostname)"; then
        sent="test message failed: check the bot token and the chat id"
    fi
    note "SSH login alerts (ignored users: ${TELEGRAM_IGNORE_USERS}) + daily report 09:00 - ${sent}"
    return 0
}

step_cloudflared() {
    [[ "$PANEL_ACCESS" == *cloudflared* ]] || return $SKIP_RC
    if systemctl is-active --quiet cloudflared 2>/dev/null; then
        note "cloudflared tunnel service already running"
    elif [[ -z "$CLOUDFLARED_TOKEN" ]]; then
        todo "Install the Cloudflare Tunnel: create a tunnel in Zero Trust and run 'sudo cloudflared service install <TOKEN>'"
        note "no tunnel token given"; return $SKIP_RC
    else
        if ! have cloudflared; then
            run mkdir -p --mode=0755 /usr/share/keyrings
            run curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg -o /usr/share/keyrings/cloudflare-public-v2.gpg \
                || { note "cannot download Cloudflare key"; return 1; }
            write_file /etc/apt/sources.list.d/cloudflared.list 644 <<'EOF'
deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main
EOF
            run apt-get -o DPkg::Lock::Timeout=600 update -q
            pkg_install cloudflared || return 1
        fi
        run_secret "$CLOUDFLARED_TOKEN" cloudflared service install "$CLOUDFLARED_TOKEN" || { note "cloudflared service install failed"; return 1; }
        changed; note "cloudflared tunnel service installed"
    fi
    todo "Cloudflare Zero Trust -> your tunnel -> Public hostnames: ssh-${HOST_SHORT}.<domain> -> ssh://localhost:${SSH_PORT}; app hostnames -> http://localhost:80"
    todo "In ${PANEL_LABEL}: add this server with the tunnel SSH hostname (Coolify: server Configuration -> Cloudflare Tunnel)"
    return 0
}

SUID_LIST=""
step_suid() {
    local f owner lines=""
    while read -r f; do
        [[ -z "$f" ]] && continue
        owner="$(dpkg -S "$f" 2>/dev/null | cut -d: -f1 | head -1)"
        lines+="| \`$f\` | ${owner:-**not owned by any package - verify**} |"$'\n'
    done < <(find / -xdev \( -path /var/lib/docker -o -path /var/lib/containerd \) -prune -o -type f -perm -4000 -print 2>/dev/null | grep -vE '^/usr/bin/|^/bin/|^/sbin/|^/usr/sbin/|^/usr/lib|^/usr/libexec')
    SUID_LIST="$lines"
    note "listed in the report (review only, nothing changed)"
    return 0
}

# ----------------------------------------------------------------------------
# Rollback script & report
# ----------------------------------------------------------------------------
write_rollback() {
    [[ $DRY_RUN -eq 1 ]] && return 0
    local rb="$BACKUP_DIR/rollback.sh" f
    {
        echo "#!/bin/bash"
        echo "# Restore files changed by server-prep run ${TS}. Review before running!"
        echo "set -x"
        for f in "${CHANGED_FILES[@]}"; do echo "cp -a '$BACKUP_DIR$f' '$f'"; done
        for f in "${NEW_FILES[@]}"; do echo "rm -f '$f'"; done
        echo "systemctl daemon-reload"
        echo "sysctl --system >/dev/null"
        echo "systemctl restart ssh.socket 2>/dev/null; systemctl restart ssh 2>/dev/null"
        echo "ufw reload 2>/dev/null"
        echo "# Packages installed and services disabled are NOT reverted automatically."
    } > "$rb"
    chmod 700 "$rb"
}

write_report() {
    local i
    {
        echo "# Server preparation report - ${HOST_SHORT}"
        echo
        echo "| | |"
        echo "|---|---|"
        echo "| Date | $(date -Is) |"
        echo "| Host | $(hostname) |"
        echo "| OS | ${OS_PRETTY} (kernel $(uname -r)) |"
        echo "| Local IP | ${LOCAL_IP:-?} |"
        echo "| Mode | $([[ $DRY_RUN -eq 1 ]] && echo 'dry-run (nothing changed)' || echo applied) |"
        echo "| server-prep | v${PREP_VERSION} |"
        echo "| Log | \`${LOG_FILE}\` |"
        echo "| Backups | \`${BACKUP_DIR}\` (rollback: \`${BACKUP_DIR}/rollback.sh\`) |"
        echo
        echo "## Settings used"
        echo
        echo "| Setting | Value |"
        echo "|---|---|"
        echo "| Admin user | ${ADMIN_USER} |"
        echo "| SSH port | ${SSH_PORT} (before: ${CURRENT_SSH_PORTS}) |"
        echo "| Panel | ${PANEL:-none} - access: ${PANEL_ACCESS:-none} ${PANEL_IP:+(server ${PANEL_IP})} |"
        echo "| Root SSH allowed from | ${ROOT_SOURCES[*]:-nowhere} |"
        echo "| SSH allowed from | ${ADMIN_IPS:-tunnel/tailnet only} |"
        echo "| Web 80/443 public | ${EXPOSE_WEB} |"
        echo "| Extra ports | ${EXTRA_PORTS:-none} |"
        echo "| fail2ban / CrowdSec | ${INSTALL_FAIL2BAN} / ${INSTALL_CROWDSEC} |"
        echo "| Telegram | ${TELEGRAM_ENABLE} |"
        echo
        echo "## What was done"
        echo
        echo "| # | Step | Result | Details |"
        echo "|---|---|---|---|"
        for i in "${!STEP_NAMES[@]}"; do
            printf '| %d | %s | %s | %s |\n' "$((i+1))" "${STEP_NAMES[$i]}" "${STEP_RESULTS[$i]}" "${STEP_DETAILS[$i]//|/\\|}"
        done
        echo
        if [[ -n "$AUDIT_BEFORE" && -n "$AUDIT_AFTER" ]]; then
            echo "## Audit before / after (server-audit.sh)"
            echo
            local pb pa fb fa
            pb=$(awk -F'\t' '$2=="PASS"' "$AUDIT_BEFORE" | wc -l); pa=$(awk -F'\t' '$2=="PASS"' "$AUDIT_AFTER" | wc -l)
            fb=$(awk -F'\t' '$2=="FAIL"' "$AUDIT_BEFORE" | wc -l); fa=$(awk -F'\t' '$2=="FAIL"' "$AUDIT_AFTER" | wc -l)
            echo "PASS ${pb} -> **${pa}** · FAIL ${fb} -> **${fa}**"
            echo
            echo "| Check | Before | After | Result now |"
            echo "|---|---|---|---|"
            awk -F'\t' 'NR==FNR { b[$1]=$2; next }
                        $2 != "INFO" {
                            before = ($1 in b) ? b[$1] : "-"
                            mark = (before != $2) ? "**" $2 "**" : $2
                            gsub(/\|/, "\\|", $4)
                            printf "| %s | %s | %s | %s |\n", $3, before, mark, $4
                        }' "$AUDIT_BEFORE" "$AUDIT_AFTER"
            echo
        fi
        echo "## Firewall"
        echo
        echo '```'
        ufw status verbose 2>/dev/null || echo "ufw status unavailable"
        echo '```'
        echo
        echo "## Listening ports"
        echo
        echo '```'
        ss -H -ltnp 2>/dev/null | awk '{print $4, $6}' | sort -u
        echo '```'
        echo
        if [[ ${#CHANGED_FILES[@]} -gt 0 || ${#NEW_FILES[@]} -gt 0 ]]; then
            echo "## Files"
            echo
            for i in "${CHANGED_FILES[@]}"; do echo "- modified: \`$i\` (backup: \`${BACKUP_DIR}${i}\`)"; done
            for i in "${NEW_FILES[@]}"; do echo "- created: \`$i\`"; done
            echo
        fi
        if [[ -n "$SUID_LIST" ]]; then
            echo "## SUID files outside standard paths (review)"
            echo
            echo "| File | Package |"
            echo "|---|---|"
            printf '%s' "$SUID_LIST"
            echo
        fi
        echo "## Connect this server to ${PANEL_LABEL}"
        echo
        echo "1. In ${PANEL_LABEL}, add a new server$([[ ${PANEL,,} == coolify ]] && echo ' (**Servers -> + Add**)'):"
        if [[ "$PANEL_ACCESS" == *cloudflared* ]]; then
            echo "   - IP/Domain: the tunnel SSH hostname (e.g. \`ssh-${HOST_SHORT}.<your-domain>\`), then enable the panel's Cloudflare Tunnel option if it has one (Coolify: server configuration)"
        fi
        if [[ "$PANEL_ACCESS" == *tailscale* ]]; then
            echo "   - or IP: the Tailscale IP of this server ($(tailscale ip -4 2>/dev/null | head -1)) - the panel server must be in the same tailnet"
        fi
        if [[ "$PANEL_ACCESS" == *public* ]]; then
            echo "   - IP: this server's public IP (panel server ${PANEL_IP} is the only allowed source)"
        fi
        echo "   - User: \`root\` · Port: \`${SSH_PORT}\` · Private key: the one whose public key was installed"
        echo "2. **Validate** the server in the panel: it checks Docker and installs its reverse proxy on 80/443."
        echo "3. Deploy an application; expose it through the tunnel (Cloudflare public hostname -> \`http://localhost:80\`)$([[ $EXPOSE_WEB == yes ]] && echo ' or directly on 80/443')."
        echo
        if [[ ${#MANUAL_TODO[@]} -gt 0 ]]; then
            echo "## Still to do by hand"
            echo
            for i in "${MANUAL_TODO[@]}"; do echo "- [ ] $i"; done
            echo
        fi
        echo "## Useful commands"
        echo
        echo '```'
        echo "sudo ufw status numbered                 # firewall rules"
        echo "sudo fail2ban-client status sshd         # fail2ban bans"
        echo "sudo cscli decisions list                # CrowdSec bans"
        echo "sudo cscli metrics                       # CrowdSec activity"
        echo "sudo ausearch -k sshd -i                 # audit trail (keys: identity sudoers sshd docker_cfg cron firewall)"
        echo "sudo tail -f /var/log/sudo.log           # sudo history"
        echo "sudo journalctl -u endlessh -f           # tarpit"
        echo "sudo ./server-audit.sh --md audit.md     # re-run the audit"
        echo '```'
    } > "$REPORT_FILE"
    chmod 600 "$REPORT_FILE"
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
        local dest; dest="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
        if [[ -d "$dest" ]]; then
            cp "$REPORT_FILE" "$dest/" && chown "$SUDO_USER": "$dest/$(basename "$REPORT_FILE")"
        fi
    fi
}

# ============================================================================
# Main
# ============================================================================
main() {
    preflight
    echo "${C_B}${C_BOLD}server-prep v${PREP_VERSION}${C_0} - ${HOST_SHORT} - ${OS_PRETTY}"
    intro
    questions
    summary_and_confirm
    save_answers

    run_audit before

    run_step update      "System update & base packages"     step_update
    run_step users       "Users & SSH keys (admin, panel)"   step_users
    run_step docker      "Docker CE"                         step_docker
    run_step firewall    "Firewall (UFW + Docker)"           step_firewall
    run_step ssh         "SSH security"                      step_ssh
    run_step ips         "Intrusion prevention"              step_ips
    run_step unattended  "Automatic security updates"        step_unattended
    run_step sysctl      "Kernel & network settings"         step_sysctl
    run_step auth        "Sudo logging & password policy"    step_auth
    run_step services    "Unneeded services"                 step_services
    run_step laptop      "Laptop server mode"                step_laptop
    run_step logging     "Journald & swap"                   step_logging
    run_step auditd      "auditd"                            step_auditd
    run_step rkhunter    "rkhunter"                          step_rkhunter
    run_step aide        "AIDE"                              step_aide
    run_step endlessh    "Endlessh tarpit"                   step_endlessh
    run_step telegraf    "Telegraf (metrics agent)"          step_telegraf
    run_step telegram    "Telegram alerts"                   step_telegram
    run_step cloudflared "Cloudflare Tunnel"                 step_cloudflared
    run_step suid        "SUID review"                       step_suid

    run_audit after
    write_rollback
    write_report

    title "Done"
    local i result
    for i in "${!STEP_NAMES[@]}"; do
        printf '  %-36s %s\n' "${STEP_NAMES[$i]}" "${STEP_RESULTS[$i]}"
    done
    echo
    echo "  Report:  ${REPORT_FILE}"
    [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]] && echo "           (copy in ~${SUDO_USER}/)"
    echo "  Log:     ${LOG_FILE}"
    if [[ ${#MANUAL_TODO[@]} -gt 0 ]]; then
        echo; echo "${C_Y}  To do by hand:${C_0}"
        for i in "${MANUAL_TODO[@]}"; do echo "   - $i"; done
    fi

    for result in "${STEP_RESULTS[@]}"; do
        [[ "$result" == "FAILED" ]] && return 1
    done
    return 0
}

# Run only when executed, so the test can load the functions without starting a run.
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
    exit $?
fi
