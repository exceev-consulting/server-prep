#!/usr/bin/env bash
# Tests the audit's third-party repository helpers (repo_status, repo_keys and key_fpr in server-audit.sh, behind
# the upd.repo_keys check of issue #70) on sample `apt-cache policy` output, a fake /etc/apt and a fake gpg.
# No root needed and nothing on the host changes.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# server-audit.sh runs its checks on load, so it cannot be sourced: load only the helpers.
eval "$(sed -n '/^repo_status() {/,/^}/p; /^repo_keys() {/,/^}/p; /^key_fpr() {/,/^}/p' "$SCRIPT_DIR/server-audit.sh")"
for f in repo_status repo_keys key_fpr; do
    declare -F "$f" >/dev/null || { printf 'not ok: %s not found in server-audit.sh\n' "$f"; exit 1; }
done

fail=0
expect() {   # expect LABEL WANTED GOT
    if [[ "$3" != "$2" ]]; then
        printf 'not ok: %s gives "%s", want "%s"\n' "$1" "$3" "$2"
        fail=1
        return
    fi
    printf 'ok: %s\n' "$1"
}

# --- repo_status: where the installed version comes from, and its pin ----------------------------------------
# What apt prints with the ips step's pin (Package: crowdsec*, priority 900): the pin is on the version line only.
PINNED='crowdsec:
  Installed: 1.8.2
  Candidate: 1.8.2
  Version table:
 *** 1.8.2 900
        500 https://packagecloud.io/crowdsec/crowdsec/any any/main amd64 Packages
        100 /var/lib/dpkg/status
     1.8.1 900
        500 https://packagecloud.io/crowdsec/crowdsec/any any/main amd64 Packages
     1.4.6-10.1ubuntu0.1~esm1 510
        510 https://esm.ubuntu.com/apps/ubuntu resolute-apps-security/main amd64 Packages
     1.4.6-10.1 500
        500 http://archive.ubuntu.com/ubuntu resolute/universe amd64 Packages'
UNPINNED='docker-ce:
  Installed: 5:29.9.3-1~ubuntu.26.04~resolute
  Candidate: 5:29.9.3-1~ubuntu.26.04~resolute
  Version table:
 *** 5:29.9.3-1~ubuntu.26.04~resolute 500
        500 https://download.docker.com/linux/ubuntu resolute/stable amd64 Packages
        100 /var/lib/dpkg/status
     5:29.9.2-1~ubuntu.26.04~resolute 500
        500 https://download.docker.com/linux/ubuntu resolute/stable amd64 Packages'
DISTRO='crowdsec:
  Installed: 1.4.6-10.1
  Candidate: 1.8.2
  Version table:
     1.8.2 900
        500 https://packagecloud.io/crowdsec/crowdsec/any any/main amd64 Packages
 *** 1.4.6-10.1 500
        500 http://archive.ubuntu.com/ubuntu resolute/universe amd64 Packages
        100 /var/lib/dpkg/status'
LOCAL_ONLY='crowdsec:
  Installed: 1.6.4
  Candidate: 1.6.4
  Version table:
 *** 1.6.4 100
        100 /var/lib/dpkg/status'
NOT_INSTALLED='crowdsec:
  Installed: (none)
  Candidate: 1.8.2
  Version table:
     1.8.2 900
        500 https://packagecloud.io/crowdsec/crowdsec/any any/main amd64 Packages'

expect "packagecloud crowdsec with the pin" pinned "$(repo_status packagecloud.io/crowdsec/crowdsec/ <<<"$PINNED")"
expect "Docker CE without the pin" unpinned "$(repo_status download.docker.com/linux/ <<<"$UNPINNED")"
expect "a distro crowdsec 1.4.6-10.1 next to the pinned repository" other "$(repo_status packagecloud.io/crowdsec/crowdsec/ <<<"$DISTRO")"
expect "a crowdsec no repository offers" other "$(repo_status packagecloud.io/crowdsec/crowdsec/ <<<"$LOCAL_ONLY")"
expect "a crowdsec that is not installed" "" "$(repo_status packagecloud.io/crowdsec/crowdsec/ <<<"$NOT_INSTALLED")"
expect "another repository's text does not count" other "$(repo_status download.docker.com/linux/ <<<"$PINNED")"

