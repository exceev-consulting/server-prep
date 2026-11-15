#!/usr/bin/env bats
# ONLY, SKIP, DRY_RUN and STEP_NOTES are set here and read by the server-prep.sh functions under test,
# which ShellCheck does not follow:
# shellcheck disable=SC2034
#
# Unit tests of the server-prep.sh helpers: the source guard, --list-steps, yes_, step_selected,
# valid_pubkey, write_file, set_kv, compute_root_sources, add_key and the config loading. No root:
# every file they write is under $BATS_TEST_TMPDIR, and nothing on the host changes (helpers.bash).
#
# Run: ./scripts/check.sh --only tests   (with the pinned bats-core), or bats tests/unit
#
# Plain [[ ]] checks and the helpers of helpers.bash, no bats-support or bats-assert. Calls that change
# files go through as_script (errexit off, as in the script) in the test's own shell, never in $(...)
# or on the left of a pipe, so CHANGED_FILES, NEW_FILES and STEP_CHANGED keep their changes.
# Only example addresses: 127.0.0.1, ::1, 100.64.0.0/10, fd7a:115c:a1e0::/48 and 203.0.113.x.

setup() {
    load helpers
    load_prep
}

reset_bookkeeping() {
    STEP_CHANGED=0
    CHANGED_FILES=()
    NEW_FILES=()
    STEP_NOTES=""
}

# --- Loading ------------------------------------------------------------------

