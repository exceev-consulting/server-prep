#!/usr/bin/env bash
# shellcheck disable=SC2034   # ASSUME_YES, ADMIN, NET_MANAGER... are read by the eval'd functions
# Tests server-preconfig.sh's hostname step (issue #81) on fixture files: the default hostname is the
# current short name in lowercase, the 127.0.1.1 line of /etc/hosts keeps its domain and nothing else
# in the file moves, and when cloud-init runs at boot a drop-in stops the next boot from undoing both.
# `hostname` and `hostnamectl` are shell functions and every path is under a temp folder: no root
# needed and nothing on the host changes.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRE="$SCRIPT_DIR/server-preconfig.sh"

# server-preconfig.sh runs main on load, so it cannot be sourced: load only the functions under test.
FNS="short_hostname hosts_has_name hosts_domain hosts_is_set hosts_set_name cloud_cfg cloud_init_off cloud_init_undo
    ask questions plan_and_confirm write_file backup step_hostname chk check_cloud_init"
for fn in $FNS; do
    eval "$(sed -n "/^$fn() {/,/^}/p" "$PRE")"
done
eval "$(grep -E '^(ok|warn|fail|info|title|run)\(\) +\{' "$PRE")"
for fn in $FNS ok warn fail info title run; do
    if ! declare -F "$fn" >/dev/null; then
        printf 'not ok: %s not found in server-preconfig.sh\n' "$fn"
        exit 1
    fi
done

# Stop before any path is built if mktemp fails: an empty $tmp would point the step at /etc.
if ! tmp="$(mktemp -d)" || [[ -z $tmp || ! -d $tmp ]]; then
    printf 'not ok: mktemp -d failed, no temporary directory for the fixtures\n'
    exit 1
fi
trap 'rm -rf "$tmp"' EXIT

