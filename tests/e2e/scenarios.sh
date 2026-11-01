# shellcheck shell=bash disable=SC2034,SC2319
# The end-to-end scenarios, in the order an operator meets them on a new server.
# Sourced by tests/e2e/run.sh. Each sc_* function opens a scenario with begin, records
# assertions with check, and closes it with finish.

# id | group | title, in run order
SCENARIO_TABLE='boot|boot|Boot the official cloud image and log in over SSH
audit-fresh|audit|Audit a fresh server: the audit must catch it
preconfig|preconfig|server-preconfig.sh: check, run without Tailscale, check again
prep-dry-run|server-prep|Dry run with the CI config changes nothing
prep-interactive|server-prep|Interactive dry run: answer every question at a terminal
prep-run|server-prep|Real run with the CI config (Coolify, SSH on 822)
ssh-access|ssh|SSH as a user sees it after server-prep
docker-firewall|firewall|Docker vs firewall: a published port stays closed from outside
audit-prepared|audit|Audit the prepared server: 0 FAIL
prep-rerun|server-prep|Second run changes nothing
reboot|reboot|Reboot: SSH comes back on 822 and the settings stay
audit-rebooted|audit|Audit after the reboot: still 0 FAIL
preconfig-after|preconfig|server-preconfig.sh --check on the finished server'
SCENARIOS=()
declare -A SC_TITLE_OF=() SC_GROUP_OF=()
while IFS='|' read -r _id _group _title; do
    SCENARIOS+=("$_id"); SC_GROUP_OF[$_id]=$_group; SC_TITLE_OF[$_id]=$_title
done <<<"$SCENARIO_TABLE"
unset _id _group _title

VM_REPO=/home/ops/server-prep   # where the operator copied the repo
VM_CFG=/home/ops/ci.cfg         # tests/e2e/ci.cfg plus the keys of this run

# --------------------------------------------------------------------------- helpers

wait_apt_idle() {   # boot-time apt runs make package lists move under a dry run
    # Not "unattended-upgr": that name also matches unattended-upgrade-shutdown, which waits
    # for the shutdown signal all the time. The apt-daily units cover unattended upgrades.
    SSH_LIMIT=660 as_root 'for i in $(seq 1 120); do
        systemctl is-active -q apt-daily.service apt-daily-upgrade.service ||
            pgrep -x "apt|apt-get|dpkg" >/dev/null || exit 0
        sleep 5
    done; exit 1'
}

snapshot() {   # what a dry run must not change: files under /etc, packages, enabled units
    as_root 'find /etc -xdev -type f ! -name "*.cache" -print0 | sort -z | xargs -0 sha256sum
        dpkg-query -W -f "pkg \${Package} \${Version}\n"
        systemctl list-unit-files --no-legend --no-pager | awk "\$2 != \"transient\"" | sort'
}

check_unchanged() {   # check_unchanged BEFORE_FILE: compare a new snapshot with BEFORE_FILE
    local before="$1" after="$WORK/snap-after" d
    wait_apt_idle
    snapshot > "$after"
    d="$(diff "$before" "$after")"
    if [[ -n "$d" ]]; then
        printf '%s\n' "--- changes under /etc, in packages or units:" "$d" >> "$OUT/$SC_ID.log"
    fi
    [[ -z "$d" ]]
    check "nothing changed under /etc, in packages or in enabled units" $? \
        "$(grep -c '^[<>]' <<<"$d") line(s) differ, see the log"
}

