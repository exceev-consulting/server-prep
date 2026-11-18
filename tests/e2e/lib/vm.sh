# shellcheck shell=bash disable=SC2034
# VM helpers for tests/e2e/run.sh: cloud image, cloud-init seed, QEMU, SSH.
# Sourced, not run. Uses the globals set by run.sh (E2E_DIR, REPO_DIR, CACHE_DIR, WORK, OUT, OS_*).

# The VM's user network uses a documentation range, so UFW and ufw-docker treat the
# host as a public client. QEMU answers for the host on .2 and gives the guest .15.
VM_NET=198.51.100.0/24
VM_HOST_IP=198.51.100.2
VM_GUEST_IP=198.51.100.15
VM_DOCKER_PORT=18080   # guest port the firewall test publishes a container on

# Debian copies each new build of its cloud images over latest/, in place, so while a build is
# published latest/SHA512SUMS can lack the image or not match it yet (issue #212). Each build
# also has its own dated folder (trixie/20261111-2659/), which no longer changes once published.
# A row whose URLs hold {build} uses those folders: the newest build whose checksum file lists
# the image and whose image downloads with that checksum, else the one before it (BUILD_TRIES).
# Until a build is picked, its URLs name the page that lists the builds, never {build}.
BUILD_TAG='{build}'
BUILD_TRIES=3

os_load() {   # os_load ID: read the row of tests/e2e/images.tsv into OS_*
    local id="$1" row
    row="$(awk -F'\t' -v id="$id" '!/^#/ && $1 == id' "$E2E_DIR/images.tsv")"
    [[ -n "$row" ]] || return 1
    IFS=$'\t' read -r OS_ID OS_LABEL OS_IMAGE_TEMPLATE OS_SUMS_TEMPLATE OS_ALGO <<<"$row"
    OS_IMAGE_URL="$OS_IMAGE_TEMPLATE" OS_SUMS_URL="$OS_SUMS_TEMPLATE"
    if os_dated; then os_use_index; fi
}

os_list() { awk -F'\t' '!/^#/ && NF {print $1}' "$E2E_DIR/images.tsv"; }

os_dated() { [[ $OS_IMAGE_TEMPLATE == *"$BUILD_TAG"* ]]; }   # the row picks a dated build folder

os_build_index() { echo "${OS_SUMS_TEMPLATE%%"$BUILD_TAG"*}"; }   # the page that lists the builds

os_use_build() {   # os_use_build BUILD: point OS_IMAGE_URL and OS_SUMS_URL at that build's folder
    OS_IMAGE_URL="${OS_IMAGE_TEMPLATE//"$BUILD_TAG"/$1}"
    OS_SUMS_URL="${OS_SUMS_TEMPLATE//"$BUILD_TAG"/$1}"
}

# os_use_index: no build picked yet, so OS_IMAGE_URL and OS_SUMS_URL name the build list, a real
# page, for the report link and the error messages
os_use_index() { OS_IMAGE_URL="$(os_build_index)" OS_SUMS_URL="$(os_build_index)"; }

fetch() {   # fetch URL FILE: download with retries, atomically
    local url="$1" file="$2" try
    for try in 1 2 3; do
        if curl -fsSL --retry 2 --connect-timeout 20 -o "$file.part" "$url"; then
            mv -f "$file.part" "$file"
            return 0
        fi
        sleep $((try * 5))
    done
    rm -f "$file.part"
    return 1
}

os_builds() {   # os_builds: the dated build folders of the row, newest first, at most BUILD_TRIES
    local index="$CACHE_DIR/images/$OS_ID.index"
    mkdir -p "$CACHE_DIR/images"
    fetch "$(os_build_index)" "$index" || return 1
    grep -oE 'href="[0-9]{8}-[0-9]+/"' "$index" | sed -E 's/^href="//; s/\/"$//' |
        sort -u -t- -k1,1nr -k2,2nr | head -n "$BUILD_TRIES"
}

image_checksum() {   # image_checksum: expected checksum of the image, from the published sums file
    local sums="$CACHE_DIR/images/$OS_ID.sums" name="${OS_IMAGE_URL##*/}"
    mkdir -p "$CACHE_DIR/images"
    fetch "$OS_SUMS_URL" "$sums" || return 1
    # Debian: "<sum>  <name>", Ubuntu: "<sum> *<name>"
    awk -v n="$name" '$2 == n || $2 == "*" n {print $1; exit}' "$sums"
}

image_there() {   # image_there: the image at OS_IMAGE_URL answers a HEAD request (no download)
    curl -fsIL --retry 2 --connect-timeout 20 -o /dev/null "$OS_IMAGE_URL"
}

