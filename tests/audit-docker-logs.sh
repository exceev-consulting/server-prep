#!/usr/bin/env bash
# Tests the audit's container log rotation check (docker_log_rotation in server-audit.sh, used by
# dock.log_rotation) on sample /etc/docker/daemon.json files, with jq and without it on PATH (the sed
# and grep reading). Issue #239: only json-file and local take max-size and max-file, so the log
# driver decides, and max-size set for a built-in driver that refuses it is a FAIL (dockerd does not
# start). Also checks that server-audit.sh and server-prep.sh list the same refusing drivers and give
# the same command to remove the options (DOCKER_LOG_OPTS_FIX), and runs that command on a copy with
# sudo and systemctl faked: it must leave the file as it is when jq is missing or cannot read it. No
# root needed and nothing on the host changes: the files are written to a temporary folder.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! tmp="$(mktemp -d)" || [[ -z $tmp || ! -d $tmp ]]; then
    printf 'not ok: mktemp -d failed, no temporary directory for the Docker log rotation tests\n'
    exit 1
fi
trap 'rm -rf "$tmp"' EXIT

# server-audit.sh runs its checks on load, so it cannot be sourced: load only the check, the driver
# list and the one-line have() it calls.
eval "$(sed -n '/^docker_log_rotation() {/,/^}/p' "$SCRIPT_DIR/server-audit.sh")"
eval "$(grep -m1 '^have() {' "$SCRIPT_DIR/server-audit.sh")"
eval "$(grep -m1 '^DOCKER_NO_ROTATION_DRIVERS=' "$SCRIPT_DIR/server-audit.sh")"
eval "$(grep -m1 '^DOCKER_LOG_OPTS_FIX=' "$SCRIPT_DIR/server-audit.sh")"
for fn in docker_log_rotation have; do
    if ! declare -F "$fn" >/dev/null; then
        printf 'not ok: %s not found in server-audit.sh\n' "$fn"
        exit 1
    fi
done
if [[ -z ${DOCKER_NO_ROTATION_DRIVERS:-} ]]; then
    printf 'not ok: DOCKER_NO_ROTATION_DRIVERS not found in server-audit.sh\n'
    exit 1
fi

# The step (server-prep.sh) and the audit must agree on the drivers that refuse max-size and max-file.
prep_list="$(grep -m1 '^DOCKER_NO_ROTATION_DRIVERS=' "$SCRIPT_DIR/server-prep.sh")"
if [[ $prep_list != "DOCKER_NO_ROTATION_DRIVERS=\"$DOCKER_NO_ROTATION_DRIVERS\"" ]]; then
    printf 'not ok: DOCKER_NO_ROTATION_DRIVERS differs: server-audit.sh has "%s", server-prep.sh has %s\n' \
        "$DOCKER_NO_ROTATION_DRIVERS" "${prep_list:-nothing}"
    exit 1
fi
printf 'ok: server-prep.sh and server-audit.sh list the same refusing drivers\n'
# ... and give the same command to remove max-size and max-file (the step's to-do, the audit's fix).
if [[ -z ${DOCKER_LOG_OPTS_FIX:-} ]]; then
    printf 'not ok: DOCKER_LOG_OPTS_FIX not found in server-audit.sh\n'
    exit 1
fi
if [[ "$(grep -m1 '^DOCKER_LOG_OPTS_FIX=' "$SCRIPT_DIR/server-prep.sh")" != "$(grep -m1 '^DOCKER_LOG_OPTS_FIX=' "$SCRIPT_DIR/server-audit.sh")" ]]; then
    printf 'not ok: DOCKER_LOG_OPTS_FIX differs between server-prep.sh and server-audit.sh\n'
    exit 1
fi
printf 'ok: server-prep.sh and server-audit.sh give the same command to remove max-size and max-file\n'

