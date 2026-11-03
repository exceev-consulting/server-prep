#!/usr/bin/env bash
# Tests server-prep.sh --upgrade against a fake release served by a fake curl. No network, no root,
# nothing outside a temporary folder changes.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0
ok()  { printf 'ok: %s\n' "$1"; }
bad() { printf 'not ok: %s\n' "$1"; fail=1; }

# A fake curl: the latest-release JSON, and the release files from $tmp/release.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
out="" url=""
while [[ $# -gt 0 ]]; do
    case $1 in
        -o) out=$2; shift 2 ;;
        -m|-H) shift 2 ;;
        http*) url=$1; shift ;;
        *) shift ;;
    esac
done
[[ -n ${FAKE_CURL_FAIL:-} ]] && exit 6
case $url in
    */releases/latest) cat "$FAKE_LATEST" ;;
    */releases/download/*)
        f="$FAKE_RELEASE/${url##*/}"
        [[ -f $f ]] || exit 22
        if [[ -n $out ]]; then cp "$f" "$out"; else cat "$f"; fi ;;
    *) exit 22 ;;
esac
EOF
chmod +x "$tmp/bin/curl"
export FAKE_LATEST="$tmp/latest.json" FAKE_RELEASE="$tmp/release"

new_install() {   # new_install: a v1.0.0 copy of the scripts in $tmp/install
    rm -rf "$tmp/install"
    mkdir -p "$tmp/install"
    sed 's/^PREP_VERSION=".*"/PREP_VERSION="1.0.0"/' "$SCRIPT_DIR/server-prep.sh" > "$tmp/install/server-prep.sh"
    printf '#!/usr/bin/env bash\necho old audit\n' > "$tmp/install/server-audit.sh"
    printf '#!/usr/bin/env bash\necho old preconfig\n' > "$tmp/install/server-preconfig.sh"
    printf '# old example\n' > "$tmp/install/server-prep.conf.example"
    chmod 755 "$tmp/install"/*.sh
    chmod 640 "$tmp/install/server-prep.conf.example"
}
new_release() {   # new_release: a v9.9.9 release with its SHA256SUMS
    rm -rf "$tmp/release"
    mkdir -p "$tmp/release"
    sed 's/^PREP_VERSION=".*"/PREP_VERSION="9.9.9"/' "$SCRIPT_DIR/server-prep.sh" > "$tmp/release/server-prep.sh"
    printf '#!/usr/bin/env bash\necho new audit\n' > "$tmp/release/server-audit.sh"
    printf '#!/usr/bin/env bash\necho new preconfig\n' > "$tmp/release/server-preconfig.sh"
    printf '# new example\n' > "$tmp/release/server-prep.conf.example"
    (cd "$tmp/release" && sha256sum -- * > SHA256SUMS)
    printf '{\n  "tag_name": "v9.9.9",\n  "name": "server-prep v9.9.9"\n}\n' > "$FAKE_LATEST"
}
upgrade() { PATH="$tmp/bin:$PATH" "$tmp/install/server-prep.sh" --upgrade "$@" > "$tmp/out" 2>&1; }
unchanged() { grep -q 'old audit' "$tmp/install/server-audit.sh" && grep -q '^PREP_VERSION="1.0.0"' "$tmp/install/server-prep.sh"; }

new_install; new_release
upgrade --yes; rc=$?
if [[ $rc == 0 ]] && grep -q 'new audit' "$tmp/install/server-audit.sh" && grep -q '^PREP_VERSION="9.9.9"' "$tmp/install/server-prep.sh" \
    && grep -q 'new example' "$tmp/install/server-prep.conf.example"; then
    ok "--upgrade --yes replaces every file of the release"
else bad "upgrade (rc $rc)"; cat "$tmp/out"; fi
[[ $(stat -c %a "$tmp/install/server-prep.sh") == 755 && $(stat -c %a "$tmp/install/server-prep.conf.example") == 640 ]] \
    && ok "file modes are kept" || bad "modes"
b=$(ls -d "$tmp/install/.server-prep-old/v1.0.0-"* 2>/dev/null | head -1)
[[ -n $b ]] && grep -q 'old audit' "$b/server-audit.sh" && grep -q '^PREP_VERSION="1.0.0"' "$b/server-prep.sh" \
    && ok "the old files are kept in .server-prep-old/v1.0.0-<date>" || bad "backup"
grep -q 'Upgraded to v9.9.9: 4 files replaced' "$tmp/out" && grep -q -- '--only <step>' "$tmp/out" \
    && ok "it says what changed and what to run next" || bad "messages"
ls "$tmp/install"/.*.upgrade >/dev/null 2>&1 && bad "temporary files left behind" || ok "no temporary file left behind"

new_install; new_release
upgrade --dry-run; unchanged && grep -q '\[dry-run\] nothing replaced' "$tmp/out" && ok "--dry-run checks but changes nothing" || bad "dry-run"

new_install; new_release
printf 'n\n' | PATH="$tmp/bin:$PATH" "$tmp/install/server-prep.sh" --upgrade > "$tmp/out" 2>&1
unchanged && grep -q 'Nothing changed' "$tmp/out" && ok "answering no changes nothing" || bad "answer no"

new_install; new_release
printf 'tampered\n' >> "$tmp/release/server-audit.sh"
upgrade --yes; rc=$?
[[ $rc == 1 ]] && unchanged && grep -q 'does not match' "$tmp/out" && ok "a file that does not match SHA256SUMS stops the upgrade" || bad "checksum (rc $rc)"

new_install; new_release
printf '%s  ../../evil.sh\n' "$(sha256sum < "$tmp/release/server-audit.sh" | cut -d' ' -f1)" >> "$tmp/release/SHA256SUMS"
cp "$tmp/release/server-audit.sh" "$tmp/release/evil.sh"
upgrade --yes; [[ ! -e "$tmp/evil.sh" && ! -e "$tmp/install/evil.sh" ]] && ok "only known file names are downloaded" || bad "unknown file name"

if [[ $EUID -ne 0 ]]; then   # root reads a mode 000 file anyway
    new_install; new_release
    chmod 000 "$tmp/install/server-preconfig.sh"
    upgrade --yes; rc=$?
    chmod 755 "$tmp/install/server-preconfig.sh"
    [[ $rc == 1 ]] && unchanged && grep -q 'Cannot back up server-preconfig.sh' "$tmp/out" \
        && ok "a backup that fails stops the upgrade" || bad "backup failure (rc $rc)"
else
    printf 'skip: backup failure (root can read every file)\n'
fi

new_install; new_release
printf 'if then fi\n' > "$tmp/release/server-preconfig.sh"
(cd "$tmp/release" && sha256sum -- server-prep.sh server-audit.sh server-preconfig.sh server-prep.conf.example > SHA256SUMS)
upgrade --yes; rc=$?
[[ $rc == 1 ]] && unchanged && grep -q 'does not parse' "$tmp/out" && ok "a script that does not parse stops the upgrade" || bad "syntax (rc $rc)"

new_install; new_release
grep -v '  server-prep.sh$' "$tmp/release/SHA256SUMS" > "$tmp/s" && mv "$tmp/s" "$tmp/release/SHA256SUMS"
upgrade --yes; rc=$?
[[ $rc == 1 ]] && unchanged && grep -q 'does not list server-prep.sh' "$tmp/out" && ok "a SHA256SUMS without server-prep.sh is refused" || bad "no server-prep.sh line"

new_install; new_release
printf '{"tag_name": "v1.0.0"}\n' > "$FAKE_LATEST"
upgrade --yes; [[ $? == 0 ]] && unchanged && grep -q 'is the latest release' "$tmp/out" && ok "up to date: nothing to do" || bad "up to date"

new_install; new_release
printf '{"tag_name": "nightly"}\n' > "$FAKE_LATEST"
upgrade --yes; [[ $? == 1 ]] && unchanged && ok "a release without a version is refused" || bad "bad tag"

new_install; new_release
FAKE_CURL_FAIL=1 upgrade --yes; [[ $? == 1 ]] && unchanged && grep -q 'Could not reach GitHub' "$tmp/out" && ok "no network: exit 1, nothing changed" || bad "no network"

new_install; new_release
mkdir "$tmp/install/.git"
upgrade --yes; [[ $? == 0 ]] && unchanged && grep -q 'git checkout' "$tmp/out" && ok "a git checkout is left to git pull" || bad "git checkout"

exit "$fail"
