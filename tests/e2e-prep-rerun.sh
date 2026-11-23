#!/usr/bin/env bash
# shellcheck disable=SC2034
# Tests the e2e scenario prep-rerun ("Second run changes nothing") on fake second runs (issue #207).
# The update step may say CHANGED when its only change was upgrading packages that were already
# installed (a repository published a release between the two runs): the scenario then passes and
# names the packages in its note. Any other change still fails it. The reports come from the real
# step_update, run_step and report writers of server-prep.sh, with apt-get, timedatectl and the VM
# faked. The scenario then re-runs services, laptop and telegram with --yes from the saved answers
# (issue #74): the fake VM reads the answers the real save_answers writes from tests/e2e/ci.cfg, and
# that re-run's reports come from the real run_step and writers too. No root, no network and no VM:
# nothing on the host changes. Needs jq.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v jq >/dev/null 2>&1; then
    printf 'ok: skip the e2e prep-rerun tests (jq missing)\n'
    exit 0
fi
# Stop before any path is built if mktemp fails: an empty $tmp would write the files to /.
if ! tmp="$(mktemp -d)" || [[ -z $tmp || ! -d $tmp ]]; then
    printf 'not ok: mktemp -d failed, no temporary directory\n'
    exit 1
fi
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'not ok: %s\n' "$*"; exit 1; }
pass() { printf 'ok: %s\n' "$*"; }
expect_eq() {   # expect_eq "what must be true" GOT WANT
    [[ "$2" == "$3" ]] || fail "$1"$'\n'"  got:  $2"$'\n'"  want: $3"
    pass "$1"
}

# fake_run NAME UPGRADES MISSING TZ OTHER: the reports of a second server-prep run, $tmp/NAME.md and
# $tmp/NAME.json, from the real step_update and writers.
#   UPGRADES  the Inst lines of apt-get -s dist-upgrade (packages with a new version)
#   MISSING   base packages that pkg_install finds missing and installs
#   TZ        the server's timezone (the config says UTC)
#   OTHER     what the firewall step does: ok or changed (users stays OK, docker is SKIPPED)
fake_run() {
    (
        # upper case: a local in server-prep.sh (pkg_install's "missing") would hide a lower-case name
        FAKE_UPGRADES="$2" FAKE_MISSING="$3" FAKE_TZ="$4" FAKE_OTHER="$5"
        # shellcheck disable=SC1091
        . "$ROOT/server-prep.sh" --yes
        fake_host "$1"
        apt-get() {   # -s dist-upgrade lists the upgrades; update, full-upgrade and install do nothing
            [[ " $* " == *" -s dist-upgrade "* ]] && printf '%s' "$FAKE_UPGRADES"
            return 0
        }
        pkg_installed() { [[ " $FAKE_MISSING " != *" $1 "* ]]; }
        timedatectl() { [[ $1 == show ]] && printf '%s\n' "$FAKE_TZ"; return 0; }
        step_users() { return 0; }
        step_docker() { return "$SKIP_RC"; }
        step_firewall() { [[ $FAKE_OTHER == changed ]] && changed; return 0; }
        run_step update "System update & base packages" step_update
        run_step users "Users & SSH keys (admin, panel)" step_users
        run_step docker "Docker CE" step_docker
        run_step firewall "Firewall (UFW + Docker)" step_firewall
        write_report && write_report_json
    ) > "$tmp/$1.out" 2>&1 || fail "the fake run $1 failed: $(cat "$tmp/$1.out")"
    [[ -s "$tmp/$1.md" && -s "$tmp/$1.json" ]] || fail "the fake run $1 wrote no reports: $(cat "$tmp/$1.out")"
}

# fake_host NAME: after server-prep.sh is sourced, what its report writers read, for the fake run NAME
fake_host() {
    LOG_FILE="$tmp/$1.log" REPORT_FILE="$tmp/$1.md" BACKUP_DIR="$tmp/backups" DRY_RUN=0
    OS_PRETTY='Debian GNU/Linux 12 (bookworm)' LOCAL_IP=192.168.1.50 CURRENT_SSH_PORTS='822 ' TIMEZONE=UTC
    unset SUDO_USER
}

