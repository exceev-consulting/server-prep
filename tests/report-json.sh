#!/usr/bin/env bash
# shellcheck disable=SC2034
# Tests the JSON report server-prep.sh writes next to the Markdown one (issue #15), on fake run data:
# valid JSON, the step ids and stable results, the settings, the audit before/after, the files, the
# to-do list, the paths, mode 600, the copy in the sudo user's home and no secret or public key.
# No root needed and nothing on the host changes: getent, runuser and chown are fakes, files go to a temp folder.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# jq reads the JSON. CI has it; on a machine without it, skip instead of failing the whole suite.
if ! command -v jq >/dev/null 2>&1; then
    printf 'ok: skip server-prep.sh JSON report tests (jq missing)\n'
    exit 0
fi

# Stop before any path is built if mktemp fails: an empty $tmp would write the files to /.
if ! tmp="$(mktemp -d)" || [[ -z $tmp || ! -d $tmp ]]; then
    printf 'not ok: mktemp -d failed, no temporary directory for the report\n'
    exit 1
fi
trap 'rm -rf "$tmp"' EXIT

# Load the real functions without starting a run (see tests/exit-status.sh).
# shellcheck disable=SC1091
. "$SCRIPT_DIR/server-prep.sh" --yes

fail() { printf 'not ok: %s\n' "$*"; exit 1; }

# The sudo user's home is in $tmp. env -i marks the environment as cleared, runuser records the user
# and that mark, then runs the command as the current user (no root here). chown only records: root
# must never chown anything in the home.
mkdir -p "$tmp/home"
getent() { [[ "$1" == passwd && "$2" == web-admin ]] && printf 'web-admin:x:1000:1000::%s:/bin/bash\n' "$tmp/home"; }
env() {
    [[ "$1" == -i ]] || return 1
    shift
    while [[ "$1" == *=* ]]; do shift; done
    ENV_CLEARED=1 "$@"
}
runuser() {
    printf '%s\n' "$1 $2 $3" >> "$tmp/runuser-args"
    printf '%s\n' "${ENV_CLEARED:-0}" >> "$tmp/runuser-env"
    [[ "$1" == -u && "$3" == -- ]] || return 1
    shift 3
    "$@"
}
chown() { printf '%s\n' "$*" >> "$tmp/chown-args"; }

# A fake applied run.
LOG_FILE="$tmp/run.log"
REPORT_FILE="$tmp/server-prep-report-web-01-20260101_000000.md"
BACKUP_DIR="$tmp/backups"
mkdir -p "$BACKUP_DIR"
printf '#!/bin/bash\n' > "$BACKUP_DIR/rollback.sh"
DRY_RUN=0
OS_PRETTY='Debian GNU/Linux 13 (trixie)'
LOCAL_IP=192.168.1.50
CURRENT_SSH_PORTS='22 2222 '
SSH_PORT=822
ADMIN_USER="admin"
ADMIN_IPS='203.0.113.10, 192.168.1.0/24'
PANEL=coolify
PANEL_ACCESS=tailscale,public
PANEL_IP=203.0.113.10
ROOT_SOURCES=()   # write_report_json fills it: users and ssh may not have run
EXPOSE_WEB=no
EXTRA_PORTS='8000/tcp 6001/tcp'
INSTALL_FAIL2BAN=yes
INSTALL_CROWDSEC=no
TELEGRAM_ENABLE=yes

# Secrets and public keys that must never reach the file.
CLOUDFLARED_TOKEN='canary-cloudflared-token-15'
TELEGRAM_BOT_TOKEN='123456:canary-telegram-token-15'
CROWDSEC_ENROLL_KEY='canary-crowdsec-key-15'
ADMIN_PUBKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAdminKeyBlobCanary15 admin@example.com'
PANEL_PUBKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPanelKeyBlobCanary15 root@web-01'
canaries=("$CLOUDFLARED_TOKEN" "$TELEGRAM_BOT_TOKEN" "$CROWDSEC_ENROLL_KEY"
    AAAAC3NzaC1lZDI1NTE5AAAAIAdminKeyBlobCanary15 AAAAC3NzaC1lZDI1NTE5AAAAIPanelKeyBlobCanary15)

