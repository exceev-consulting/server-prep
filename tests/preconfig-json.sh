#!/usr/bin/env bash
# Tests `server-preconfig.sh --check --json` (issue #13) with every host command it calls replaced by a
# read-only fake on PATH: one JSON object on stdout, lines for people on stderr, the same exit code and
# counts as without --json, and no TS_AUTHKEY in the output. No root needed and nothing on the host changes.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRE="$SCRIPT_DIR/server-preconfig.sh"

# jq reads the JSON. CI has it; on a machine without it, skip instead of failing the whole suite.
if ! command -v jq >/dev/null 2>&1; then
    printf 'ok: skip server-preconfig.sh --check --json tests (jq missing)\n'
    exit 0
fi
# server-preconfig.sh stops on other systems before its checks.
os_info=$(. /etc/os-release 2>/dev/null; echo "${ID:-} ${ID_LIKE:-}")
if [[ " $os_info " != *" debian "* && " $os_info " != *" ubuntu "* ]]; then
    printf 'ok: skip server-preconfig.sh --check --json tests (not Debian/Ubuntu)\n'
    exit 0
fi

# Stop before any path is built if mktemp fails: an empty $tmp would put the fakes in /bin.
if ! tmp="$(mktemp -d)" || [[ -z $tmp || ! -d $tmp ]]; then
    printf 'not ok: mktemp -d failed, no temporary directory for the fakes\n'
    exit 1
fi
trap 'rm -rf "$tmp"' EXIT
stub="$tmp/bin"
mkdir -p "$stub" "$tmp/home/.ssh"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForTestsOnly test@example.com\n' > "$tmp/home/.ssh/authorized_keys"

# Fakes for the commands the --check path calls. They only print: nothing reaches the real host.
cat > "$stub/ip" <<'EOF'
#!/bin/sh
case "$*" in
    "-4 route show default") echo "default via 192.168.1.1 dev eth0 proto static" ;;
    "-4 -o addr show dev eth0 scope global") echo "2: eth0    inet 192.168.1.50/24 brd 192.168.1.255 scope global eth0" ;;
    *) exit 1 ;;
esac
EOF
cat > "$stub/systemctl" <<'EOF'
#!/bin/sh
case "$1 $2" in
    "is-enabled ssh"|"is-enabled tailscaled"|"is-enabled networking") echo enabled ;;
    is-enabled\ *.target) echo masked ;;
    *) exit 1 ;;
esac
EOF
cat > "$stub/ping" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$stub/tailscale" <<'EOF'
#!/bin/sh
case "$*" in
    "status --json") printf '{"BackendState":"%s","Self":{"HostName":"web-01","KeyExpiry":"2027-01-01T00:00:00Z"}}\n' "${STUB_TS_STATE:-Running}" ;;
    "ip -4") echo 100.x.y.z ;;
    *) exit 1 ;;
esac
EOF
cat > "$stub/getent" <<'EOF'
#!/bin/sh
case "$1" in
    hosts) echo "192.0.2.10      debian.org" ;;
    passwd) if [ -z "${2:-}" ] || [ "$2" = admin ]; then echo "admin:x:1000:1000::$STUB_HOME:/bin/bash"; else exit 2; fi ;;
    *) exit 2 ;;
