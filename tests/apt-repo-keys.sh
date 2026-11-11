#!/usr/bin/env bash
# shellcheck disable=SC2034
# Tests the third-party apt key check of issue #70: apt_repo_key with a fake curl and a fake gpg, the removal of a
# second source for the same repository (drop_other_sources), the origin test of an installed package (pkg_from),
# then the docker, ips (CrowdSec), telegraf and cloudflared steps with apt_repo_key and every command that would
# reach the host replaced. No root, no network, and the host is not changed.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Load the real functions without starting a run (see tests/exit-status.sh).
# shellcheck disable=SC1091
. "$SCRIPT_DIR/server-prep.sh" --yes
LOG_FILE="$tmp/run.log"
BACKUP_DIR="$tmp/backups"
DRY_RUN=0
ONLY=""; SKIP=""
# the apt sources drop_other_sources reads: never the host's
mkdir -p "$tmp/apt/sources.list.d"
APT_SOURCES="$tmp/apt/sources.list"
APT_SOURCES_D="$tmp/apt/sources.list.d"

fail() { printf 'not ok: %s\n' "$*"; [[ -f "$tmp/out" ]] && cat "$tmp/out" >&2; exit 1; }
pass() { printf 'ok: %s\n' "$*"; }

# Made-up fingerprints (40 hex digits). A fake key file holds one key per line: a fingerprint is a public key,
# SEC:<fingerprint> a secret key. Lines starting with # or ----- are content gpg does not list as a key.
FPR=0123456789ABCDEF0123456789ABCDEF01234567
OTHER=89ABCDEF0123456789ABCDEF0123456789ABCDEF
printf '%s\n' "$FPR" > "$tmp/good.key"
printf '%s\n' "$OTHER" > "$tmp/wrong.key"
printf '%s\n' "$FPR" "$OTHER" > "$tmp/bundle.key"
printf '%s\n' "$FPR" "SEC:$OTHER" > "$tmp/secret-bundle.key"
printf '%s\n' "SEC:$FPR" > "$tmp/secret.key"
printf '%s\n' "$FPR" '#something gpg does not list' > "$tmp/extra.key"

# Fake curl: records its arguments, fails with CURL_RC, or writes KEY_FIXTURE to the -o path.
CURLS=()
CURL_RC=0
KEY_FIXTURE="$tmp/good.key"
curl() {
    local a prev="" out=""
    CURLS+=("$*")
    [[ $CURL_RC -eq 0 ]] || return "$CURL_RC"
    for a in "$@"; do
        [[ $prev == -o ]] && out="$a"
        prev="$a"
    done
    [[ -z "$out" ]] || cat "$KEY_FIXTURE" > "$out"
}

# Fake gpg. --import FILE appends FILE's lines to GNUPGHOME/pubring; --export FPR prints the pubring lines equal to
# FPR (inside armor lines with --armor); --show-keys FILE prints each key of FILE the way gpg's colon output does:
# a pub (or sec) line, its fpr, a subkey (sub or ssb) and the subkey's fpr. Each GNUPGHOME it gets is recorded, to
# check that it is a throwaway folder that is removed afterwards.
gpg() {
    local -a args=("$@")
    local i import="" export="" armored=0 show=0 f line kind sub
    printf '%s\n' "${GNUPGHOME:-}" >> "$tmp/gnupghomes"
    for ((i = 0; i < ${#args[@]}; i++)); do
        case "${args[i]}" in
            --import) import="${args[i + 1]}" ;;
            --export) export="${args[i + 1]}" ;;
            --armor) armored=1 ;;
            --show-keys) show=1 ;;
        esac
    done
    if [[ -n "$import" ]]; then
        cat "$import" >> "$GNUPGHOME/pubring"; return 0
    fi
    if [[ -n "$export" ]]; then
        [[ $armored -eq 1 ]] && printf '%s\n' '-----BEGIN PGP PUBLIC KEY BLOCK-----'
        grep -sxF "$export" "$GNUPGHOME/pubring"
        [[ $armored -eq 1 ]] && printf '%s\n' '-----END PGP PUBLIC KEY BLOCK-----'
        return 0
    fi
    [[ $show -eq 1 ]] || return 2
    f="${!#}"
    [[ -s "$f" ]] || return 2
    while IFS= read -r line; do
        [[ $line == '#'* || $line == -----* ]] && continue
        kind=pub; sub=sub
        if [[ $line == SEC:* ]]; then kind=sec; sub=ssb; line="${line#SEC:}"; fi
        printf '%s:-:4096:1:%s:0:::-:::scESC::::::23::0:\n' "$kind" "${line: -16}"
        printf 'fpr:::::::::%s:\n' "$line"
        printf '%s:-:4096:1:0000000000000000:0::::::e::::::23:\n' "$sub"
        printf 'fpr:::::::::SUB%s:\n' "$line"
    done < "$f"
    return 0
}