# image_resolve: for a dated row, use the newest build whose sums file lists the image and whose
# image is there. That is the build image_get boots unless its image does not match: run.sh
# --image-key names the CI image cache after it, so the cache must not get an older build's image.
image_resolve() {
    local builds b
    os_dated || return 0
    os_use_index
    builds="$(os_builds)" || { echo "cannot read $(os_build_index)" >&2; return 1; }
    for b in $builds; do
        os_use_build "$b"
        [[ -n "$(image_checksum)" ]] && image_there && return 0
    done
    os_use_index
    echo "no build listed in $(os_build_index) has its image and its checksum" >&2
    return 1
}

image_fetch() {   # image_fetch: make sure $IMAGE is the image at OS_IMAGE_URL, downloading it if needed
    local want got
    want="$(image_checksum)" || { echo "cannot read $OS_SUMS_URL" >&2; return 1; }
    [[ -n "$want" ]] || { echo "no checksum for ${OS_IMAGE_URL##*/} in $OS_SUMS_URL" >&2; return 1; }
    if [[ -f "$IMAGE" ]]; then
        got="$("${OS_ALGO}sum" "$IMAGE" | cut -d' ' -f1)"
        [[ "$got" == "$want" ]] && { IMAGE_CHECKSUM="$OS_ALGO:$want"; return 0; }
        echo "cached image is out of date, downloading again" >&2
    fi
    fetch "$OS_IMAGE_URL" "$IMAGE" || { echo "cannot download $OS_IMAGE_URL" >&2; return 1; }
    got="$("${OS_ALGO}sum" "$IMAGE" | cut -d' ' -f1)"
    if [[ "$got" != "$want" ]]; then
        rm -f "$IMAGE"
        echo "checksum mismatch for ${OS_IMAGE_URL##*/}" >&2
        return 1
    fi
    IMAGE_CHECKSUM="$OS_ALGO:$want"
}

image_get() {   # image_get: make sure $IMAGE is the published image, downloading it if needed
    local builds b
    IMAGE="$CACHE_DIR/images/$OS_ID.img" IMAGE_CHECKSUM=""
    os_dated || { image_fetch; return; }
    os_use_index
    builds="$(os_builds)" || { echo "cannot read $(os_build_index)" >&2; return 1; }
    [[ -n "$builds" ]] || { echo "no build folder listed in $(os_build_index)" >&2; return 1; }
    for b in $builds; do
        os_use_build "$b"
        echo "build $b: $OS_IMAGE_URL"
        image_fetch && return 0
        echo "build $b is not usable, trying the build before it" >&2
    done
    os_use_build "${builds%%$'\n'*}"   # the report links the newest build
    return 1
}

free_port() {   # free_port: a free TCP port on 127.0.0.1
    local p
    while true; do
        p=$((20000 + RANDOM % 40000))
        ss -Htln "sport = :$p" 2>/dev/null | grep -q . || { echo "$p"; return; }
    done
}

make_keys() {   # throwaway keys for the operator (cloud-init user), the admin and the panel
    local k
    mkdir -p "$WORK/keys"
    for k in ops admin panel; do
        [[ -f "$WORK/keys/$k" ]] || ssh-keygen -q -t ed25519 -N '' -C "e2e-$k" -f "$WORK/keys/$k"
    done
}

# The seed is a virtio disk labelled cidata, not a CD-ROM: Debian 12's cloud kernel has no driver
# for the q35 CD-ROM controller, so cloud-init never found it there.
make_seed() {   # NoCloud seed: one sudo user "ops" with a key, like a provider's default account
    local d="$WORK/seed"
    mkdir -p "$d"
    cat > "$d/user-data" <<EOF
#cloud-config
hostname: $VM_HOSTNAME
users:
  - name: ops
    gecos: E2E operator
    groups: [sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys:
      - $(cat "$WORK/keys/ops.pub")
# Many providers leave password logins on. server-prep must turn them off.
ssh_pwauth: true
EOF
    printf 'instance-id: e2e-%s\nlocal-hostname: %s\n' "$VM_HOSTNAME" "$VM_HOSTNAME" > "$d/meta-data"
    xorriso -as mkisofs -quiet -output "$WORK/seed.iso" -volid cidata -joliet -rock \
        "$d/user-data" "$d/meta-data" 2>/dev/null
}

vm_accel() {   # kvm when /dev/kvm is usable, else tcg (slow but works anywhere)
    case "${E2E_ACCEL:-auto}" in
        kvm|tcg) echo "$E2E_ACCEL" ;;
        *) if [[ -r /dev/kvm && -w /dev/kvm ]]; then echo kvm; else echo tcg; fi ;;
    esac
}