# A PATH without jq: links to the commands the check runs, nothing else.
mkdir -p "$tmp/bin-nojq"
for c in cat tr sed grep; do
    p="$(command -v "$c")" || { printf 'not ok: %s not found on this host\n' "$c"; exit 1; }
    ln -s "$p" "$tmp/bin-nojq/$c"
done

MODE=""      # jq or nojq, set by the loop at the end
expect() {   # expect STATUS LABEL CONTENT [TEXT]: CONTENT "-" means no file; TEXT must be in the message
    local want="$1" label="$2" content="$3" text="${4:-}" f="$tmp/daemon.json"
    rm -f "$f"
    [[ $content == - ]] || printf '%s\n' "$content" > "$f"
    if [[ $MODE == nojq ]]; then
        PATH="$tmp/bin-nojq" docker_log_rotation "$f"
    else
        docker_log_rotation "$f"
    fi
    if [[ $DLR_STATUS != "$want" || $DLR_MSG != *"$text"* ]]; then
        printf 'not ok: %s (%s) gives %s "%s", want %s with "%s"\n' "$label" "$MODE" "$DLR_STATUS" "$DLR_MSG" "$want" "$text"
        exit 1
    fi
    if [[ $want == WARN || $want == FAIL ]] && [[ -z $DLR_FIX ]]; then
        printf 'not ok: %s (%s) gives %s with no fix hint\n' "$label" "$MODE" "$want"
        exit 1
    fi
    # the jq command only when jq read the file: with no jq, or a file jq cannot read, it would stop at jq
    if [[ $want == FAIL ]]; then
        if [[ $MODE == jq ]] && jq -e . >/dev/null 2>&1 <<<"$content"; then
            [[ $DLR_FIX == "$DOCKER_LOG_OPTS_FIX" ]] || {
                printf 'not ok: %s (%s) fix is "%s", want DOCKER_LOG_OPTS_FIX\n' "$label" "$MODE" "$DLR_FIX"; exit 1; }
        elif [[ $DLR_FIX != *'by hand'* || $DLR_FIX == *jq* ]]; then
            printf 'not ok: %s (%s) fix is "%s", want the by-hand hint (jq did not read the file)\n' "$label" "$MODE" "$DLR_FIX"
            exit 1
        fi
    fi
    printf 'ok: %s (%s) gives %s\n' "$label" "$MODE" "$DLR_STATUS"
}

# What the docker step writes on a server with no daemon.json (jq's indented output).
PREP_JSON='{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}'