# --- apt_repo_key -----------------------------------------------------------------------------------------
KEYRING="$tmp/keyrings/test.gpg"
expect_key() {   # expect_key LABEL WANT_STATUS WANT_CHANGED WANT_DOWNLOADS [WANT_NOTE]
    local label="$1" want="$2" want_changed="$3" want_curls="$4" want_note="${5:-}" status=0
    STEP_CHANGED=0; STEP_NOTES=""; CURLS=()
    apt_repo_key Test https://example.com/key.gpg "$FPR" "$KEYRING" > "$tmp/out" 2>&1 || status=$?
    [[ $status -eq $want ]] || fail "key $label: status $status, want $want (notes: $STEP_NOTES)"
    [[ $STEP_CHANGED -eq $want_changed ]] || fail "key $label: changed=$STEP_CHANGED, want $want_changed"
    [[ ${#CURLS[@]} -eq $want_curls ]] || fail "key $label: ${#CURLS[@]} download(s), want $want_curls"
    [[ -z "$want_note" || "$STEP_NOTES" == *"$want_note"* ]] || fail "key $label: notes '$STEP_NOTES', want '$want_note'"
    pass "key $label"
}

KEY_FIXTURE="$tmp/good.key"
expect_key 'with the published fingerprint is installed' 0 1 1
[[ "${CURLS[0]}" == *"https://example.com/key.gpg"* ]] || fail "key: curl did not get the key URL: ${CURLS[0]}"
cmp -s "$tmp/good.key" "$KEYRING" || fail "key: the keyring does not hold the checked key"
[[ "$(stat -c %a "$KEYRING")" == 644 ]] || fail "key: the keyring mode is $(stat -c %a "$KEYRING"), want 644"
[[ " ${NEW_FILES[*]} " == *" $KEYRING "* ]] || fail "key: the new keyring is not listed in the report's files"
pass 'key: keyring written with mode 644 and listed as created'

expect_key 'already in place is kept and not downloaded again' 0 0 0

rm -f "$KEYRING"
KEY_FIXTURE="$tmp/wrong.key"
expect_key 'with another fingerprint is refused' 1 0 1 'Test key fingerprint mismatch - not installing'
[[ ! -e "$KEYRING" ]] || fail "key: a key with another fingerprint was written"

KEY_FIXTURE="$tmp/bundle.key"
expect_key 'bundled with a second key is refused' 1 0 1 'Test key fingerprint mismatch - not installing'
[[ ! -e "$KEYRING" ]] || fail "key: a bundle of two keys was written"

KEY_FIXTURE="$tmp/secret-bundle.key"
expect_key 'bundled with a secret key is refused' 1 0 1 'Test key fingerprint mismatch - not installing'
[[ ! -e "$KEYRING" ]] || fail "key: a bundle with a secret key was written"

KEY_FIXTURE="$tmp/secret.key"
expect_key 'sent as a secret key is refused' 1 0 1 'Test key fingerprint mismatch - not installing'
[[ ! -e "$KEYRING" ]] || fail "key: a secret key was written"

KEY_FIXTURE="$tmp/extra.key"
expect_key 'with content gpg does not list is installed without it' 0 1 1
cmp -s "$tmp/good.key" "$KEYRING" || fail "key: the keyring holds more than the exported key: $(cat "$KEYRING")"
pass 'key: only the checked key is exported to the keyring'
rm -f "$KEYRING"

KEY_FIXTURE="$tmp/good.key"
CURL_RC=22
expect_key 'that cannot be downloaded fails' 1 0 1 'cannot download the Test key'
[[ ! -e "$KEYRING" ]] || fail "key: a keyring was written although the download failed"
CURL_RC=0

DRY_RUN=1
expect_key 'in a dry run is not downloaded or written' 0 1 0
[[ ! -e "$KEYRING" ]] || fail "key: a dry run wrote the keyring"
DRY_RUN=0

cp "$tmp/wrong.key" "$KEYRING"
CHANGED_FILES=()
expect_key 'replaces a keyring that holds another key' 0 1 1
cmp -s "$tmp/good.key" "$KEYRING" || fail "key: the keyring with another key was not replaced"
cmp -s "$tmp/wrong.key" "$BACKUP_DIR$KEYRING" || fail "key: the replaced keyring was not backed up"
[[ " ${CHANGED_FILES[*]} " == *" $KEYRING "* ]] || fail "key: the replaced keyring is not listed in the report's files"
pass 'key: the replaced keyring is backed up and listed as modified'

KEYRING="$tmp/keyrings/test.asc"
expect_key 'for an .asc keyring is written armored' 0 1 1
[[ "$(head -1 "$KEYRING")" == '-----BEGIN PGP PUBLIC KEY BLOCK-----' ]] && grep -qxF "$FPR" "$KEYRING" ||
    fail "key: the .asc keyring is not armored: $(cat "$KEYRING")"
expect_key 'armored in place is kept and not downloaded again' 0 0 0

: > "$tmp/not-a-folder"
KEYRING="$tmp/not-a-folder/test.gpg"
expect_key 'that cannot be written fails' 1 0 1 "cannot write $KEYRING"
KEYRING="$tmp/keyrings/test.gpg"

while IFS= read -r home; do
    [[ -n "$home" && "$home" != "$HOME/.gnupg" && "$home" != /root/.gnupg ]] || fail "gpg ran with GNUPGHOME '$home'"
    [[ ! -e "$home" ]] || fail "the throwaway GNUPGHOME $home was not removed"
done < "$tmp/gnupghomes"
pass 'gpg always ran in a throwaway GNUPGHOME, removed afterwards'

# --- drop_other_sources ------------------------------------------------------------------------------------
D="$APT_SOURCES_D"
DOCKER=download.docker.com/linux/debian
expect_drop() {   # expect_drop LABEL WANT_STATUS [WANT_NOTE]
    local label="$1" want="$2" want_note="${3:-}" status=0
    STEP_CHANGED=0; STEP_NOTES=""
    drop_other_sources "$DOCKER" docker.sources > "$tmp/out" 2>&1 || status=$?
    [[ $status -eq $want ]] || fail "sources $label: status $status, want $want (notes: $STEP_NOTES)"
    [[ -z "$want_note" || "$STEP_NOTES" == *"$want_note"* ]] || fail "sources $label: notes '$STEP_NOTES', want '$want_note'"
    pass "sources $label"
}
printf '%s\n' 'deb http://deb.debian.org/debian trixie main' "# deb https://$DOCKER trixie stable" > "$APT_SOURCES"
printf 'Types: deb\nURIs: https://%s\nSuites: trixie\nComponents: stable\nSigned-By: /etc/apt/keyrings/docker.asc\n' "$DOCKER" > "$D/docker.sources"
# what an older Docker guide left: the same repository with another key, which apt refuses next to docker.sources
printf 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://%s trixie stable\n' "$DOCKER" > "$D/docker.list"
printf 'Types: deb\nURIs: https://%s\nSuites: trixie\nComponents: stable\nSigned-By: /usr/share/keyrings/docker.gpg\n' "$DOCKER" > "$D/docker-ce.sources"
printf '%s\n' 'deb [signed-by=/etc/apt/keyrings/crowdsec_crowdsec-archive-keyring.gpg] https://packagecloud.io/crowdsec/crowdsec/any/ any main' > "$D/crowdsec_crowdsec.list"
printf '%s\n' 'deb https://example.com/repo stable main' "# deb https://$DOCKER trixie stable" > "$D/example.list"
cp "$D/docker.list" "$tmp/docker.list.orig"

CHANGED_FILES=(); NEW_FILES=()
DRY_RUN=1
expect_drop 'in a dry run removes nothing' 0 "would remove $D/docker.list, another source for $DOCKER"
[[ "$STEP_NOTES" != *"removed "* ]] || fail "sources: a dry run says a file was removed: $STEP_NOTES"
[[ -e "$D/docker.list" && -e "$D/docker-ce.sources" ]] || fail "sources: a dry run removed a file"
[[ ${#CHANGED_FILES[@]} -eq 0 ]] || fail "sources: a dry run listed files for rollback.sh: ${CHANGED_FILES[*]}"
DRY_RUN=0

expect_drop 'another source for the repository is removed' 0 "removed $D/docker.list, another source for $DOCKER (backed up)"
[[ ! -e "$D/docker.list" && ! -e "$D/docker-ce.sources" ]] || fail "sources: the other Docker sources are still there"
[[ $STEP_CHANGED -eq 1 ]] || fail "sources: removing a source does not make the step CHANGED"
cmp -s "$tmp/docker.list.orig" "$BACKUP_DIR$D/docker.list" || fail "sources: the removed docker.list was not backed up"
# rollback.sh copies back every CHANGED_FILES entry from its backup, and the report lists them
[[ " ${CHANGED_FILES[*]} " == *" $D/docker.list "* && " ${CHANGED_FILES[*]} " == *" $D/docker-ce.sources "* ]] ||
    fail "sources: the removed sources are not listed for rollback.sh: '${CHANGED_FILES[*]}'"
[[ ${#NEW_FILES[@]} -eq 0 ]] || fail "sources: a removed source is listed as created: ${NEW_FILES[*]}"
[[ -e "$D/docker.sources" ]] || fail "sources: the step's own docker.sources was removed"
[[ -e "$D/crowdsec_crowdsec.list" && -e "$D/example.list" ]] || fail "sources: another repository's file was removed"
pass 'sources: only the other Docker sources are removed, backed up'

expect_drop 'nothing to remove leaves the step unchanged' 0
[[ $STEP_CHANGED -eq 0 ]] || fail "sources: nothing to remove made the step CHANGED"

printf '%s\n' "deb https://$DOCKER trixie stable" 'deb https://example.com/repo stable main' > "$D/mixed.list"
expect_drop 'a file that also lists another repository stops the step' 1 "$D/mixed.list also lists other repositories"
[[ -e "$D/mixed.list" ]] || fail "sources: a file with another repository was removed"
rm -f "$D/mixed.list"

printf '%s\n' "deb [signed-by=/etc/apt/keyrings/docker.gpg] https://$DOCKER trixie stable" >> "$APT_SOURCES"
expect_drop 'the repository in sources.list stops the step' 1 "$APT_SOURCES lists $DOCKER"
rm -f "$APT_SOURCES" "$D"/*

# --- the steps ---------------------------------------------------------------------------------------------
# apt_repo_key is tested above: here it only records its arguments and returns KEY_RC. `run` records the
# command; an "apt-get ... update" returns UPDATE_RC. Every other command that would reach the host is a stub.
# INSTALLED is the "package version" list of installed packages; MADISON is what `apt-cache madison` prints.
KEY_RC=0; UPDATE_RC=0; MADISON=""; INSTALLED=()
KEYS=(); RAN=(); SECRETS=()
apt_repo_key() { KEYS+=("$*"); return "$KEY_RC"; }
run() {
    RAN+=("$*")
    [[ "$*" == "apt-get "*" update"* ]] && return "$UPDATE_RC"
    return 0
}
write_file() { cat > "$tmp/written-${1##*/}"; }
pkg_install() { :; }
installed_version() { local p; for p in "${INSTALLED[@]}"; do [[ ${p%% *} == "$1" ]] && { printf '%s' "${p#* }"; return 0; }; done; return 1; }
pkg_installed() { installed_version "$1" > /dev/null; }
dpkg-query() { installed_version "${!#}"; }
run_secret() { SECRETS+=("${*:2}"); }
systemctl() { [[ ${1:-} == is-active ]] && return 3; return 0; }
apt-cache() { printf '%s\n' "$MADISON"; }
dpkg() { :; }
cscli() { :; }
docker() { :; }
have() { return 1; }
HOST_SHORT=web-01; SSH_PORT=822; PANEL_LABEL=Coolify; ADMIN_IPS=192.168.1.50; PANEL_IP=''; PANEL_ACCESS=tailscale
OS_ID=debian; OS_CODENAME=trixie; HAS_DOCKER=0; CROWDSEC_ENROLL_KEY=''

# pkg_from: the installed version must be offered by the repository, whatever its version string says
DISTRO_CS=' crowdsec | 1.4.6-10.1 | http://archive.ubuntu.com/ubuntu resolute/universe amd64 Packages'
PC_CS='  crowdsec |      1.8.2 | https://packagecloud.io/crowdsec/crowdsec/any any/main amd64 Packages'
MADISON="$PC_CS"$'\n'"$DISTRO_CS"
INSTALLED=("crowdsec 1.4.6-10.1")
pkg_from crowdsec packagecloud.io/crowdsec/crowdsec/ && fail "pkg_from: the distro crowdsec 1.4.6-10.1 counts as packagecloud's"
INSTALLED=("crowdsec 1.8.2")
pkg_from crowdsec packagecloud.io/crowdsec/crowdsec/ || fail "pkg_from: packagecloud's crowdsec 1.8.2 does not count"
INSTALLED=("crowdsec 1.8")
pkg_from crowdsec packagecloud.io/crowdsec/crowdsec/ && fail "pkg_from: a version packagecloud does not offer counts"
INSTALLED=()
pkg_from crowdsec packagecloud.io/crowdsec/crowdsec/ && fail "pkg_from: a crowdsec that is not installed counts"
pass 'pkg_from: decides by where the installed version comes from, not by its version string'
MADISON=""

ran() { local c; for c in "${RAN[@]}"; do [[ "$c" == *"$1"* ]] && return 0; done; return 1; }
ran_exact() { local c; for c in "${RAN[@]}"; do [[ "$c" == "$1" ]] && return 0; done; return 1; }
expect_step() {   # expect_step LABEL FUNCTION WANT_STATUS [WANT_NOTE]
    local label="$1" fn="$2" want="$3" want_note="${4:-}" status=0
    STEP_CHANGED=0; STEP_NOTES=""; MANUAL_TODO=(); KEYS=(); RAN=(); SECRETS=()
    rm -f "$tmp"/written-*
    "$fn" > "$tmp/out" 2>&1 || status=$?
    [[ $status -eq $want ]] || fail "$label: status $status, want $want (notes: $STEP_NOTES)"
    [[ -z "$want_note" || "$STEP_NOTES" == *"$want_note"* ]] || fail "$label: notes '$STEP_NOTES', want '$want_note'"
    pass "$label"
}
CURLS=()

# Docker
INSTALL_DOCKER=yes
KEY_RC=1; DRY_RUN=0
expect_step 'docker: a key that fails the check stops the step' step_docker 1
[[ ! -e "$tmp/written-docker.sources" ]] || fail "docker: docker.sources written although the key check failed"
ran 'apt-get install' && fail "docker: apt-get install ran although the key check failed"
pass 'docker: no source and no install when the key check fails'

KEY_RC=0; DRY_RUN=1
expect_step 'docker: dry run with the checked key' step_docker 0
[[ "${KEYS[0]:-}" == "Docker https://download.docker.com/linux/debian/gpg 9DC858229FC7DD38854AE2D88D81803C0EBFCD88 /etc/apt/keyrings/docker.asc" ]] ||
    fail "docker: apt_repo_key got '${KEYS[0]:-}'"
grep -qxF 'Signed-By: /etc/apt/keyrings/docker.asc' "$tmp/written-docker.sources" ||
    fail "docker: docker.sources does not use /etc/apt/keyrings/docker.asc, the key name of Docker's guide"
grep -qxF 'URIs: https://download.docker.com/linux/debian' "$tmp/written-docker.sources" ||
    fail "docker: docker.sources changed its repository URL"
grep -qxF 'Pin: origin download.docker.com' "$tmp/written-docker" && grep -qxF 'Pin-Priority: 900' "$tmp/written-docker" ||
    fail "docker: no 900 pin for download.docker.com"
ran 'apt-get install' || fail "docker: a dry run does not show the Docker install"
pass 'docker: signed-by source on the checked key, pinned at 900'

# Docker already installed: from download.docker.com for this release, its key is checked and it is pinned;
# another Docker is left alone
have() { [[ $1 == docker ]]; }
INSTALLED=("docker-ce 5:29.0.0-1~debian.13~trixie")
MADISON=' docker-ce | 5:29.0.0-1~debian.13~trixie | https://download.docker.com/linux/debian trixie/stable amd64 Packages'
expect_step 'docker: an installed Docker CE from download.docker.com gets the checked key and the pin' step_docker 0
[[ ${#KEYS[@]} -eq 1 && -e "$tmp/written-docker" && -e "$tmp/written-docker.sources" ]] ||
    fail "docker: the installed Docker CE's repository was not checked"
ran 'apt-get install' && fail "docker: Docker was installed again"
KEY_RC=1
expect_step 'docker: an installed Docker CE whose key fails the check FAILS the step' step_docker 1
# The source of Docker's 2023 guide (docker.list on docker.gpg) is the only one that still works: a failed key
# download or check must keep it, or apt drops Docker's lists and later runs no longer see Docker CE as Docker's.
printf 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian trixie stable\n' \
    > "$APT_SOURCES_D/docker.list"
expect_step 'docker: a failed key check keeps the other Docker source' step_docker 1
ran "rm -f $APT_SOURCES_D/docker.list" && fail "docker: docker.list removed although the key check failed"
KEY_RC=0
expect_step 'docker: the other Docker source is removed once the key has passed' step_docker 0
ran "rm -f $APT_SOURCES_D/docker.list" || fail "docker: docker.list not removed after the key check passed"
[[ ${#KEYS[@]} -eq 1 ]] || fail "docker: the key was not checked before docker.list was removed"
rm -f "$APT_SOURCES_D/docker.list"
pass 'docker: another source is removed only after the key check passed'
INSTALLED=("docker.io 26.1.5+dfsg1-9")
MADISON=' docker.io | 26.1.5+dfsg1-9 | http://deb.debian.org/debian trixie/main amd64 Packages'
expect_step 'docker: a docker.io from the distro is left alone' step_docker 0 'Docker already installed'
[[ ${#KEYS[@]} -eq 0 && ! -e "$tmp/written-docker.sources" ]] || fail "docker: the distro docker.io got Docker's repository"
have() { return 1; }
INSTALLED=(); MADISON=""
HAS_DOCKER=0
DRY_RUN=0

# CrowdSec (ips step)
INSTALL_FAIL2BAN=no; INSTALL_CROWDSEC=yes
cs_install="apt-get install ${APT_OPTS[*]} crowdsec"
cs_list='deb [signed-by=/etc/apt/keyrings/crowdsec_crowdsec-archive-keyring.gpg] https://packagecloud.io/crowdsec/crowdsec/any/ any main'

KEY_RC=1
expect_step 'ips: a CrowdSec key that fails the check FAILS the step' step_ips 1 'CrowdSec not installed'
ran_exact "$cs_install" && fail "ips: crowdsec installed although its key check failed"
[[ ! -e "$tmp/written-crowdsec_crowdsec.list" ]] || fail "ips: CrowdSec source written although its key check failed"
grep -qxF 'Pin: origin packagecloud.io' "$tmp/written-crowdsec" || fail "ips: the packagecloud.io pin is gone"
pass 'ips: no source and no install when the key check fails'

KEY_RC=0; UPDATE_RC=100
expect_step 'ips: a failed apt-get update FAILS the step' step_ips 1 'apt-get update failed'
ran_exact "$cs_install" && fail "ips: crowdsec installed although apt-get update failed"
UPDATE_RC=0

MADISON=' crowdsec |   1.4.6-10 | http://deb.debian.org/debian trixie/main amd64 Packages'
expect_step 'ips: no crowdsec from packagecloud FAILS instead of installing the distro one' step_ips 1 'not installing the distro one'
ran_exact "$cs_install" && fail "ips: the distro crowdsec was installed"
[[ "$(cat "$tmp/written-crowdsec_crowdsec.list")" == "$cs_list" ]] ||
    fail "ips: crowdsec_crowdsec.list is '$(cat "$tmp/written-crowdsec_crowdsec.list")'"
[[ "${KEYS[0]:-}" == "CrowdSec https://packagecloud.io/crowdsec/crowdsec/gpgkey 6A89E3C2303A901A889971D3376ED5326E93CD0C /etc/apt/keyrings/crowdsec_crowdsec-archive-keyring.gpg" ]] ||
    fail "ips: apt_repo_key got '${KEYS[0]:-}'"
pass 'ips: the CrowdSec source is the one install.crowdsec.net writes, on the checked key'

MADISON="$PC_CS"
step_ips > "$tmp/out" 2>&1   # the rest of the step needs a real crowdsec: only the install matters here
ran_exact "$cs_install" || fail "ips: crowdsec not installed although packagecloud.io offers it"
pass 'ips: crowdsec is installed when packagecloud.io offers it'

DRY_RUN=1; MADISON=""
expect_step 'ips: dry run sets up the CrowdSec repository' step_ips 0
ran_exact "$cs_install" || fail "ips: a dry run does not show the crowdsec install"
DRY_RUN=0

for c in "${CURLS[@]}"; do
    [[ "$c" != *install.crowdsec.net* ]] || fail "ips: the remote install script was downloaded: curl $c"
done
pass 'ips: the remote install script (install.crowdsec.net) is never downloaded'

# An old crowdsec from Ubuntu Pro (ESM) is replaced only through the checked repository.
INSTALLED=("crowdsec 1.4.6-10ubuntu0.1+esm1")
KEY_RC=1
expect_step 'ips: an ESM crowdsec with a key that fails the check FAILS without an install' step_ips 1 'crowdsec 1.4.6-10ubuntu0.1+esm1 left as it is'
ran_exact "$cs_install" && fail "ips: the ESM crowdsec was upgraded although the key check failed"
KEY_RC=0

# A distro crowdsec whose version has no ubuntu, deb or esm in it (Ubuntu 26.04 universe, Debian 13) is replaced too.
INSTALLED=("crowdsec 1.4.6-10.1")
MADISON="$PC_CS"$'\n'"$DISTRO_CS"
DRY_RUN=1
expect_step 'ips: a distro crowdsec 1.4.6-10.1 is replaced with the official one' step_ips 0
ran_exact "$cs_install" || fail "ips: the distro crowdsec 1.4.6-10.1 was kept"
grep -qF 'replacing crowdsec 1.4.6-10.1 (not from packagecloud.io)' "$tmp/out" || fail "ips: no message about replacing the distro crowdsec"
DRY_RUN=0

# A crowdsec from packagecloud (and its bouncer) gets its key checked again, and no install.
INSTALLED=("crowdsec 1.8.2" "crowdsec-firewall-bouncer-iptables 0.0.31")
MADISON="$PC_CS"
DRY_RUN=1
expect_step 'ips: a crowdsec from packagecloud keeps its version' step_ips 0
[[ "${KEYS[0]:-}" == CrowdSec* ]] || fail "ips: the key of an installed crowdsec was not checked"
ran 'update' && fail "ips: apt-get update ran for a crowdsec from packagecloud"
ran_exact "$cs_install" && fail "ips: crowdsec installed again"
[[ $STEP_CHANGED -eq 0 ]] || fail "ips: a crowdsec from packagecloud makes the step CHANGED"
pass 'ips: a re-run with crowdsec from packagecloud is OK (already)'
KEY_RC=1
expect_step 'ips: a crowdsec from packagecloud whose key fails the check FAILS the step' step_ips 1 'crowdsec 1.8.2 left as it is'
printf 'deb [signed-by=/usr/share/keyrings/crowdsec.gpg] https://packagecloud.io/crowdsec/crowdsec/any/ any main\n' \
    > "$APT_SOURCES_D/crowdsec.list"
expect_step 'ips: a failed key check keeps the other CrowdSec source' step_ips 1 'crowdsec 1.8.2 left as it is'
ran "rm -f $APT_SOURCES_D/crowdsec.list" && fail "ips: crowdsec.list removed although the key check failed"
KEY_RC=0
expect_step 'ips: the other CrowdSec source is removed once the key has passed' step_ips 0
ran "rm -f $APT_SOURCES_D/crowdsec.list" || fail "ips: crowdsec.list not removed after the key check passed"
rm -f "$APT_SOURCES_D/crowdsec.list"
pass 'ips: another source is removed only after the key check passed'
DRY_RUN=0
INSTALLED=(); MADISON=""

# Telegraf: the same key check as the other repositories, on every run
INSTALL_TELEGRAF=yes
KEY_RC=1
expect_step 'telegraf: a key that fails the check stops the step' step_telegraf 1
[[ ! -e "$tmp/written-influxdata.list" ]] || fail "telegraf: source written although the key check failed"
KEY_RC=0; DRY_RUN=1
expect_step 'telegraf: dry run with the checked key' step_telegraf 0
[[ "${KEYS[0]:-}" == "InfluxData https://repos.influxdata.com/influxdata-archive.key 24C975CBA61A024EE1B631787C3D57159FC2F927 /etc/apt/keyrings/influxdata-archive.gpg" ]] ||
    fail "telegraf: apt_repo_key got '${KEYS[0]:-}'"
DRY_RUN=0

# cloudflared
PANEL_ACCESS=cloudflared; CLOUDFLARED_TOKEN=test-token
KEY_RC=1
expect_step 'cloudflared: a key that fails the check stops the step' step_cloudflared 1 'cloudflared not installed'
[[ ${#SECRETS[@]} -eq 0 ]] || fail "cloudflared: the service was installed although the key check failed"
[[ ! -e "$tmp/written-cloudflared.list" ]] || fail "cloudflared: source written although the key check failed"
pass 'cloudflared: no source and no service when the key check fails'

KEY_RC=0; DRY_RUN=1
expect_step 'cloudflared: dry run with the checked key' step_cloudflared 0
[[ "${KEYS[0]:-}" == "Cloudflare https://pkg.cloudflare.com/cloudflare-public-v2.gpg CC94B39C77AE7342A68B89628A682D308D4E5E73 /etc/apt/keyrings/cloudflare-public-v2.gpg" ]] ||
    fail "cloudflared: apt_repo_key got '${KEYS[0]:-}'"
[[ "$(cat "$tmp/written-cloudflared.list")" == 'deb [signed-by=/etc/apt/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' ]] ||
    fail "cloudflared: cloudflared.list is '$(cat "$tmp/written-cloudflared.list")'"
grep -qxF 'Package: cloudflared' "$tmp/written-cloudflared" && grep -qxF 'Pin: origin pkg.cloudflare.com' "$tmp/written-cloudflared" &&
    grep -qxF 'Pin-Priority: 900' "$tmp/written-cloudflared" || fail "cloudflared: no 900 pin for pkg.cloudflare.com"
[[ ${#SECRETS[@]} -eq 1 ]] || fail "cloudflared: the service install was not run through run_secret"
pass 'cloudflared: signed-by source in /etc/apt/keyrings, pinned at 900'

# cloudflared installed by an earlier run (key in /usr/share/keyrings, no pin): checked and pinned on a re-run
have() { [[ $1 == cloudflared ]]; }
INSTALLED=("cloudflared 2026.1.0")
MADISON=' cloudflared |   2026.1.0 | https://pkg.cloudflare.com/cloudflared any/main amd64 Packages'
expect_step 'cloudflared: an installed cloudflared from pkg.cloudflare.com gets the checked key and the pin' step_cloudflared 0
[[ ${#KEYS[@]} -eq 1 && -e "$tmp/written-cloudflared" ]] || fail "cloudflared: the installed cloudflared's repository was not checked"
KEY_RC=1
expect_step 'cloudflared: an installed cloudflared whose key fails the check FAILS the step' step_cloudflared 1 'cloudflared left as it is'
printf 'Types: deb\nURIs: https://pkg.cloudflare.com/cloudflared\nSuites: any\nComponents: main\nSigned-By: /usr/share/keyrings/cloudflare-main.gpg\n' \
    > "$APT_SOURCES_D/cloudflared.sources"
expect_step 'cloudflared: a failed key check keeps the other cloudflared source' step_cloudflared 1 'cloudflared left as it is'
ran "rm -f $APT_SOURCES_D/cloudflared.sources" && fail "cloudflared: cloudflared.sources removed although the key check failed"
KEY_RC=0
expect_step 'cloudflared: the other cloudflared source is removed once the key has passed' step_cloudflared 0
ran "rm -f $APT_SOURCES_D/cloudflared.sources" || fail "cloudflared: cloudflared.sources not removed after the key check passed"
rm -f "$APT_SOURCES_D/cloudflared.sources"
pass 'cloudflared: another source is removed only after the key check passed'
have() { return 1; }
INSTALLED=(); MADISON=""
DRY_RUN=0