G=""; Y=""; R=""; C=""; B=""; N=""
WARNS=0; FAILS=0; DRY_RUN=0; ASSUME_YES=1
ADMIN="admin"; GH_KEYS=""; NET_MANAGER="netplan"; DO_TAILSCALE=""; STATIC_IP=""; GATEWAY=""; IFACE=eth0
HOSTS_FILE="$tmp/etc/hosts"
CLOUD_DIR="$tmp/etc/cloud"
CLOUD_DROPIN="$CLOUD_DIR/cloud.cfg.d/zz-server-preconfig.cfg"
DROPIN_NAME=${CLOUD_DROPIN##*/}
PROC_CMDLINE="$tmp/proc-cmdline"
BACKUP_DIR="$tmp/backups"
P_ID=(); P_STATUS=(); P_MSG=(); P_FIX=()
for p in "$HOSTS_FILE" "$CLOUD_DIR" "$CLOUD_DROPIN" "$PROC_CMDLINE" "$BACKUP_DIR"; do
    if [[ $p != "$tmp"/* ]]; then
        printf 'not ok: %s is not under the temp folder\n' "$p"
        exit 1
    fi
done
# A kernel command line without cloud-init=: the real one of the machine running the tests never counts.
CMDLINE_DEFAULT='BOOT_IMAGE=/boot/vmlinuz root=/dev/vda1 ro console=ttyS0 init=/sbin/*'
printf '%s\n' "$CMDLINE_DEFAULT" > "$PROC_CMDLINE"

STUB_HOSTNAME=web-01
hostname() { printf '%s\n' "$STUB_HOSTNAME"; }
hostnamectl() { printf '%s\n' "$*" >> "$tmp/hostnamectl.log"; }

not_ok() {   # not_ok "message" [FILE]: stop, showing FILE when given
    printf 'not ok: %s\n' "$1"
    if [[ -n ${2:-} && -f $2 ]]; then sed 's/^/    | /' "$2"; fi
    exit 1
}

expect_eq() {   # expect_eq "label" GOT WANT
    [[ $2 == "$3" ]] || not_ok "$1: got '$2', want '$3'"
    printf 'ok: %s\n' "$1"
}

expect_true() {   # expect_true "label" CMD...: CMD must succeed
    local label=$1; shift
    "$@" || not_ok "$label"
    printf 'ok: %s\n' "$label"
}

expect_false() {   # expect_false "label" CMD...: CMD must fail
    local label=$1; shift
    if "$@"; then not_ok "$label"; fi
    printf 'ok: %s\n' "$label"
}

has_name() { printf '%s' "$2" | hosts_has_name "$1"; }   # has_name NAME HOSTS-TEXT
is_set() { printf '%s' "$3" | hosts_is_set "$1" "$2"; }   # is_set NAME DOMAIN HOSTS-TEXT

# (a) The default: the short name in lowercase.
expect_eq "short_hostname Web-01" "$(short_hostname Web-01)" web-01
expect_eq "short_hostname vps123.example.net" "$(short_hostname vps123.example.net)" vps123
expect_eq "short_hostname web-01 stays web-01" "$(short_hostname web-01)" web-01

# (b) questions(): under --yes the default goes through as is, so it must be valid, and the operator
# is told when it differs from the current name.
run_questions() {   # run_questions CURRENT [PRESET]: HOSTNAME_NEW after questions(), output in $tmp/q.out
    STUB_HOSTNAME=$1; HOSTNAME_NEW=${2:-}
    questions > "$tmp/q.out" 2>&1
}
run_questions Web-01
expect_eq "questions: Web-01 gives the default web-01" "$HOSTNAME_NEW" web-01
grep -qF "current hostname 'Web-01': the default is 'web-01'" "$tmp/q.out" \
    || not_ok "questions: no 'current hostname' line under --yes" "$tmp/q.out"
printf 'ok: questions: says the default differs from Web-01, also with --yes\n'
run_questions web-01
expect_eq "questions: web-01 stays web-01" "$HOSTNAME_NEW" web-01
if grep -q 'current hostname' "$tmp/q.out"; then not_ok "questions: 'current hostname' line for a name that did not change" "$tmp/q.out"; fi
printf 'ok: questions: no line when the name does not change\n'
run_questions vps123.example.net
expect_eq "questions: vps123.example.net gives vps123" "$HOSTNAME_NEW" vps123
run_questions web-01 Web-01
expect_eq "questions: an explicit --hostname Web-01 is kept as given" "$HOSTNAME_NEW" Web-01
printf '127.0.0.1\tlocalhost\n' > "$tmp/hosts.orig"
mkdir -p "$tmp/etc" && cp "$tmp/hosts.orig" "$HOSTS_FILE"
FAILS=0
step_hostname > "$tmp/step.out" 2>&1
[[ $FAILS -eq 1 ]] && grep -qF "invalid hostname 'Web-01'" "$tmp/step.out" \
    || not_ok "step_hostname: --hostname Web-01 does not FAIL" "$tmp/step.out"
cmp -s "$tmp/hosts.orig" "$HOSTS_FILE" || not_ok "step_hostname: an invalid name changed the hosts file"
[[ ! -e $tmp/hostnamectl.log ]] || not_ok "step_hostname: an invalid name reached hostnamectl"
printf 'ok: step_hostname: --hostname Web-01 still FAILs and changes nothing\n'
FAILS=0; rm -f "$HOSTS_FILE"

helper_cases() {   # helper_cases LABEL: (c) to (e), run once per awk
    local l=$1 out
    # (c) hosts_has_name: exact names on 127.0.1.1 lines only.
    expect_true "$l: hosts_has_name finds web-01 as the alias after an FQDN" \
        has_name web-01 $'127.0.0.1\tlocalhost\n127.0.1.1\tweb-01.example.com web-01\n'
    expect_true "$l: hosts_has_name finds the FQDN itself" \
        has_name web-01.example.com $'127.0.1.1 web-01.example.com web-01\n'
    expect_true "$l: hosts_has_name reads a last line without a newline" has_name web-01 '127.0.1.1 web-01'
    expect_false "$l: web-010 is not web-01" has_name web-01 $'127.0.1.1 web-010\n'
    expect_false "$l: web.01 is a name, not a pattern" has_name web.01 $'127.0.1.1 webX01\n'
    expect_false "$l: a commented 127.0.1.1 line does not count" has_name web-01 $'#127.0.1.1 web-01\n# 127.0.1.1 web-01\n'
    expect_false "$l: a name in a trailing comment does not count" has_name web-01 $'127.0.1.1 other # web-01\n'
    expect_false "$l: only 127.0.1.1 lines count" has_name web-01 $'127.0.0.1 localhost web-01\n'
    # hosts_is_set: the name, and NAME.DOMAIN when there is a domain (issue #81 review: the FQDN was lost).
    expect_true "$l: hosts_is_set: web-01 without a domain" is_set web-01 "" $'127.0.1.1 web-01\n'
    expect_true "$l: hosts_is_set: web-01.example.com web-01" is_set web-01 example.com $'127.0.1.1\tweb-01.example.com web-01\n'
    expect_false "$l: hosts_is_set: '127.0.1.1 web-01' lacks web-01.example.com" is_set web-01 example.com $'127.0.1.1 web-01\n'
    expect_false "$l: hosts_is_set: '127.0.1.1 web-01.example.com' lacks web-01" is_set web-01 example.com $'127.0.1.1 web-01.example.com\n'
    expect_false "$l: hosts_is_set: a stale FQDN is not the one to keep" is_set web-01 example.com $'127.0.1.1 old.example.com web-01\n'

    # (d) hosts_domain and hosts_set_name: the domain stays, the other lines do not move.
    out=$(printf '127.0.0.1 localhost\n127.0.1.1\told.example.com old\n' | hosts_domain old)
    expect_eq "$l: hosts_domain reads the domain of the FQDN on the 127.0.1.1 line" "$out" example.com
    out=$(printf '127.0.0.1 localhost\n127.0.1.1\told\n' | hosts_domain old)
    expect_eq "$l: hosts_domain is empty without a domain" "$out" ""
    out=$(printf '127.0.0.1 localhost\n' | hosts_domain vps123.example.net)
    expect_eq "$l: hosts_domain falls back to the domain of the current FQDN" "$out" example.net
    out=$(printf '127.0.1.1 old.-bad- old\n' | hosts_domain old)
    expect_eq "$l: hosts_domain drops a domain that is not a valid name" "$out" ""
    out=$(printf '# 127.0.1.1 old.example.org\n127.0.1.1 old\n' | hosts_domain old)
    expect_eq "$l: hosts_domain ignores comments" "$out" ""

    printf '127.0.0.1\tlocalhost\n127.0.1.1\told.example.com old\n\n# The following lines are desirable for IPv6 capable hosts\n::1     localhost ip6-localhost ip6-loopback\nff02::1 ip6-allnodes\n' \
        > "$tmp/fqdn.in"
    printf '127.0.0.1\tlocalhost\n127.0.1.1\tweb-01.example.com web-01\n\n# The following lines are desirable for IPv6 capable hosts\n::1     localhost ip6-localhost ip6-loopback\nff02::1 ip6-allnodes\n' \
        > "$tmp/fqdn.want"
    hosts_set_name web-01 example.com < "$tmp/fqdn.in" > "$tmp/fqdn.got"
    diff "$tmp/fqdn.want" "$tmp/fqdn.got" > "$tmp/fqdn.diff" || not_ok "$l: hosts_set_name with a domain" "$tmp/fqdn.diff"
    printf 'ok: %s: hosts_set_name writes 127.0.1.1<TAB>web-01.example.com web-01, other lines byte for byte\n' "$l"
    hosts_set_name web-01 example.com < "$tmp/fqdn.got" > "$tmp/fqdn.again"
    cmp -s "$tmp/fqdn.got" "$tmp/fqdn.again" || not_ok "$l: hosts_set_name is not stable on its own output"
    printf 'ok: %s: hosts_set_name gives the same file when run on its output\n' "$l"
    out=$(printf '127.0.0.1 localhost\n127.0.1.1 old\n' | hosts_set_name web-01 "")
    expect_eq "$l: hosts_set_name without a domain" "$out" $'127.0.0.1 localhost\n127.0.1.1\tweb-01'
    out=$(printf '127.0.0.1 localhost\n::1 localhost\n' | hosts_set_name web-01)
    expect_eq "$l: hosts_set_name adds the line when there is none" "$out" $'127.0.0.1 localhost\n::1 localhost\n127.0.1.1\tweb-01'
    out=$(printf '127.0.1.1 a\n127.0.0.1 localhost\n127.0.1.1 b\n' | hosts_set_name web-01)
    expect_eq "$l: hosts_set_name sets every 127.0.1.1 line" "$out" $'127.0.1.1\tweb-01\n127.0.0.1 localhost\n127.0.1.1\tweb-01'
    out=$(printf '' | hosts_set_name web-01)
    expect_eq "$l: hosts_set_name on an empty file" "$out" $'127.0.1.1\tweb-01'

    # (e) cloud_init_undo: the effective values, cloud.cfg then cloud.cfg.d/*.cfg, the last file wins.
    local saved=$CLOUD_DIR
    CLOUD_DIR="$tmp/cloud-$l"
    mkdir -p "$CLOUD_DIR/cloud.cfg.d"
    printf '# The top level settings are used as module and base configuration.\n# preserve_hostname: true\npreserve_hostname: false\nsystem_info:\n  preserve_hostname: true\n  manage_etc_hosts: true\n' \
        > "$CLOUD_DIR/cloud.cfg"
    out=$(cloud_init_undo)
    [[ $out == "preserve_hostname: false in $CLOUD_DIR/cloud.cfg" ]] \
        || not_ok "$l: stock cloud.cfg (preserve_hostname: false) gives '$out'"
    printf 'ok: %s: stock cloud.cfg can undo the hostname (commented and indented keys ignored)\n' "$l"
    printf 'manage_etc_hosts: true   # rewrite /etc/hosts at every boot\n' > "$CLOUD_DIR/cloud.cfg.d/01_debian_cloud.cfg"
    out=$(cloud_init_undo)
    [[ $out == *"manage_etc_hosts: true in $CLOUD_DIR/cloud.cfg.d/01_debian_cloud.cfg"* ]] \
        || not_ok "$l: manage_etc_hosts: true in cloud.cfg.d gives '$out'"
    printf 'ok: %s: manage_etc_hosts: true in cloud.cfg.d is named with its file\n' "$l"
    printf 'manage_etc_hosts: "template"\n' > "$CLOUD_DIR/cloud.cfg.d/01_debian_cloud.cfg"
    out=$(cloud_init_undo)
    [[ $out == *"manage_etc_hosts: template in"* ]] || not_ok "$l: manage_etc_hosts: template gives '$out'"
    printf 'ok: %s: manage_etc_hosts: template counts too\n' "$l"
    printf '# Managed by server-preconfig.sh\npreserve_hostname: true\nmanage_etc_hosts: false\n' > "$CLOUD_DIR/cloud.cfg.d/$DROPIN_NAME"
    # The usual files, all read before the drop-in: '_' (99_provider) and letters (curtin-) sort after '99-'.
    printf 'preserve_hostname: false\n' > "$CLOUD_DIR/cloud.cfg.d/99-installer.cfg"
    printf 'manage_etc_hosts: true\n' > "$CLOUD_DIR/cloud.cfg.d/99_provider.cfg"
    printf 'preserve_hostname: false\n' > "$CLOUD_DIR/cloud.cfg.d/curtin-preserve-sources.cfg"
    printf 'preserve_hostname: false\n' > "$CLOUD_DIR/cloud.cfg.d/zzz-later.cfg.bak"
    out=$(cloud_init_undo)
    expect_eq "$l: the drop-in wins over 99-installer, 99_provider and curtin- files (and *.cfg.bak is not read)" "$out" ""
    out=$(cloud_init_undo "$CLOUD_DIR/cloud.cfg.d/$DROPIN_NAME")
    expect_eq "$l: no file is read after the drop-in" "$out" ""
    printf 'preserve_hostname: "False"\n' > "$CLOUD_DIR/cloud.cfg.d/zzz-later.cfg"
    out=$(cloud_init_undo)
    expect_eq "$l: a later file setting \"False\" wins over the drop-in and is named" "$out" \
        "preserve_hostname: false in $CLOUD_DIR/cloud.cfg.d/zzz-later.cfg"
    out=$(cloud_init_undo "$CLOUD_DIR/cloud.cfg.d/$DROPIN_NAME")
    expect_eq "$l: cloud_init_undo AFTER names only the file read after the drop-in" "$out" \
        "preserve_hostname: false in $CLOUD_DIR/cloud.cfg.d/zzz-later.cfg"
    printf 'preserve_hostname: yes\nmanage_etc_hosts: localhost\n' > "$CLOUD_DIR/cloud.cfg.d/zzz-later.cfg"
    out=$(cloud_init_undo)
    expect_eq "$l: preserve_hostname: yes and manage_etc_hosts: localhost are safe" "$out" ""
    if [[ $EUID -ne 0 ]]; then
        printf 'preserve_hostname: false\n' > "$CLOUD_DIR/cloud.cfg.d/50-secret.cfg"
        chmod 000 "$CLOUD_DIR/cloud.cfg.d/50-secret.cfg"
        printf 'preserve_hostname: off\n' > "$CLOUD_DIR/cloud.cfg.d/zzz-later.cfg"
        out=$(cloud_init_undo)
        expect_eq "$l: an unreadable file is skipped and the files after it are still read" "$out" \
            "preserve_hostname: off in $CLOUD_DIR/cloud.cfg.d/zzz-later.cfg"
        rm -f "$CLOUD_DIR/cloud.cfg.d/50-secret.cfg"
    fi

    # cloud-init disabled (Ubuntu installed from the ISO: stock cloud.cfg + cloud-init.disabled): nothing to undo.
    printf 'preserve_hostname: off\n' > "$CLOUD_DIR/cloud.cfg.d/zzz-later.cfg"
    : > "$CLOUD_DIR/cloud-init.disabled"
    expect_eq "$l: cloud_init_off names cloud-init.disabled" "$(cloud_init_off)" "$CLOUD_DIR/cloud-init.disabled exists"
    expect_eq "$l: cloud-init.disabled: nothing to undo" "$(cloud_init_undo)" ""
    printf 'ro quiet cloud-init=enabled\n' > "$PROC_CMDLINE"
    expect_eq "$l: cloud-init=enabled on the kernel command line wins over cloud-init.disabled" "$(cloud_init_off)" ""
    expect_eq "$l: cloud-init=enabled: the later file is named again" "$(cloud_init_undo)" \
        "preserve_hostname: off in $CLOUD_DIR/cloud.cfg.d/zzz-later.cfg"
    printf 'ro cloud-init=enabled quiet cloud-init=disabled\n' > "$PROC_CMDLINE"
    expect_eq "$l: the last cloud-init= of the kernel command line wins" "$(cloud_init_off)" \
        "cloud-init=disabled on the kernel command line"
    rm -f "$CLOUD_DIR/cloud-init.disabled"
    printf 'ro cloud-init=disabled splash\n' > "$PROC_CMDLINE"
    expect_eq "$l: cloud-init=disabled alone turns it off" "$(cloud_init_off)" "cloud-init=disabled on the kernel command line"
    expect_eq "$l: cloud-init=disabled: nothing to undo" "$(cloud_init_undo)" ""
    printf 'ro cloud-init=maybe\n' > "$PROC_CMDLINE"
    expect_eq "$l: another cloud-init= value without the file: cloud-init runs" "$(cloud_init_off)" ""
    printf '%s\n' "$CMDLINE_DEFAULT" > "$PROC_CMDLINE"
    expect_eq "$l: no cloud-init= and no file: cloud-init runs" "$(cloud_init_off)" ""
    rm -f "$PROC_CMDLINE"
    expect_eq "$l: no kernel command line to read: cloud-init runs" "$(cloud_init_off)" ""
    printf '%s\n' "$CMDLINE_DEFAULT" > "$PROC_CMDLINE"
    rm -f "$CLOUD_DIR/cloud.cfg"
    out=$(cloud_init_undo)
    expect_eq "$l: no cloud.cfg (no cloud-init): nothing to undo" "$out" ""
    rm -rf "$CLOUD_DIR"
    CLOUD_DIR=$saved
}

helper_cases awk
if command -v mawk >/dev/null 2>&1; then
    # Debian and Ubuntu use mawk as awk: run the same cases through it.
    awk() { mawk "$@"; }
    helper_cases mawk
    unset -f awk
else
    printf 'ok: skip the mawk run (mawk not installed)\n'
fi

# Fixtures for the step: an FQDN on the 127.0.1.1 line and the stock cloud.cfg of a cloud image.
mkdir -p "$tmp/etc" "$CLOUD_DIR/cloud.cfg.d"
printf '127.0.0.1\tlocalhost\n127.0.1.1\told-name.example.com old-name\n\n::1     localhost ip6-localhost ip6-loopback\nff02::1 ip6-allnodes\n' \
    > "$HOSTS_FILE"
printf 'users:\n  - default\npreserve_hostname: false\nmanage_etc_hosts: true\n' > "$CLOUD_DIR/cloud.cfg"
cp "$HOSTS_FILE" "$tmp/hosts.orig"; cp "$CLOUD_DIR/cloud.cfg" "$tmp/cloud.cfg.orig"
printf '127.0.0.1\tlocalhost\n127.0.1.1\tweb-01.example.com web-01\n\n::1     localhost ip6-localhost ip6-loopback\nff02::1 ip6-allnodes\n' \
    > "$tmp/hosts.want"

# (f) --dry-run: shows every change, changes nothing.
STUB_HOSTNAME=old-name; HOSTNAME_NEW=web-01; DRY_RUN=1; FAILS=0
plan_and_confirm > "$tmp/plan.out" 2>&1
grep -qF 'old-name -> web-01 (+ /etc/hosts: 127.0.1.1 web-01.example.com web-01; cloud-init drop-in keeps them at boot)' "$tmp/plan.out" \
    || not_ok "dry run: the plan does not show the hosts line and the drop-in" "$tmp/plan.out"
printf 'ok: dry run: the plan shows the FQDN line and the cloud-init drop-in\n'
step_hostname > "$tmp/dry.out" 2>&1
for want in "[dry-run] write $HOSTS_FILE" "web-01.example.com web-01" "[dry-run] write $CLOUD_DROPIN" \
    "preserve_hostname: true" "manage_etc_hosts: false" "[dry-run] hostnamectl set-hostname web-01"; do
    grep -qF -- "$want" "$tmp/dry.out" || not_ok "dry run: '$want' missing" "$tmp/dry.out"
done
printf 'ok: dry run: shows the hosts file, the drop-in and hostnamectl\n'
cmp -s "$tmp/hosts.orig" "$HOSTS_FILE" && cmp -s "$tmp/cloud.cfg.orig" "$CLOUD_DIR/cloud.cfg" \
    || not_ok "dry run: a fixture changed"
[[ ! -e $CLOUD_DROPIN && ! -e $BACKUP_DIR && ! -e $tmp/hostnamectl.log ]] \
    || not_ok "dry run: wrote the drop-in, a backup or called hostnamectl"
expect_eq "dry run: no FAIL" "$FAILS" 0
printf 'ok: dry run: nothing changed\n'

# (g) The real step: FQDN kept, other lines intact, original backed up, drop-in written.
DRY_RUN=0
step_hostname > "$tmp/run.out" 2>&1
expect_eq "run: no FAIL" "$FAILS" 0
diff "$tmp/hosts.want" "$HOSTS_FILE" > "$tmp/run.diff" || not_ok "run: hosts file" "$tmp/run.diff"
printf 'ok: run: 127.0.1.1<TAB>web-01.example.com web-01, the other lines unchanged\n'
cmp -s "$tmp/hosts.orig" "$BACKUP_DIR$HOSTS_FILE" || not_ok "run: the original hosts file is not in the backup folder"
printf 'ok: run: the original hosts file is backed up\n'
grep -qx 'preserve_hostname: true' "$CLOUD_DROPIN" && grep -qx 'manage_etc_hosts: false' "$CLOUD_DROPIN" \
    || not_ok "run: the drop-in does not set both keys" "$CLOUD_DROPIN"
printf 'ok: run: the drop-in sets preserve_hostname: true and manage_etc_hosts: false\n'
expect_eq "run: cloud-init no longer undoes anything" "$(cloud_init_undo)" ""
expect_eq "run: hostnamectl set the short name" "$(cat "$tmp/hostnamectl.log")" "set-hostname web-01"
grep -qF "OK    /etc/hosts: 127.0.1.1 web-01.example.com web-01" "$tmp/run.out" \
    || not_ok "run: no OK line for /etc/hosts" "$tmp/run.out"
grep -qF "cloud-init keeps the hostname and /etc/hosts at boot ($CLOUD_DROPIN)" "$tmp/run.out" \
    || not_ok "run: no OK line for the drop-in" "$tmp/run.out"
printf 'ok: run: OK lines for /etc/hosts and the drop-in\n'

# (h) A re-run once the name is set changes nothing.
STUB_HOSTNAME=web-01
cp "$HOSTS_FILE" "$tmp/hosts.after"; cp "$CLOUD_DROPIN" "$tmp/dropin.after"
step_hostname > "$tmp/rerun.out" 2>&1
expect_eq "re-run: no FAIL" "$FAILS" 0
cmp -s "$tmp/hosts.after" "$HOSTS_FILE" && cmp -s "$tmp/dropin.after" "$CLOUD_DROPIN" \
    || not_ok "re-run: a file changed"
if grep -qE '/etc/hosts:|cloud-init keeps' "$tmp/rerun.out"; then not_ok "re-run: says it changed something" "$tmp/rerun.out"; fi
grep -qF 'hostname: web-01 (unchanged)' "$tmp/rerun.out" || not_ok "re-run: no '(unchanged)' line" "$tmp/rerun.out"
expect_eq "re-run: hostnamectl not called again" "$(grep -c . "$tmp/hostnamectl.log")" 1
printf 'ok: re-run: nothing changed\n'
plan_and_confirm > "$tmp/plan.out" 2>&1
grep -qF 'web-01 -> web-01 (/etc/hosts unchanged)' "$tmp/plan.out" \
    || not_ok "re-run: the plan does not say /etc/hosts is unchanged" "$tmp/plan.out"
printf 'ok: re-run: the plan says /etc/hosts is unchanged, and no drop-in\n'

# (i) An FQDN hostname with only the short name on the 127.0.1.1 line (vps123.example.net with
# '127.0.1.1 vps123'): the default is the short name, so the line must get the FQDN or it is lost.
printf '127.0.0.1\tlocalhost\n127.0.1.1\tweb-01\n' > "$HOSTS_FILE"
run_questions web-01.example.com
expect_eq "fqdn: web-01.example.com gives the default web-01" "$HOSTNAME_NEW" web-01
plan_and_confirm > "$tmp/plan.out" 2>&1
grep -qF 'web-01.example.com -> web-01 (+ /etc/hosts: 127.0.1.1 web-01.example.com web-01)' "$tmp/plan.out" \
    || not_ok "fqdn: the plan does not show the FQDN line" "$tmp/plan.out"
printf 'ok: fqdn: the plan shows 127.0.1.1 web-01.example.com web-01\n'
step_hostname > "$tmp/fqdn.out" 2>&1
expect_eq "fqdn: no FAIL" "$FAILS" 0
expect_eq "fqdn: the 127.0.1.1 line keeps the domain" "$(cat "$HOSTS_FILE")" $'127.0.0.1\tlocalhost\n127.0.1.1\tweb-01.example.com web-01'
grep -qF "OK    /etc/hosts: 127.0.1.1 web-01.example.com web-01" "$tmp/fqdn.out" \
    || not_ok "fqdn: the step does not say what the plan showed" "$tmp/fqdn.out"
expect_eq "fqdn: hostnamectl set the short name" "$(tail -1 "$tmp/hostnamectl.log")" "set-hostname web-01"
STUB_HOSTNAME=web-01
cp "$HOSTS_FILE" "$tmp/hosts.after"
step_hostname > "$tmp/fqdn-rerun.out" 2>&1
cmp -s "$tmp/hosts.after" "$HOSTS_FILE" || not_ok "fqdn: the re-run changed the hosts file" "$tmp/fqdn-rerun.out"
expect_eq "fqdn: the domain is still found on the re-run" "$(hosts_domain web-01 < "$HOSTS_FILE")" example.com
printf 'ok: fqdn: the re-run keeps the FQDN line\n'

# (j) cloud-init disabled (Ubuntu installed from the ISO): the stock cloud.cfg does not matter, no drop-in.
rm -f "$CLOUD_DROPIN"
: > "$CLOUD_DIR/cloud-init.disabled"
plan_and_confirm > "$tmp/plan.out" 2>&1
if grep -q 'cloud-init' "$tmp/plan.out"; then not_ok "disabled: the plan mentions cloud-init" "$tmp/plan.out"; fi
step_hostname > "$tmp/disabled.out" 2>&1
[[ ! -e $CLOUD_DROPIN ]] || not_ok "disabled: the drop-in was written" "$tmp/disabled.out"
if grep -q 'cloud-init' "$tmp/disabled.out"; then not_ok "disabled: the step mentions cloud-init" "$tmp/disabled.out"; fi
printf 'ok: disabled: no drop-in, nothing said about cloud-init\n'
rm -f "$CLOUD_DIR/cloud-init.disabled"

# (k) A file read after the drop-in sets manage_etc_hosts: true: the drop-in alone does not fix it, so
# the step warns and names the file instead of saying OK, in the plan, the dry run, the run and a re-run.
LATER="$CLOUD_DIR/cloud.cfg.d/zzz-provider.cfg"
printf 'manage_etc_hosts: true\n' > "$LATER"
expect_late_warn() {   # expect_late_warn LABEL OUTPUT-FILE
    grep -qF "WARN  cloud-init can still reset the hostname or /etc/hosts at the next boot: manage_etc_hosts: true in $LATER" "$2" \
        || not_ok "$1: no WARN naming the later file" "$2"
    grep -qF "cloud-init reads that file after $CLOUD_DROPIN, so it wins" "$2" || not_ok "$1: no line saying why" "$2"
    if grep -q 'OK .*cloud-init keeps' "$2"; then not_ok "$1: still says cloud-init keeps them" "$2"; fi
    printf 'ok: %s: WARN names the file read after the drop-in, no OK line\n' "$1"
}
plan_and_confirm > "$tmp/plan.out" 2>&1
grep -qF "cloud-init drop-in, but a file read after it still wins: manage_etc_hosts: true in $LATER" "$tmp/plan.out" \
    || not_ok "later: the plan does not name the file read after the drop-in" "$tmp/plan.out"
printf 'ok: later: the plan names the file read after the drop-in\n'
DRY_RUN=1; WARNS=0
step_hostname > "$tmp/later-dry.out" 2>&1
grep -qF "[dry-run] write $CLOUD_DROPIN" "$tmp/later-dry.out" || not_ok "later: dry run: no drop-in shown" "$tmp/later-dry.out"
[[ ! -e $CLOUD_DROPIN ]] || not_ok "later: dry run: the drop-in was written"
expect_late_warn "later: dry run" "$tmp/later-dry.out"
DRY_RUN=0
step_hostname > "$tmp/later.out" 2>&1
[[ -f $CLOUD_DROPIN ]] || not_ok "later: the drop-in was not written (it still fixes cloud.cfg)" "$tmp/later.out"
expect_late_warn "later: run" "$tmp/later.out"
step_hostname > "$tmp/later-rerun.out" 2>&1
expect_late_warn "later: re-run, drop-in already there" "$tmp/later-rerun.out"
expect_eq "later: one WARN per run, no FAIL" "$WARNS/$FAILS" 3/0
rm -f "$LATER"

# (l) pre.cloud_init_hostname (check_cloud_init): its status, and a fix that can clear the WARN.
run_check() {   # run_check: "STATUS|MESSAGE|FIX" of check_cloud_init, nothing when it records no result
    P_ID=(); P_STATUS=(); P_MSG=(); P_FIX=()
    check_cloud_init web-01 > "$tmp/check.out" 2>&1
    if (( ${#P_ID[@]} )); then printf '%s|%s|%s\n' "${P_STATUS[0]}" "${P_MSG[0]}" "${P_FIX[0]}"; fi
}
rm -f "$CLOUD_DROPIN"
expect_eq "check: stock cloud.cfg: WARN, a re-run writes the drop-in" "$(run_check)" \
    "WARN|cloud-init can reset the hostname and /etc/hosts at the next boot: preserve_hostname: false in $CLOUD_DIR/cloud.cfg; manage_etc_hosts: true in $CLOUD_DIR/cloud.cfg|sudo ./server-preconfig.sh --hostname web-01 (writes $CLOUD_DROPIN)"
: > "$CLOUD_DIR/cloud-init.disabled"
expect_eq "check: cloud-init.disabled: INFO" "$(run_check)" \
    "INFO|cloud-init is disabled ($CLOUD_DIR/cloud-init.disabled exists): it leaves the hostname and /etc/hosts alone at boot|"
rm -f "$CLOUD_DIR/cloud-init.disabled"
step_hostname > /dev/null 2>&1
expect_eq "check: after the step: PASS" "$(run_check)" "PASS|cloud-init keeps the hostname and /etc/hosts at boot|"
printf 'manage_etc_hosts: true\n' > "$LATER"
expect_eq "check: drop-in there, a later file wins: the fix is to edit that file, not a re-run" "$(run_check)" \
    "WARN|cloud-init can reset the hostname and /etc/hosts at the next boot: manage_etc_hosts: true in $LATER|edit or remove manage_etc_hosts: true in $LATER: cloud-init reads it after $CLOUD_DROPIN, so it wins"
rm -f "$CLOUD_DROPIN"
expect_eq "check: no drop-in and a later file: re-run, then edit that file" "$(run_check)" \
    "WARN|cloud-init can reset the hostname and /etc/hosts at the next boot: preserve_hostname: false in $CLOUD_DIR/cloud.cfg; manage_etc_hosts: true in $LATER|sudo ./server-preconfig.sh --hostname web-01 (writes $CLOUD_DROPIN), then edit or remove manage_etc_hosts: true in $LATER: cloud-init reads it after $CLOUD_DROPIN, so it wins"
rm -f "$LATER"
mv "$CLOUD_DIR/cloud.cfg" "$tmp/cloud.cfg.moved"
expect_eq "check: no cloud.cfg (no cloud-init): no result" "$(run_check)" ""

printf 'ok: all server-preconfig.sh hostname cases\n'