run_cases() {
    # json-file, Docker's default: rotated only with max-size, as before
    expect WARN 'no daemon.json (json-file by default)' - 'grow without limit'
    expect WARN 'empty daemon.json' '' 'grow without limit'
    expect WARN '{}' '{}' 'grow without limit'
    expect PASS 'what the docker step writes' "$PREP_JSON" 'max-size 10m'
    expect PASS 'max-size with no log-driver (json-file)' '{"log-opts":{"max-size":"50m"}}' 'max-size 50m'
    expect PASS 'one line, json-file and max-size' '{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}' 'json-file'
    expect WARN 'json-file with max-file only' '{"log-driver":"json-file","log-opts":{"max-file":"3"}}' 'grow without limit'
    expect WARN 'json-file with other options only' '{"log-driver":"json-file","log-opts":{"labels":"app"}}' 'grow without limit'
    expect WARN 'an empty log-driver (json-file)' '{"log-driver":"","log-opts":{}}' 'grow without limit'
    # local rotates by default
    expect PASS 'local' '{"log-driver":"local"}' '20m x 5'
    expect PASS 'local with max-size' '{"log-driver":"local","log-opts":{"max-size":"10m","max-file":"3"}}' 'max-size 10m'
    # journald: the journal limits its own size, but refuses max-size and max-file
    expect PASS 'journald' '{"log-driver": "journald"}' 'journal limits its own size'
    expect PASS 'journald with its own options' '{"log-driver":"journald","log-opts":{"tag":"{{.Name}}"}}' 'journal'
    expect FAIL 'journald with max-size and max-file (issue #239)' '{
  "log-driver": "journald",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}' 'Docker will not start'
    expect FAIL 'journald with max-file only' '{"log-driver":"journald","log-opts":{"max-file":"3"}}' 'journald log driver'
    # the other built-in drivers: rotation is up to the log system, and they all refuse max-size
    expect INFO 'syslog to a log server' '{"log-driver": "syslog", "log-opts": {"syslog-address": "udp://192.168.1.50:514"}}' 'logs go to syslog'
    local d
    for d in $DOCKER_NO_ROTATION_DRIVERS; do
        expect FAIL "$d with max-size" "{\"log-driver\":\"$d\",\"log-opts\":{\"max-size\":\"10m\"}}" "the $d log driver"
    done
    expect INFO 'syslog with cache-max-size (dual logging, not max-size)' \
        '{"log-driver":"syslog","log-opts":{"cache-max-size":"20m","cache-max-file":"5"}}' 'logs go to syslog'
    expect INFO 'gelf' '{"log-driver":"gelf","log-opts":{"gelf-address":"udp://192.168.1.50:12201"}}' 'logs go to gelf'
    # none keeps no logs and takes any option; a plugin driver gets the options as they are
    expect INFO 'none' '{"log-driver":"none"}' 'keep no logs'
    expect INFO 'none with max-size (dockerd skips the check)' '{"log-driver":"none","log-opts":{"max-size":"10m"}}' 'keep no logs'
    expect INFO 'Loki plugin with max-size' '{"log-driver":"grafana/loki-docker-driver:2.9.2","log-opts":{"max-size":"10m"}}' 'logs go to grafana/loki-docker-driver:2.9.2'
    expect INFO 'Loki plugin under an alias with max-size' '{"log-driver":"loki","log-opts":{"loki-url":"https://logs.example.com/loki/api/v1/push","max-size":"10m"}}' 'logs go to loki'
    # a file jq cannot read is read as text, so the result does not depend on jq
    expect FAIL 'journald with max-size and a trailing comma' '{"log-driver":"journald","log-opts":{"max-size":"10m",}}' 'Docker will not start'
    expect PASS 'json-file with max-size and CRLF line ends' $'{\r\n  "log-driver": "json-file",\r\n  "log-opts": {"max-size": "10m"}\r\n}' 'max-size 10m'
}

# DOCKER_LOG_OPTS_FIX on a copy: /etc/docker/daemon.json becomes $tmp/fix/daemon.json, sudo runs the
# command as this user and logs it, systemctl only logs. fix_run JQ CONTENT: JQ is jq or nojq (the PATH);
# sets FIX_RC and leaves the file, its .bak and the log in $tmp/fix.
mkdir -p "$tmp/fix" "$tmp/bin-fix-jq" "$tmp/bin-fix-nojq"
printf '#!/bin/sh\nprintf "sudo %%s\\n" "$1" >> "%s/fix/calls"\nexec "$@"\n' "$tmp" > "$tmp/bin-fix-nojq/sudo"
printf '#!/bin/sh\nprintf "systemctl %%s\\n" "$*" >> "%s/fix/calls"\n' "$tmp" > "$tmp/bin-fix-nojq/systemctl"
chmod +x "$tmp/bin-fix-nojq/sudo" "$tmp/bin-fix-nojq/systemctl"
for c in cp tee; do
    p="$(command -v "$c")" || { printf 'not ok: %s not found on this host\n' "$c"; exit 1; }
    ln -s "$p" "$tmp/bin-fix-nojq/$c"
