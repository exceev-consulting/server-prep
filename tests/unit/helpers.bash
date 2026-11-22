# shellcheck shell=bash
# Variables set here (STATE_DIR, BACKUP_DIR, LOG_FILE...) are read by the server-prep.sh functions,
# which ShellCheck does not follow from this file:
# shellcheck disable=SC2034
#
# helpers.bash - loads server-prep.sh into a bats test without running main. Needs no root, and
# changes nothing outside $BATS_TEST_TMPDIR. Each test file loads it with `load helpers`.
#
# Two traps once the script is sourced:
#   - `run` is server-prep.sh's dry-run-aware run(), not the bats helper: it never sets $status or
#     $output. Capture output with $(...) and check exit codes with `if` or refute.
#   - The script's `set -u` and `shopt -s lastpipe` stay on inside the tests. Every variable a helper
#     reads must be set, and "... | write_file" runs in the test's own shell, so its changes to
#     CHANGED_FILES, NEW_FILES and STEP_CHANGED are visible to the test.

PREP="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/server-prep.sh"

# load_prep [ARGS...]: source server-prep.sh with --yes and ARGS (for example --config FILE), then
# point every path it writes to under $BATS_TEST_TMPDIR. It can run again in the same test: the
# settings are unset first, so each load starts clean.
load_prep() {
    # The safety net if a regression of the source guard ever made sourcing start a real run.
    [[ $EUID -ne 0 ]] || skip "unit tests run as a normal user only"
    # Settings read from the environment (SETTING="${SETTING:-...}" lines), plus the old names that
    # a config maps to PANEL_*: a developer's shell or CI must not change the results.
    local setting
    for setting in $(sed -n 's/^\([A-Z][A-Z0-9_]*\)="\${\1:-.*/\1/p' "$PREP") COOLIFY_PUBKEY COOLIFY_ACCESS COOLIFY_IP; do
        unset "$setting"
    done
    # write_file makes its temporary file with mktemp
    export TMPDIR="$BATS_TEST_TMPDIR"
    # shellcheck source=../../server-prep.sh
    . "$PREP" --yes "$@"
    STATE_DIR="$BATS_TEST_TMPDIR/state"
    BACKUP_DIR="$BATS_TEST_TMPDIR/backups"
    LOG_DIR="$BATS_TEST_TMPDIR/log"
    LOG_FILE="$BATS_TEST_TMPDIR/run.log"
    REPORT_DIR="$BATS_TEST_TMPDIR/reports"
    REPORT_FILE="$REPORT_DIR/server-prep-report-web-01.md"
    CONF_DIR="$BATS_TEST_TMPDIR/conf"
    DRY_RUN=0
}

# as_script CMD...: run a server-prep.sh function the way the script runs it, with errexit off. The
# script never sets -e, but bats runs every test with set -e, and the left side of a pipe then stops
# at its first failing command: add_key's `{ grep -vF ...; echo ...; } | write_file` would lose the
# new line when no other line is left. It runs in the test's own shell, so CHANGED_FILES, NEW_FILES
# and STEP_CHANGED keep their changes. It returns the function's exit status.
as_script() {
    local rc=0
    "$@" || rc=$?
    return "$rc"
}

# refute CMD...: fails when CMD succeeds. A bats test never fails on `! cmd`, and the bats `run !`
# is not available once the script's run() has replaced bats' run.
refute() {
    if "$@"; then
        echo "expected to fail: $*" >&2
        return 1
    fi
}

# assert_sources WANT...: ROOT_SOURCES holds exactly WANT, in that order.
assert_sources() {
    if [[ "${ROOT_SOURCES[*]}" != "$*" || ${#ROOT_SOURCES[@]} -ne $# ]]; then
        printf 'ROOT_SOURCES: (%s), %s entries\n' "${ROOT_SOURCES[*]}" "${#ROOT_SOURCES[@]}" >&2
        printf 'expected:     (%s), %s entries\n' "$*" "$#" >&2
        return 1
    fi
}

# make_key NAME: a throwaway ed25519 key pair, $BATS_TEST_TMPDIR/NAME and NAME.pub. It exists only
# for the test and is never committed.
make_key() {
    ssh-keygen -q -t ed25519 -N '' -C "$1@web-01" -f "$BATS_TEST_TMPDIR/$1" </dev/null
}

# write_conf FILE NAME=VALUE...: a config file with one quoted NAME=VALUE line per pair. Configs are
# written at test time: *.conf files must not be committed.
write_conf() {
    local file="$1" pair
    shift
    : >"$file"
    for pair in "$@"; do
        printf '%s=%q\n' "${pair%%=*}" "${pair#*=}" >>"$file"
    done
}

# linux_only: skips the test outside Linux (set_kv needs GNU sed, the mode checks need stat -c).
linux_only() {
    [[ $(uname -s) == Linux ]] || skip "needs GNU sed and stat -c"
}