# Every display result run_step writes, and a detail that needs escaping.
tricky=$'say "hi" \\ back\tslash | pipe'
STEP_IDS=(update users firewall ssh suid)
STEP_NAMES=("System update & base packages" "Users & SSH keys (admin, panel)" "Firewall (UFW + Docker)" "SSH security" "SUID review")
STEP_RESULTS=(CHANGED "OK (already)" SKIPPED FAILED "WOULD CHANGE")
STEP_DETAILS=("12 package(s) upgraded" - "disabled" "$tricky" "listed in the report")
CHANGED_FILES=(/etc/ssh/sshd_config)
NEW_FILES=(/etc/ssh/sshd_config.d/10-server-prep.conf)
MANUAL_TODO=("Reboot to finish updates: sudo reboot" "Add web-01 to the panel as root on port 822")

# Audit TSVs (id, status, title, message): ssh.port goes WARN -> PASS, ips.crowdsec is new in the
# after run, fw.status and upd.pending do not change, and sys.os is INFO (never listed).
printf '%s\t%s\t%s\t%s\n' \
    ssh.port WARN 'SSH port' 'port 22' \
    fw.status PASS 'Firewall' 'active' \
    upd.pending FAIL 'Security updates' '3 pending' > "$tmp/audit-before.tsv"
printf '%s\t%s\t%s\t%s\n' \
    ssh.port PASS 'SSH port' 'port 822 "keys only"' \
    fw.status PASS 'Firewall' 'active' \
    ips.crowdsec PASS 'CrowdSec' 'running' \
    upd.pending FAIL 'Security updates' '3 pending' \
    sys.os INFO 'OS' 'Debian 13' > "$tmp/audit-after.tsv"
AUDIT_BEFORE="$tmp/audit-before.tsv"
AUDIT_AFTER="$tmp/audit-after.tsv"

json="$tmp/server-prep-report-web-01-20260101_000000.json"
home_copy="$tmp/home/server-prep-report-web-01-20260101_000000.json"

expect() {   # expect LABEL JQ_FILTER [FILE]: the filter must give true
    if ! jq -e "$2" "${3:-$json}" >/dev/null 2>&1; then
        printf 'not ok: %s (%s)\n' "$1" "$2"
        jq . "${3:-$json}" >&2 2>/dev/null || cat "${3:-$json}" >&2
        exit 1
    fi
    printf 'ok: %s\n' "$1"
}

# --- Case 1: an applied run -------------------------------------------------------------------------
SUDO_USER=web-admin
umask 022   # the file must still be 600
status=0
write_report_json > "$tmp/out" 2>&1 || status=$?
[[ $status -eq 0 ]] || fail "write_report_json exited $status"
[[ -f "$json" ]] || fail "no JSON report next to the Markdown one ($json)"
jq -e . "$json" >/dev/null 2>&1 || fail "the JSON report is not valid JSON: $(head -c 300 "$json")"
[[ "$(wc -l < "$json")" -eq 1 ]] || fail "the JSON report is not one line ending in a newline"
printf 'ok: applied run writes one line of valid JSON next to the Markdown report\n'

expect 'tool, schema_version and mode' '.tool == "server-prep" and .schema_version == 1 and .mode == "applied"'
expect 'version is PREP_VERSION' ".version == \"$PREP_VERSION\""
expect 'host, os, kernel, date and local IP' \
    '.os == "Debian GNU/Linux 13 (trixie)" and .local_ip == "192.168.1.50"
     and (.host | length > 0) and (.kernel | length > 0) and (.date | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))'