done
cp -P "$tmp/bin-fix-nojq/"* "$tmp/bin-fix-jq/"
if p="$(command -v jq)"; then ln -s "$p" "$tmp/bin-fix-jq/jq"; fi
FIX_RC=0
fix_run() {
    local d="$tmp/fix" cmd
    rm -f "$d/daemon.json" "$d/daemon.json.bak" "$d/calls"
    printf '%s\n' "$2" > "$d/daemon.json"
    cmd="${DOCKER_LOG_OPTS_FIX//"/etc/docker/daemon.json"/"$d/daemon.json"}"
    FIX_RC=0
    PATH="$tmp/bin-fix-$1" "$BASH" -c "$cmd" > "$d/out" 2>&1 || FIX_RC=$?
}
fix_fail() { printf 'not ok: the fix command %s: %s\n' "$1" "$2"; command cat "$tmp/fix/out" "$tmp/fix/calls" 2>/dev/null; exit 1; }
if [[ $DOCKER_LOG_OPTS_FIX != *'/etc/docker/daemon.json'* ]]; then
    fix_fail 'names no /etc/docker/daemon.json' 'update this test'
fi
FIX_SAMPLE='{
  "data-root": "/srv/docker",
  "log-driver": "journald",
  "log-opts": {"max-size": "10m", "max-file": "3", "tag": "{{.Name}}"}
}'
# no jq: the command stops at jq, before it writes or restarts anything
fix_run nojq "$FIX_SAMPLE"
[[ $FIX_RC -ne 0 ]] || fix_fail 'with no jq' 'exits 0'
[[ "$(command cat "$tmp/fix/daemon.json")" == "$FIX_SAMPLE" ]] || fix_fail 'with no jq' 'changed daemon.json'
grep -q 'systemctl' "$tmp/fix/calls" 2>/dev/null && fix_fail 'with no jq' 'restarted Docker'
printf 'ok: the fix command with no jq leaves daemon.json as it is and does not restart Docker\n'
if [[ -e $tmp/bin-fix-jq/jq ]]; then
    # a file jq cannot read: same
    fix_run jq '{"log-driver":"journald","log-opts":{"max-size":"10m",}}'
    [[ $FIX_RC -ne 0 ]] || fix_fail 'on a file jq cannot read' 'exits 0'
    [[ "$(command cat "$tmp/fix/daemon.json")" == '{"log-driver":"journald","log-opts":{"max-size":"10m",}}' ]] ||
        fix_fail 'on a file jq cannot read' 'changed daemon.json'
    grep -q 'systemctl' "$tmp/fix/calls" 2>/dev/null && fix_fail 'on a file jq cannot read' 'restarted Docker'
    printf 'ok: the fix command on a file jq cannot read leaves it as it is and does not restart Docker\n'
    # jq reads it: max-size and max-file go, the rest stays, the original is in .bak, Docker restarts
    fix_run jq "$FIX_SAMPLE"
    [[ $FIX_RC -eq 0 ]] || fix_fail 'with jq' "exits $FIX_RC"
    [[ "$(jq -c -S . "$tmp/fix/daemon.json")" == '{"data-root":"/srv/docker","log-driver":"journald","log-opts":{"tag":"{{.Name}}"}}' ]] ||
        fix_fail 'with jq' "wrote $(command cat "$tmp/fix/daemon.json")"
    [[ "$(command cat "$tmp/fix/daemon.json.bak")" == "$FIX_SAMPLE" ]] || fix_fail 'with jq' 'the .bak is not the original'
    grep -qx 'sudo jq' "$tmp/fix/calls" || fix_fail 'with jq' 'jq does not run as root'
    grep -qx 'systemctl restart docker' "$tmp/fix/calls" || fix_fail 'with jq' 'Docker not restarted'
    printf 'ok: the fix command with jq removes max-size and max-file, keeps the rest and a .bak, restarts Docker\n'
else
    printf 'skip: the fix command with jq (jq not found)\n'
fi

MODE=nojq
if PATH="$tmp/bin-nojq" have jq; then
    printf 'not ok: jq still found on the PATH without jq\n'
    exit 1
fi
run_cases
if have jq; then
    MODE=jq
    run_cases
else
    printf 'skip: Docker log rotation check with jq (jq not found)\n'
fi