esac
EOF
cat > "$stub/id" <<'EOF'
#!/bin/sh
if [ "${1:-}" = -nG ]; then echo "admin sudo"; fi
exit 0
EOF
cat > "$stub/hostname" <<'EOF'
#!/bin/sh
echo web-01
EOF
cat > "$stub/systemd-detect-virt" <<'EOF'
#!/bin/sh
echo kvm
EOF
cat > "$stub/ifquery" <<'EOF'
#!/bin/sh
echo "address: 192.168.1.50/24"
EOF
chmod +x "$stub"/*

STUB_TS_STATE=Running
run_pre() {   # run_pre NAME ARGS...: runs server-preconfig.sh with the fakes, output in $tmp/NAME.out/.err
    local name=$1 status=0
    shift
    env -u SUDO_USER PATH="$stub:$PATH" STUB_HOME="$tmp/home" STUB_TS_STATE="$STUB_TS_STATE" \
        TS_AUTHKEY=canary-not-a-key bash "$PRE" "$@" >"$tmp/$name.out" 2>"$tmp/$name.err" </dev/null || status=$?
    return "$status"
}

dump() {   # dump NAME: show what the run printed
    printf '%s\n' "--- stdout:"; cat "$tmp/$1.out"
    printf '%s\n' "--- stderr:"; cat "$tmp/$1.err"
}

not_ok() {   # not_ok NAME "message"
    printf 'not ok: %s\n' "$2"
    dump "$1"
    exit 1
}

expect_jq() {   # expect_jq NAME "label" FILTER: FILTER must be true on the JSON of run NAME
    if ! jq -e "$3" "$tmp/$1.out" >/dev/null 2>&1; then
        not_ok "$1" "$2 (jq: $3)"
    fi
    printf 'ok: %s\n' "$2"
}

counts_line() { grep -oE '^  [0-9]+ FAIL, [0-9]+ WARN$' "$1" | tail -1; }

expect_common() {   # expect_common NAME STATUS: checks every --check --json run must pass
    local name=$1 status=$2 root_bool=false line want
    [[ $EUID -eq 0 ]] && root_bool=true
    [[ $status -eq 0 || $status -eq 1 ]] || not_ok "$name" "--check --json exited $status, want 0 or 1"
    if ! jq -e -s 'length == 1 and (.[0] | type == "object")' "$tmp/$name.out" >/dev/null 2>&1; then
        not_ok "$name" "stdout is not exactly one JSON object"
    fi
    [[ $(wc -l < "$tmp/$name.out") -eq 1 ]] || not_ok "$name" "the JSON is not on one line"
    printf 'ok: %s: stdout is one JSON object on one line\n' "$name"
    expect_jq "$name" "$name: tool and schema_version" '.tool == "server-preconfig" and .schema_version == 1'
    expect_jq "$name" "$name: root is $root_bool" ".root == $root_bool"
    expect_jq "$name" "$name: date is ISO 8601 with an offset" \
        '.date | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([+-][0-9]{2}:[0-9]{2}|Z)$")'
    expect_jq "$name" "$name: facts from the fakes" \
        '.facts.virt == "kvm" and .facts.iface == "eth0" and .facts.cidr == "192.168.1.50/24" and .facts.gateway == "192.168.1.1" and .facts.tailscale_ip == "100.x.y.z" and .facts.admin == "admin" and (.facts.os | length > 0) and (.facts.net_manager | length > 0)'
    expect_jq "$name" "$name: every status is PASS, WARN, FAIL or INFO" \
        '[.checks[].status] | all(. == "PASS" or . == "WARN" or . == "FAIL" or . == "INFO")'
    expect_jq "$name" "$name: every check has a string id, message and fix" \
        '.checks | length > 0 and all(.[]; (.id | type == "string") and (.message | type == "string") and (.fix | type == "string"))'
    expect_jq "$name" "$name: ids are unique" '[.checks[].id] | length == (unique | length)'
    expect_jq "$name" "$name: the checks that always run are there" \
        '[.checks[].id] as $ids | (["pre.hostname","pre.gateway","pre.internet","pre.dns","pre.ssh_boot","pre.tailscaled_boot","pre.sleep","pre.tailscale","pre.admin_sudo","pre.admin_keys","pre.bios"] | all(. as $i | $ids | index($i)))
            and ($ids | index("pre.net_saved") or index("pre.net_valid"))'
    expect_jq "$name" "$name: summary matches the checks" \
        '.summary as $s | [.checks[].status] as $st
            | $s.pass == ($st | map(select(. == "PASS")) | length) and $s.warn == ($st | map(select(. == "WARN")) | length)
              and $s.fail == ($st | map(select(. == "FAIL")) | length) and $s.info == ($st | map(select(. == "INFO")) | length)'
    line=$(counts_line "$tmp/$name.err")
    want=$(jq -r '"  \(.summary.fail) FAIL, \(.summary.warn) WARN"' "$tmp/$name.out")
    [[ -n $line && $line == "$want" ]] || not_ok "$name" "stderr says '$line', summary says '$want'"
    printf 'ok: %s: the line for people (%s) matches the summary\n' "$name" "${line#  }"
    if grep -q canary-not-a-key "$tmp/$name.out" "$tmp/$name.err"; then not_ok "$name" "TS_AUTHKEY reached the output"; fi
    printf 'ok: %s: TS_AUTHKEY is not in the output\n' "$name"
}

expect_same_as_text() {   # expect_same_as_text NAME STATUS: the run without --json gives the same status and counts
    local name=$1 status=$2 text_status=0 a b
    run_pre "$name-text" --check || text_status=$?
    [[ $text_status -eq $status ]] || not_ok "$name-text" "--check exited $text_status, --check --json exited $status"
    a=$(counts_line "$tmp/$name-text.out"); b=$(counts_line "$tmp/$name.err")
    [[ -n $a && $a == "$b" ]] || not_ok "$name-text" "--check says '$a', --check --json says '$b'"
    if grep -q canary-not-a-key "$tmp/$name-text.out" "$tmp/$name-text.err"; then not_ok "$name-text" "TS_AUTHKEY reached the output"; fi
    printf 'ok: %s: --check without --json exits %s with the same counts\n' "$name" "$status"
}

# Tailscale connected, key expiry on: a WARN whose fix is in .fix, not in .message.
STUB_TS_STATE=Running
status=0; run_pre running --check --json || status=$?
expect_common running "$status"
expect_jq running "running: Tailscale connected" '.checks[] | select(.id == "pre.tailscale") | .status == "PASS"'
expect_jq running "running: key expiry WARN with its fix apart" \
    '.checks[] | select(.id == "pre.tailscale_expiry") | .status == "WARN" and (.fix | contains("Disable key expiry")) and (.message | contains("Disable key expiry") | not)'
grep -q '^        fix: .*Disable key expiry' "$tmp/running.err" || not_ok running "the fix line for people is missing"
printf 'ok: running: people still see the fix line\n'
expect_same_as_text running "$status"

# Tailscale not logged in: FAIL with its fix, exit 1 with and without --json.
STUB_TS_STATE=NeedsLogin
status=0; run_pre needslogin --check --json || status=$?
expect_common needslogin "$status"
[[ $status -eq 1 ]] || not_ok needslogin "--check --json exited $status with a FAIL, want 1"
expect_jq needslogin "needslogin: Tailscale FAIL with 'sudo tailscale up'" \
    '.checks[] | select(.id == "pre.tailscale") | .status == "FAIL" and .fix == "sudo tailscale up"'
expect_jq needslogin "needslogin: no key expiry check" '[.checks[].id] | index("pre.tailscale_expiry") | not'
expect_jq needslogin "needslogin: tailscale_state fact" '.facts.tailscale_state == "NeedsLogin"'
expect_same_as_text needslogin "$status"

# --json without --check is a usage error, before the root check. Only as non-root: there, a broken
# check stops at "Run as root" (exit 1) instead of starting a real run.
if [[ $EUID -ne 0 ]]; then
    for args in "--json" "--json --yes"; do
        status=0
        # shellcheck disable=SC2086
        run_pre usage $args || status=$?
        if [[ $status -ne 2 ]] || ! grep -q -- '--json works only with --check' "$tmp/usage.err"; then
            not_ok usage "$args exited $status, want 2 and '--json works only with --check'"
        fi
        [[ -s $tmp/usage.out ]] && not_ok usage "$args printed on stdout"
        printf 'ok: server-preconfig.sh %s exits 2\n' "$args"
    done
else
    printf 'ok: skip the --json usage cases as root\n'
fi

bash "$PRE" --help | grep -q -- '--json' || { printf 'not ok: --help does not list --json\n'; exit 1; }
printf 'ok: --help lists --json\n'

printf 'ok: all server-preconfig.sh --check --json cases\n'