expect 'steps[].name are the step ids, in run order' '[.steps[].name] == ["update","users","firewall","ssh","suid"]'
expect 'steps[].title are the labels' '.steps[0].title == "System update & base packages" and .steps[4].title == "SUID review"'
expect 'steps[].result uses the stable values' \
    '[.steps[].result] == ["changed","already_ok","skipped","failed","would_change"]'
expect 'a step without notes has empty details' '.steps[1].details == ""'
[[ "$(jq -r '.steps[3].details' "$json")" == "$tricky" ]] || fail "a detail with a quote, a backslash, a tab and a pipe does not round-trip: $(jq '.steps[3].details' "$json")"
printf 'ok: a detail with a quote, a backslash, a tab and a pipe round-trips\n'

expect 'SSH port now and before are numbers' '.settings.ssh_port == 822 and .settings.ssh_port_before == [22,2222]'
expect 'admin user, panel and panel IP' \
    '.settings.admin_user == "admin" and .settings.panel == "coolify" and .settings.panel_ip == "203.0.113.10"'
expect 'panel access, admin IPs and extra ports are arrays' \
    '.settings.panel_access == ["tailscale","public"] and .settings.admin_ips == ["203.0.113.10","192.168.1.0/24"]
     and .settings.extra_ports == ["8000/tcp","6001/tcp"]'
expect 'root SSH sources' '.settings.root_ssh_from == ["100.64.0.0/10","fd7a:115c:a1e0::/48","203.0.113.10"]'
# The Markdown report shows the same sources, also when users and ssh did not run (no home copy here).
( unset SUDO_USER; ROOT_SOURCES=(); write_report ) > "$tmp/out" 2>&1 || fail "write_report failed: $(cat "$tmp/out")"
grep -qxF '| Root SSH allowed from | 100.64.0.0/10 fd7a:115c:a1e0::/48 203.0.113.10 |' "$REPORT_FILE" ||
    fail "the Markdown report's root SSH sources differ from the JSON: $(grep 'Root SSH' "$REPORT_FILE")"
printf 'ok: the Markdown report lists the same root SSH sources\n'
expect 'yes/no settings are booleans' \
    '.settings.expose_web == false and .settings.fail2ban == true and .settings.crowdsec == false and .settings.telegram == true'

expect 'audit counts before and after' \
    '.audit.before == {"pass":1,"warn":1,"fail":1} and .audit.after == {"pass":3,"warn":0,"fail":1}'
expect 'audit changed lists the WARN -> PASS check and the new check, no INFO' \
    '[.audit.changed[] | [.id, .before, .after]] == [["ssh.port","WARN","PASS"],["ips.crowdsec",null,"PASS"]]'
expect 'audit changed has the title and message' \
    '.audit.changed[0].title == "SSH port" and .audit.changed[0].message == "port 822 \"keys only\""'

expect 'modified files with their backup' \
    ".files.modified == [{\"path\":\"/etc/ssh/sshd_config\",\"backup\":\"$tmp/backups/etc/ssh/sshd_config\"}]"
expect 'created files' '.files.created == ["/etc/ssh/sshd_config.d/10-server-prep.conf"]'
expect 'to-do items' \
    '.todo == ["Reboot to finish updates: sudo reboot","Add web-01 to the panel as root on port 822"]'
expect 'paths: report, log, backups and rollback' \
    ".paths == {\"report\":\"$REPORT_FILE\",\"log\":\"$tmp/run.log\",\"backups\":\"$tmp/backups\",\"rollback\":\"$tmp/backups/rollback.sh\"}"

[[ "$(stat -c %a "$json")" == 600 ]] || fail "the JSON report is mode $(stat -c %a "$json"), want 600"
printf 'ok: the JSON report is mode 600\n'
[[ -f "$home_copy" ]] || fail "no copy of the JSON report in the sudo user's home"
[[ "$(stat -c %a "$home_copy")" == 600 ]] || fail "the home copy is mode $(stat -c %a "$home_copy"), want 600"
cmp -s "$json" "$home_copy" || fail "the home copy differs from the JSON report"
grep -qxF -- "-u web-admin --" "$tmp/runuser-args" 2>/dev/null ||
    fail "the home copy was not written as web-admin (runuser: $(cat "$tmp/runuser-args" 2>/dev/null))"
