#!/usr/bin/env bash
# Tests how the e2e harness picks and checks its cloud image (tests/e2e/lib/vm.sh): the dated
# Debian build folders of issue #212, and the fixed URLs of the other rows. A fake curl serves a
# fake image site. No network, no root, no VM.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0
ok()  { printf 'ok: %s\n' "$1"; }
bad() { printf 'not ok: %s\n' "$1"; fail=1; }

# The fake curl serves https://HOST/PATH from $FAKE_SITE/HOST/PATH (index.html for a folder),
# fails like curl -f on a missing file, and logs every URL it is asked for ("HEAD URL" for -I).
mkdir -p "$tmp/bin"
cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
out="" url="" head=""
while [[ $# -gt 0 ]]; do
    case $1 in
        -o) out=$2; shift 2 ;;
        --retry|--connect-timeout) shift 2 ;;
        --head|-[!-]*I*) head="HEAD "; shift ;;
        https://*) url=$1; shift ;;
        *) shift ;;
    esac
done
echo "$head$url" >> "$FAKE_LOG"
f="$FAKE_SITE/${url#https://}"
[[ $f == */ ]] && f+=index.html
[[ -f $f ]] || exit 22
[[ -n $head ]] && exit 0
if [[ -n $out ]]; then cp "$f" "$out"; else cat "$f"; fi
EOF
chmod +x "$tmp/bin/curl"
export FAKE_SITE="$tmp/site" FAKE_LOG="$tmp/curl.log"
export PATH="$tmp/bin:$PATH"

# The harness library, with a test images.tsv: one row with dated builds, one with a fixed URL.
E2E_DIR="$tmp/e2e" CACHE_DIR="$tmp/cache"
mkdir -p "$E2E_DIR"
{
    printf '# test rows\n'
    printf 'dated\tDated\thttps://images.example.com/os/{build}/os-amd64-{build}.qcow2\thttps://images.example.com/os/{build}/SHA512SUMS\tsha512\n'
    printf 'fixed\tFixed\thttps://images.example.com/fixed/release/os.img\thttps://images.example.com/fixed/release/SHA256SUMS\tsha256\n'
} > "$E2E_DIR/images.tsv"
# shellcheck source=tests/e2e/lib/vm.sh
. "$SCRIPT_DIR/tests/e2e/lib/vm.sh"
sleep() { :; }   # fetch waits between its tries
export -f sleep  # also in the run.sh --image-key child below

OSD="$FAKE_SITE/images.example.com/os"
INDEX=https://images.example.com/os/   # the build list of the dated row
reset_site() { rm -rf "$FAKE_SITE" "$CACHE_DIR" "$FAKE_LOG"; mkdir -p "$OSD"; }
site_build() {   # site_build BUILD: a complete build folder, its image and its SHA512SUMS
    mkdir -p "$OSD/$1"
    printf 'image %s\n' "$1" > "$OSD/$1/os-amd64-$1.qcow2"
    printf 'json %s\n' "$1" > "$OSD/$1/os-amd64-$1.json"
    (cd "$OSD/$1" && sha512sum -- *.json *.qcow2 > SHA512SUMS)
}
site_index() {   # site_index BUILD...: the build list in Apache's format (each folder linked twice)
    local b
    { echo '<html><body><table><tr><td><a href="../">Parent Directory</a></td></tr>'
      for b in "$@"; do
          printf '<tr><td><a href="%s/"><img src="/icons/folder.gif"></a></td><td><a href="%s/">%s/</a></td></tr>\n' "$b" "$b" "$b"
      done
      echo '<tr><td><a href="daily/">daily/</a></td></tr><tr><td><a href="latest/">latest/</a></td></tr></table></body></html>'
    } > "$OSD/index.html"
}
get() { os_load "$1" && image_get > "$tmp/out" 2>&1; }   # get ID: image_get for that row
sum512() { sha512sum "$1" | cut -d' ' -f1; }
fetched() { grep -c -- "$1" "$FAKE_LOG" 2>/dev/null; }   # fetched PATTERN: how many curl calls matched
show() { sed 's/^/    /' "$tmp/out"; }