# fake_saved_run NAME SERVICES: the reports of the --yes re-run of services, laptop and telegram from
# the saved answers (issue #74), $tmp/NAME.md and $tmp/NAME.json, from the real run_step and writers.
#   SERVICES  what the services step does: ok or changed (laptop and telegram are SKIPPED, as in the
#             VM: no battery, and ci.cfg has TELEGRAM_ENABLE=no)
fake_saved_run() {
    (
        FAKE_SERVICES="$2"
        # shellcheck disable=SC1091
        . "$ROOT/server-prep.sh" --yes --only services,laptop,telegram
        fake_host "$1"
        step_services() { [[ $FAKE_SERVICES == changed ]] && changed; return 0; }
        step_laptop() { return "$SKIP_RC"; }
        step_telegram() { return "$SKIP_RC"; }
        run_step services "Unneeded services" step_services
        run_step laptop "Laptop server mode" step_laptop
        run_step telegram "Telegram alerts" step_telegram
        write_report && write_report_json
    ) > "$tmp/$1.out" 2>&1 || fail "the fake run $1 failed: $(cat "$tmp/$1.out")"
    [[ -s "$tmp/$1.md" && -s "$tmp/$1.json" ]] || fail "the fake run $1 wrote no reports: $(cat "$tmp/$1.out")"
}

# The saved answers of the first run (issue #74): the real save_answers, with the settings of
# tests/e2e/ci.cfg. The fake VM reads them in place of /etc/server-prep/server-prep.conf. The copy in
# saved-old has no LAPTOP_MODE line, as answers saved by 1.1.1 or older.
mkdir -p "$tmp/saved" "$tmp/saved-old"
(
    # shellcheck disable=SC1091
    . "$ROOT/server-prep.sh" --config "$ROOT/tests/e2e/ci.cfg" --yes
    CONF_DIR="$tmp/saved" DRY_RUN=0
    save_answers
) > "$tmp/saved.out" 2>&1 || fail "save_answers failed: $(cat "$tmp/saved.out")"
[[ -s "$tmp/saved/server-prep.conf" ]] || fail "save_answers wrote no answers: $(cat "$tmp/saved.out")"
grep -v '^LAPTOP_MODE=' "$tmp/saved/server-prep.conf" > "$tmp/saved-old/server-prep.conf"
CANDIDATES="$(sed -n 's/^SERVICE_CANDIDATES="\(.*\)"$/\1/p' "$ROOT/server-prep.sh")"

# dpkg-query output in the VM: status, name, version. rc is a removed package whose config stays.
dpkg_list() { printf 'ii  %s\n' "$@"; printf 'rc  linux-image-6.1.0-9-amd64 6.1.27-1\n'; }

COMPOSE_OLD='5.7.0-1~debian.12~bookworm' COMPOSE_NEW='5.7.1-1~debian.12~bookworm'
CE_OLD='5:28.5.1-1~debian.12~bookworm' CE_NEW='5:28.5.2-1~debian.12~bookworm'
BASE=("ca-certificates 20230311" "jq 1.6-2.1" "lsof 4.95.0-1")
INST_COMPOSE="Inst docker-compose-plugin [$COMPOSE_OLD] ($COMPOSE_NEW Docker:bookworm [amd64])"$'\n'
INST_CE="Inst docker-ce [$CE_OLD] ($CE_NEW Docker:bookworm [amd64])"$'\n'

dpkg_list "${BASE[@]}" "docker-ce $CE_OLD" "docker-compose-plugin $COMPOSE_OLD" > "$tmp/dpkg-before"
dpkg_list "${BASE[@]}" "docker-ce $CE_OLD" "docker-compose-plugin $COMPOSE_NEW" > "$tmp/dpkg-compose"
dpkg_list "${BASE[@]}" "docker-ce $CE_NEW" "docker-compose-plugin $COMPOSE_NEW" > "$tmp/dpkg-both"
dpkg_list "${BASE[@]}" "docker-ce $CE_OLD" "docker-compose-plugin $COMPOSE_NEW" "vim 2:9.0.1378-2" > "$tmp/dpkg-added"
dpkg_list "${BASE[@]:0:2}" "docker-ce $CE_OLD" "docker-compose-plugin $COMPOSE_NEW" > "$tmp/dpkg-removed"
# versions awk would read as numbers: 1.1 and 1.10, 2.0 and 2.00 are equal as numbers
dpkg_list "ca-certificates 20230311" "jq 1.1" "lsof 2.0" > "$tmp/dpkg-numeric"
dpkg_list "ca-certificates 20230311" "jq 1.10" "lsof 2.00" > "$tmp/dpkg-numeric-new"