[[ -s "$tmp/chown-args" ]] && fail "root chowned a path in the home: $(cat "$tmp/chown-args")"
grep -qvxF -- 1 "$tmp/runuser-env" &&
    fail "runuser starts with root's environment (an exported token would reach the user's process)"
printf 'ok: the JSON report is copied to the sudo user home as that user, mode 600, root chowns nothing\n'

for c in "${canaries[@]}"; do
    if grep -qF -- "$c" "$json" "$home_copy"; then
        fail "the JSON report holds a secret or a public key (${c:0:12}...)"
    fi
done
printf 'ok: the JSON report holds no token and no public key\n'

# --- Case 1b: a link already sits at the home copy's name -------------------------------------------
# The copy replaces a link at its name instead of writing to the link's target.
printf 'untouched\n' > "$tmp/link-target"
rm -f "$home_copy"
ln -s "$tmp/link-target" "$home_copy"
write_report_json > "$tmp/out" 2>&1 || fail "write_report_json failed with a link at the home copy's name"
[[ "$(cat "$tmp/link-target")" == untouched ]] || fail "the JSON home copy wrote through a link to its target"
[[ -f "$home_copy" && ! -L "$home_copy" ]] || fail "the JSON home copy is still a link"
cmp -s "$json" "$home_copy" || fail "the JSON home copy differs from the report after replacing a link"
printf 'ok: a link at the JSON home copy name is replaced, its target stays unchanged\n'

# The Markdown report goes through the same copy.
printf '# report\n' > "$REPORT_FILE"
md_copy="$tmp/home/${REPORT_FILE##*/}"
ln -s "$tmp/link-target" "$md_copy"
copy_to_sudo_home "$REPORT_FILE" > "$tmp/out" 2>&1 || fail "copy_to_sudo_home failed for the Markdown report"
[[ "$(cat "$tmp/link-target")" == untouched ]] || fail "the Markdown home copy wrote through a link to its target"
[[ -f "$md_copy" && ! -L "$md_copy" ]] || fail "the Markdown home copy is still a link"
cmp -s "$REPORT_FILE" "$md_copy" || fail "the Markdown home copy differs from the report"
[[ "$(stat -c %a "$md_copy")" == 600 ]] || fail "the Markdown home copy is mode $(stat -c %a "$md_copy"), want 600"
[[ -s "$tmp/chown-args" ]] && fail "root chowned a path in the home: $(cat "$tmp/chown-args")"
printf 'ok: a link at the Markdown home copy name is replaced, its target stays unchanged\n'

# --- Case 2: a dry run without an audit -------------------------------------------------------------
DRY_RUN=1
unset SUDO_USER
mkdir -p "$tmp/dry"
REPORT_FILE="$tmp/dry/server-prep-report-web-01-20260101_000000-dryrun.md"
json="$tmp/dry/server-prep-report-web-01-20260101_000000-dryrun.json"
BACKUP_DIR="$tmp/dry/backups"   # a dry run creates no backup folder
AUDIT_BEFORE=""; AUDIT_AFTER=""
CHANGED_FILES=(); NEW_FILES=(); MANUAL_TODO=()
STEP_IDS=(firewall); STEP_NAMES=("Firewall (UFW + Docker)"); STEP_RESULTS=("WOULD CHANGE"); STEP_DETAILS=(-)
status=0
write_report_json > "$tmp/out" 2>&1 || status=$?
[[ $status -eq 0 ]] || fail "dry run: write_report_json exited $status"
jq -e . "$json" >/dev/null 2>&1 || fail "dry run: the JSON report is missing or not valid JSON"
printf 'ok: dry run writes valid JSON\n'
expect 'dry run: mode is dry-run' '.mode == "dry-run" and .steps == [{"name":"firewall","title":"Firewall (UFW + Docker)","result":"would_change","details":""}]'
expect 'dry run without an audit: counts are null, nothing changed' \
    '.audit == {"before":null,"after":null,"changed":[]}'