report_steps() {   # report_steps FILE: the "What was done" table of a prep report as JSON
    local ids
    # step id for each title, from the run_step lines of server-prep.sh
    ids="$(sed -nE 's/^ *run_step ([a-z]+) +"([^"]+)".*/\2\t\1/p' "$REPO_DIR/server-prep.sh")"
    awk '/^## What was done/{on=1; next} on && /^## /{on=0} on && /^\| [0-9]+ \|/' "$1" |
        awk -F' \\| ' '{print $2 "\t" $3}' |
        jq -R -s --arg ids "$ids" '
            ($ids | split("\n") | map(select(length > 0) | split("\t") | {(.[0]): .[1]}) | add) as $map
            | split("\n") | map(select(length > 0) | split("\t")
            | {step: ($map[.[0]] // .[0]), label: .[0], result: .[1]})'
}

run_prep() {   # run_prep NAME ARGS...: run server-prep.sh as the operator would, keep its report
    local name="$1" rc report
    shift
    SSH_LIMIT=2400 as_root "cd $VM_REPO && ./server-prep.sh $*" < /dev/null 2>&1 | log_to > /dev/null
    rc=${PIPESTATUS[0]}
    # port 22 may be the tarpit now
    [[ $CHANNEL == ops ]] && use_new_port
    report="$(as_root 'ls -t /root/server-prep-reports/server-prep-report-*.md 2>/dev/null | head -1')"
    PREP_REPORT=""
    if [[ -n "$report" ]] && fetch_file "$report" "$name-report.md"; then
        PREP_REPORT="$OUT/$name-report.md"
        attach "$name-report.md"
    fi
    return "$rc"
}

run_audit() {   # run_audit NAME: server-audit.sh as root, JSON kept as audit-NAME.json
    local name="$1" rc
    SSH_LIMIT=600 as_root "mkdir -p /var/tmp/e2e && cd $VM_REPO && bash ./server-audit.sh --no-color --no-network \
        --txt /var/tmp/e2e/audit-$name.txt --json /var/tmp/e2e/audit-$name.json" < /dev/null 2>&1 | log_to > /dev/null
    rc=${PIPESTATUS[0]}
    AUDIT_JSON=""
    [[ -s "$WORK/audits.json" ]] || echo '{}' > "$WORK/audits.json"
    if fetch_file "/var/tmp/e2e/audit-$name.json" "audit-$name.json" && jq -e .summary "$OUT/audit-$name.json" >/dev/null 2>&1; then
        AUDIT_JSON="$OUT/audit-$name.json"
        fetch_file "/var/tmp/e2e/audit-$name.txt" "audit-$name.txt"
        attach "audit-$name.txt" "audit-$name.json"
        jq --arg n "$name" --slurpfile a "$AUDIT_JSON" '.[$n] = ($a[0].summary + {score: $a[0].score})' \
            "$WORK/audits.json" > "$WORK/audits.tmp" && mv "$WORK/audits.tmp" "$WORK/audits.json"
    fi
    return "$rc"
}

audit_status() {   # audit_status ID: status of one check in the last audit, "absent" if not run
    jq -r --arg id "$1" '[.checks[] | select(.id == $id) | .status] | first // "absent"' "$AUDIT_JSON"
}

check_audit_clean() {   # 0 FAIL, and the checks a prepared server must pass
    local id st
    [[ -n "$AUDIT_JSON" ]]; check "the audit writes a JSON report" $?
    [[ -n "$AUDIT_JSON" ]] || return
    check_eq "0 FAIL" "$(jq .summary.fail "$AUDIT_JSON")" 0
    check_eq "the audit exits 0" "$1" 0
    for id in ssh.root_login ssh.password_auth ssh.port ssh.max_auth ssh.allow_users fw.status \
        fw.docker_bypass net.exposure ips.fail2ban ips.crowdsec ips.crowdsec_bouncer ips.f2b_sshd_jail \
        upd.unattended acc.sudo_log acc.password_policy acc.password_dict kern.sysctl mon.auditd \
        dock.log_rotation res.swap panel.root_key; do
        st="$(audit_status "$id")"
        check_eq "$id passes" "$st" PASS
    done
}

check_regressions() {   # the "hard-won gotchas" of AGENTS.md that a reboot or a re-run can undo
    local v
    v="$(as_root 'sysctl -n net.ipv4.conf.all.log_martians')"
    check_eq "net.ipv4.conf.all.log_martians is 1 (UFW's sysctl.conf can reset it)" "$v" 1
    v="$(as_root 'sysctl -n fs.suid_dumpable')"
    check_eq "fs.suid_dumpable is 0 (apport can reset it)" "$v" 0
    as_root '! grep -qs "log_martians=0" /etc/ufw/sysctl.conf'
    check "/etc/ufw/sysctl.conf does not turn log_martians off" $?
    as_root 'iptables -S DOCKER-USER 2>/dev/null | grep -q ufw-user-forward'
    check "the DOCKER-USER chain sends traffic through UFW (ufw-docker)" $?
    v="$(as_root 'dpkg-query -W -f "\${Version}" crowdsec 2>/dev/null')"
    [[ -n "$v" && ! "$v" =~ ubuntu|deb|esm ]]
    check "CrowdSec comes from packagecloud, not an old distro or ESM build" $? "version '$v'"
    as_root 'ss -Hltn "sport = :8091" | grep -q LISTEN'
    check "the CrowdSec API listens on 8091, away from Traefik's 8080" $?
    as_root 'test -e /var/cache/cracklib/cracklib_dict.pwd'
    check "the cracklib dictionary exists, so passwd works" $?
    if as_root 'sudo --version 2>/dev/null | head -1 | grep -q sudo-rs'; then
        as_root '! grep -rqs "^Defaults.*logfile" /etc/sudoers /etc/sudoers.d'
        check "sudo-rs: no Defaults logfile line, which it rejects" $?
    else
        as_root 'grep -rqs "^Defaults.*logfile" /etc/sudoers /etc/sudoers.d && visudo -c >/dev/null'
        check "sudo logs to a file and visudo accepts the config" $?
    fi
    if as_root 'systemctl cat apport.service >/dev/null 2>&1'; then
        v="$(as_root 'systemctl is-active apport.service')"
        [[ "$v" != active ]]
        check "apport is not running" $? "$v"
    fi
}

wait_services() {   # what the audit needs settled: services up, AIDE's first database, a calm CPU
    SSH_LIMIT=1500 as_root 'for i in $(seq 1 60); do
        systemctl is-active -q docker crowdsec crowdsec-firewall-bouncer && break; sleep 5; done
        # [a]: the pattern must not match the command line of this very shell
        for i in $(seq 1 180); do pgrep -f "[a]ideinit|[a]ide --init" >/dev/null || break; sleep 5; done
        for i in $(seq 1 36); do
            awk -v n="$(nproc)" "{exit !(\$1 < 0.7 * n)}" /proc/loadavg && break; sleep 5; done
        true' < /dev/null
}

check_tarpit() {   # where the endlessh package exists, the tarpit must really listen on 22
    if ! as_root 'systemctl cat endlessh.service >/dev/null 2>&1'; then
        printf 'endlessh is not installed on this release\n' >> "$OUT/$SC_ID.log"
        return 0
    fi
    as_root 'systemctl is-active -q endlessh && ss -Hltn "sport = :22" | grep -q LISTEN'
    check "the endlessh tarpit is running on port 22" $? "$(as_root 'systemctl is-active endlessh; journalctl -u endlessh -n 3 --no-pager -o cat' 2>&1 | tr '\n' ' ' | head -c 300)"
}

no_ssh_banner() {   # no_ssh_banner PORT: true when the port gives no SSH greeting (closed or tarpit)
    local line=""
    { exec 3<>"/dev/tcp/127.0.0.1/$1"; } 2>/dev/null || return 0
    IFS= read -r -t 12 line <&3
    exec 3<&- 3>&-
    [[ "$line" != SSH-* ]]
}

# --------------------------------------------------------------------------- scenarios

sc_boot() {
    begin boot
    image_get >> "$OUT/$SC_ID.log" 2>&1
    [[ -f "$IMAGE" ]]; check "the image matches its published checksum" $? "${IMAGE_CHECKSUM:-none}"
    [[ -f "$IMAGE" ]] || { finish; return 1; }
    make_keys && make_seed
    vm_start >> "$OUT/$SC_ID.log" 2>&1
    vm_running; check "QEMU starts the VM ($ACCEL)" $?
    vm_running || { finish; return 1; }
    wait_ssh ops ops "$P22" "$BOOT_TIMEOUT"
    check "the cloud-init user logs in over SSH on port 22" $?
    if ! ssh_as ops ops "$P22" true 2>/dev/null; then finish; return 1; fi
    local st
    SSH_LIMIT=900 ssh_as ops ops "$P22" 'cloud-init status --wait' 2>&1 | log_to > /dev/null
    st=${PIPESTATUS[0]}
    [[ $st -eq 0 || $st -eq 2 ]]; check "cloud-init finishes" $? "exit $st"
    VM_OS_RELEASE="$(ssh_as ops ops "$P22" '. /etc/os-release && echo "$PRETTY_NAME"')"
    VM_KERNEL="$(ssh_as ops ops "$P22" 'uname -r')"
    copy_repo; check "the operator copies the repo to the server" $?
    { cat "$E2E_DIR/ci.cfg"
      printf 'ADMIN_PUBKEY="%s"\nPANEL_PUBKEY="%s"\n' "$(cat "$WORK/keys/admin.pub")" "$(cat "$WORK/keys/panel.pub")"
    } | ssh_as ops ops "$P22" "cat > $VM_CFG"
    check "the test config is on the server" $?
    VM_UP=1
    finish
}

sc_audit_fresh() {
    begin audit-fresh
    local rc id
    run_audit fresh; rc=$?
    check_eq "the audit exits 1" "$rc" 1
    [[ -n "$AUDIT_JSON" ]]; check "the audit writes a JSON report" $?
    if [[ -n "$AUDIT_JSON" ]]; then
        for id in fw.status ips.any acc.password_policy kern.sysctl ssh.password_auth; do
            check_eq "$id fails" "$(audit_status "$id")" FAIL
        done
    fi
    finish
}

# server-preconfig.sh pings 1.1.1.1. Cloud runners often block ICMP, so that one FAIL is
# accepted when the VM can't ping but reaches the internet over HTTPS.
preconfig_fails() {   # preconfig_fails LOG: the FAIL lines that are not explained by blocked ICMP
    local fails
    fails="$(ansi_strip < "$1" | grep -E '^  FAIL ' || true)"
    if [[ $NO_ICMP -eq 1 ]]; then fails="$(grep -v 'no internet (ping 1.1.1.1)' <<<"$fails" || true)"; fi
    printf '%s' "$fails"
}

sc_preconfig() {
    begin preconfig
    local rc fails log="$WORK/preconfig.out"
    if as_root 'ping -c1 -W3 1.1.1.1 >/dev/null 2>&1'; then NO_ICMP=0; else NO_ICMP=1; fi
    as_root 'curl -fsS -o /dev/null --max-time 20 https://deb.debian.org/'
    check "the VM reaches the internet over HTTPS" $? "ICMP blocked: $NO_ICMP"
    as_root "cd $VM_REPO && ./server-preconfig.sh --check --user ops" < /dev/null > "$log" 2>&1
    rc=$?; log_to < "$log" > /dev/null
    grep -q '== Result ==' "$log"; check "--check on a fresh server prints its result (exit $rc)" $?
    SSH_LIMIT=900 as_root "cd $VM_REPO && ./server-preconfig.sh --hostname e2e-web-01 --user ops --no-tailscale --yes" \
        < /dev/null > "$log" 2>&1
    rc=$?; log_to < "$log" > /dev/null
    fails="$(preconfig_fails "$log")"
    [[ -z "$fails" ]]; check "a run without Tailscale reports no FAIL" $? "${fails//$'\n'/; }"
    as_root "cd $VM_REPO && ./server-preconfig.sh --check --user ops" < /dev/null > "$log" 2>&1
    rc=$?; log_to < "$log" > /dev/null
    fails="$(preconfig_fails "$log")"
    [[ -z "$fails" ]]; check "--check after the run reports no FAIL" $? "${fails//$'\n'/; }"
    check_eq "the hostname is e2e-web-01" "$(as_root 'hostname')" e2e-web-01
    finish
}

sc_prep_dry_run() {
    begin prep-dry-run
    local rc
    wait_apt_idle
    snapshot > "$WORK/snap-before"
    run_prep dry-run --config "$VM_CFG" --yes --dry-run; rc=$?
    check_eq "the dry run exits 0" "$rc" 0
    grep -q 'WOULD CHANGE' "$OUT/$SC_ID.log"; check "the plan lists steps that would change" $?
    check_unchanged "$WORK/snap-before"
    finish
}

sc_prep_interactive() {
    begin prep-interactive
    local rc unanswered
    wait_apt_idle
    snapshot > "$WORK/snap-before"
    interact "$OUT/prep-interactive-screen.log" ops ops "$P22" "cd $VM_REPO && sudo ./server-prep.sh --dry-run"
    rc=$?
    attach prep-interactive-screen.log
    check_eq "the interactive dry run exits 0" "$rc" 0
    grep -q '\[e2e\] answered "y" to: Proceed?' "$OUT/prep-interactive-screen.log"
    check "the plan is shown and confirmed" $?
    unanswered="$(grep -c '^\[e2e\] kept the default for' "$OUT/prep-interactive-screen.log")"
    printf 'questions left at their default: %s\n' "$unanswered" >> "$OUT/$SC_ID.log"
    grep -q 'Mode .*DRY-RUN' "$OUT/prep-interactive-screen.log"; check "the plan says DRY-RUN" $?
    check_unchanged "$WORK/snap-before"
    finish
}

sc_prep_run() {
    begin prep-run
    local rc failed
    run_prep first --config "$VM_CFG" --yes; rc=$?
    check_eq "server-prep.sh exits 0" "$rc" 0
    [[ -n "$PREP_REPORT" ]]; check "the report is written" $?
    if [[ -n "$PREP_REPORT" ]]; then
        report_steps "$PREP_REPORT" > "$WORK/steps-first.json"
        failed="$(jq -r '[.[] | select(.result == "FAILED") | .step] | join(", ")' "$WORK/steps-first.json")"
        [[ -z "$failed" ]]; check "no step FAILED" $? "$failed"
    fi
    [[ $CHANNEL == root ]] && PREP_DONE=1
    [[ $PREP_DONE -eq 1 ]]; check "the panel key logs in as root on port 822" $?
    finish
}

sc_ssh_access() {
    begin ssh-access
    local out pw rc
    check_eq "the admin logs in with their key on 822" "$(ssh_as admin admin "$P822" 'id -un' 2>&1)" admin
    pw="$(as_root 'cat /etc/server-prep/admin.initial-password 2>/dev/null')"
    [[ -n "$pw" ]]; check "the admin's first sudo password is saved for them" $?
    if [[ -n "$pw" ]]; then
        printf '%s\n' "$pw" | ssh_as admin admin "$P822" 'sudo -S -k -p "" true' > /dev/null 2>&1
        check "the admin can use sudo with that password" $?
    fi
    ! ssh_as ops ops "$P822" true 2>/dev/null
    check "the cloud-init user is refused (only the admin may log in)" $?
    out="$(timeout 30 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
        -o ConnectTimeout=15 -o PreferredAuthentications=none -o LogLevel=DEBUG1 \
        -p "$P822" nobody@127.0.0.1 true 2>&1 |
        tr -d '\r' | sed -n 's/.*Authentications that can continue: //p' | head -1)"
    check_eq "the server offers keys only" "$out" publickey
    ! ssh_as root admin "$P822" true 2>/dev/null
    check "root is refused with the admin's key" $?
    as_root "install -m 600 /dev/stdin /root/e2e-panel-key" < "$WORK/keys/panel"
    as_root "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
        -o ConnectTimeout=10 -i /root/e2e-panel-key -p 822 root@$VM_GUEST_IP true" < /dev/null > /dev/null 2>&1
    rc=$?
    as_root 'rm -f /root/e2e-panel-key'
    [[ $rc -ne 0 ]]; check "root is refused from an address that is not the panel's" $?
    no_ssh_banner "$P22"; check "port 22 gives no SSH login any more" $?
    check_tarpit
    finish
}

sc_docker_firewall() {
    begin docker-firewall
    local token="e2e-$RANDOM$RANDOM" got
    # Any small image with an HTTP server will do. Shared runner IPs hit registry pull limits
    # ("Data limit exceeded"), so try a few registries in turn.
    SSH_LIMIT=600 as_root "for img in mirror.gcr.io/library/busybox:stable public.ecr.aws/docker/library/busybox:stable \
            docker.io/library/busybox:stable; do docker pull -q \$img && docker tag \$img e2e-busybox && break; done
        docker run -d --name e2e-web -p $VM_DOCKER_PORT:80 e2e-busybox \
        sh -c 'mkdir -p /w && echo $token > /w/index.html && exec httpd -f -p 80 -h /w'" < /dev/null 2>&1 | log_to > /dev/null
    sleep 3
    got="$(as_root "curl -fsS --max-time 10 http://127.0.0.1:$VM_DOCKER_PORT/" 2>/dev/null)"
    check_eq "the container answers inside the server" "$got" "$token"
    got="$(curl -sS --max-time 15 "http://127.0.0.1:$PDOCK/" 2>&1)"
    [[ "$got" != *"$token"* ]]; check "the published port does not answer from outside" $? "${got:0:120}"
    # Control: once UFW allows the route, the same request must get through, which
    # shows the test above really goes through the firewall.
    as_root 'ufw route allow proto tcp from any to any port 80' 2>&1 | log_to > /dev/null
    got="$(curl -sS --max-time 15 "http://127.0.0.1:$PDOCK/" 2>&1)"
    check_eq "control: with 'ufw route allow' the port answers from outside" "$got" "$token"
    as_root 'ufw route delete allow proto tcp from any to any port 80' 2>&1 | log_to > /dev/null
    as_root 'docker rm -f e2e-web; docker image ls --format "{{.Repository}}:{{.Tag}}" | grep busybox | xargs -r docker image rm' 2>&1 | log_to > /dev/null
    finish
}

sc_audit_prepared() {
    begin audit-prepared
    local rc
    wait_services
    run_audit prepared; rc=$?
    check_audit_clean "$rc"
    check_regressions
    finish
}

sc_prep_rerun() {
    begin prep-rerun
    local rc moved chain
    run_prep second --config "$VM_CFG" --yes; rc=$?
    check_eq "server-prep.sh exits 0" "$rc" 0
    if [[ -n "$PREP_REPORT" ]]; then
        report_steps "$PREP_REPORT" > "$WORK/steps-second.json"
        moved="$(jq -r '[.[] | select(.result != "OK (already)" and .result != "SKIPPED")
            | "\(.step) \(.result)"] | join(", ")' "$WORK/steps-second.json")"
        [[ -z "$moved" ]]; check "every step is OK (already) or SKIPPED" $? "$moved"
    else
        check "the report is written" 1
    fi
    # The to-do for a panel that installs Docker later says to re-run the firewall step alone.
    run_prep firewall-only --config "$VM_CFG" --yes --only firewall; rc=$?
    check_eq "a firewall-only run exits 0" "$rc" 0
    chain="$(as_root 'for i in $(seq 1 15); do iptables -S DOCKER-USER | grep -q CROWDSEC && break; sleep 2; done
        iptables -S DOCKER-USER')"
    printf 'DOCKER-USER after the firewall-only run:\n%s\n' "$chain" >> "$OUT/$SC_ID.log"
    grep -q -- '-j ufw-user-forward' <<<"$chain"
    check "after it, DOCKER-USER still goes through UFW" $? "$(head -c 300 <<<"$chain")"
    grep -q CROWDSEC <<<"$chain"
    check "after it, DOCKER-USER still goes through CrowdSec" $? "$(head -c 300 <<<"$chain")"
    finish
}

sc_reboot() {
    begin reboot
    local failed
    vm_reboot "$BOOT_TIMEOUT"; check "the server reboots and root logs in again on 822" $?
    as_root 'systemctl is-system-running --wait >/dev/null 2>&1; systemctl --failed --no-legend --plain' \
        > "$WORK/failed-units" 2>&1
    failed="$(awk '{print $1}' "$WORK/failed-units" | paste -sd' ')"
    [[ -z "$failed" ]]; check "no systemd unit failed at boot" $? "$failed"
    check_eq "the admin logs in on 822" "$(ssh_as admin admin "$P822" 'id -un' 2>&1)" admin
    no_ssh_banner "$P22"; check "port 22 still gives no SSH login" $?
    check_tarpit
    finish
}

sc_audit_rebooted() {
    begin audit-rebooted
    local rc
    wait_services
    run_audit rebooted; rc=$?
    check_audit_clean "$rc"
    check_regressions
    finish
}

sc_preconfig_after() {
    begin preconfig-after
    local fails log="$WORK/preconfig.out"
    as_root "cd $VM_REPO && ./server-preconfig.sh --check --user admin" < /dev/null > "$log" 2>&1
    log_to < "$log" > /dev/null
    fails="$(preconfig_fails "$log")"
    [[ -z "$fails" ]]; check "--check reports no FAIL" $? "${fails//$'\n'/; }"
    finish
}

# --------------------------------------------------------------------------- order

needs() {   # needs SCENARIO-ID: skip it when the server is not in the state it needs
    case $1 in
        boot) return 0 ;;
        audit-fresh|preconfig|prep-dry-run|prep-interactive|prep-run)
            [[ $VM_UP -eq 1 ]] || { SKIP_REASON="the VM did not boot"; return 1; } ;;
        *)  [[ $PREP_DONE -eq 1 ]] || { SKIP_REASON="the real server-prep run did not finish"; return 1; } ;;
    esac
}