# The scenario's helpers and bookkeeping, loaded as tests/e2e/run.sh loads them.
E2E_DIR="$ROOT/tests/e2e" REPO_DIR="$ROOT"
WORK="$tmp/work" OUT="$tmp/out" OS_ID=debian-12 VM_CFG=/home/ops/ci.cfg
mkdir -p "$WORK" "$OUT"
# shellcheck source=tests/e2e/lib/record.sh
. "$E2E_DIR/lib/record.sh"
# shellcheck source=tests/e2e/scenarios.sh
. "$E2E_DIR/scenarios.sh"

# The VM, faked: dpkg-query answers from $tmp/dpkg-$DPKG (before, then the case's list once the run
# is done), DOCKER-USER still goes through UFW and CrowdSec, the command that reads the saved answers
# runs here on $SAVED_DIR/server-prep.conf in a clean environment, as root's would, and run_prep hands
# over the case's reports: fake_run CASE for the second run, fake_saved_run SAVED_RUN for the re-run
# from the saved answers.
as_root() {
    local saved=/etc/server-prep/
    case $1 in
        *dpkg-query*) cat "$tmp/dpkg-$DPKG" 2>/dev/null ;;
        *DOCKER-USER*) printf '%s\n' '-N DOCKER-USER' '-A DOCKER-USER -j CROWDSEC_CHAIN' '-A DOCKER-USER -j ufw-user-forward' ;;
        *"$saved"server-prep.conf*) env -i PATH="$PATH" bash -c "${1//"$saved"/$SAVED_DIR/}" ;;
    esac
}
run_prep() {
    case $1 in
        second)
            PREP_REPORT="$tmp/$CASE.md" PREP_JSON="$tmp/$CASE.json" DPKG="$AFTER"
            [[ $NO_JSON == no-json ]] && PREP_JSON=""
            ;;
        saved-answers) PREP_REPORT="$tmp/$SAVED_RUN.md" PREP_JSON="$tmp/$SAVED_RUN.json" ;;
    esac
    return 0
}

# Every case below reads the answers of save_answers and gets a re-run from them that changes
# nothing, unless it sets SAVED_DIR or SAVED_RUN.
SAVED_DIR="$tmp/saved" SAVED_RUN=saved-ok
fake_saved_run saved-ok ok

# rerun CASE AFTER [no-json]: sc_prep_rerun on the reports of fake_run CASE, with the packages of
# $tmp/dpkg-AFTER once the run is done. The saved answers are $SAVED_DIR/server-prep.conf and the
# re-run from them gives the reports of fake_saved_run $SAVED_RUN. Sets STATUS, REASON and DETAIL
# (of the step check).
rerun() {
    CASE="$1" AFTER="$2" NO_JSON="${3:-}" DPKG=before
    : > "$WORK/scenarios.jsonl"
    sc_prep_rerun > "$tmp/$CASE.harness" 2>&1
    STATUS="$(jq -r .status "$WORK/scenarios.jsonl")"
    REASON="$(jq -r .reason "$WORK/scenarios.jsonl")"
    DETAIL="$(jq -r '.assertions[] | select(.name == "every step is OK (already) or SKIPPED")
        | "\(if .ok then "ok" else "not ok" end): \(.detail)"' "$WORK/scenarios.jsonl")"
}

# --- the package diff ---------------------------------------------------------------------------------
pkg_versions_of() { DPKG="$1"; pkg_versions > "$tmp/pkgs-$1"; }
for l in before compose both added removed numeric numeric-new; do pkg_versions_of "$l"; done
expect_eq "pkg_versions keeps installed packages only (no rc line)" \
    "$(grep -c linux-image "$tmp/pkgs-before")" 0