expect 'dry run: no files, no to-do' '.files == {"modified":[],"created":[]} and .todo == []'
expect 'dry run: no backups folder and no rollback' '.paths.backups == null and .paths.rollback == null'
[[ -e "$tmp/dry/backups" ]] && fail "dry run: write_report_json created the backup folder"

# Only the before audit ran (the after one gave no output): its counts stay, nothing is compared.
AUDIT_BEFORE="$tmp/audit-before.tsv"
write_report_json > "$tmp/out" 2>&1 || fail "dry run with only the before audit: write_report_json failed"
expect 'only the before audit: before counts, after null, changed empty' \
    '.audit == {"before":{"pass":1,"warn":1,"fail":1},"after":null,"changed":[]}'

# A link planted at the JSON's own name (a non-root dry run writes into the current folder) is replaced.
printf 'untouched\n' > "$tmp/link-target"
rm -f "$json"
ln -s "$tmp/link-target" "$json"
write_report_json > "$tmp/out" 2>&1 || fail "dry run: write_report_json failed with a link at the JSON's name"
[[ "$(cat "$tmp/link-target")" == untouched ]] || fail "the JSON report wrote through a link at its name"
[[ -f "$json" && ! -L "$json" ]] || fail "the JSON report is still a link"
jq -e . "$json" >/dev/null 2>&1 || fail "dry run: no valid JSON after replacing a link at its name"
printf 'ok: a link at the JSON report name is replaced, its target stays unchanged\n'

# --- Case 3: the report folder cannot be written ------------------------------------------------------
REPORT_FILE="$tmp/missing-dir/server-prep-report-web-01-20260101_000000.md"
status=0
write_report_json > "$tmp/out" 2>&1 || status=$?
[[ $status -eq 0 ]] || fail "an unwritable report folder makes write_report_json exit $status, want 0"
grep -qF 'JSON report not written' "$tmp/out" || fail "an unwritable report folder gives no warning: $(cat "$tmp/out")"
printf 'ok: an unwritable report folder only warns, write_report_json still returns 0\n'

# --- Case 4: a non-root dry run in the repo folder leaves git status clean -----------------------------
if git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$SCRIPT_DIR" check-ignore -q server-prep-report-web-01-20260101_000000-dryrun.json ||
        fail ".gitignore does not ignore server-prep-report-*.json"
    printf 'ok: .gitignore ignores the JSON report of a dry run in the repo folder\n'
fi

# --- Case 5: the write fails half way (a full disk) ----------------------------------------------------
# A 1-block file size limit and a long to-do item stop the write after the first lines reached the
# file, as a full disk would (SIGXFSZ ignored, so the write fails instead of killing the shell).
REPORT_FILE="$tmp/dry/server-prep-report-web-01-20260101_000001-dryrun.md"
json="$tmp/dry/server-prep-report-web-01-20260101_000001-dryrun.json"
MANUAL_TODO=("$(printf '%04096d' 0)")
status=0
( ulimit -f 1; trap '' XFSZ; write_report_json ) > "$tmp/out" 2>&1 || status=$?
MANUAL_TODO=()
[[ $status -eq 0 ]] || fail "a write that fails half way makes write_report_json exit $status, want 0"
grep -qF 'JSON report not written' "$tmp/out" || fail "a write that fails half way gives no warning: $(cat "$tmp/out")"
[[ -e "$json" ]] && fail "a write that fails half way leaves a partial JSON report: $(head -c 300 "$json")"
printf 'ok: a write that fails half way leaves no partial JSON report\n'