# --- repo_keys: the signed-by keys of a repository's sources -------------------------------------------------
R="$tmp/root"
mkdir -p "$R/etc/apt/sources.list.d"
D="$R/etc/apt/sources.list.d"
printf '%s\n' 'deb http://deb.debian.org/debian trixie main' \
    '# deb https://download.docker.com/linux/debian trixie stable' > "$R/etc/apt/sources.list"
printf '%s\n' 'Types: deb' 'URIs: https://download.docker.com/linux/debian' 'Suites: trixie' 'Components: stable' \
    'Signed-By: /etc/apt/keyrings/docker.asc' > "$D/docker.sources"
printf '%s\n' 'deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian trixie stable' \
    > "$D/docker.list"
printf '%s\n' 'deb https://download.docker.com/linux/debian trixie stable' > "$D/no-key.list"
printf '%s\n' 'Types: deb' 'URIs: https://download.docker.com/linux/debian' 'Suites: trixie' 'Components: stable' \
    'Enabled: no' 'Signed-By: /etc/apt/keyrings/disabled.gpg' > "$D/disabled.sources"
printf '%s\n' 'Types: deb' 'URIs: http://deb.debian.org/debian' 'Suites: trixie' 'Components: main' \
    'Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg' '' \
    'Types: deb' 'URIs: https://download.docker.com/linux/debian' 'Suites: trixie' 'Components: stable' \
    'Signed-By:' ' -----BEGIN PGP PUBLIC KEY BLOCK-----' ' .' ' xsFNBFit2ioBEADhWpZ8' ' -----END PGP PUBLIC KEY BLOCK-----' \
    > "$D/inline.sources"
printf '%s\n' 'deb [signed-by=/etc/apt/keyrings/crowdsec_crowdsec-archive-keyring.gpg] https://packagecloud.io/crowdsec/crowdsec/any/ any main' \
    > "$D/crowdsec_crowdsec.list"

expect "every Docker source's key, commented and disabled ones left out" \
    "- /etc/apt/keyrings/docker.asc /usr/share/keyrings/docker-archive-keyring.gpg inline" \
    "$(repo_keys download.docker.com/linux/ "$R" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
expect "CrowdSec's source" /etc/apt/keyrings/crowdsec_crowdsec-archive-keyring.gpg \
    "$(repo_keys packagecloud.io/crowdsec/crowdsec/ "$R")"
expect "no source for the repository" "" "$(repo_keys pkg.cloudflare.com/cloudflared "$R")"

# --- key_fpr: one public key only ------------------------------------------------------------------------------
# Fake gpg --show-keys: each line of the file is a key, a fingerprint (public) or SEC:<fingerprint> (secret).
gpg() {
    local f="${!#}" line kind sub
    [[ -s "$f" ]] || return 2
    while IFS= read -r line; do
        kind=pub; sub=sub
        if [[ $line == SEC:* ]]; then kind=sec; sub=ssb; line="${line#SEC:}"; fi
        printf '%s:-:4096:1:%s:0:::-:::scESC::::::23::0:\n' "$kind" "${line: -16}"
        printf 'fpr:::::::::%s:\n' "$line"
        printf '%s:-:4096:1:0000000000000000:0::::::e::::::23:\n' "$sub"
        printf 'fpr:::::::::SUB%s:\n' "$line"
    done < "$f"
}
FPR=0123456789ABCDEF0123456789ABCDEF01234567
OTHER=89ABCDEF0123456789ABCDEF0123456789ABCDEF
printf '%s\n' "$FPR" > "$tmp/one.key"
printf '%s\n' "$FPR" "$OTHER" > "$tmp/two.key"
printf '%s\n' "$FPR" "SEC:$OTHER" > "$tmp/secret-bundle.key"
printf '%s\n' "SEC:$FPR" > "$tmp/secret.key"
expect "one public key gives its fingerprint" "$FPR" "$(key_fpr "$tmp" "$tmp/one.key")"
expect "two keys give nothing" "" "$(key_fpr "$tmp" "$tmp/two.key")"
expect "a key bundled with a secret key gives nothing" "" "$(key_fpr "$tmp" "$tmp/secret-bundle.key")"
expect "a secret key gives nothing" "" "$(key_fpr "$tmp" "$tmp/secret.key")"
expect "a missing file gives nothing" "" "$(key_fpr "$tmp" "$tmp/missing.key")"
exit "$fail"