# A fixed URL (Ubuntu's release/): no build list, the "<sum> *<name>" format.
reset_site
mkdir -p "$FAKE_SITE/images.example.com/fixed/release"
printf 'fixed image\n' > "$FAKE_SITE/images.example.com/fixed/release/os.img"
(cd "$FAKE_SITE/images.example.com/fixed/release" && sha256sum -b os.img > SHA256SUMS)
want="$(sha256sum "$FAKE_SITE/images.example.com/fixed/release/os.img" | cut -d' ' -f1)"
if get fixed && [[ $IMAGE_CHECKSUM == "sha256:$want" ]] && cmp -s "$IMAGE" "$FAKE_SITE/images.example.com/fixed/release/os.img" \
    && [[ $OS_IMAGE_URL == https://images.example.com/fixed/release/os.img ]] && [[ $(fetched '/os/$') == 0 ]]; then
    ok "a fixed URL is downloaded and checked as before, with no build list"
else bad "fixed URL"; show; fi

# Before a build is picked, a dated row names its build list, not a {build} URL: results.json
# links OS_IMAGE_URL even when the run stops before boot.
os_load dated
[[ $OS_IMAGE_URL == "$INDEX" && $OS_SUMS_URL == "$INDEX" ]] \
    && ok "os_load: a dated row's URLs name the build list until a build is picked" \
    || bad "os_load dated: $OS_IMAGE_URL $OS_SUMS_URL"

# Dated builds: the newest one, compared by date then build number.
reset_site
for b in 20261103-2651 20261111-999 20261111-1000 20250806-2196; do site_build "$b"; done
site_index 20250806-2196 20261103-2651 20261111-1000 20261111-999
if get dated && [[ $OS_IMAGE_URL == https://images.example.com/os/20261111-1000/os-amd64-20261111-1000.qcow2 ]] \
    && [[ $OS_SUMS_URL == https://images.example.com/os/20261111-1000/SHA512SUMS ]] \
    && [[ $IMAGE_CHECKSUM == "sha512:$(sum512 "$OSD/20261111-1000/os-amd64-20261111-1000.qcow2")" ]] \
    && cmp -s "$IMAGE" "$OSD/20261111-1000/os-amd64-20261111-1000.qcow2" && [[ $IMAGE == "$CACHE_DIR/images/dated.img" ]]; then
    ok "dated builds: the newest build is used, by date then build number"
else bad "newest build"; show; fi
grep -q 'build 20261111-1000: https://images.example.com/os/20261111-1000/os-amd64-20261111-1000.qcow2' "$tmp/out" \
    && ok "the boot log names the build and its image URL" || { bad "build in the log"; show; }
: > "$FAKE_LOG"
get dated && [[ $(fetched '\.qcow2$') == 0 ]] && ok "a cached image that matches the build is not downloaded again" \
    || { bad "cached image"; show; }

# Issue #212: the newest build's checksum file does not list the image yet.
reset_site
site_build 20261103-2651; site_build 20261111-2659
sed -i '/qcow2$/d' "$OSD/20261111-2659/SHA512SUMS"
site_index 20261103-2651 20261111-2659
if get dated && [[ $OS_IMAGE_URL == */20261103-2651/os-amd64-20261103-2651.qcow2 ]] \
    && cmp -s "$IMAGE" "$OSD/20261103-2651/os-amd64-20261103-2651.qcow2" \
    && grep -q 'no checksum for os-amd64-20261111-2659.qcow2' "$tmp/out" && grep -q 'build 20261111-2659 is not usable' "$tmp/out"; then
    ok "the newest build's checksum file lacks the image (#212): the build before it is used"
else bad "#212 fallback"; show; fi
os_load dated
image_resolve && [[ $OS_SUMS_URL == */20261103-2651/SHA512SUMS && $OS_IMAGE_URL == */os-amd64-20261103-2651.qcow2 ]] \
    && ok "image_resolve (--image-key) skips the build whose checksum file lacks the image" \
    || bad "image_resolve: $OS_SUMS_URL"

# The newest build lists the image, but the file is not there yet.
reset_site
site_build 20261103-2651; site_build 20261111-2659
rm "$OSD/20261111-2659/os-amd64-20261111-2659.qcow2"
site_index 20261103-2651 20261111-2659
if get dated && [[ $OS_IMAGE_URL == */20261103-2651/* ]] && grep -q 'cannot download .*20261111-2659' "$tmp/out" \
    && [[ -z $(find "$CACHE_DIR" -name '*.part') ]]; then
    ok "the newest build's image is missing: the build before it is used"
else bad "missing image"; show; fi
# The CI cache key must name that build too, or the older image is cached under the newer key.
: > "$FAKE_LOG"
os_load dated
image_resolve && [[ $OS_SUMS_URL == */20261103-2651/SHA512SUMS ]] && [[ $(fetched '^HEAD ') == 2 ]] \
    && [[ $(fetched '^https://.*\.qcow2$') == 0 ]] \
    && ok "image_resolve (--image-key) skips the build whose image is missing, with HEAD requests only" \
    || { bad "image_resolve, missing image: $OS_SUMS_URL"; cat "$FAKE_LOG"; }

# The newest build's image does not match its checksum (half copied).
reset_site
site_build 20261103-2651; site_build 20261111-2659
printf 'half\n' > "$OSD/20261111-2659/os-amd64-20261111-2659.qcow2"
site_index 20261103-2651 20261111-2659
if get dated && [[ $OS_IMAGE_URL == */20261103-2651/* ]] && grep -q 'checksum mismatch for os-amd64-20261111-2659.qcow2' "$tmp/out" \
    && cmp -s "$IMAGE" "$OSD/20261103-2651/os-amd64-20261103-2651.qcow2"; then
    ok "the newest build's image does not match its checksum: the build before it is used"
else bad "checksum mismatch"; show; fi

# The newest build's checksum file cannot be read.
reset_site
site_build 20261103-2651; site_build 20261111-2659
rm "$OSD/20261111-2659/SHA512SUMS"
site_index 20261103-2651 20261111-2659
get dated && [[ $OS_IMAGE_URL == */20261103-2651/* ]] && grep -q 'cannot read https://images.example.com/os/20261111-2659/SHA512SUMS' "$tmp/out" \
    && ok "the newest build's checksum file is missing: the build before it is used" || { bad "missing SHA512SUMS"; show; }

# No usable build: it fails, even with an old image in the cache, and tries BUILD_TRIES builds.
reset_site
for b in 20261001-2618 20261015-2632 20261103-2651 20261111-2659; do site_build "$b"; done
site_index 20261001-2618 20261015-2632 20261103-2651 20261111-2659
get dated || bad "setup: a first image in the cache"
for b in 20261001-2618 20261015-2632 20261103-2651 20261111-2659; do sed -i '/qcow2$/d' "$OSD/$b/SHA512SUMS"; done
: > "$FAKE_LOG"
if ! get dated && [[ -z $IMAGE_CHECKSUM ]] && [[ $OS_IMAGE_URL == */20261111-2659/os-amd64-20261111-2659.qcow2 ]]; then
    ok "no build lists the image: it fails, and the report links the newest build"
else bad "no usable build (checksum '$IMAGE_CHECKSUM', url $OS_IMAGE_URL)"; show; fi
[[ $(sort -u "$FAKE_LOG" | grep -c 'SHA512SUMS$') == "$BUILD_TRIES" ]] && [[ $(fetched '20261001-2618') == 0 ]] \
    && ok "it tries the $BUILD_TRIES newest builds, no more" || { bad "builds tried"; cat "$FAKE_LOG"; }

# The build list cannot be read, or lists no build: the report and the messages name the build
# list, never a URL with {build} in it.
reset_site
rm -f "$OSD/index.html"
if ! get dated && grep -q 'cannot read https://images.example.com/os/$' "$tmp/out" \
    && [[ $OS_IMAGE_URL == "$INDEX" && $OS_SUMS_URL == "$INDEX" ]]; then
    ok "the build list cannot be read: it fails, says which page, and the report links that page"
else bad "no build list (url $OS_IMAGE_URL)"; show; fi
os_load dated; os_use_build 20261111-2659   # left over from an earlier choice
if ! image_resolve 2> "$tmp/out" && grep -q 'cannot read https://images.example.com/os/$' "$tmp/out" \
    && [[ $OS_IMAGE_URL == "$INDEX" && $OS_SUMS_URL == "$INDEX" ]]; then
    ok "image_resolve: the build list cannot be read, it says which page"
else bad "image_resolve, no build list (url $OS_SUMS_URL)"; show; fi
site_index
if ! get dated && grep -q 'no build folder listed in https://images.example.com/os/$' "$tmp/out" \
    && [[ $OS_IMAGE_URL == "$INDEX" ]]; then
    ok "the build list holds no build: it fails and says so"
else bad "empty build list (url $OS_IMAGE_URL)"; show; fi

# The real images.tsv: {build} rows name it in both URLs, in the same folder, and run.sh --image-key
# works on them against a fake copy of the build list.
E2E_DIR="$SCRIPT_DIR/tests/e2e"
n=0
for id in $(os_list); do
    os_load "$id" || { bad "$id: os_load"; continue; }
    os_dated || continue
    n=$((n + 1))
    if [[ $OS_SUMS_TEMPLATE == *"$BUILD_TAG"* && ${OS_IMAGE_TEMPLATE%/*} == "${OS_SUMS_TEMPLATE%/*}" ]]; then
        ok "$id: {build} is in both URLs, in the same folder"
    else bad "$id: {build} URLs: $OS_IMAGE_TEMPLATE $OS_SUMS_TEMPLATE"; continue; fi
    reset_site
    index="$(os_build_index)"; index="$FAKE_SITE/${index#https://}"   # ends with /
    os_use_build 20261111-2659
    d="$FAKE_SITE/${OS_IMAGE_URL#https://}"; d="${d%/*}"
    mkdir -p "$d" "$index"
    printf 'image\n' > "$d/${OS_IMAGE_URL##*/}"
    (cd "$d" && sha512sum -- "${OS_IMAGE_URL##*/}" > SHA512SUMS)
    printf '<a href="20261111-2659/">20261111-2659/</a> <a href="latest/">latest/</a>\n' > "${index}index.html"
    key="$(E2E_CACHE="$tmp/key-cache" bash "$SCRIPT_DIR/tests/e2e/run.sh" --image-key --os "$id" 2>&1)"
    [[ $key == "$id-$(sum512 "$d/${OS_IMAGE_URL##*/}" | cut -c1-16)" ]] \
        && ok "$id: run.sh --image-key reads the newest build" || bad "$id: --image-key printed '$key'"
    rm "${index}index.html"
    key="$(E2E_CACHE="$tmp/key-cache" bash "$SCRIPT_DIR/tests/e2e/run.sh" --image-key --os "$id" 2>&1)" \
        && bad "$id: --image-key with no build list printed '$key'"
    [[ $key == "cannot read $(os_build_index)" ]] \
        && ok "$id: run.sh --image-key with no build list names that page" \
        || bad "$id: --image-key with no build list said '$key'"
done
((n > 0)) && ok "images.tsv has $n row(s) with dated builds" || bad "no {build} row in images.tsv"

exit "$fail"