@test "sourcing with --yes defines the helpers and does not run main" {
    [[ $(type -t write_file) == function && $(type -t main) == function ]]
    [[ $INTERACTIVE -eq 0 && $ASSUME_YES -eq 1 ]]
    # main would have run preflight and the steps: nothing is recorded
    [[ ${#STEP_IDS[@]} -eq 0 && ${#STEP_RESULTS[@]} -eq 0 ]]
}

@test "the source guard runs main from a file, stdin and a pipe, and not when sourced" {
    local copy="$BATS_TEST_TMPDIR/prep-stub.sh" loader="$BATS_TEST_TMPDIR/loader.sh" out
    # A copy whose main only prints: the real main is renamed, so no run can start from here.
    [[ $(grep -c '^main() {$' "$PREP") -eq 1 ]]
    {
        head -n 1 "$PREP"
        printf '%s\n' 'main() { echo "stub main ran"; }'
        tail -n +2 "$PREP" | sed 's/^main() {$/main_not_called() {/'
    } >"$copy"
    refute grep -q '^main() {$' "$copy"
    grep -q '^main_not_called() {$' "$copy"

    out="$(bash "$copy" --yes 2>&1)"
    [[ $out == "stub main ran" ]]
    out="$(bash -s -- --yes <"$copy" 2>&1)"
    [[ $out == "stub main ran" ]]
    out="$(cat "$copy" | bash -s -- --yes 2>&1)"
    [[ $out == "stub main ran" ]]

    printf '%s\n' '. "$1" --yes' 'echo sourced' >"$loader"
    out="$(bash "$loader" "$copy" 2>&1)"
    [[ $out == sourced ]]
    out="$(bash -c '. "$1" --yes; echo sourced' prep "$copy" 2>&1)"
    [[ $out == sourced ]]
    out="$(bash -c 'src() { . "$1" --yes; }; src "$1"; echo sourced' prep "$copy" 2>&1)"
    [[ $out == sourced ]]
    # Not tested: bash -c "$(cat server-prep.sh)". The script is over Linux's 128 KiB limit for one
    # argument (tests/exit-status.sh skips that case for the same reason).
}

@test "--list-steps prints ALL_STEPS" {
    local out
    out="$(bash "$PREP" --list-steps)"
    [[ $out == "$ALL_STEPS" ]]
}

# --- yes_, step_selected, valid_pubkey ------------------------------------------

@test "yes_ accepts y, yes, true and 1 in any case, and nothing else" {
    local v
    for v in y Y yes YES Yes true TRUE 1; do
        yes_ "$v" || { echo "yes_ rejected: $v" >&2; return 1; }
    done
    for v in n no false 0 "" maybe yess; do
        refute yes_ "$v"
    done
}

@test "step_selected follows ONLY and SKIP, and SKIP wins" {
    local s
    # neither set: every step
    ONLY=""
    SKIP=""
    for s in $ALL_STEPS; do
        step_selected "$s" || { echo "not selected: $s" >&2; return 1; }
    done

    ONLY="users ssh"
    SKIP=""
    step_selected users
    refute step_selected docker

    ONLY=""
    SKIP="ssh"
    refute step_selected ssh
    step_selected users

    ONLY="users ssh"
    SKIP="ssh"
    refute step_selected ssh
    step_selected users
    refute step_selected docker

    # whole names only: ssh is part of the name of the real step endlessh, and --only endlessh
    # must not run the ssh step (port move and rollback timer), nor --skip endlessh skip it
    ONLY="ssh"
    SKIP=""
    refute step_selected sshd
    ONLY="endlessh"
    SKIP=""
    step_selected endlessh
    refute step_selected ssh
    ONLY=""
    SKIP="endlessh"
    refute step_selected endlessh
    step_selected ssh
}

@test "valid_pubkey accepts a public key and rejects a private key, garbage and an empty string" {
    make_key admin
    valid_pubkey "$(cat "$BATS_TEST_TMPDIR/admin.pub")"
    refute valid_pubkey "$(cat "$BATS_TEST_TMPDIR/admin")"
    refute valid_pubkey "not a key"
    refute valid_pubkey ""
}

# --- write_file -----------------------------------------------------------------

@test "write_file: the same content changes nothing and makes no backup" {
    local f="$BATS_TEST_TMPDIR/etc/app.conf"
    mkdir -p "${f%/*}"
    printf 'a = 1\n' >"$f"
    as_script write_file "$f" 644 <<<'a = 1'
    [[ $STEP_CHANGED -eq 0 ]]
    [[ ${#CHANGED_FILES[@]} -eq 0 && ${#NEW_FILES[@]} -eq 0 ]]
    [[ ! -e $BACKUP_DIR$f ]]
    [[ $(cat "$f") == 'a = 1' ]]
}

@test "write_file: new content is written and the old file backed up" {
    local f="$BATS_TEST_TMPDIR/etc/app.conf"
    mkdir -p "${f%/*}"
    printf 'a = 1\n' >"$f"
    as_script write_file "$f" 644 <<<'a = 2'
    [[ $(cat "$f") == 'a = 2' ]]
    [[ $(cat "$BACKUP_DIR$f") == 'a = 1' ]]
    [[ ${CHANGED_FILES[*]} == "$f" && ${#CHANGED_FILES[@]} -eq 1 ]]
    [[ ${#NEW_FILES[@]} -eq 0 ]]
    [[ $STEP_CHANGED -eq 1 ]]
}

@test "write_file: a missing file is created with the mode given" {
    linux_only
    local f="$BATS_TEST_TMPDIR/new/dir/app.conf"
    as_script write_file "$f" 600 <<<'b = 1'
    [[ $(cat "$f") == 'b = 1' ]]
    [[ ${NEW_FILES[*]} == "$f" && ${#NEW_FILES[@]} -eq 1 ]]
    [[ ${#CHANGED_FILES[@]} -eq 0 ]]
    [[ $(stat -c %a "$f") == 600 ]]
    [[ $STEP_CHANGED -eq 1 ]]
}

@test "write_file with DRY_RUN=1 writes nothing and makes no backup" {
    local f="$BATS_TEST_TMPDIR/etc/app.conf" missing="$BATS_TEST_TMPDIR/etc/missing.conf"
    mkdir -p "${f%/*}"
    printf 'a = 1\n' >"$f"
    DRY_RUN=1
    as_script write_file "$f" 644 <<<'a = 2' >"$BATS_TEST_TMPDIR/dry-run.out"
    [[ $(cat "$f") == 'a = 1' ]]
    [[ ! -e $BACKUP_DIR$f ]]
    [[ ${#CHANGED_FILES[@]} -eq 0 && ${#NEW_FILES[@]} -eq 0 ]]
    # the current dry-run behaviour: the step shows WOULD CHANGE
    [[ $STEP_CHANGED -eq 1 ]]
    [[ $(cat "$BATS_TEST_TMPDIR/dry-run.out") == *"would write $f"* ]]

    reset_bookkeeping
    as_script write_file "$missing" 644 <<<'b = 1' >/dev/null
    [[ ! -e $missing ]]
    [[ ${#CHANGED_FILES[@]} -eq 0 && ${#NEW_FILES[@]} -eq 0 ]]
}

# --- set_kv (GNU sed 0,/re/ and stat -c: Linux only) ------------------------------

@test "set_kv replaces a commented line and leaves the other lines alone" {
    linux_only
    local f="$BATS_TEST_TMPDIR/sshd_config"
    printf '%s\n' '# comment' '#PermitRootLogin yes' 'Port 22' >"$f"
    as_script set_kv "$f" PermitRootLogin no " "
    [[ $(cat "$f") == $'# comment\nPermitRootLogin no\nPort 22' ]]
    [[ ${CHANGED_FILES[*]} == "$f" && $STEP_CHANGED -eq 1 ]]
}

@test "set_kv appends a missing key with the default separator" {
    linux_only
    local f="$BATS_TEST_TMPDIR/app.conf"
    printf 'A = 1\n' >"$f"
    as_script set_kv "$f" B 2
    [[ $(cat "$f") == $'A = 1\nB = 2' ]]
}

@test "set_kv keeps the file mode" {
    linux_only
    local f="$BATS_TEST_TMPDIR/app.conf"
    printf 'A = 1\n' >"$f"
    chmod 640 "$f"
    as_script set_kv "$f" A 2
    [[ $(cat "$f") == 'A = 2' ]]
    [[ $(stat -c %a "$f") == 640 ]]
}

@test "set_kv: a second identical call changes nothing" {
    linux_only
    local f="$BATS_TEST_TMPDIR/app.conf"
    printf 'A = 1\n' >"$f"
    as_script set_kv "$f" A 2
    [[ $STEP_CHANGED -eq 1 ]]
    reset_bookkeeping
    as_script set_kv "$f" A 2
    [[ $STEP_CHANGED -eq 0 && ${#CHANGED_FILES[@]} -eq 0 ]]
    [[ $(cat "$f") == 'A = 2' ]]
}

# --- compute_root_sources (the from= restriction of the panel's root key) ----------

@test "compute_root_sources: one access mode at a time" {
    PANEL_IP=""
    PANEL_ACCESS=""
    compute_root_sources
    assert_sources

    PANEL_ACCESS=cloudflared
    compute_root_sources
    assert_sources 127.0.0.1 ::1

    PANEL_ACCESS=tailscale
    compute_root_sources
    assert_sources 100.64.0.0/10 fd7a:115c:a1e0::/48

    PANEL_ACCESS=public
    PANEL_IP=203.0.113.10
    compute_root_sources
    assert_sources 203.0.113.10

    # public without PANEL_IP adds nothing
    PANEL_IP=""
    compute_root_sources
    assert_sources
}

@test "compute_root_sources: combinations, in function order, without stale entries" {
    PANEL_IP=""
    PANEL_ACCESS=cloudflared,tailscale
    compute_root_sources
    assert_sources 127.0.0.1 ::1 100.64.0.0/10 fd7a:115c:a1e0::/48

    PANEL_IP=203.0.113.10
    PANEL_ACCESS=tailscale,public
    compute_root_sources
    assert_sources 100.64.0.0/10 fd7a:115c:a1e0::/48 203.0.113.10

    PANEL_ACCESS=public,tailscale,cloudflared
    compute_root_sources
    assert_sources 127.0.0.1 ::1 100.64.0.0/10 fd7a:115c:a1e0::/48 203.0.113.10

    # a second call with another value starts from an empty list
    PANEL_ACCESS=cloudflared
    compute_root_sources
    assert_sources 127.0.0.1 ::1
}

# --- add_key ------------------------------------------------------------------

@test "add_key adds a key once, and a second identical call changes nothing" {
    local user file key
    make_key panel
    user="$(id -un)"
    file="$BATS_TEST_TMPDIR/home/.ssh/authorized_keys"
    key="$(cat "$BATS_TEST_TMPDIR/panel.pub")"

    as_script add_key "$user" "$file" "$key"
    [[ $(cat "$file") == "$key" ]]
    [[ ${NEW_FILES[*]} == "$file" && ${#NEW_FILES[@]} -eq 1 ]]
    [[ $STEP_CHANGED -eq 1 ]]

    reset_bookkeeping
    as_script add_key "$user" "$file" "$key"
    [[ $STEP_CHANGED -eq 0 && ${#CHANGED_FILES[@]} -eq 0 && ${#NEW_FILES[@]} -eq 0 ]]
    [[ $(cat "$file") == "$key" ]]
}

@test "add_key adds a new key after the keys already in the file" {
    local user file key other
    make_key panel
    make_key admin
    user="$(id -un)"
    file="$BATS_TEST_TMPDIR/home/.ssh/authorized_keys"
    key="$(cat "$BATS_TEST_TMPDIR/panel.pub")"
    other="$(cat "$BATS_TEST_TMPDIR/admin.pub")"
    mkdir -p "${file%/*}"
    printf '%s\n' "$other" >"$file"

    as_script add_key "$user" "$file" "$key"
    # losing the admin's key here would lock the operator out
    [[ $(cat "$file") == "$other"$'\n'"$key" ]]
    [[ ${CHANGED_FILES[*]} == "$file" && ${#CHANGED_FILES[@]} -eq 1 ]]
    [[ ${#NEW_FILES[@]} -eq 0 ]]
    [[ $(cat "$BACKUP_DIR$file") == "$other" ]]
    [[ $STEP_CHANGED -eq 1 ]]
}

@test "add_key makes authorized_keys 600 and its folder 700" {
    linux_only
    local file key
    make_key panel
    file="$BATS_TEST_TMPDIR/home/.ssh/authorized_keys"
    key="$(cat "$BATS_TEST_TMPDIR/panel.pub")"
    as_script add_key "$(id -un)" "$file" "$key"
    [[ $(stat -c %a "$file") == 600 ]]
    [[ $(stat -c %a "${file%/*}") == 700 ]]
}

@test "add_key replaces the line of a key whose from= options change" {
    local user file key blob from='from="127.0.0.1,::1"'
    make_key panel
    user="$(id -un)"
    file="$BATS_TEST_TMPDIR/home/.ssh/authorized_keys"
    key="$(cat "$BATS_TEST_TMPDIR/panel.pub")"
    blob="$(awk '{ print $2 }' <<<"$key")"

    as_script add_key "$user" "$file" "$key"
    reset_bookkeeping
    as_script add_key "$user" "$file" "$key" "$from"
    [[ $(cat "$file") == "$from $key" ]]
    [[ $(grep -cF "$blob" "$file") -eq 1 ]]
    [[ ${CHANGED_FILES[*]} == "$file" && ${#CHANGED_FILES[@]} -eq 1 ]]
    [[ $(cat "$BACKUP_DIR$file") == "$key" ]]
    [[ $STEP_CHANGED -eq 1 ]]
}

@test "add_key keeps the other keys and puts the updated line last" {
    local user file key other from='from="127.0.0.1,::1"'
    make_key panel
    make_key admin
    user="$(id -un)"
    file="$BATS_TEST_TMPDIR/home/.ssh/authorized_keys"
    key="$(cat "$BATS_TEST_TMPDIR/panel.pub")"
    other="$(cat "$BATS_TEST_TMPDIR/admin.pub")"
    mkdir -p "${file%/*}"
    printf '%s\n' "$key" "$other" >"$file"

    as_script add_key "$user" "$file" "$key" "$from"
    [[ $(cat "$file") == "$other"$'\n'"$from $key" ]]
}

# --- Config loading -----------------------------------------------------------

@test "a config with only the old COOLIFY_* names sets PANEL=coolify and the PANEL_* values" {
    local conf="$BATS_TEST_TMPDIR/old-names.conf" pub
    make_key panel
    pub="$(cat "$BATS_TEST_TMPDIR/panel.pub")"
    write_conf "$conf" "COOLIFY_PUBKEY=$pub" COOLIFY_ACCESS=tailscale COOLIFY_IP=203.0.113.10
    load_prep --config "$conf"
    [[ $PANEL == coolify && $PANEL_LABEL == Coolify ]]
    [[ $PANEL_PUBKEY == "$pub" ]]
    [[ $PANEL_ACCESS == tailscale ]]
    [[ $PANEL_IP == 203.0.113.10 ]]
}

@test "a config with old and new names: the PANEL_* names win" {
    local conf="$BATS_TEST_TMPDIR/both-names.conf" old new
    make_key old
    make_key new
    old="$(cat "$BATS_TEST_TMPDIR/old.pub")"
    new="$(cat "$BATS_TEST_TMPDIR/new.pub")"
    write_conf "$conf" "COOLIFY_PUBKEY=$old" COOLIFY_ACCESS=tailscale COOLIFY_IP=203.0.113.10 \
        PANEL=dokploy "PANEL_PUBKEY=$new" PANEL_ACCESS=cloudflared PANEL_IP=203.0.113.20
    load_prep --config "$conf"
    [[ $PANEL == dokploy && $PANEL_LABEL == Dokploy ]]
    [[ $PANEL_PUBKEY == "$new" ]]
    [[ $PANEL_ACCESS == cloudflared ]]
    [[ $PANEL_IP == 203.0.113.20 ]]
}