expect_eq "pkg_moves lists an upgrade with its old and new version" \
    "$(pkg_moves "$tmp/pkgs-before" "$tmp/pkgs-compose")" "upgraded docker-compose-plugin $COMPOSE_OLD $COMPOSE_NEW"
expect_eq "pkg_moves lists a new package" \
    "$(pkg_moves "$tmp/pkgs-before" "$tmp/pkgs-added" | grep -v '^upgraded')" "installed vim 2:9.0.1378-2"
expect_eq "pkg_moves lists a removed package" \
    "$(pkg_moves "$tmp/pkgs-before" "$tmp/pkgs-removed" | grep -v '^upgraded')" "removed lsof 4.95.0-1"
expect_eq "pkg_moves compares versions as strings (1.1 -> 1.10, 2.0 -> 2.00)" \
    "$(pkg_moves "$tmp/pkgs-numeric" "$tmp/pkgs-numeric-new")" $'upgraded jq 1.1 1.10\nupgraded lsof 2.0 2.00'
: > "$tmp/pkgs-empty"
pkg_moves "$tmp/pkgs-empty" "$tmp/pkgs-compose" > /dev/null && fail "pkg_moves accepts a list that was not read"
pass "pkg_moves fails when a list was not read"

# --- the scenario on second runs ----------------------------------------------------------------------
fake_run nothing "" "" UTC ok
rerun nothing before
expect_eq "nothing changed: the scenario passes without a note" "$STATUS|$REASON|$DETAIL" "passed||ok: "
expect_eq "the scenario checks the saved answers and the re-run from them (issue #74)" \
    "$(jq -r '[.assertions[] | select(.name | test("saved.answers")) | if .ok then "ok" else "not ok" end] | join(" ")' \
        "$WORK/scenarios.jsonl")" "ok ok ok ok"

fake_run compose "$INST_COMPOSE" "" UTC ok
expect_eq "the real step_update notes the upgrade in the JSON report" \
    "$(jq -r '.steps[0] | "\(.name) \(.result): \(.details)"' "$tmp/compose.json")" "update changed: 1 package(s) upgraded"
expect_eq "update_upgrades_only names the upgraded package" \
    "$(update_upgrades_only "$tmp/compose.json" "$tmp/pkgs-before" "$tmp/pkgs-compose")" \
    "docker-compose-plugin $COMPOSE_OLD -> $COMPOSE_NEW"
expect_eq "update_upgrades_only names an upgrade whose versions look like numbers" \
    "$(update_upgrades_only "$tmp/compose.json" "$tmp/pkgs-numeric" "$tmp/pkgs-numeric-new")" \
    "jq 1.1 -> 1.10, lsof 2.0 -> 2.00"
rerun compose compose
expect_eq "issue #207: a docker-compose-plugin release between the runs passes, with a note naming it" \
    "$STATUS|$REASON" \
    "passed|update CHANGED only because it upgraded packages already installed (new releases since the first run): docker-compose-plugin $COMPOSE_OLD -> $COMPOSE_NEW"
expect_eq "the step check says why it accepts update CHANGED" "$DETAIL" \
    "ok: update CHANGED by package upgrades only, see the note"
grep -qx "note update CHANGED only because .*docker-compose-plugin.*" "$OUT/prep-rerun.log" ||
    fail "the note is not in the scenario log: $(cat "$OUT/prep-rerun.log")"
grep -qx "upgraded docker-compose-plugin $COMPOSE_OLD $COMPOSE_NEW" "$OUT/prep-rerun.log" ||
    fail "the scenario log does not list the packages the run changed: $(cat "$OUT/prep-rerun.log")"
pass "the scenario log has the note and the packages the run changed"
grep -q "^note: debian-12 prep-rerun: update CHANGED" "$tmp/compose.harness" ||
    fail "the harness output does not show the note: $(cat "$tmp/compose.harness")"
pass "the harness output shows the note"

fake_run both "$INST_CE$INST_COMPOSE" "" UTC ok
rerun both both
expect_eq "two upgrades: the note names both, in name order" "$STATUS|${REASON#*: }" \
    "passed|docker-ce $CE_OLD -> $CE_NEW, docker-compose-plugin $COMPOSE_OLD -> $COMPOSE_NEW"