vm_start() {   # boot a copy-on-write overlay of the cloud image
    local cpu fwd
    ACCEL="$(vm_accel)"
    [[ $ACCEL == kvm ]] && cpu=host || cpu=max
    P22="$(free_port)"; P822="$(free_port)"; PDOCK="$(free_port)"
    qemu-img create -q -f qcow2 -F qcow2 -b "$IMAGE" "$WORK/disk.qcow2" 20G || return 1
    fwd="hostfwd=tcp:127.0.0.1:$P22-:22,hostfwd=tcp:127.0.0.1:$P822-:822"
    fwd+=",hostfwd=tcp:127.0.0.1:$PDOCK-:$VM_DOCKER_PORT"
    qemu-system-x86_64 -name "e2e-$OS_ID" -machine "q35,accel=$ACCEL" -cpu "$cpu" \
        -smp "$CPUS" -m "$MEMORY_MB" \
        -drive "file=$WORK/disk.qcow2,if=virtio,format=qcow2,discard=unmap" \
        -drive "file=$WORK/seed.iso,if=virtio,format=raw,readonly=on" \
        -netdev "user,id=n0,net=$VM_NET,host=$VM_HOST_IP,dhcpstart=$VM_GUEST_IP,$fwd" \
        -device virtio-net-pci,netdev=n0 -device virtio-rng-pci \
        -display none -serial "file:$OUT/serial.log" \
        -pidfile "$WORK/qemu.pid" -daemonize
}

vm_running() { [[ -f "$WORK/qemu.pid" ]] && kill -0 "$(cat "$WORK/qemu.pid")" 2>/dev/null; }

vm_kill() {
    vm_running || return 0
    kill "$(cat "$WORK/qemu.pid")" 2>/dev/null
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do vm_running || return 0; sleep 1; done
    kill -9 "$(cat "$WORK/qemu.pid")" 2>/dev/null
    return 0
}

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
    -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=15
    -o ServerAliveInterval=15 -o ServerAliveCountMax=12)

# Every SSH call has a time limit (SSH_LIMIT seconds, 120 by default; long commands set more).
# Port 22 becomes the Endlessh tarpit: it accepts the connection and never answers.
ssh_as() {   # ssh_as USER KEY PORT COMMAND: one fresh login, like a person opening a terminal
    local user="$1" key="$2" port="$3"
    shift 3
    timeout -k 10 "${SSH_LIMIT:-120}" ssh "${SSH_OPTS[@]}" -i "$WORK/keys/$key" -p "$port" "$user@127.0.0.1" "$@"
}

# The privileged channel: the cloud user with sudo until server-prep runs, then root with
# the panel key on the new port, the way Coolify connects.
as_root() {   # as_root COMMAND (a shell string run by root in the VM)
    if [[ $CHANNEL == ops ]]; then
        ssh_as ops ops "$P22" "sudo bash -c $(printf '%q' "$1")"
    else
        ssh_as root panel "$P822" "$1"
    fi
}

use_new_port() {   # after a real run, act as root with the panel key on 822, like the panel
    SSH_LIMIT=30 ssh_as root panel "$P822" true 2>/dev/null || return 1
    CHANNEL=root
}

wait_ssh() {   # wait_ssh USER KEY PORT SECONDS
    local user="$1" key="$2" port="$3" deadline=$((SECONDS + $4))
    while ((SECONDS < deadline)); do
        SSH_LIMIT=30 ssh_as "$user" "$key" "$port" true 2>/dev/null && return 0
        sleep 3
    done
    return 1
}

copy_repo() {   # copy the working tree (tracked and new files, not ignored ones) to ~ops/server-prep
    (cd "$REPO_DIR" && git ls-files -z -co --exclude-standard | tar --null -T - -czf -) |
        ssh_as ops ops "$P22" 'rm -rf ~/server-prep && mkdir ~/server-prep && tar -xzf - -C ~/server-prep'
}

fetch_file() {   # fetch_file REMOTE_PATH LOCAL_NAME: copy a VM file (read as root) into $OUT
    as_root "cat $(printf '%q' "$1")" > "$OUT/$2" 2>/dev/null || { rm -f "$OUT/$2"; return 1; }
}

boot_id() { SSH_LIMIT=30 as_root 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null; }

vm_reboot() {   # vm_reboot SECONDS: reboot and wait for the privileged channel to answer again
    local before after deadline=$((SECONDS + $1))
    before="$(boot_id)"
    SSH_LIMIT=30 as_root 'systemctl reboot' >/dev/null 2>&1
    while ((SECONDS < deadline)); do
        sleep 5
        after="$(boot_id)" || continue
        [[ -n "$after" && "$after" != "$before" ]] && return 0
    done
    return 1
}
