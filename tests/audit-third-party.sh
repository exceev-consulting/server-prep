#!/usr/bin/env bash
# Tests the audit's third-party update matcher (third_party_uncovered in server-audit.sh) on sample
# `apt-config dump` output. No root needed and nothing on the host changes.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# server-audit.sh runs its checks on load, so it cannot be sourced: load only the matcher.
eval "$(sed -n '/^third_party_uncovered() {/,/^}/p' "$SCRIPT_DIR/server-audit.sh")"
if ! declare -F third_party_uncovered >/dev/null; then
    printf 'not ok: third_party_uncovered not found in server-audit.sh\n'
    exit 1
fi

fail=0
expect() {   # expect LABEL "WANTED OUTPUT" DUMP PKG...
    local label="$1" want="$2" dump="$3" got
    shift 3
    got=$(printf '%s\n' "$dump" | third_party_uncovered "$@")
    if [[ "$got" != "$want" ]]; then
        printf 'not ok: %s gives "%s", want "%s"\n' "$label" "$got" "$want"
        fail=1
        return
    fi
    printf 'ok: %s\n' "$label"
}

# What server-prep's unattended step writes, as `apt-config dump` prints it.
ALL='Unattended-Upgrade::Origins-Pattern "";
Unattended-Upgrade::Origins-Pattern:: "origin=Debian,codename=${distro_codename},label=Debian-Security";
Unattended-Upgrade::Origins-Pattern:: "origin=Docker,label=Docker CE";
Unattended-Upgrade::Origins-Pattern:: "origin=packagecloud.io/crowdsec/crowdsec,label=crowdsec";
Unattended-Upgrade::Origins-Pattern:: "origin=cloudflared,label=cloudflared";
Unattended-Upgrade::Origins-Pattern:: "origin=InfluxDB,label=InfluxDB";
Unattended-Upgrade::Origins-Pattern:: "origin=Tailscale,label=Tailscale";'
DISTRO_ONLY='Unattended-Upgrade::Origins-Pattern "";
Unattended-Upgrade::Origins-Pattern:: "origin=Debian,codename=${distro_codename},label=Debian-Security";
Unattended-Upgrade::Origins-Pattern:: "origin=Docker,label=Docker CE";'
SHORT='Unattended-Upgrade::Origins-Pattern:: "o=Tailscale";
Unattended-Upgrade::Origins-Pattern:: "o=packagecloud.io/crowdsec/crowdsec,l=crowdsec";'
LOOKALIKE='Unattended-Upgrade::Origins-Pattern:: "origin=Tailscale-Unstable";
Unattended-Upgrade::Origins-Pattern:: "origin=packagecloudXio/crowdsec/crowdsec";
Unattended-Upgrade::Allowed-Origins:: "cloudflared:any";'

expect "every tool covered" "" "$ALL" crowdsec cloudflared telegraf tailscale
expect "distro and Docker only: every tool uncovered" "crowdsec cloudflared telegraf tailscale" "$DISTRO_ONLY" crowdsec cloudflared telegraf tailscale
expect "only installed tools are checked" "telegraf" "$DISTRO_ONLY" telegraf
expect "short o= form counts" "" "$SHORT" tailscale crowdsec
expect "a look-alike origin does not count" "crowdsec tailscale cloudflared" "$LOOKALIKE" crowdsec tailscale cloudflared
expect "no Origins-Pattern at all" "crowdsec" "" crowdsec
expect "unknown names are ignored" "" "$ALL" docker-ce nginx
exit "$fail"