fake_run other "$INST_COMPOSE" "" UTC changed
rerun other compose
expect_eq "an upgrade in update and another step CHANGED: the other step fails the check" \
    "$STATUS|$DETAIL" "failed|not ok: firewall CHANGED"

# The note is the same with a package installed: only the package diff tells them apart.
fake_run installed "$INST_COMPOSE" "vim" UTC ok
expect_eq "step_update installing a base package writes the same note" \
    "$(jq -r '.steps[0].details' "$tmp/installed.json")" "1 package(s) upgraded"
rerun installed added
expect_eq "an upgrade and a package installed: update fails the check" "$STATUS|$DETAIL" "failed|not ok: update CHANGED"

fake_run removed "$INST_COMPOSE" "" UTC ok
rerun removed removed
expect_eq "an upgrade that removes a package: update fails the check" "$STATUS|$DETAIL" "failed|not ok: update CHANGED"

fake_run timezone "$INST_COMPOSE" "" Europe/Paris ok
expect_eq "a new timezone adds its note to the upgrade's" \
    "$(jq -r '.steps[0].details' "$tmp/timezone.json")" "1 package(s) upgraded; timezone UTC"
rerun timezone compose
expect_eq "an upgrade and a new timezone: update fails the check" "$STATUS|$DETAIL" "failed|not ok: update CHANGED"

fake_run install-only "" "vim" UTC ok
rerun install-only added
expect_eq "a package installed without an upgrade: update fails the check" "$STATUS|$DETAIL" "failed|not ok: update CHANGED"

rerun compose compose no-json
expect_eq "without the JSON report the check stays strict" "$STATUS|$DETAIL" "failed|not ok: update CHANGED"

rerun compose empty
expect_eq "when the packages after the run cannot be read, the check stays strict" "$STATUS|$DETAIL" \
    "failed|not ok: update CHANGED"
grep -q '^a package list could not be read' "$OUT/prep-rerun.log" ||
    fail "the scenario log does not say a package list could not be read: $(cat "$OUT/prep-rerun.log")"
pass "the scenario log says when a package list could not be read"

printf '[{"step":"update","label":"System update & base packages","result":"FAILED"}]\n' > "$tmp/failed-steps.json"
expect_eq "steps_moved never leaves out a FAILED step" "$(steps_moved "$tmp/failed-steps.json" update)" "update FAILED"

# --- the re-run from the saved answers (issue #74) -----------------------------------------------------
SAVED_DIR="$tmp/saved-old"
rerun nothing before
SAVED_DIR="$tmp/saved"
expect_eq "saved answers without LAPTOP_MODE (1.1.1 or older) fail the scenario" "$STATUS|$REASON" \
    "failed|the saved answers keep DISABLE_SERVICES and LAPTOP_MODE of ci.cfg: got '$CANDIDATES|', want '$CANDIDATES|auto'"

fake_saved_run saved-changed changed
SAVED_RUN="saved-changed"
rerun nothing before
SAVED_RUN="saved-ok"
expect_eq "a --yes re-run from the saved answers that changes the services step fails the scenario" "$STATUS|$REASON" \
    "failed|from the saved answers, services, laptop and telegram are OK (already) or SKIPPED: services CHANGED"

# --- notes in the scenario record ---------------------------------------------------------------------
: > "$WORK/scenarios.jsonl"
{ begin prep-rerun; note "first"; note "second"; check "a check" 1 "why"; finish; } > /dev/null
expect_eq "a failed scenario keeps its first failed check as the reason" \
    "$(jq -r '"\(.status)|\(.reason)"' "$WORK/scenarios.jsonl")" "failed|a check: why"
: > "$WORK/scenarios.jsonl"
{ begin prep-rerun; note "first"; note "second"; check "a check" 0; finish; } > /dev/null
expect_eq "a passed scenario's notes are its reason, joined with ;" \
    "$(jq -r '"\(.status)|\(.reason)"' "$WORK/scenarios.jsonl")" "passed|first; second"
