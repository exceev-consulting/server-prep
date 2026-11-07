#!/usr/bin/env bash
# shellcheck disable=SC2034
# Tests the Openship paths of step_aide and step_auditd (issue #54) with fake commands; no system changes.
# With PANEL=openship, AIDE leaves out Openship's deploy files but still checks its SSH key folders and
# certbot's hooks, and auditd watches each key folder that exists. Other panels get the same files as before.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Stop before any path is built if mktemp fails: an empty $tmp would write the files to /.
if ! tmp="$(mktemp -d)" || [[ -z $tmp || ! -d $tmp ]]; then
    printf 'not ok: mktemp -d failed, no temporary directory for the test\n'
    exit 1
fi
trap 'rm -rf "$tmp"' EXIT

AIDE_CONF=/etc/aide/aide.conf.d/99_server-prep
AIDE_CONF_FAKE="$tmp/aide-conf"
# step_aide reads its own drop-in to know whether the Openship lines are new: read the fake one instead.
grep() {
    if [[ $# -ge 1 && ${!#} == "$AIDE_CONF" ]]; then
        command grep "${@:1:$#-1}" "$AIDE_CONF_FAKE"
        return
    fi
    command grep "$@"
}

# Load the real functions without starting a run (see tests/exit-status.sh).
# shellcheck disable=SC1091
. "$SCRIPT_DIR/server-prep.sh" --yes
LOG_FILE="$tmp/run.log"
LOG_DIR="$tmp"
DRY_RUN=1
INSTALL_AIDE=yes
INSTALL_AUDITD=yes

# Fake host: packages are there, `run` only records the command, files go to $tmp/written-<name>.
# FAKE_KEY_DIRS and BASELINE_RC set what openship_key_dirs and aide_baseline_exists answer.
pkg_install() { return 0; }
run() { CMDS+=("$*"); return 0; }
info() { :; }
nohup() { :; }
aideinit() { :; }
write_file() { cat > "$tmp/written-${1##*/}"; }
openship_key_dirs() { [[ ${#FAKE_KEY_DIRS[@]} -eq 0 ]] || printf '%s\n' "${FAKE_KEY_DIRS[@]}"; }
aide_baseline_exists() { return "$BASELINE_RC"; }
FAKE_KEY_DIRS=()
BASELINE_RC=1

KEY_DIRS=(/etc/openship/ssh-keys /var/lib/openship/ssh-keys /var/lib/openship/host-ssh)
OPENSHIP_EXCLUDES=('!/var/lib/openship/(?!(ssh-keys|host-ssh)(/|$))' '!/etc/openship/modules(/|$)'
    '!/etc/openresty(/|$)' '!/usr/local/openresty/nginx/conf(/|$)'
    '!/etc/letsencrypt/(live|archive|renewal|csr|keys)(/|$)' '/etc/letsencrypt$ d VarDir')
# What AIDE must still check on an Openship server, and what it must leave out.
CHECKED=(/etc/openship/ssh-keys /etc/openship/ssh-keys/id_ed25519
    /var/lib/openship/ssh-keys /var/lib/openship/ssh-keys/host_ed25519
    /var/lib/openship/host-ssh /var/lib/openship/host-ssh/id_ed25519
    /etc/letsencrypt /etc/letsencrypt/renewal-hooks /etc/letsencrypt/renewal-hooks/deploy/reload.sh
    /etc/letsencrypt/cli.ini /etc/letsencrypt/accounts/acme-v02.api.letsencrypt.org/directory/x/private_key.json
    /etc/openship /etc/openresty.conf /usr/local/openresty/bin/openresty)
LEFT_OUT=(/var/lib/openship/app-config/p1/web/etc/nginx.conf /var/lib/openship/edge/sites-enabled/example.com.conf
    /var/lib/openship/edge-takeover.json /var/lib/openship/backups/b1.tar /var/lib/openship/ssh-keys.old
    /etc/openship/modules /etc/openship/modules/m.conf /etc/openresty /etc/openresty/nginx.conf
    /usr/local/openresty/nginx/conf/nginx.conf /etc/letsencrypt/live /etc/letsencrypt/live/example.com/privkey.pem
    /etc/letsencrypt/archive/example.com/privkey1.pem /etc/letsencrypt/renewal/example.com.conf
    /etc/letsencrypt/csr/0000_csr-certbot.pem /etc/letsencrypt/keys/0000_key-certbot.pem)

fail() { printf 'not ok: %s\n' "$*"; exit 1; }
todos() { printf '%s\n' "${MANUAL_TODO[@]}"; }

# run_case STEP PANEL OUT: run one step on a clean slate and keep what it wrote in $tmp/OUT
run_case() {
    local step="$1" panel="$2" out="$3" file rc=0
    case "$step" in
        aide) file="99_server-prep" ;;
        auditd) file="50-server-prep.rules" ;;
    esac
    PANEL="$panel"; MANUAL_TODO=(); STEP_NOTES=""; CMDS=()
    rm -f "$tmp/written-$file"
    "step_$step" > "$tmp/out" 2>&1 || rc=$?
    [[ $rc -eq 0 ]] || fail "step_$step with PANEL='$panel' returned $rc"
    [[ -f "$tmp/written-$file" ]] || fail "step_$step with PANEL='$panel' wrote nothing through write_file"
    cp "$tmp/written-$file" "$tmp/$out"
}

# left_out DROPIN PATH: 0 when an exclude of DROPIN matches PATH, 1 when AIDE checks it. AIDE (0.17
# and later) reads each `!` line as a PCRE regex anchored at the start; perl reads the same syntax.
left_out() {
    local line rc
    while IFS= read -r line; do
        [[ $line == '!'* ]] || continue
        perl -e 'my ($re, $path) = @ARGV; exit(($path =~ /^(?:$re)/) ? 0 : 1)' -- "${line#!}" "$2"
        rc=$?
        [[ $rc -le 1 ]] || fail "AIDE: perl cannot read the exclude '$line'"
        [[ $rc -eq 1 ]] || return 0
    done < "$1"
    return 1
}

# --- the lists stay the same in every place ------------------------------------------------------

[[ "${OPENSHIP_KEY_DIRS[*]}" == "${KEY_DIRS[*]}" ]] ||
    fail "OPENSHIP_KEY_DIRS in server-prep.sh is '${OPENSHIP_KEY_DIRS[*]}', the test expects '${KEY_DIRS[*]}'"
command grep -qxF "for os_dir in ${KEY_DIRS[*]}; do" "$SCRIPT_DIR/server-audit.sh" ||
    fail "server-audit.sh (mon.auditd_panel) does not loop over the same key folders: ${KEY_DIRS[*]}"
printf 'ok: server-prep.sh and server-audit.sh list the same Openship key folders\n'

# --- AIDE ------------------------------------------------------------------------------------------

# (1) Coolify, Dokploy and no panel: the same drop-in as before, with no Openship line.
run_case aide coolify aide-coolify
run_case aide dokploy aide-dokploy
run_case aide "" aide-none
cmp -s "$tmp/aide-coolify" "$tmp/aide-dokploy" || fail "AIDE: Dokploy gets a different drop-in than Coolify"
cmp -s "$tmp/aide-coolify" "$tmp/aide-none" || fail "AIDE: an empty panel gets a different drop-in than Coolify"
command grep -qiE 'openship|openresty|letsencrypt' "$tmp/aide-coolify" && fail "AIDE: Openship lines for PANEL=coolify"
[[ "$(tail -n 1 "$tmp/aide-coolify")" == '!/swapfile' ]] || fail "AIDE: lines added after !/swapfile for PANEL=coolify"
[[ ${#MANUAL_TODO[@]} -eq 0 ]] || fail "AIDE: to-do for PANEL='': $(todos)"
printf 'ok: AIDE drop-in is the same for Coolify, Dokploy and no panel, with no Openship line\n'

# (2) Openship (any case): the same lines, then the Openship excludes.
run_case aide OpenShip aide-openship
n="$(wc -l < "$tmp/aide-coolify")"
head -n "$n" "$tmp/aide-openship" | cmp -s - "$tmp/aide-coolify" ||
    fail "AIDE: the Openship drop-in does not start with the usual lines"
for line in "${OPENSHIP_EXCLUDES[@]}"; do
    command grep -qxF -- "$line" "$tmp/aide-openship" || fail "AIDE: '$line' missing for PANEL=OpenShip"
done
command grep -q '^!/var/lib/openship/' "$tmp/aide-openship" ||
    fail "AIDE: no line server-audit.sh (mon.aide_panel) can find"
printf 'ok: AIDE gets the Openship excludes for PANEL=OpenShip\n'

# (3) What the excludes cover: Openship's SSH key folders and certbot's hooks stay checked, the deploy
# files are left out. Checked on the Coolify drop-in first, so the test itself is known to work.
for path in "${LEFT_OUT[@]}"; do
    left_out "$tmp/aide-coolify" "$path" && fail "AIDE: the Coolify drop-in already leaves out $path"
    left_out "$tmp/aide-openship" "$path" || fail "AIDE: $path is still checked for PANEL=openship"
done
for path in "${CHECKED[@]}"; do
    left_out "$tmp/aide-openship" "$path" && fail "AIDE: $path is left out for PANEL=openship"
done
printf 'ok: AIDE leaves out %d Openship deploy paths and still checks %d key, hook and nearby paths\n' \
    "${#LEFT_OUT[@]}" "${#CHECKED[@]}"

# (3b) The same with AIDE itself, when this machine has it (CI does not): --path-check (AIDE 0.17 and
# later) exits 0 when AIDE checks a path and 1 when a rule leaves it out. VarDir comes from aide-common's
# aide.conf, which includes the drop-in.
if command -v aide >/dev/null 2>&1; then
    AIDE_GROUPS='VarDir = p+u+g+ftype+n+i
'
    { printf '%s/ p+u+g+sha256\n' "$AIDE_GROUPS"; cat "$tmp/aide-openship"; } > "$tmp/aide-real.conf"
    aide --config "$tmp/aide-real.conf" --config-check > "$tmp/aide-real.out" 2>&1 ||
        fail "AIDE: aide --config-check refuses the Openship drop-in: $(head -c 300 "$tmp/aide-real.out")"
    for path in "${CHECKED[@]}" "${LEFT_OUT[@]}"; do
        rc=0
        aide --config "$tmp/aide-real.conf" --path-check "f:$path" > "$tmp/aide-real.out" 2>&1 || rc=$?
        want=0
        [[ " ${LEFT_OUT[*]} " == *" $path "* ]] && want=1
        [[ $rc -eq $want ]] || fail "AIDE: aide --path-check f:$path exits $rc, want $want: $(tail -c 300 "$tmp/aide-real.out")"
    done
    printf 'ok: aide %s accepts the drop-in and selects the same paths\n' "$(aide --version 2>&1 | sed -n '1s/^AIDE //p')"

    # Every certbot run creates and deletes /etc/letsencrypt/.certbot.lock: with aide-common's catch-all
    # rule (`/ 0 Full`, mtime and ctime included), a check would list the folder after each run. On a
    # small tree (root_prefix): no change after that and a renewal, a change for a new deploy hook.
    le="$tmp/root/etc/letsencrypt"
    mkdir -p "$le/renewal-hooks/deploy" "$le/live/example.com"
    echo old > "$le/live/example.com/privkey.pem"
    touch -d '2020-01-01' "$le"   # an older mtime, so the lock file changes it even within the same second
    { printf 'root_prefix=%s\ndatabase_in=file:%s\ndatabase_out=file:%s\ngzip_dbout=no\n' \
        "$tmp/root" "$tmp/aide.db" "$tmp/aide.db.new"
      printf '%s/ p+u+g+ftype+n+i+s+m+c+sha256\n' "$AIDE_GROUPS"; cat "$tmp/aide-openship"; } > "$tmp/aide-root.conf"
    if ! aide --config "$tmp/aide-root.conf" --init > "$tmp/aide-real.out" 2>&1 ||
        ! mv "$tmp/aide.db.new" "$tmp/aide.db"; then
        fail "AIDE: aide --init on a test tree failed: $(tail -c 300 "$tmp/aide-real.out")"
    fi
    : > "$le/.certbot.lock"; rm -f "$le/.certbot.lock"
    echo new > "$le/live/example.com/privkey.pem"
    aide --config "$tmp/aide-root.conf" --check > "$tmp/aide-real.out" 2>&1 ||
        fail "AIDE: a certbot run (lock file, renewed key) shows as a change: $(command grep ': /' "$tmp/aide-real.out" | head -c 300)"
    echo 'systemctl reload openresty' > "$le/renewal-hooks/deploy/reload.sh"
    rc=0
    aide --config "$tmp/aide-root.conf" --check > "$tmp/aide-real.out" 2>&1 || rc=$?
    if [[ $rc -eq 0 ]] || ! command grep -q '/etc/letsencrypt/renewal-hooks/deploy/reload.sh' "$tmp/aide-real.out"; then
        fail "AIDE: a new certbot deploy hook does not show as a change (exit $rc)"
    fi
    printf "ok: aide ignores certbot's lock file and renewed certificates, and still reports a new deploy hook\n"
else
    printf 'ok: aide is not installed here, the check with aide --path-check is skipped\n'
fi

# (4) An existing baseline still lists the newly excluded paths: say how to rebuild it, once.
BASELINE_RC=0
cp "$tmp/aide-coolify" "$AIDE_CONF_FAKE"
run_case aide openship aide-openship-baseline
todos | command grep -q 'aideinit' || fail "AIDE: no to-do to rebuild the baseline on an Openship server that had one"
cmp -s "$tmp/aide-openship-baseline" "$tmp/aide-openship" || fail "AIDE: different drop-in with a baseline"
rm -f "$AIDE_CONF_FAKE"
run_case aide openship aide-openship-baseline
todos | command grep -q 'aideinit' || fail "AIDE: no to-do to rebuild the baseline when the drop-in is missing"
# a drop-in with only some of the excludes (an older list) also needs a rebuild
command grep -vxF -- "${OPENSHIP_EXCLUDES[4]}" "$tmp/aide-openship" > "$AIDE_CONF_FAKE"
run_case aide openship aide-openship-baseline
todos | command grep -q 'aideinit' || fail "AIDE: no to-do to rebuild the baseline when an exclude is new"
cp "$tmp/aide-openship" "$AIDE_CONF_FAKE"
run_case aide openship aide-openship-rerun
[[ ${#MANUAL_TODO[@]} -eq 0 ]] || fail "AIDE: to-do again on a re-run with the Openship lines in place: $(todos)"
cp "$tmp/aide-coolify" "$AIDE_CONF_FAKE"
run_case aide coolify aide-coolify-baseline
[[ ${#MANUAL_TODO[@]} -eq 0 ]] || fail "AIDE: to-do for PANEL=coolify with a baseline: $(todos)"
BASELINE_RC=1
run_case aide openship aide-openship-fresh
[[ ${#MANUAL_TODO[@]} -eq 0 ]] || fail "AIDE: to-do on a server without a baseline yet: $(todos)"
rm -f "$AIDE_CONF_FAKE"
printf 'ok: AIDE asks to rebuild an existing baseline once, only for Openship\n'

# --- auditd ----------------------------------------------------------------------------------------

# (5) Coolify, Dokploy and no panel: the same rules as before, with no panel watch, even with key folders.
FAKE_KEY_DIRS=("${KEY_DIRS[@]}")
run_case auditd coolify auditd-coolify
run_case auditd dokploy auditd-dokploy
run_case auditd "" auditd-none
cmp -s "$tmp/auditd-coolify" "$tmp/auditd-dokploy" || fail "auditd: Dokploy gets different rules than Coolify"
cmp -s "$tmp/auditd-coolify" "$tmp/auditd-none" || fail "auditd: an empty panel gets different rules than Coolify"
command grep -qiE 'openship|-k panel' "$tmp/auditd-coolify" && fail "auditd: Openship watch for PANEL=coolify"
[[ "$(tail -n 1 "$tmp/auditd-coolify")" == '-a always,exit '*'-k admin_root_cmd' ]] ||
    fail "auditd: lines added after the admin_root_cmd rule for PANEL=coolify"
[[ $STEP_NOTES == *"admin root commands (ausearch -k <key>)"* ]] || fail "auditd: note changed for no panel: $STEP_NOTES"
printf 'ok: auditd rules are the same for Coolify, Dokploy and no panel, with no Openship watch\n'

# (6) Openship on the server that runs its API: one watch per key folder, after the other rules.
run_case auditd openship auditd-openship
want="$(printf -- '-w %s -p wa -k panel\n' "${KEY_DIRS[@]}")"
[[ "$(tail -n "${#KEY_DIRS[@]}" "$tmp/auditd-openship")" == "$want" ]] ||
    fail "auditd: the last lines are not the watches on ${KEY_DIRS[*]}: $(tail -n 3 "$tmp/auditd-openship")"
n="$(wc -l < "$tmp/auditd-openship")"
head -n "$((n - ${#KEY_DIRS[@]}))" "$tmp/auditd-openship" | cmp -s - "$tmp/auditd-coolify" ||
    fail "auditd: the Openship rules differ from Coolify's by more than the panel watches"
[[ ${#MANUAL_TODO[@]} -eq 0 ]] || fail "auditd: to-do although the key folders exist: $(todos)"
[[ $STEP_NOTES == *"Openship SSH keys (panel)"* ]] || fail "auditd: the note does not mention the panel key: $STEP_NOTES"
FAKE_KEY_DIRS=(/var/lib/openship/host-ssh)
run_case auditd openship auditd-openship-one
[[ "$(tail -n 1 "$tmp/auditd-openship-one")" == '-w /var/lib/openship/host-ssh -p wa -k panel' ]] ||
    fail "auditd: no watch on the only key folder there, /var/lib/openship/host-ssh"
[[ "$(command grep -c -- '-k panel' "$tmp/auditd-openship-one")" -eq 1 ]] ||
    fail "auditd: a watch on a key folder that does not exist (auditd would refuse it)"
printf 'ok: auditd watches each Openship key folder that exists (key panel), after the other rules\n'

# (7) Openship on a server it manages: no key folder, so no watch auditd would refuse. A note says
# why, and there is no to-do: re-running the step would not clear it.
FAKE_KEY_DIRS=()
run_case auditd OPENSHIP auditd-openship-nokeys
cmp -s "$tmp/auditd-openship-nokeys" "$tmp/auditd-coolify" ||
    fail "auditd: rules changed for Openship although no key folder exists"
[[ ${#MANUAL_TODO[@]} -eq 0 ]] || fail "auditd: to-do on a server without Openship key folders: $(todos)"
[[ $STEP_NOTES == *"no auditd watch for Openship"* && $STEP_NOTES == *"Openship API"* ]] ||
    fail "auditd: no note about the missing key folders: $STEP_NOTES"
printf 'ok: auditd adds no watch and no to-do where no Openship key folder exists, and says why\n'

# (8) Idempotent: a second run writes the same content.
FAKE_KEY_DIRS=("${KEY_DIRS[@]}")
for c in "aide coolify" "aide openship" "auditd coolify" "auditd openship"; do
    read -r step panel <<<"$c"
    run_case "$step" "$panel" "first"
    run_case "$step" "$panel" "second"
    cmp -s "$tmp/first" "$tmp/second" || fail "$step with PANEL=$panel: a second run writes different content"
done
printf 'ok: step_aide and step_auditd write the same content on a second run\n'
